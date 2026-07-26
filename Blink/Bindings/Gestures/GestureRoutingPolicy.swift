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
    // Dock, Space, wake, session, and display events are the primary source of
    // invalidation. This 30-second lease only bounds uncertainty if one of those
    // events is missed. Renewal five seconds before expiry leaves time for a
    // mayBegin retry without returning to continuous window enumeration.
    static let standard = OverlayRoutingFreshnessPolicy(
        leaseDuration: 30,
        safetyRenewalLeadTime: 5,
        uncertaintyRetryDelays: [0.2, 0.6]
    )

    let leaseDuration: TimeInterval
    let safetyRenewalLeadTime: TimeInterval
    // A transition sample can legitimately land inside Dock animation. These
    // two event-bound retries settle that uncertainty without creating an idle
    // polling loop.
    let uncertaintyRetryDelays: [TimeInterval]

    init(
        leaseDuration: TimeInterval,
        safetyRenewalLeadTime: TimeInterval,
        uncertaintyRetryDelays: [TimeInterval] = [0.2, 0.6]
    ) {
        precondition(leaseDuration > 0)
        precondition(safetyRenewalLeadTime > 0)
        precondition(safetyRenewalLeadTime < leaseDuration)
        precondition(uncertaintyRetryDelays.allSatisfy { $0 > 0 })
        self.leaseDuration = leaseDuration
        self.safetyRenewalLeadTime = safetyRenewalLeadTime
        self.uncertaintyRetryDelays = uncertaintyRetryDelays
    }

    func expirationUptime(forSampleAt sampleUptime: TimeInterval) -> TimeInterval {
        sampleUptime + leaseDuration
    }

    func safetyRenewalDelay(
        for lease: OverlayRoutingLease,
        at uptime: TimeInterval
    ) -> TimeInterval {
        max(0, lease.expirationUptime - safetyRenewalLeadTime - uptime)
    }

    func shouldRenewOpportunistically(
        _ lease: OverlayRoutingLease,
        at uptime: TimeInterval
    ) -> Bool {
        safetyRenewalDelay(for: lease, at: uptime) == 0
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
        let isValid = isValid(
            at: uptime,
            requiredGeneration: requiredGeneration,
            currentTargetDisplayID: currentDisplayID
        )
        let selectedRoute = route(
            at: uptime,
            requiredGeneration: requiredGeneration,
            currentTargetDisplayID: currentDisplayID,
            missionControlSyntheticState: missionControlSyntheticState
        )
        let capturedMode = isValid ? overlayMode : .unknown
        let postingMode: SpaceSwitchMode? =
            if selectedRoute == .blink {
                switch capturedMode {
                case .none: .instant
                case .missionControl: .missionControl
                case .appExpose, .unknown: nil
                }
            } else {
                nil
            }

        return GestureSessionContext(
            generation: sessionGeneration,
            route: postingMode == nil && selectedRoute == .blink ? .system : selectedRoute,
            targetDisplayID: currentDisplayID,
            capturedOverlayMode: capturedMode,
            missionControlSyntheticState: missionControlSyntheticState,
            requiredPostingMode: postingMode
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
        currentDisplayID: DisplayID,
        at uptime: TimeInterval,
        missionControlSyntheticState: MissionControlSyntheticState
    ) -> GestureSessionContext {
        guard let lease else {
            return .system(
                generation: sessionGeneration,
                targetDisplayID: currentDisplayID,
                missionControlSyntheticState: missionControlSyntheticState
            )
        }
        return lease.makeContext(
            sessionGeneration: sessionGeneration,
            requiredGeneration: generation,
            currentDisplayID: currentDisplayID,
            at: uptime,
            missionControlSyntheticState: missionControlSyntheticState
        )
    }
}

actor OverlayModeSampler {
    typealias UptimeProvider = @Sendable () -> TimeInterval
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private enum RefreshPurpose: Sendable {
        case confirmation(attempt: Int)
        case opportunistic
        case forced
        case safetyRenewal
    }

    private let displayLocator: any DisplayLocating
    private let detector: any OverlayDetecting
    private let freshnessPolicy: OverlayRoutingFreshnessPolicy
    private let uptime: UptimeProvider
    private let sleep: Sleeper

    private var samplingTask: Task<Void, Never>?
    private var safetyRenewalTask: Task<Void, Never>?
    private var uncertaintyRetryTask: Task<Void, Never>?
    private var requestSequence: UInt64 = 0
    private var lifecycleSequence: UInt64 = 0
    private var renewalSequence: UInt64 = 0
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

    init() {
        let displayLocator = DisplayLocator()
        self.displayLocator = displayLocator
        self.detector = CoreGraphicsOverlayDetector(displayLocator: displayLocator)
        self.freshnessPolicy = .standard
        self.uptime = { ProcessInfo.processInfo.systemUptime }
        self.sleep = { delay in
            try await Task<Never, Never>.sleep(for: .seconds(delay))
        }
    }

    func start(
        generation: UInt64,
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
            purpose: .confirmation(attempt: 0)
        )
    }

    func stop(generation: UInt64? = nil) {
        let stoppedGeneration = generation ?? acceptedGeneration &+ 1
        guard stoppedGeneration >= acceptedGeneration else { return }

        acceptedGeneration = stoppedGeneration
        lifecycleSequence &+= 1
        isRunning = false
        onUpdate = nil
        cancelAllWork()
    }

    func invalidate(generation: UInt64) {
        guard generation >= acceptedGeneration else { return }
        acceptedGeneration = generation
        requestSequence &+= 1
        samplingTask?.cancel()
        samplingTask = nil
        cancelSafetyRenewal()
        cancelUncertaintyRetry()
    }

    func refresh(generation: UInt64) {
        guard canRefresh(generation: generation) else { return }
        beginRefresh(generation: generation, purpose: .forced)
    }

    func opportunisticRefresh(generation: UInt64) {
        guard
            canRefresh(generation: generation),
            samplingTask == nil
        else {
            return
        }
        beginRefresh(generation: generation, purpose: .opportunistic)
    }

    private func canRefresh(generation: UInt64) -> Bool {
        isRunning
            && onUpdate != nil
            && generation == acceptedGeneration
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
        samplingTask = Task { [weak self] in
            let observation = await Task.detached {
                guard let displayID = try? displayLocator.cursorDisplayID() else {
                    return nil as (DisplayID, OverlayMode, TimeInterval)?
                }
                let mode = detector.detect(on: displayID)
                guard mode != .unknown else { return nil }
                return (displayID, mode, uptime())
            }.value
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
            if case .confirmation(let attempt) = purpose {
                scheduleUncertaintyRetry(
                    afterFailedAttempt: attempt,
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
        scheduleSafetyRenewal(for: lease, lifecycle: lifecycle)
        if overlayMode == .appExpose,
            case .confirmation(let attempt) = purpose
        {
            scheduleUncertaintyRetry(
                afterFailedAttempt: attempt,
                generation: generation,
                lifecycle: lifecycle
            )
        }
    }

    private func scheduleSafetyRenewal(
        for lease: OverlayRoutingLease,
        lifecycle: UInt64
    ) {
        cancelSafetyRenewal()
        renewalSequence &+= 1
        let renewal = renewalSequence
        let delay = freshnessPolicy.safetyRenewalDelay(
            for: lease,
            at: uptime()
        )
        let sleep = sleep
        safetyRenewalTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.performSafetyRenewal(
                generation: lease.generation,
                lifecycle: lifecycle,
                renewal: renewal
            )
        }
    }

    private func performSafetyRenewal(
        generation: UInt64,
        lifecycle: UInt64,
        renewal: UInt64
    ) {
        guard
            isRunning,
            generation == acceptedGeneration,
            lifecycle == lifecycleSequence,
            renewal == renewalSequence
        else {
            return
        }
        safetyRenewalTask = nil
        beginRefresh(generation: generation, purpose: .safetyRenewal)
    }

    private func scheduleUncertaintyRetry(
        afterFailedAttempt attempt: Int,
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
                generation: generation,
                lifecycle: lifecycle,
                retry: retry
            )
        }
    }

    private func performUncertaintyRetry(
        nextAttempt: Int,
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
                generation: generation,
                lifecycle: lifecycle
            )
            return
        }
        beginRefresh(
            generation: generation,
            purpose: .confirmation(attempt: nextAttempt)
        )
    }

    private func cancelAllWork() {
        requestSequence &+= 1
        samplingTask?.cancel()
        samplingTask = nil
        cancelSafetyRenewal()
        cancelUncertaintyRetry()
    }

    private func cancelSafetyRenewal() {
        renewalSequence &+= 1
        safetyRenewalTask?.cancel()
        safetyRenewalTask = nil
    }

    private func cancelUncertaintyRetry() {
        uncertaintyRetrySequence &+= 1
        uncertaintyRetryTask?.cancel()
        uncertaintyRetryTask = nil
    }
}
