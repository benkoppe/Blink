import Foundation

@MainActor
final class ActionDispatcher {
    typealias RequestCapture = @MainActor (
        SpaceSwitchAction,
        SpaceInputSource
    ) -> SpaceSwitchRequest?
    typealias RequestSubmission = @MainActor @Sendable (
        SpaceSwitchRequest
    ) async -> SpaceSwitchOutcome
    typealias OutcomeDiagnosis = @MainActor @Sendable (
        SpaceSwitchRequest,
        SpaceSwitchOutcome
    ) async -> Void

    private let captureRequest: RequestCapture
    private let continuation: AsyncStream<SpaceSwitchRequest>.Continuation
    private var consumerTask: Task<Void, Never>?

    convenience init(spaceSwitcher: SpaceSwitcher) {
        self.init(
            captureRequest: { [weak spaceSwitcher] action, source in
                spaceSwitcher?.makeRequest(action: action, source: source)
            },
            submitRequest: { [weak spaceSwitcher] request in
                guard let spaceSwitcher else { return .unavailable }
                return await spaceSwitcher.submit(request)
            },
            diagnoseOutcome: { request, outcome in
                await DiagnosticsStore.shared.record(
                    "switch",
                    "rejected source=\(request.source.rawValue) "
                        + "display=\(request.targetDisplayID.rawValue) outcome=\(outcome)"
                )
            }
        )
    }

    init(
        captureRequest: @escaping RequestCapture,
        submitRequest: @escaping RequestSubmission,
        diagnoseOutcome: @escaping OutcomeDiagnosis = { _, _ in }
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: SpaceSwitchRequest.self
        )
        self.captureRequest = captureRequest
        self.continuation = continuation
        self.consumerTask = Task {
            for await request in stream {
                guard !Task.isCancelled else { break }
                let outcome = await submitRequest(request)
                guard outcome != .accepted else { continue }
                await diagnoseOutcome(request, outcome)
            }
        }
    }

    deinit {
        continuation.finish()
        consumerTask?.cancel()
    }

    func dispatch(
        _ action: BoundAction,
        source: SpaceInputSource
    ) {
        dispatch(action.spaceSwitchAction, source: source)
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
        continuation.yield(request)
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
}
