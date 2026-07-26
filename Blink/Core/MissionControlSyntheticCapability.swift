import Foundation

nonisolated final class MissionControlSyntheticCapability: @unchecked Sendable {
    private struct Failure: Equatable {
        let displayID: DisplayID
        let uptime: TimeInterval
    }

    private let lock = NSLock()
    private var failure: Failure?

    init(initialState: MissionControlSyntheticState = .available) {
        if initialState == .unavailableUntilOverlayExit {
            // Tests and recovery state created without a display cannot be
            // reopened by an unrelated observation.
            failure = Failure(
                displayID: DisplayID(rawValue: "unknown-display")!,
                uptime: ProcessInfo.processInfo.systemUptime
            )
        }
    }

    var state: MissionControlSyntheticState {
        lock.withLock {
            failure == nil ? .available : .unavailableUntilOverlayExit
        }
    }

    @discardableResult
    func markUnavailable(
        on displayID: DisplayID,
        at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        lock.withLock {
            let candidate = Failure(displayID: displayID, uptime: uptime)
            guard failure != candidate else { return false }
            failure = candidate
            return true
        }
    }

    @discardableResult
    func observeOverlay(
        _ mode: OverlayMode,
        on displayID: DisplayID,
        sampledAtUptime: TimeInterval
    ) -> Bool {
        guard mode == .none else { return false }
        return lock.withLock {
            guard
                let failure,
                failure.displayID == displayID,
                sampledAtUptime > failure.uptime
            else {
                return false
            }
            self.failure = nil
            return true
        }
    }
}
