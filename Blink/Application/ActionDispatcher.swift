import Foundation

@MainActor
final class ActionDispatcher {
    typealias RequestCapture = @MainActor (
        SpaceSwitchAction,
        SpaceInputSource
    ) -> SpaceSwitchRequest?
    typealias GestureRequestCapture = @MainActor (
        SpaceSwitchAction,
        GestureSessionContext
    ) -> SpaceSwitchRequest?
    typealias RequestSubmission = @MainActor @Sendable (
        SpaceSwitchRequest
    ) async -> SpaceSwitchOutcome
    typealias OutcomeDiagnosis = @MainActor @Sendable (
        SpaceSwitchRequest,
        SpaceSwitchOutcome
    ) async -> Void
    typealias LifecycleDiagnosis = @MainActor @Sendable (String) -> Void

    private struct QueuedRequest: Sendable {
        let sequence: UInt64
        let acceptedAtUptime: TimeInterval
        let request: SpaceSwitchRequest
    }

    private let captureRequest: RequestCapture
    private let captureGestureRequest: GestureRequestCapture
    private let diagnoseLifecycle: LifecycleDiagnosis
    private let continuation: AsyncStream<QueuedRequest>.Continuation
    private var consumerTask: Task<Void, Never>?
    private var nextSequence: UInt64 = 0

    convenience init(spaceSwitcher: SpaceSwitcher) {
        self.init(
            captureRequest: { [weak spaceSwitcher] action, source in
                spaceSwitcher?.makeRequest(action: action, source: source)
            },
            captureGestureRequest: { [weak spaceSwitcher] action, context in
                spaceSwitcher?.makeGestureRequest(action: action, context: context)
            },
            submitRequest: { [weak spaceSwitcher] request in
                guard let spaceSwitcher else { return .unavailable }
                return await spaceSwitcher.submit(request)
            },
            diagnoseOutcome: { request, outcome in
                DiagnosticsStore.shared.record(
                    "switch",
                    "rejected source=\(request.source.rawValue) "
                        + "display=\(request.targetDisplayID.rawValue) outcome=\(outcome)"
                )
            },
            diagnoseLifecycle: { message in
                Logger.switchTiming.info(message)
                DiagnosticsStore.shared.record("switch-timing", message)
            }
        )
    }

    init(
        captureRequest: @escaping RequestCapture,
        captureGestureRequest: GestureRequestCapture? = nil,
        submitRequest: @escaping RequestSubmission,
        diagnoseOutcome: @escaping OutcomeDiagnosis = { _, _ in },
        diagnoseLifecycle: @escaping LifecycleDiagnosis = { _ in }
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: QueuedRequest.self
        )
        self.captureRequest = captureRequest
        self.captureGestureRequest = captureGestureRequest ?? { action, context in
            guard
                context.isAuthoritativeBlinkContext,
                let request = captureRequest(action, .gesture),
                request.targetDisplayID == context.targetDisplayID
            else {
                return nil
            }
            return SpaceSwitchRequest(
                action: request.action,
                source: request.source,
                targetDisplayID: context.targetDisplayID,
                wraps: request.wraps,
                velocity: request.velocity,
                requiredMode: context.requiredPostingMode
            )
        }
        self.diagnoseLifecycle = diagnoseLifecycle
        self.continuation = continuation
        self.consumerTask = Task {
            for await queued in stream {
                guard !Task.isCancelled else { break }
                let dequeuedAt = ProcessInfo.processInfo.systemUptime
                diagnoseLifecycle(
                    "command dequeued sequence=\(queued.sequence) "
                        + "queue-ms=\(Self.milliseconds(from: queued.acceptedAtUptime, to: dequeuedAt))"
                )
                let request = queued.request
                let outcome = await submitRequest(request)
                guard
                    outcome != .accepted,
                    outcome != .missionControlSyntheticUnavailable
                else {
                    continue
                }
                await diagnoseOutcome(request, outcome)
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask?.cancel()
    }

    func dispatch(
        _ action: SpaceSwitchAction,
        gestureContext: GestureSessionContext
    ) {
        guard
            gestureContext.isAuthoritativeBlinkContext,
            let request = captureGestureRequest(
                action,
                gestureContext
            )
        else {
            Logger.actionDispatcher.warning(
                "Rejected gesture without an authoritative Blink context"
            )
            return
        }
        enqueue(request)
    }

    func dispatch(
        _ action: SpaceSwitchAction,
        source: SpaceInputSource
    ) {
        guard let request = captureRequest(action, source) else {
            Logger.actionDispatcher.warning(
                "Could not capture display context for \(source.rawValue) action"
            )
            return
        }
        enqueue(request)
    }

    private func enqueue(_ request: SpaceSwitchRequest) {
        nextSequence &+= 1
        let acceptedAt = ProcessInfo.processInfo.systemUptime
        diagnoseLifecycle(
            "input accepted sequence=\(nextSequence) source=\(request.source.rawValue) "
                + "display=\(request.targetDisplayID.rawValue) uptime=\(acceptedAt)"
        )
        continuation.yield(
            QueuedRequest(
                sequence: nextSequence,
                acceptedAtUptime: acceptedAt,
                request: request
            )
        )
    }

    private static func milliseconds(from start: TimeInterval, to end: TimeInterval) -> String {
        String(format: "%.3f", max(0, end - start) * 1_000)
    }

    func shutdown() async {
        continuation.finish()
        consumerTask?.cancel()
        await consumerTask?.value
        consumerTask = nil
    }
}

extension Logger {
    fileprivate static let actionDispatcher = Logger(category: "ActionDispatcher")
    fileprivate static let switchTiming = Logger(category: "SwitchTiming")
}
