import Foundation

nonisolated enum GestureRoute: String, Equatable, Sendable {
    case blink
    case system
}

nonisolated struct GestureSessionContext: Equatable, Sendable {
    let generation: UInt64
    let route: GestureRoute
    let targetDisplayID: DisplayID
    let capturedOverlayMode: OverlayMode
    let missionControlSyntheticState: MissionControlSyntheticState
    let requiredPostingMode: SpaceSwitchMode?

    var isAuthoritativeBlinkContext: Bool {
        guard route == .blink else { return false }
        switch (capturedOverlayMode, requiredPostingMode) {
        case (.none, .instant), (.missionControl, .missionControl):
            return missionControlSyntheticState == .available
                || requiredPostingMode == .instant
        default:
            return false
        }
    }

    func isValidForDispatch(
        currentDisplayID: DisplayID?,
        currentMissionControlSyntheticState: MissionControlSyntheticState
    ) -> Bool {
        guard
            isAuthoritativeBlinkContext,
            currentDisplayID == targetDisplayID
        else {
            return false
        }
        return requiredPostingMode != .missionControl
            || currentMissionControlSyntheticState == .available
    }

    static func observed(
        generation: UInt64,
        targetDisplayID: DisplayID,
        overlayMode: OverlayMode,
        missionControlSyntheticState: MissionControlSyntheticState
    ) -> GestureSessionContext {
        let postingMode: SpaceSwitchMode? =
            switch overlayMode {
            case .none:
                .instant
            case .missionControl where missionControlSyntheticState == .available:
                .missionControl
            case .missionControl, .appExpose, .unknown:
                nil
            }
        return GestureSessionContext(
            generation: generation,
            route: postingMode == nil ? .system : .blink,
            targetDisplayID: targetDisplayID,
            capturedOverlayMode: overlayMode,
            missionControlSyntheticState: missionControlSyntheticState,
            requiredPostingMode: postingMode
        )
    }

    static func system(
        generation: UInt64,
        targetDisplayID: DisplayID,
        missionControlSyntheticState: MissionControlSyntheticState
    ) -> GestureSessionContext {
        GestureSessionContext(
            generation: generation,
            route: .system,
            targetDisplayID: targetDisplayID,
            capturedOverlayMode: .unknown,
            missionControlSyntheticState: missionControlSyntheticState,
            requiredPostingMode: nil
        )
    }
}

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

actor OverlayModeSampler {
    typealias UptimeProvider = @Sendable () -> TimeInterval
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private enum RefreshPurpose: Sendable {
        case confirmation(attempt: Int, settlesTransition: Bool)
    }

    private let displayLocator: any DisplayLocating
    private let detector: any OverlayDetecting
    private let freshnessPolicy: OverlayRoutingFreshnessPolicy
    private let uptime: UptimeProvider
    private let sleep: Sleeper
    /// WindowServer enumeration is synchronous and cannot be cancelled once it
    /// starts. A dedicated serial queue makes cancellation meaningful for
    /// delivery while guaranteeing that invalidation never overlaps scans.
    private let scanQueue = DispatchQueue(
        label: "com.thekoppe.Blink.overlay-sampling"
    )

    private var samplingTask: Task<Void, Never>?
    private var uncertaintyRetryTask: Task<Void, Never>?
    private var requestSequence: UInt64 = 0
    private var lifecycleSequence: UInt64 = 0
    private var uncertaintyRetrySequence: UInt64 = 0
    private var acceptedGeneration: UInt64 = 0
    private var isRunning = false
    private var onUpdate: (@Sendable (OverlayRoutingLease) -> Void)?

    init(
        displayLocator: any DisplayLocating,
        detector: any OverlayDetecting,
        freshnessPolicy: OverlayRoutingFreshnessPolicy = .standard,
        uptime: @escaping UptimeProvider = {
            ProcessInfo.processInfo.systemUptime
        },
        sleep: @escaping Sleeper = { delay in
            try await Task<Never, Never>.sleep(for: .seconds(delay))
        }
    ) {
        self.displayLocator = displayLocator
        self.detector = detector
        self.freshnessPolicy = freshnessPolicy
        self.uptime = uptime
        self.sleep = sleep
    }

    func start(
        generation: UInt64,
        settlesTransition: Bool = false,
        onUpdate: @escaping @Sendable (OverlayRoutingLease) -> Void
    ) {
        if isRunning, generation == acceptedGeneration {
            return
        }
        guard generation > acceptedGeneration else { return }

        cancelAllWork()
        acceptedGeneration = generation
        lifecycleSequence &+= 1
        isRunning = true
        self.onUpdate = onUpdate
        beginRefresh(
            generation: generation,
            purpose: .confirmation(
                attempt: 0,
                settlesTransition: settlesTransition
            )
        )
    }

    func stop(generation: UInt64? = nil) async {
        let stoppedGeneration = generation ?? acceptedGeneration &+ 1
        guard stoppedGeneration >= acceptedGeneration else { return }

        acceptedGeneration = stoppedGeneration
        lifecycleSequence &+= 1
        isRunning = false
        onUpdate = nil
        let pendingScan = samplingTask
        cancelAllWork()
        // Enumeration itself is synchronous, so cancellation suppresses stale
        // delivery and shutdown waits for the serial scan to actually finish.
        await pendingScan?.value
    }

    private func beginRefresh(
        generation: UInt64,
        purpose: RefreshPurpose
    ) {
        requestSequence &+= 1
        let sequence = requestSequence
        let lifecycle = lifecycleSequence
        samplingTask?.cancel()

        let displayLocator = displayLocator
        let detector = detector
        let uptime = uptime
        let scanQueue = scanQueue
        samplingTask = Task { [weak self] in
            let observation: (DisplayID, OverlayMode, TimeInterval)? =
                await withCheckedContinuation { continuation in
                    scanQueue.async {
                        guard let displayID = try? displayLocator.cursorDisplayID() else {
                            continuation.resume(returning: nil)
                            return
                        }
                        let sampledAtUptime = uptime()
                        let mode = detector.detect(on: displayID)
                        guard mode != .unknown else {
                            continuation.resume(returning: nil)
                            return
                        }
                        continuation.resume(
                            returning: (displayID, mode, sampledAtUptime)
                        )
                    }
                }
            guard !Task.isCancelled else { return }
            await self?.complete(
                observation,
                sequence: sequence,
                generation: generation,
                lifecycle: lifecycle,
                purpose: purpose
            )
        }
    }

    private func complete(
        _ observation: (DisplayID, OverlayMode, TimeInterval)?,
        sequence: UInt64,
        generation: UInt64,
        lifecycle: UInt64,
        purpose: RefreshPurpose
    ) {
        guard
            isRunning,
            sequence == requestSequence,
            generation == acceptedGeneration,
            lifecycle == lifecycleSequence,
            onUpdate != nil
        else {
            return
        }

        samplingTask = nil
        guard let (displayID, overlayMode, sampledAtUptime) = observation else {
            switch purpose {
            case .confirmation(let attempt, let settlesTransition):
                scheduleUncertaintyRetry(
                    afterFailedAttempt: attempt,
                    settlesTransition: settlesTransition,
                    generation: generation,
                    lifecycle: lifecycle
                )
            }
            return
        }

        cancelUncertaintyRetry()
        let lease = OverlayRoutingLease(
            generation: generation,
            targetDisplayID: displayID,
            overlayMode: overlayMode,
            sampledAtUptime: sampledAtUptime,
            expirationUptime: freshnessPolicy.expirationUptime(
                forSampleAt: sampledAtUptime
            ),
            requestSequence: sequence
        )
        onUpdate?(lease)
        if case .confirmation(let attempt, true) = purpose {
            scheduleUncertaintyRetry(
                afterFailedAttempt: attempt,
                settlesTransition: true,
                generation: generation,
                lifecycle: lifecycle
            )
        }
    }

    private func scheduleUncertaintyRetry(
        afterFailedAttempt attempt: Int,
        settlesTransition: Bool,
        generation: UInt64,
        lifecycle: UInt64
    ) {
        guard freshnessPolicy.uncertaintyRetryDelays.indices.contains(attempt) else {
            return
        }
        cancelUncertaintyRetry()
        uncertaintyRetrySequence &+= 1
        let retry = uncertaintyRetrySequence
        let delay = freshnessPolicy.uncertaintyRetryDelays[attempt]
        let sleep = sleep
        uncertaintyRetryTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.performUncertaintyRetry(
                nextAttempt: attempt + 1,
                settlesTransition: settlesTransition,
                generation: generation,
                lifecycle: lifecycle,
                retry: retry
            )
        }
    }

    private func performUncertaintyRetry(
        nextAttempt: Int,
        settlesTransition: Bool,
        generation: UInt64,
        lifecycle: UInt64,
        retry: UInt64
    ) {
        guard
            isRunning,
            generation == acceptedGeneration,
            lifecycle == lifecycleSequence,
            retry == uncertaintyRetrySequence
        else {
            return
        }
        uncertaintyRetryTask = nil
        guard samplingTask == nil else {
            scheduleUncertaintyRetry(
                afterFailedAttempt: nextAttempt - 1,
                settlesTransition: settlesTransition,
                generation: generation,
                lifecycle: lifecycle
            )
            return
        }
        beginRefresh(
            generation: generation,
            purpose: .confirmation(
                attempt: nextAttempt,
                settlesTransition: settlesTransition
            )
        )
    }

    private func cancelAllWork() {
        requestSequence &+= 1
        samplingTask?.cancel()
        samplingTask = nil
        cancelUncertaintyRetry()
    }

    private func cancelUncertaintyRetry() {
        uncertaintyRetrySequence &+= 1
        uncertaintyRetryTask?.cancel()
        uncertaintyRetryTask = nil
    }
}
