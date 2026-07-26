import Foundation

actor OverlayModeSampler {
    typealias UptimeProvider = @Sendable () -> TimeInterval
    typealias Sleeper = @Sendable (TimeInterval) async throws -> Void

    private enum RefreshPurpose: Sendable {
        case confirmation(attempt: Int, settlesTransition: Bool)
        case boundary
        case renewal

        var priority: Int {
            switch self {
            case .boundary: 3
            case .confirmation: 2
            case .renewal: 1
            }
        }
    }

    private struct RefreshRequest: Sendable {
        let sequence: UInt64
        let generation: UInt64
        let lifecycle: UInt64
        let targetDisplayID: DisplayID?
        let evidenceToken: UInt64?
        let purpose: RefreshPurpose
    }

    private let displayLocator: any DisplayLocating
    private let detector: any OverlayDetecting
    private let freshnessPolicy: OverlayRoutingFreshnessPolicy
    private let uptime: UptimeProvider
    private let sleep: Sleeper
    private let scanQueue = DispatchQueue(
        label: "com.thekoppe.Blink.overlay-sampling"
    )

    private var samplingTask: Task<Void, Never>?
    private var pendingRequest: RefreshRequest?
    private var uncertaintyRetryTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var requestSequence: UInt64 = 0
    private var lifecycleSequence: UInt64 = 0
    private var retrySequence: UInt64 = 0
    private var renewalSequence: UInt64 = 0
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

        cancelScheduledWork()
        pendingRequest = nil
        acceptedGeneration = generation
        lifecycleSequence &+= 1
        isRunning = true
        self.onUpdate = onUpdate
        enqueueRefresh(
            generation: generation,
            targetDisplayID: nil,
            evidenceToken: nil,
            purpose: .confirmation(
                attempt: 0,
                settlesTransition: settlesTransition
            )
        )
    }

    /// Requests fresh evidence without invalidating a usable lease. Requests
    /// coalesce behind the one non-cancellable WindowServer scan in flight.
    func refresh(
        generation: UInt64,
        targetDisplayID: DisplayID,
        evidenceToken: UInt64? = nil,
        settlesTransition: Bool = false
    ) {
        guard isRunning, generation == acceptedGeneration else { return }
        enqueueRefresh(
            generation: generation,
            targetDisplayID: targetDisplayID,
            evidenceToken: evidenceToken,
            purpose: evidenceToken == nil
                ? .confirmation(attempt: 0, settlesTransition: settlesTransition)
                : .boundary
        )
    }

    func stop(generation: UInt64? = nil) async {
        let stoppedGeneration = generation ?? acceptedGeneration &+ 1
        guard stoppedGeneration >= acceptedGeneration else { return }

        acceptedGeneration = stoppedGeneration
        lifecycleSequence &+= 1
        isRunning = false
        onUpdate = nil
        pendingRequest = nil
        cancelScheduledWork()
        let pendingScan = samplingTask
        await pendingScan?.value
    }

    private func enqueueRefresh(
        generation: UInt64,
        targetDisplayID: DisplayID?,
        evidenceToken: UInt64?,
        purpose: RefreshPurpose
    ) {
        requestSequence &+= 1
        let request = RefreshRequest(
            sequence: requestSequence,
            generation: generation,
            lifecycle: lifecycleSequence,
            targetDisplayID: targetDisplayID,
            evidenceToken: evidenceToken,
            purpose: purpose
        )

        guard samplingTask == nil else {
            if pendingRequest == nil || purpose.priority >= pendingRequest!.purpose.priority {
                pendingRequest = request
            }
            return
        }
        beginScan(request)
    }

    private func beginScan(_ request: RefreshRequest) {
        let displayLocator = displayLocator
        let detector = detector
        let uptime = uptime
        let scanQueue = scanQueue
        samplingTask = Task { [weak self] in
            let observation: (DisplayID, OverlayMode, TimeInterval)? =
                await withCheckedContinuation { continuation in
                    scanQueue.async {
                        let displayID: DisplayID
                        if let target = request.targetDisplayID {
                            displayID = target
                        } else if let located = try? displayLocator.cursorDisplayID() {
                            displayID = located
                        } else {
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
            await self?.complete(observation, request: request)
        }
    }

    private func complete(
        _ observation: (DisplayID, OverlayMode, TimeInterval)?,
        request: RefreshRequest
    ) {
        samplingTask = nil
        let isCurrent = isRunning
            && request.generation == acceptedGeneration
            && request.lifecycle == lifecycleSequence
            && onUpdate != nil

        if isCurrent {
            if let (displayID, overlayMode, sampledAtUptime) = observation {
                cancelUncertaintyRetry()
                let lease = OverlayRoutingLease(
                    generation: request.generation,
                    targetDisplayID: displayID,
                    overlayMode: overlayMode,
                    sampledAtUptime: sampledAtUptime,
                    expirationUptime: freshnessPolicy.expirationUptime(
                        forSampleAt: sampledAtUptime
                    ),
                    requestSequence: request.sequence,
                    evidenceToken: request.evidenceToken
                )
                onUpdate?(lease)
                scheduleRenewal(
                    generation: request.generation,
                    lifecycle: request.lifecycle,
                    displayID: displayID,
                    sampledAtUptime: sampledAtUptime
                )
                if case .confirmation(let attempt, true) = request.purpose {
                    scheduleUncertaintyRetry(
                        afterAttempt: attempt,
                        settlesTransition: true,
                        generation: request.generation,
                        lifecycle: request.lifecycle,
                        displayID: displayID
                    )
                }
            } else {
                switch request.purpose {
                case .confirmation(let attempt, let settles):
                    scheduleUncertaintyRetry(
                        afterAttempt: attempt,
                        settlesTransition: settles,
                        generation: request.generation,
                        lifecycle: request.lifecycle,
                        displayID: request.targetDisplayID
                    )
                case .renewal:
                    scheduleUncertaintyRetry(
                        afterAttempt: 0,
                        settlesTransition: false,
                        generation: request.generation,
                        lifecycle: request.lifecycle,
                        displayID: request.targetDisplayID
                    )
                case .boundary:
                    break
                }
            }
        }

        if isRunning, let pendingRequest {
            self.pendingRequest = nil
            beginScan(pendingRequest)
        }
    }

    private func scheduleRenewal(
        generation: UInt64,
        lifecycle: UInt64,
        displayID: DisplayID,
        sampledAtUptime: TimeInterval
    ) {
        cancelRenewal()
        renewalSequence &+= 1
        let token = renewalSequence
        let renewalDeadline = sampledAtUptime + freshnessPolicy.leaseDuration * 0.8
        let delay = max(0, renewalDeadline - uptime())
        let sleep = sleep
        renewalTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.performRenewal(
                token: token,
                generation: generation,
                lifecycle: lifecycle,
                displayID: displayID
            )
        }
    }

    private func performRenewal(
        token: UInt64,
        generation: UInt64,
        lifecycle: UInt64,
        displayID: DisplayID
    ) {
        guard
            isRunning,
            token == renewalSequence,
            generation == acceptedGeneration,
            lifecycle == lifecycleSequence
        else {
            return
        }
        renewalTask = nil
        enqueueRefresh(
            generation: generation,
            targetDisplayID: displayID,
            evidenceToken: nil,
            purpose: .renewal
        )
    }

    private func scheduleUncertaintyRetry(
        afterAttempt attempt: Int,
        settlesTransition: Bool,
        generation: UInt64,
        lifecycle: UInt64,
        displayID: DisplayID?
    ) {
        guard freshnessPolicy.uncertaintyRetryDelays.indices.contains(attempt) else {
            return
        }
        cancelUncertaintyRetry()
        retrySequence &+= 1
        let token = retrySequence
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
                token: token,
                nextAttempt: attempt + 1,
                settlesTransition: settlesTransition,
                generation: generation,
                lifecycle: lifecycle,
                displayID: displayID
            )
        }
    }

    private func performUncertaintyRetry(
        token: UInt64,
        nextAttempt: Int,
        settlesTransition: Bool,
        generation: UInt64,
        lifecycle: UInt64,
        displayID: DisplayID?
    ) {
        guard
            isRunning,
            token == retrySequence,
            generation == acceptedGeneration,
            lifecycle == lifecycleSequence
        else {
            return
        }
        uncertaintyRetryTask = nil
        enqueueRefresh(
            generation: generation,
            targetDisplayID: displayID,
            evidenceToken: nil,
            purpose: .confirmation(
                attempt: nextAttempt,
                settlesTransition: settlesTransition
            )
        )
    }

    private func cancelScheduledWork() {
        cancelUncertaintyRetry()
        cancelRenewal()
    }

    private func cancelUncertaintyRetry() {
        retrySequence &+= 1
        uncertaintyRetryTask?.cancel()
        uncertaintyRetryTask = nil
    }

    private func cancelRenewal() {
        renewalSequence &+= 1
        renewalTask?.cancel()
        renewalTask = nil
    }
}
