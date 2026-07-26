import Foundation

nonisolated final class MissionControlSyntheticCapability: @unchecked Sendable {
    static let confirmedNonmovementThreshold = 2

    private struct DisplayState {
        var consecutiveConfirmedNonmovement = 0
        var lastConfirmedNonmovementUptime: TimeInterval?
        var openedAtUptime: TimeInterval?
    }

    private let lock = NSLock()
    private var states: [DisplayID: DisplayState] = [:]

    func state(on displayID: DisplayID) -> MissionControlSyntheticState {
        lock.withLock {
            states[displayID]?.openedAtUptime == nil
                ? .available : .unavailableUntilOverlayExit
        }
    }

    @discardableResult
    func recordPostRejection(
        on displayID: DisplayID,
        at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        lock.withLock {
            var state = states[displayID] ?? DisplayState()
            guard state.openedAtUptime == nil else { return false }
            state.openedAtUptime = uptime
            states[displayID] = state
            return true
        }
    }

    @discardableResult
    func recordConfirmedNonmovement(
        on displayID: DisplayID,
        at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> Bool {
        lock.withLock {
            var state = states[displayID] ?? DisplayState()
            guard state.openedAtUptime == nil else { return false }
            state.consecutiveConfirmedNonmovement += 1
            state.lastConfirmedNonmovementUptime = uptime
            if state.consecutiveConfirmedNonmovement >= Self.confirmedNonmovementThreshold {
                state.openedAtUptime = uptime
            }
            states[displayID] = state
            return state.openedAtUptime != nil
        }
    }

    func recordAuthoritativeAcknowledgement(on displayID: DisplayID) {
        lock.withLock {
            guard var state = states[displayID], state.openedAtUptime == nil else { return }
            state.consecutiveConfirmedNonmovement = 0
            state.lastConfirmedNonmovementUptime = nil
            states[displayID] = state
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
            guard var state = states[displayID] else { return false }
            let failureUptime = state.openedAtUptime
                ?? state.lastConfirmedNonmovementUptime
            guard let failureUptime, sampledAtUptime > failureUptime else { return false }
            let recoveredCircuit = state.openedAtUptime != nil
            state.openedAtUptime = nil
            state.consecutiveConfirmedNonmovement = 0
            state.lastConfirmedNonmovementUptime = nil
            states[displayID] = state
            return recoveredCircuit
        }
    }
}
