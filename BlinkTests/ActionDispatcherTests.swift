import Foundation
import Testing

@testable import Blink

private actor DispatcherSubmissionProbe {
    private var storedRequests: [SpaceSwitchRequest] = []
    private var outcomes: [SpaceSwitchOutcome]
    private var gatesFirstSubmission: Bool
    private var firstSubmissionContinuation: CheckedContinuation<Void, Never>?

    init(
        outcomes: [SpaceSwitchOutcome] = [],
        gatesFirstSubmission: Bool = false
    ) {
        self.outcomes = outcomes
        self.gatesFirstSubmission = gatesFirstSubmission
    }

    var requests: [SpaceSwitchRequest] { storedRequests }

    func submit(_ request: SpaceSwitchRequest) async -> SpaceSwitchOutcome {
        storedRequests.append(request)
        let index = storedRequests.count - 1
        if index == 0, gatesFirstSubmission {
            await withCheckedContinuation { continuation in
                firstSubmissionContinuation = continuation
            }
        }
        return outcomes.indices.contains(index) ? outcomes[index] : .accepted
    }

    func releaseFirstSubmission() {
        gatesFirstSubmission = false
        firstSubmissionContinuation?.resume()
        firstSubmissionContinuation = nil
    }
}

@MainActor
private final class MutableRequestContext {
    var displayID: DisplayID
    var wraps: Bool
    var velocity: Double

    init(displayID: DisplayID, wraps: Bool, velocity: Double) {
        self.displayID = displayID
        self.wraps = wraps
        self.velocity = velocity
    }
}

private actor DispatcherDiagnosisProbe {
    private var storedValues: [(SpaceSwitchAction, SpaceSwitchOutcome)] = []

    var values: [(SpaceSwitchAction, SpaceSwitchOutcome)] { storedValues }

    func record(_ request: SpaceSwitchRequest, _ outcome: SpaceSwitchOutcome) {
        storedValues.append((request.action, outcome))
    }
}

@MainActor
@Suite("Action dispatcher")
struct ActionDispatcherTests {
    private let displayA = DisplayID(rawValue: "display-a")!
    private let displayB = DisplayID(rawValue: "display-b")!

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
        }
        Issue.record("Timed out waiting for dispatcher state")
    }

    @Test("Mixed sources preserve FIFO order and captured context")
    func mixedSourcesPreserveOrderAndContext() async throws {
        let probe = DispatcherSubmissionProbe(gatesFirstSubmission: true)
        let context = MutableRequestContext(
            displayID: displayA,
            wraps: false,
            velocity: 100
        )
        var lifecycleEvents: [String] = []
        let dispatcher = ActionDispatcher(
            captureRequest: { action, source in
                SpaceSwitchRequest(
                    action: action,
                    source: source,
                    targetDisplayID: context.displayID,
                    wraps: context.wraps,
                    velocity: context.velocity
                )
            },
            submitRequest: { request in
                await probe.submit(request)
            },
            diagnoseLifecycle: { lifecycleEvents.append($0) }
        )

        dispatcher.dispatch(SpaceSwitchAction.step(.right), source: .menu)
        context.displayID = displayB
        context.wraps = true
        context.velocity = 200
        dispatcher.dispatch(SpaceSwitchAction.step(.right), source: .hotkey)
        context.displayID = displayA
        context.wraps = false
        context.velocity = 300
        dispatcher.dispatch(SpaceSwitchAction.step(.left), source: .gesture)

        context.displayID = displayB
        context.wraps = true
        context.velocity = 400

        try await waitUntil { await probe.requests.count == 1 }
        #expect(await probe.requests.count == 1)
        #expect(lifecycleEvents.count == 4)
        #expect(lifecycleEvents[0].hasPrefix("input accepted sequence=1"))
        #expect(lifecycleEvents[1].hasPrefix("input accepted sequence=2"))
        #expect(lifecycleEvents[2].hasPrefix("input accepted sequence=3"))
        #expect(lifecycleEvents[3].hasPrefix("command dequeued sequence=1"))

        await probe.releaseFirstSubmission()
        try await waitUntil { await probe.requests.count == 3 }

        let requests = await probe.requests
        #expect(requests.map(\.action) == [.step(.right), .step(.right), .step(.left)])
        #expect(requests.map(\.source) == [.menu, .hotkey, .gesture])
        #expect(requests.map(\.targetDisplayID) == [displayA, displayB, displayA])
        #expect(requests.map(\.wraps) == [false, true, false])
        #expect(requests.map(\.velocity) == [100, 200, 300])
        #expect(lifecycleEvents[4].hasPrefix("command dequeued sequence=2"))
        #expect(lifecycleEvents[5].hasPrefix("command dequeued sequence=3"))

        await dispatcher.shutdown()
    }

    @Test("Rejected submissions do not reorder later commands")
    func rejectedSubmissionsPreserveOrder() async throws {
        let submissionProbe = DispatcherSubmissionProbe(
            outcomes: [.blockedAtEdge, .unavailable, .accepted]
        )
        let diagnosisProbe = DispatcherDiagnosisProbe()
        let dispatcher = ActionDispatcher(
            captureRequest: { [displayA] action, source in
                SpaceSwitchRequest(
                    action: action,
                    source: source,
                    targetDisplayID: displayA,
                    wraps: false,
                    velocity: 100
                )
            },
            submitRequest: { request in
                await submissionProbe.submit(request)
            },
            diagnoseOutcome: { request, outcome in
                await diagnosisProbe.record(request, outcome)
            }
        )

        dispatcher.dispatch(SpaceSwitchAction.step(.left), source: .menu)
        dispatcher.dispatch(SpaceSwitchAction.index(9), source: .hotkey)
        dispatcher.dispatch(SpaceSwitchAction.step(.right), source: .gesture)

        try await waitUntil { await submissionProbe.requests.count == 3 }
        let requests = await submissionProbe.requests
        #expect(requests.map(\.action) == [.step(.left), .index(9), .step(.right)])
        try await waitUntil { await diagnosisProbe.values.count == 2 }
        let diagnoses = await diagnosisProbe.values
        #expect(diagnoses.map(\.0) == [.step(.left), .index(9)])
        #expect(diagnoses.map(\.1) == [.blockedAtEdge, .unavailable])

        await dispatcher.shutdown()
    }

    @Test("Circuit-open outcomes do not emit repeated rejection diagnostics")
    func circuitOpenOutcomesDoNotRepeatDiagnostics() async throws {
        let submissionProbe = DispatcherSubmissionProbe(
            outcomes: [
                .missionControlSyntheticUnavailable,
                .missionControlSyntheticUnavailable,
            ]
        )
        let diagnosisProbe = DispatcherDiagnosisProbe()
        let dispatcher = ActionDispatcher(
            captureRequest: { [displayA] action, source in
                SpaceSwitchRequest(
                    action: action,
                    source: source,
                    targetDisplayID: displayA,
                    wraps: false,
                    velocity: 100
                )
            },
            submitRequest: { request in
                await submissionProbe.submit(request)
            },
            diagnoseOutcome: { request, outcome in
                await diagnosisProbe.record(request, outcome)
            }
        )

        dispatcher.dispatch(SpaceSwitchAction.step(.left), source: .menu)
        dispatcher.dispatch(SpaceSwitchAction.step(.right), source: .hotkey)
        try await waitUntil { await submissionProbe.requests.count == 2 }
        #expect(await diagnosisProbe.values.isEmpty)

        await dispatcher.shutdown()
    }

    @Test("Application shutdown removes input before dispatcher and engine")
    func applicationShutdownIsDependencyOrdered() async {
        var events: [String] = []
        await ApplicationShutdownSequence(
            stopInput: { events.append("input") },
            stopDispatcher: { events.append("dispatcher") },
            stopSpaceEngine: { events.append("engine") }
        ).run()

        #expect(events == ["input", "dispatcher", "engine"])
    }

    @Test("Shutdown cancels the sole consumer")
    func shutdownCancelsConsumer() async {
        let started = AsyncStream<Void>.makeStream()
        let dispatcher = ActionDispatcher(
            captureRequest: { [displayA] action, source in
                SpaceSwitchRequest(
                    action: action,
                    source: source,
                    targetDisplayID: displayA,
                    wraps: false,
                    velocity: 100
                )
            },
            submitRequest: { _ in
                started.continuation.yield()
                do {
                    try await Task<Never, Never>.sleep(for: .seconds(60))
                    return .accepted
                } catch {
                    return .unavailable
                }
            }
        )

        dispatcher.dispatch(SpaceSwitchAction.step(.right), source: .gesture)
        for await _ in started.stream.prefix(1) { break }
        await dispatcher.shutdown()
        await dispatcher.shutdown()
    }
}
