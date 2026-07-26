import Foundation

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
