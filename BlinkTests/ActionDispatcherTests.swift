import CoreGraphics
import Foundation
import Testing

@testable import Blink

private actor DispatcherSubmissionProbe {
    private var storedRequests: [SpaceSwitchRequest] = []
    private var outcomes: [SpaceSwitchOutcome]
    private var gatesFirstSubmission: Bool
    private var firstSubmissionContinuation: CheckedContinuation<Void, Never>?
    private var requestWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

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
        let ready = requestWaiters.filter { storedRequests.count >= $0.0 }
        requestWaiters.removeAll { storedRequests.count >= $0.0 }
        ready.forEach { $0.1.resume() }
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

    func waitForRequestCount(_ count: Int) async {
        guard storedRequests.count < count else { return }
        await withCheckedContinuation { requestWaiters.append((count, $0)) }
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
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var values: [(SpaceSwitchAction, SpaceSwitchOutcome)] { storedValues }

    func record(_ request: SpaceSwitchRequest, _ outcome: SpaceSwitchOutcome) {
        storedValues.append((request.action, outcome))
        let ready = waiters.filter { storedValues.count >= $0.0 }
        waiters.removeAll { storedValues.count >= $0.0 }
        ready.forEach { $0.1.resume() }
    }

    func waitForValueCount(_ count: Int) async {
        guard storedValues.count < count else { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

@MainActor
private final class DispatcherLifecycleProbe {
    private(set) var messages: [String] = []
    private var waiters: [(String, CheckedContinuation<Void, Never>)] = []

    func record(_ message: String) {
        messages.append(message)
        let ready = waiters.filter { message.contains($0.0) }
        waiters.removeAll { message.contains($0.0) }
        ready.forEach { $0.1.resume() }
    }

    func waitForMessage(containing text: String) async {
        guard !messages.contains(where: { $0.contains(text) }) else { return }
        await withCheckedContinuation { waiters.append((text, $0)) }
    }
}

private nonisolated final class BusySpaceSystem: SpaceSystemClient, @unchecked Sendable {
    private let condition = NSCondition()
    private let snapshot: SystemSpaceSnapshot
    private let blockedSignal: AsyncStream<Void>
    private let blockedContinuation: AsyncStream<Void>.Continuation
    private var blocksNextLoad = false
    private var isReleased = false
    private var storedLoadCount = 0

    init(snapshot: SystemSpaceSnapshot) {
        self.snapshot = snapshot
        (blockedSignal, blockedContinuation) = AsyncStream.makeStream(of: Void.self)
    }

    var loadCount: Int { condition.withLock { storedLoadCount } }

    func blockNextLoad() {
        condition.withLock {
            blocksNextLoad = true
            isReleased = false
        }
    }

    func waitForBlockedLoad() async {
        for await _ in blockedSignal.prefix(1) { return }
    }

    func releaseBlockedLoad() {
        condition.withLock {
            isReleased = true
            condition.broadcast()
        }
    }

    func loadSnapshot() throws -> SystemSpaceSnapshot {
        condition.lock()
        storedLoadCount += 1
        if blocksNextLoad {
            blocksNextLoad = false
            blockedContinuation.yield()
            while !isReleased { condition.wait() }
        }
        condition.unlock()
        return snapshot
    }
}

private nonisolated struct DispatcherDisplayLocator: DisplayLocating {
    let displayID: DisplayID

    func cursorDisplayID() throws -> DisplayID { displayID }
    func bounds(for displayID: DisplayID) -> CGRect? {
        displayID == self.displayID
            ? CGRect(x: 0, y: 0, width: 1920, height: 1080)
            : nil
    }
}

private nonisolated struct DispatcherOverlayDetector: OverlayDetecting {
    func detect(on displayID: DisplayID) -> OverlayMode {
        _ = displayID
        return .none
    }
}

private nonisolated final class DispatcherPoster: SpaceGesturePosting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedAttempts = 0

    var attempts: Int { lock.withLock { storedAttempts } }

    func postStep(
        mode: SpaceSwitchMode,
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> Bool {
        _ = (mode, direction, velocity)
        lock.withLock { storedAttempts += 1 }
        return true
    }
}

private nonisolated final class DispatcherEngineDiagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMessages: [String] = []

    var messages: [String] { lock.withLock { storedMessages } }

    func record(_ category: String, _ message: String) {
        lock.withLock { storedMessages.append("\(category):\(message)") }
    }
}

@MainActor
@Suite("Action dispatcher")
struct ActionDispatcherTests {
    private let displayA = DisplayID(rawValue: "display-a")!
    private let displayB = DisplayID(rawValue: "display-b")!

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

        await probe.waitForRequestCount(1)
        #expect(await probe.requests.count == 1)
        #expect(lifecycleEvents.count == 4)
        #expect(lifecycleEvents[0].hasPrefix("input accepted sequence=1"))
        #expect(lifecycleEvents[1].hasPrefix("input accepted sequence=2"))
        #expect(lifecycleEvents[2].hasPrefix("input accepted sequence=3"))
        #expect(lifecycleEvents[3].hasPrefix("command dequeued sequence=1"))

        await probe.releaseFirstSubmission()
        await probe.waitForRequestCount(3)

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

        await submissionProbe.waitForRequestCount(3)
        let requests = await submissionProbe.requests
        #expect(requests.map(\.action) == [.step(.left), .index(9), .step(.right)])
        await diagnosisProbe.waitForValueCount(2)
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
        await submissionProbe.waitForRequestCount(2)
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

    @Test("Shutdown cancels a command queued behind the real engine actor")
    func shutdownCancelsQueuedRealEngineSubmission() async {
        let managedDisplay = ManagedDisplayID(rawValue: displayA.rawValue)!
        let snapshot = SystemSpaceSnapshot(
            topologiesByManagedDisplay: [
                managedDisplay: DisplayTopology(
                    managedDisplayID: managedDisplay,
                    spaceIDs: [SpaceID(rawValue: 100)!, SpaceID(rawValue: 101)!],
                    currentSpaceID: SpaceID(rawValue: 100)!
                )!,
            ],
            menuBarDisplayID: displayA
        )
        let system = BusySpaceSystem(snapshot: snapshot)
        let poster = DispatcherPoster()
        let engineDiagnostics = DispatcherEngineDiagnostics()
        let engine = SpaceSwitchEngine(dependencies: .init(
            system: system,
            displays: DispatcherDisplayLocator(displayID: displayA),
            overlays: DispatcherOverlayDetector(),
            poster: poster,
            missionControlCapability: .init(),
            diagnose: engineDiagnostics.record
        ))
        await engine.start()
        let initialPresentation = await engine.presentation()

        system.blockNextLoad()
        let busyRefresh = Task { await engine.refresh(reason: .passive) }
        await system.waitForBlockedLoad()

        let lifecycle = DispatcherLifecycleProbe()
        let outcomeDiagnoses = DispatcherDiagnosisProbe()
        var captureCount = 0
        let dispatcher = ActionDispatcher(
            captureRequest: { [displayA] action, source in
                captureCount += 1
                return SpaceSwitchRequest(
                    action: action,
                    source: source,
                    targetDisplayID: displayA,
                    wraps: false,
                    velocity: 100
                )
            },
            submitRequest: { request in
                await engine.submit(request)
            },
            diagnoseOutcome: { request, outcome in
                await outcomeDiagnoses.record(request, outcome)
            },
            diagnoseLifecycle: { message in
                lifecycle.record(message)
                if message.contains("dispatcher shutdown") {
                    system.releaseBlockedLoad()
                }
            }
        )

        dispatcher.dispatch(SpaceSwitchAction.step(.right), source: .gesture)
        await lifecycle.waitForMessage(containing: "command dequeued sequence=1")
        await dispatcher.shutdown()
        await busyRefresh.value

        let request = SpaceSwitchRequest(
            action: .step(.left),
            source: .menu,
            targetDisplayID: displayA,
            wraps: true,
            velocity: 200
        )
        dispatcher.dispatch(request)
        dispatcher.dispatch(.step(.left), source: .hotkey)
        await dispatcher.shutdown()

        #expect(captureCount == 1)
        #expect(system.loadCount == 2)
        #expect(poster.attempts == 0)
        #expect(engineDiagnostics.messages.isEmpty)
        #expect(await outcomeDiagnoses.values.isEmpty)
        #expect(await engine.presentation() == initialPresentation)
        #expect(lifecycle.messages.filter { $0.contains("input accepted") }.count == 1)
        await engine.stop()
    }
}
