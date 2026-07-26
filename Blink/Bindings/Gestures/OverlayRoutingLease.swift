import Foundation

nonisolated struct OverlayRoutingFreshnessPolicy: Equatable, Sendable {
    static let standard = OverlayRoutingFreshnessPolicy(
        leaseDuration: 30,
        uncertaintyRetryDelays: [0.2, 0.6]
    )

    let leaseDuration: TimeInterval
    // A transition sample can legitimately land inside Dock animation. These
    // event-bound retries settle that uncertainty without idle polling.
    let uncertaintyRetryDelays: [TimeInterval]

    init(
        leaseDuration: TimeInterval,
        uncertaintyRetryDelays: [TimeInterval] = [0.2, 0.6]
    ) {
        precondition(leaseDuration > 0)
        precondition(uncertaintyRetryDelays.allSatisfy { $0 > 0 })
        self.leaseDuration = leaseDuration
        self.uncertaintyRetryDelays = uncertaintyRetryDelays
    }

    func expirationUptime(forSampleAt sampleUptime: TimeInterval) -> TimeInterval {
        sampleUptime + leaseDuration
    }
}

nonisolated struct OverlayRoutingLease: Equatable, Sendable {
    let generation: UInt64
    let targetDisplayID: DisplayID
    let overlayMode: OverlayMode
    let sampledAtUptime: TimeInterval
    let expirationUptime: TimeInterval
    let requestSequence: UInt64

    func isValid(
        at uptime: TimeInterval,
        requiredGeneration: UInt64,
        currentTargetDisplayID: DisplayID
    ) -> Bool {
        generation == requiredGeneration
            && targetDisplayID == currentTargetDisplayID
            && overlayMode != .unknown
            && uptime >= sampledAtUptime
            && uptime < expirationUptime
    }

    func route(
        at uptime: TimeInterval,
        requiredGeneration: UInt64,
        currentTargetDisplayID: DisplayID,
        missionControlSyntheticState: MissionControlSyntheticState = .available
    ) -> GestureRoute {
        guard isValid(
            at: uptime,
            requiredGeneration: requiredGeneration,
            currentTargetDisplayID: currentTargetDisplayID
        ) else {
            return .system
        }

        switch overlayMode {
        case .none:
            return .blink
        case .missionControl:
            return missionControlSyntheticState == .available ? .blink : .system
        case .appExpose, .unknown:
            return .system
        }
    }

    func makeContext(
        sessionGeneration: UInt64,
        requiredGeneration: UInt64,
        currentDisplayID: DisplayID,
        at uptime: TimeInterval,
        missionControlSyntheticState: MissionControlSyntheticState
    ) -> GestureSessionContext {
        guard isValid(
            at: uptime,
            requiredGeneration: requiredGeneration,
            currentTargetDisplayID: currentDisplayID
        ) else {
            return .system(
                generation: sessionGeneration,
                targetDisplayID: currentDisplayID,
                missionControlSyntheticState: missionControlSyntheticState
            )
        }
        return .observed(
            generation: sessionGeneration,
            targetDisplayID: currentDisplayID,
            overlayMode: overlayMode,
            missionControlSyntheticState: missionControlSyntheticState
        )
    }
}

nonisolated struct OverlayRoutingLeaseState: Equatable, Sendable {
    private(set) var generation: UInt64 = 0
    private(set) var lease: OverlayRoutingLease?
    private(set) var acceptedRequestSequence: UInt64 = 0

    @discardableResult
    mutating func invalidate() -> UInt64 {
        generation &+= 1
        lease = nil
        acceptedRequestSequence = 0
        return generation
    }

    @discardableResult
    mutating func accept(_ candidate: OverlayRoutingLease) -> Bool {
        guard
            candidate.generation == generation,
            candidate.overlayMode != .unknown,
            candidate.requestSequence > acceptedRequestSequence
        else {
            return false
        }

        lease = candidate
        acceptedRequestSequence = candidate.requestSequence
        return true
    }

    func makeContext(
        sessionGeneration: UInt64,
        at uptime: TimeInterval,
        missionControlSyntheticState: MissionControlSyntheticState
    ) -> GestureSessionContext? {
        guard let lease else { return nil }
        return lease.makeContext(
            sessionGeneration: sessionGeneration,
            requiredGeneration: generation,
            currentDisplayID: lease.targetDisplayID,
            at: uptime,
            missionControlSyntheticState: missionControlSyntheticState
        )
    }
}
