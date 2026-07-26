import CoreGraphics
import Foundation
import Testing

@testable import Blink

private actor ControlledSleeper {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var waiters: [Waiter] = []
    private var waiterObservers: [CheckedContinuation<Void, Never>] = []
    private var emptyObservers: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int { waiters.count }

    func sleep(_ duration: Duration) async throws {
        _ = duration
        try Task.checkCancellation()

        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    waiters.append(Waiter(id: id, continuation: continuation))
                    let observers = waiterObservers
                    waiterObservers.removeAll()
                    observers.forEach { $0.resume() }
                }
            }
        } onCancel: {
            Task { await self.resume(id: id) }
        }

        try Task.checkCancellation()
    }

    func resumeFirst() {
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().continuation.resume()
        notifyIfEmpty()
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume() }
        notifyIfEmpty()
    }

    func waitForWaiter() async {
        guard waiters.isEmpty else { return }
        await withCheckedContinuation { waiterObservers.append($0) }
    }

    func waitUntilEmpty() async {
        guard !waiters.isEmpty else { return }
        await withCheckedContinuation { emptyObservers.append($0) }
    }

    private func resume(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
        notifyIfEmpty()
    }

    private func notifyIfEmpty() {
        guard waiters.isEmpty else { return }
        let observers = emptyObservers
        emptyObservers.removeAll()
        observers.forEach { $0.resume() }
    }
}

private enum TestDependencyError: Error {
    case unavailable
}

private nonisolated final class TestSpaceSystem: SpaceSystemClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot: SystemSpaceSnapshot
    private var remainingFailures = 0
    private var storedLoadCount = 0

    var loadCount: Int { lock.withLock { storedLoadCount } }

    init(snapshot: SystemSpaceSnapshot) {
        storedSnapshot = snapshot
    }

    func loadSnapshot() throws -> SystemSpaceSnapshot {
        try lock.withLock {
            storedLoadCount += 1
            guard remainingFailures == 0 else {
                remainingFailures -= 1
                throw TestDependencyError.unavailable
            }
            return storedSnapshot
        }
    }

    func setSnapshot(_ snapshot: SystemSpaceSnapshot) {
        lock.withLock { storedSnapshot = snapshot }
    }

    func failNextLoad() {
        lock.withLock { remainingFailures += 1 }
    }
}

private nonisolated final class TestDisplayLocator: DisplayLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDisplayID: DisplayID?

    init(displayID: DisplayID) {
        storedDisplayID = displayID
    }

    func cursorDisplayID() throws -> DisplayID {
        try lock.withLock {
            guard let storedDisplayID else { throw TestDependencyError.unavailable }
            return storedDisplayID
        }
    }

    func bounds(for displayID: DisplayID) -> CGRect? {
        _ = displayID
        return CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    func setDisplayID(_ displayID: DisplayID?) {
        lock.withLock { storedDisplayID = displayID }
    }
}

private nonisolated final class TestOverlayDetector: OverlayDetecting, @unchecked Sendable {
    private let lock = NSLock()
    private var storedMode: OverlayMode

    init(mode: OverlayMode) {
        storedMode = mode
    }

    func detect(on displayID: DisplayID) -> OverlayMode {
        _ = displayID
        return lock.withLock { storedMode }
    }

    func setMode(_ mode: OverlayMode) {
        lock.withLock { storedMode = mode }
    }
}

private nonisolated final class TestPoster: SpaceGesturePosting, @unchecked Sendable {
    struct Post: Equatable, Sendable {
        let mode: SpaceSwitchMode
        let direction: SpaceSwitchDirection
        let velocity: Double
    }

    private let lock = NSLock()
    private var storedPosts: [Post] = []
    private var storedAttempts = 0
    private var failingAttempts: Set<Int> = []

    var posts: [Post] {
        lock.withLock { storedPosts }
    }

    var attempts: Int {
        lock.withLock { storedAttempts }
    }

    func fail(attempt: Int) {
        lock.withLock { _ = failingAttempts.insert(attempt) }
    }

    func postStep(
        mode: SpaceSwitchMode,
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> Bool {
        lock.withLock {
            storedAttempts += 1
            guard !failingAttempts.contains(storedAttempts) else { return false }
            storedPosts.append(Post(mode: mode, direction: direction, velocity: velocity))
            return true
        }
    }
}

private nonisolated final class TestFailureRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedCount = 0

    var count: Int { lock.withLock { storedCount } }

    func record() {
        lock.withLock { storedCount += 1 }
    }
}

private nonisolated final class TestDiagnosticRecorder: @unchecked Sendable {
    private struct Waiter {
        let text: String
        let continuation: CheckedContinuation<String, Never>
    }

    private let lock = NSLock()
    private var storedMessages: [String] = []
    private var waiters: [Waiter] = []

    var messages: [String] { lock.withLock { storedMessages } }

    func clear() {
        lock.withLock { storedMessages.removeAll() }
    }

    func record(category: String, message: String) {
        let value = "\(category):\(message)"
        let completed: [Waiter] = lock.withLock {
            storedMessages.append(value)
            let completed = waiters.filter { value.contains($0.text) }
            waiters.removeAll { value.contains($0.text) }
            return completed
        }
        completed.forEach { $0.continuation.resume(returning: value) }
    }

    func message(containing text: String) async -> String {
        await withCheckedContinuation { continuation in
            let existing = lock.withLock { () -> String? in
                if let existing = storedMessages.first(where: { $0.contains(text) }) {
                    return existing
                }
                waiters.append(Waiter(text: text, continuation: continuation))
                return nil
            }
            if let existing {
                continuation.resume(returning: existing)
            }
        }
    }
}

private extension SpacePresentation {
    var projectedSpaceByDisplay: [ManagedDisplayID: SpaceID] {
        projectedSpaceByManagedDisplay
    }

    var lastSpaceByDisplay: [ManagedDisplayID: SpaceID] {
        lastSpaceByManagedDisplay
    }
}

private extension SystemSpaceSnapshot {
    var topologiesByDisplay: [ManagedDisplayID: DisplayTopology] {
        topologiesByManagedDisplay
    }
}

private extension Dictionary where Key == ManagedDisplayID {
    subscript(_ physicalDisplayID: DisplayID) -> Value? {
        self[ManagedDisplayID(rawValue: physicalDisplayID.rawValue)!]
    }
}

@MainActor
@Suite("Space switch engine")
struct SpaceSwitchEngineTests {
    private let displayA = DisplayID(rawValue: "display-a")!
    private let displayB = DisplayID(rawValue: "display-b")!

    private func space(_ value: UInt64) -> SpaceID {
        SpaceID(rawValue: value)!
    }

    private func snapshot(
        currentA: UInt64,
        spacesA: [UInt64] = [100, 101, 102, 103],
        currentB: UInt64? = nil
    ) -> SystemSpaceSnapshot {
        var values: [ManagedDisplayID: DisplayTopology] = [
            ManagedDisplayID(rawValue: displayA.rawValue)!: DisplayTopology(
                managedDisplayID: ManagedDisplayID(rawValue: displayA.rawValue)!,
                spaceIDs: spacesA.map(space),
                currentSpaceID: space(currentA)
            )!
        ]
        if let currentB {
            let managedDisplayB = ManagedDisplayID(rawValue: displayB.rawValue)!
            values[managedDisplayB] = DisplayTopology(
                managedDisplayID: managedDisplayB,
                spaceIDs: [200, 201, 202].map(space),
                currentSpaceID: space(currentB)
            )!
        }
        return SystemSpaceSnapshot(
            topologiesByManagedDisplay: values,
            menuBarDisplayID: displayA
        )
    }

    private func sharedSnapshot(current: UInt64) -> SystemSpaceSnapshot {
        SystemSpaceSnapshot(
            topologiesByManagedDisplay: [
                .main: DisplayTopology(
                    managedDisplayID: .main,
                    spaceIDs: [100, 101, 102].map(space),
                    currentSpaceID: space(current)
                )!
            ],
            menuBarDisplayID: displayA
        )
    }

    private func makeEngine(
        snapshot: SystemSpaceSnapshot,
        mode: OverlayMode = .none,
        overlayDetector: TestOverlayDetector? = nil,
        missionControlCapability: MissionControlSyntheticCapability = .init(),
        failureRecorder: TestFailureRecorder? = nil,
        diagnosticRecorder: TestDiagnosticRecorder? = nil
    ) -> (
        SpaceSwitchEngine,
        TestSpaceSystem,
        TestDisplayLocator,
        TestPoster,
        ControlledSleeper
    ) {
        let system = TestSpaceSystem(snapshot: snapshot)
        let display = TestDisplayLocator(displayID: displayA)
        let poster = TestPoster()
        let sleeper = ControlledSleeper()
        let engine = SpaceSwitchEngine(
            dependencies: .init(
                system: system,
                displays: display,
                overlays: overlayDetector ?? TestOverlayDetector(mode: mode),
                poster: poster,
                missionControlCapability: missionControlCapability,
                sleep: { try await sleeper.sleep($0) },
                diagnose: { category, message in
                    diagnosticRecorder?.record(category: category, message: message)
                    if category == "mission-control" {
                        failureRecorder?.record()
                    }
                }
            )
        )
        return (engine, system, display, poster, sleeper)
    }

    private func emptySnapshot() -> SystemSpaceSnapshot {
        SystemSpaceSnapshot(
            topologiesByManagedDisplay: [:],
            menuBarDisplayID: nil
        )
    }

    @Test("A submitted step posts and projects the target")
    func stepPostsAndProjects() async throws {
        let (engine, _, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        let outcome = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(outcome == .accepted)

        let presentation = await engine.presentation()
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(101))
        #expect(poster.posts.first?.direction == .right)
    }

    @Test("A four-step direct jump posts one bounded instant window")
    func fourStepJumpPostsImmediately() async {
        let spaces = Array(UInt64(100)...UInt64(104))
        let (engine, _, _, poster, _) = makeEngine(
            snapshot: snapshot(currentA: 100, spacesA: spaces)
        )
        await engine.start()

        let outcome = await engine.submit(
            SpaceSwitchRequest(
                action: .index(4),
                source: .hotkey,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )

        #expect(outcome == .accepted)
        #expect(poster.posts.count == 4)
        #expect(poster.posts.allSatisfy { $0.direction == .right })
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(104))
    }

    @Test("A ten-step jump advances in bounded four-step windows")
    func longJumpUsesBoundedWindows() async throws {
        let spaces = Array(UInt64(100)...UInt64(110))
        let (engine, system, _, poster, _) = makeEngine(
            snapshot: snapshot(currentA: 100, spacesA: spaces)
        )
        await engine.start()

        let outcome = await engine.submit(
            SpaceSwitchRequest(
                action: .index(10),
                source: .hotkey,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(outcome == .accepted)
        #expect(poster.posts.count == 4)

        let expectedPostedCounts = [4, 4, 4, 8, 8, 8, 8, 10, 10, 10]
        for (offset, currentSpace) in spaces.dropFirst().enumerated() {
            system.setSnapshot(snapshot(currentA: currentSpace, spacesA: spaces))
            await engine.refresh(reason: .activeSpaceChanged)
            #expect(poster.posts.count == expectedPostedCounts[offset])
        }
        #expect(poster.posts.count == 10)
        #expect(poster.posts.allSatisfy { $0.direction == .right })
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(110))
    }

    @Test("Transient overlay uncertainty acknowledges progress without stopping a long jump")
    func transientOverlayUncertaintyPreservesLongJump() async throws {
        let spaces = Array(UInt64(100)...UInt64(107))
        let overlays = TestOverlayDetector(mode: .none)
        let (engine, system, _, poster, _) = makeEngine(
            snapshot: snapshot(currentA: 100, spacesA: spaces),
            overlayDetector: overlays
        )
        await engine.start()

        #expect(await engine.submit(SpaceSwitchRequest(
            action: .index(7),
            source: .menu,
            targetDisplayID: displayA,
            wraps: false,
            velocity: 100
        )) == .accepted)
        #expect(poster.posts.count == 4)

        overlays.setMode(.unknown)
        system.setSnapshot(snapshot(currentA: 104, spacesA: spaces))
        await engine.refresh(reason: .activeSpaceChanged)
        #expect(poster.posts.count == 4)
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(107))

        overlays.setMode(.none)
        await engine.refresh(reason: .passive)
        #expect(poster.posts.count == 7)
        system.setSnapshot(snapshot(currentA: 107, spacesA: spaces))
        await engine.refresh(reason: .activeSpaceChanged)
        #expect((await engine.presentation()).lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("Repeated requests plan from the desired endpoint")
    func repeatedRequestsAccumulate() async throws {
        let (engine, system, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 1)

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 1)

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        #expect(poster.posts.count == 2)

        let presentation = await engine.presentation()
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(102))
    }

    @Test("Authoritative acknowledgement records confirmed history")
    func acknowledgementRecordsHistory() async throws {
        let initial = snapshot(currentA: 100)
        let (engine, system, _, poster, _) = makeEngine(snapshot: initial)
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .hotkey,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 1)

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(101))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("Switch lifecycle diagnostics cover post, acknowledgement, and settlement")
    func switchLifecycleDiagnostics() async throws {
        let recorder = TestDiagnosticRecorder()
        let (engine, system, _, poster, _) = makeEngine(
            snapshot: snapshot(currentA: 100),
            diagnosticRecorder: recorder
        )
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .hotkey,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 1)
        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)

        let messages = recorder.messages
        #expect(messages.contains { $0.contains("transaction accepted") })
        #expect(messages.contains { $0.contains("synthetic post") })
        #expect(messages.contains { $0.contains("authoritative acknowledgement") })
        #expect(messages.contains { $0.contains("transaction settlement") })
    }

    @Test("An unacknowledged post rolls projection back")
    func missingAcknowledgementRollsBack() async throws {
        let recorder = TestDiagnosticRecorder()
        let (engine, _, _, poster, sleeper) = makeEngine(
            snapshot: snapshot(currentA: 100),
            diagnosticRecorder: recorder
        )
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 1)
        await sleeper.waitForWaiter()

        let timeout = Task { await recorder.message(containing: "timeout display=") }
        await sleeper.resumeFirst()
        _ = await timeout.value
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(100))
        #expect(recorder.messages.contains { $0.contains("timeout display=") })
        #expect(recorder.messages.contains {
            $0.contains("cancellation") && $0.contains("projection-rollback=100")
        })
    }

    @Test("Moving the cursor cancels a bounded window instead of retargeting")
    func cursorMovementAbortsWork() async throws {
        let initial = snapshot(
            currentA: 100,
            spacesA: Array(UInt64(100)...UInt64(107)),
            currentB: 200
        )
        let (engine, system, display, poster, _) = makeEngine(snapshot: initial)
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .index(7),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 4)

        display.setDisplayID(displayB)
        system.setSnapshot(
            snapshot(
                currentA: 104,
                spacesA: Array(UInt64(100)...UInt64(107)),
                currentB: 200
            )
        )
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 4)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(104))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("A reversal waits for the in-flight step to be acknowledged")
    func reversalWaitsForAcknowledgement() async throws {
        let (engine, system, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 1)

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.left),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 1)

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        #expect(poster.posts.count == 2)
        #expect(poster.posts.map(\.direction) == [.right, .left])

        system.setSnapshot(snapshot(currentA: 100))
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(100))
    }

    @Test("Alternating intent coalesces while a step is in flight")
    func alternatingIntentCoalesces() async throws {
        let (engine, system, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        for direction in [
            SpaceSwitchDirection.right,
            .left,
            .right,
        ] {
            _ = await engine.submit(
                SpaceSwitchRequest(
                    action: .step(direction),
                    source: .gesture,
                    targetDisplayID: displayA,
                    wraps: false,
                    velocity: 100
                )
            )
        }
        #expect(poster.posts.count == 1)
        #expect(poster.posts.first?.direction == .right)

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        #expect(poster.posts.count == 1)

        let presentation = await engine.presentation()
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(101))
    }

    @Test("A request on another display acquires the transaction lease")
    func crossDisplayRequestSupersedesTransaction() async throws {
        let initial = snapshot(currentA: 100, currentB: 200)
        let (engine, system, display, poster, sleeper) = makeEngine(snapshot: initial)
        await engine.start()

        #expect(
            await engine.submit(
                SpaceSwitchRequest(
                    action: .step(.right),
                    source: .gesture,
                    targetDisplayID: displayA,
                    wraps: false,
                    velocity: 100
                )
            ) == .accepted
        )
        #expect(poster.posts.count == 1)
        await sleeper.waitForWaiter()

        display.setDisplayID(displayB)
        #expect(
            await engine.submit(
                SpaceSwitchRequest(
                    action: .step(.right),
                    source: .hotkey,
                    targetDisplayID: displayB,
                    wraps: false,
                    velocity: 100
                )
            ) == .accepted
        )
        #expect(poster.posts.count == 2)
        await sleeper.waitForWaiter()

        let leased = await engine.presentation()
        #expect(leased.projectedSpaceByDisplay[displayA] == space(100))
        #expect(leased.projectedSpaceByDisplay[displayB] == space(201))
        #expect(leased.lastSpaceByDisplay[displayA] == nil)

        system.setSnapshot(snapshot(currentA: 100, currentB: 201))
        await engine.refresh(reason: .activeSpaceChanged)
        await sleeper.waitUntilEmpty()
        await sleeper.resumeAll()

        let settled = await engine.presentation()
        #expect(poster.posts.count == 2)
        #expect(settled.projectedSpaceByDisplay[displayA] == space(100))
        #expect(settled.projectedSpaceByDisplay[displayB] == space(201))
        #expect(settled.lastSpaceByDisplay[displayA] == nil)
        #expect(settled.lastSpaceByDisplay[displayB] == space(200))
    }

    @Test("Another physical display sharing Main safely supersedes execution")
    func sharedMainPhysicalTargetSupersedesExecution() async {
        let (engine, system, display, poster, sleeper) = makeEngine(
            snapshot: sharedSnapshot(current: 100)
        )
        await engine.start()

        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right),
            source: .gesture,
            targetDisplayID: displayA,
            wraps: false,
            velocity: 100
        )) == .accepted)
        #expect(poster.posts.count == 1)

        display.setDisplayID(displayB)
        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right),
            source: .hotkey,
            targetDisplayID: displayB,
            wraps: false,
            velocity: 100
        )) == .accepted)
        #expect(poster.posts.count == 2)
        #expect(
            (await engine.presentation()).projectedSpaceByManagedDisplay[.main]
                == space(101)
        )

        system.setSnapshot(sharedSnapshot(current: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        await sleeper.waitUntilEmpty()
        #expect(
            (await engine.presentation()).lastSpaceByManagedDisplay[.main]
                == space(100)
        )
    }

    @Test("Mission Control keeps one synthetic step in flight")
    func missionControlKeepsSingleStepInFlight() async throws {
        let (engine, system, _, poster, _) = makeEngine(
            snapshot: snapshot(currentA: 100),
            mode: .missionControl
        )
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .index(3),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 1)
        #expect(poster.posts.first?.mode == .missionControl)

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        #expect(poster.posts.count == 2)
    }

    @Test("An immediate Mission Control post failure opens the circuit")
    func missionControlPostFailureOpensCircuit() async {
        let capability = MissionControlSyntheticCapability()
        let recorder = TestFailureRecorder()
        let (engine, _, _, poster, _) = makeEngine(
            snapshot: snapshot(currentA: 100),
            mode: .missionControl,
            missionControlCapability: capability,
            failureRecorder: recorder
        )
        poster.fail(attempt: 1)
        await engine.start()

        let outcome = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .hotkey,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        let laterOutcome = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )

        #expect(outcome == .missionControlSyntheticUnavailable)
        #expect(laterOutcome == .missionControlSyntheticUnavailable)
        #expect(capability.state(on: displayA) == .unavailableUntilOverlayExit)
        #expect(poster.attempts == 1)
        #expect(recorder.count == 1)
    }

    @Test("A bounded Mission Control timeout does not create persistent failure")
    func missionControlTimeoutDoesNotOpenCircuit() async throws {
        let capability = MissionControlSyntheticCapability()
        let recorder = TestFailureRecorder()
        let diagnostics = TestDiagnosticRecorder()
        let overlays = TestOverlayDetector(mode: .missionControl)
        let (engine, _, _, poster, sleeper) = makeEngine(
            snapshot: snapshot(currentA: 100),
            overlayDetector: overlays,
            missionControlCapability: capability,
            failureRecorder: recorder,
            diagnosticRecorder: diagnostics
        )
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 1)
        await sleeper.waitForWaiter()
        let timeout = Task { await diagnostics.message(containing: "aborted topology=") }
        await sleeper.resumeFirst()
        _ = await timeout.value

        #expect(capability.state(on: displayA) == .available)
        #expect(recorder.count == 0)
        let nextOutcome = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(nextOutcome == .accepted)
        #expect(poster.attempts == 2)
    }

    @Test("Two confirmed Mission Control nonmovements open only that display circuit")
    func missionControlConfirmedNonmovementThreshold() async {
        let capability = MissionControlSyntheticCapability()
        let recorder = TestDiagnosticRecorder()
        let (engine, _, _, poster, sleeper) = makeEngine(
            snapshot: snapshot(currentA: 100),
            mode: .missionControl,
            missionControlCapability: capability,
            diagnosticRecorder: recorder
        )
        await engine.start()

        for attempt in 1...2 {
            recorder.clear()
            #expect(await engine.submit(SpaceSwitchRequest(
                action: .step(.right),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )) == .accepted)
            await sleeper.waitForWaiter()
            let completion = Task { await recorder.message(containing: "aborted topology=") }
            await sleeper.resumeFirst()
            _ = await completion.value
            #expect(poster.attempts == attempt)
        }

        #expect(capability.state(on: displayA) == .unavailableUntilOverlayExit)
        #expect(capability.state(on: displayB) == .available)
    }

    @Test("Authoritative acknowledgement resets pending Mission Control strikes")
    func missionControlAcknowledgementResetsStrikes() async {
        let capability = MissionControlSyntheticCapability()
        let recorder = TestDiagnosticRecorder()
        let (engine, system, _, _, sleeper) = makeEngine(
            snapshot: snapshot(currentA: 100),
            mode: .missionControl,
            missionControlCapability: capability,
            diagnosticRecorder: recorder
        )
        await engine.start()

        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right), source: .menu, targetDisplayID: displayA,
            wraps: false, velocity: 100
        )) == .accepted)
        await sleeper.waitForWaiter()
        let firstTimeout = Task { await recorder.message(containing: "aborted topology=") }
        await sleeper.resumeFirst()
        _ = await firstTimeout.value

        recorder.clear()
        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right), source: .menu, targetDisplayID: displayA,
            wraps: false, velocity: 100
        )) == .accepted)
        await sleeper.waitForWaiter()
        system.setSnapshot(snapshot(currentA: 101))
        let acknowledgement = Task {
            await recorder.message(containing: "authoritative acknowledgement")
        }
        await engine.refresh(reason: .activeSpaceChanged)
        _ = await acknowledgement.value
        await sleeper.waitUntilEmpty()

        recorder.clear()
        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.left), source: .menu, targetDisplayID: displayA,
            wraps: false, velocity: 100
        )) == .accepted)
        await sleeper.waitForWaiter()
        let timeoutAfterAcknowledgement = Task {
            await recorder.message(containing: "aborted topology=")
        }
        await sleeper.resumeFirst()
        _ = await timeoutAfterAcknowledgement.value

        #expect(capability.state(on: displayA) == .available)
    }

    @Test("An unverifiable Mission Control deadline does not consume a strike")
    func missionControlUnverifiableDeadlineDoesNotCount() async {
        let capability = MissionControlSyntheticCapability()
        let recorder = TestDiagnosticRecorder()
        let (engine, system, _, _, sleeper) = makeEngine(
            snapshot: snapshot(currentA: 100),
            mode: .missionControl,
            missionControlCapability: capability,
            diagnosticRecorder: recorder
        )
        await engine.start()

        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right), source: .menu, targetDisplayID: displayA,
            wraps: false, velocity: 100
        )) == .accepted)
        await sleeper.waitForWaiter()
        system.failNextLoad()
        let unverifiable = Task {
            await recorder.message(containing: "acknowledgement unverifiable")
        }
        await sleeper.resumeFirst()
        _ = await unverifiable.value

        recorder.clear()
        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right), source: .menu, targetDisplayID: displayA,
            wraps: false, velocity: 100
        )) == .accepted)
        await sleeper.waitForWaiter()
        let confirmed = Task { await recorder.message(containing: "aborted topology=") }
        await sleeper.resumeFirst()
        _ = await confirmed.value

        #expect(capability.state(on: displayA) == .available)
    }

    @Test("Mission Control timeout after cursor movement does not consume a strike")
    func missionControlCursorChangeIsUnverifiable() async {
        let capability = MissionControlSyntheticCapability()
        let diagnostics = TestDiagnosticRecorder()
        let (engine, _, display, _, sleeper) = makeEngine(
            snapshot: snapshot(currentA: 100),
            mode: .missionControl,
            missionControlCapability: capability,
            diagnosticRecorder: diagnostics
        )
        await engine.start()

        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right), source: .menu, targetDisplayID: displayA,
            wraps: false, velocity: 100
        )) == .accepted)
        await sleeper.waitForWaiter()
        display.setDisplayID(displayB)
        let aborted = Task {
            await diagnostics.message(containing: "acknowledgement context changed")
        }
        await sleeper.resumeFirst()
        _ = await aborted.value

        display.setDisplayID(displayA)
        diagnostics.clear()
        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right), source: .menu, targetDisplayID: displayA,
            wraps: false, velocity: 100
        )) == .accepted)
        await sleeper.waitForWaiter()
        let confirmed = Task { await diagnostics.message(containing: "aborted topology=") }
        await sleeper.resumeFirst()
        _ = await confirmed.value
        #expect(capability.state(on: displayA) == .available)
    }

    @Test("Mission Control timeout after overlay exit does not consume a strike")
    func missionControlOverlayExitIsUnverifiable() async {
        let capability = MissionControlSyntheticCapability()
        let diagnostics = TestDiagnosticRecorder()
        let overlays = TestOverlayDetector(mode: .missionControl)
        let (engine, _, _, _, sleeper) = makeEngine(
            snapshot: snapshot(currentA: 100),
            overlayDetector: overlays,
            missionControlCapability: capability,
            diagnosticRecorder: diagnostics
        )
        await engine.start()

        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right), source: .menu, targetDisplayID: displayA,
            wraps: false, velocity: 100
        )) == .accepted)
        await sleeper.waitForWaiter()
        overlays.setMode(.none)
        let aborted = Task {
            await diagnostics.message(containing: "acknowledgement overlay unverifiable")
        }
        await sleeper.resumeFirst()
        _ = await aborted.value

        overlays.setMode(.missionControl)
        diagnostics.clear()
        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right), source: .menu, targetDisplayID: displayA,
            wraps: false, velocity: 100
        )) == .accepted)
        await sleeper.waitForWaiter()
        let confirmed = Task { await diagnostics.message(containing: "aborted topology=") }
        await sleeper.resumeFirst()
        _ = await confirmed.value
        #expect(capability.state(on: displayA) == .available)
    }

    @Test("Mission Control timeout after topology change does not consume a strike")
    func missionControlTopologyChangeIsUnverifiable() async {
        let capability = MissionControlSyntheticCapability()
        let diagnostics = TestDiagnosticRecorder()
        let (engine, system, _, _, sleeper) = makeEngine(
            snapshot: snapshot(currentA: 100),
            mode: .missionControl,
            missionControlCapability: capability,
            diagnosticRecorder: diagnostics
        )
        await engine.start()

        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right), source: .menu, targetDisplayID: displayA,
            wraps: false, velocity: 100
        )) == .accepted)
        await sleeper.waitForWaiter()
        system.setSnapshot(snapshot(currentA: 100, spacesA: [100, 101, 104]))
        let aborted = Task {
            await diagnostics.message(containing: "acknowledgement unverifiable")
        }
        await sleeper.resumeFirst()
        _ = await aborted.value

        system.setSnapshot(snapshot(currentA: 100))
        diagnostics.clear()
        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right), source: .menu, targetDisplayID: displayA,
            wraps: false, velocity: 100
        )) == .accepted)
        await sleeper.waitForWaiter()
        let confirmed = Task { await diagnostics.message(containing: "aborted topology=") }
        await sleeper.resumeFirst()
        _ = await confirmed.value
        #expect(capability.state(on: displayA) == .available)
    }

    @Test("A cancelled task is rejected before snapshot reconciliation")
    func cancelledSubmitHasNoSideEffects() async {
        let (engine, system, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()
        let initialLoadCount = system.loadCount

        let outcome = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await engine.submit(SpaceSwitchRequest(
                action: .step(.right),
                source: .hotkey,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            ))
        }.value

        #expect(outcome == .unavailable)
        #expect(system.loadCount == initialLoadCount)
        #expect(poster.posts.isEmpty)
    }

    @Test("An empty system topology is unavailable")
    func emptyTopologyIsUnavailable() async {
        let empty = emptySnapshot()
        let (engine, _, _, poster, _) = makeEngine(snapshot: empty)
        await engine.start()

        let outcome = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .hotkey,
                targetDisplayID: displayA,
                wraps: true,
                velocity: 100
            )
        )
        let presentation = await engine.presentation()

        #expect(outcome == .unavailable)
        #expect(poster.posts.isEmpty)
        #expect(presentation.snapshot == empty)
        #expect(presentation.projectedSpaceByDisplay.isEmpty)
        #expect(presentation.lastSpaceByDisplay.isEmpty)
    }

    @Test("A one-Space display blocks directional movement")
    func oneSpaceDisplayCannotMove() async {
        let (engine, _, _, poster, _) = makeEngine(
            snapshot: snapshot(currentA: 100, spacesA: [100])
        )
        await engine.start()

        let left = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.left),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        let wrappedRight = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .menu,
                targetDisplayID: displayA,
                wraps: true,
                velocity: 100
            )
        )
        let currentIndex = await engine.submit(
            SpaceSwitchRequest(
                action: .index(0),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        let presentation = await engine.presentation()

        #expect(left == .blockedAtEdge)
        #expect(wrappedRight == .blockedAtEdge)
        #expect(currentIndex == .alreadyAtTarget)
        #expect(poster.posts.isEmpty)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(100))
    }

    @Test("Direct indices outside the topology are rejected")
    func invalidDirectIndicesAreRejected() async {
        let (engine, _, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 101))
        await engine.start()

        let negative = await engine.submit(
            SpaceSwitchRequest(
                action: .index(-1),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        let pastEnd = await engine.submit(
            SpaceSwitchRequest(
                action: .index(4),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        let presentation = await engine.presentation()

        #expect(negative == .invalidTarget)
        #expect(pastEnd == .invalidTarget)
        #expect(poster.posts.isEmpty)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(101))
    }

    @Test("Wrapping left from the first Space posts one bounded instant window")
    func wrappingLeftTravelsRight() async throws {
        let (engine, system, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        let outcome = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.left),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: true,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 3)
        #expect(outcome == .accepted)
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(103))

        system.setSnapshot(snapshot(currentA: 103))
        await engine.refresh(reason: .activeSpaceChanged)

        let presentation = await engine.presentation()
        #expect(poster.posts.map(\.direction) == [.right, .right, .right])
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(103))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("Wrapping right from the last Space posts one bounded instant window")
    func wrappingRightTravelsLeft() async throws {
        let (engine, system, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 103))
        await engine.start()

        let outcome = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: true,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 3)
        #expect(outcome == .accepted)
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(100))

        system.setSnapshot(snapshot(currentA: 100))
        await engine.refresh(reason: .activeSpaceChanged)

        let presentation = await engine.presentation()
        #expect(poster.posts.map(\.direction) == [.left, .left, .left])
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(100))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(103))
    }

    @Test("A direct target supersedes queued intent without bypassing acknowledgement")
    func directTargetSupersedesQueuedIntent() async throws {
        let (engine, system, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        #expect(
            await engine.submit(
                SpaceSwitchRequest(
                    action: .index(3),
                    source: .gesture,
                    targetDisplayID: displayA,
                    wraps: false,
                    velocity: 100
                )
            ) == .accepted
        )
        #expect(poster.posts.count == 3)

        #expect(
            await engine.submit(
                SpaceSwitchRequest(
                    action: .index(1),
                    source: .menu,
                    targetDisplayID: displayA,
                    wraps: false,
                    velocity: 100
                )
            ) == .accepted
        )
        #expect(poster.posts.count == 3)
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(101))

        system.setSnapshot(snapshot(currentA: 103))
        await engine.refresh(reason: .activeSpaceChanged)
        #expect(poster.posts.count == 5)
        #expect(poster.posts.map(\.direction) == [.right, .right, .right, .left, .left])

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 5)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(101))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("Missing cursor or display context fails closed")
    func missingCursorOrDisplayContextCancelsWork() async throws {
        let (engine, system, display, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        display.setDisplayID(nil)
        #expect(
            await engine.submit(
                SpaceSwitchRequest(
                    action: .step(.right),
                    source: .gesture,
                    targetDisplayID: displayA,
                    wraps: false,
                    velocity: 100
                )
            ) == .unavailable
        )
        display.setDisplayID(displayB)
        #expect(
            await engine.submit(
                SpaceSwitchRequest(
                    action: .step(.right),
                    source: .gesture,
                    targetDisplayID: displayA,
                    wraps: false,
                    velocity: 100
                )
            ) == .unavailable
        )
        #expect(poster.posts.isEmpty)

        display.setDisplayID(displayA)
        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .index(2),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 2)

        display.setDisplayID(nil)
        system.setSnapshot(snapshot(currentA: 102))
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 2)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(102))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("Changing overlay mode cancels an active transaction")
    func overlayModeChangeCancelsTransaction() async throws {
        let overlays = TestOverlayDetector(mode: .none)
        let (engine, _, _, poster, sleeper) = makeEngine(
            snapshot: snapshot(currentA: 100),
            overlayDetector: overlays
        )
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .index(2),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 2)
        await sleeper.waitForWaiter()

        overlays.setMode(.missionControl)
        await engine.refresh(reason: .passive)
        await sleeper.waitUntilEmpty()
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 2)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(100))
        #expect(presentation.lastSpaceByDisplay[displayA] == nil)
    }

    @Test("App Exposé and unknown overlay state reject every input source")
    func unsafeOverlayModesRejectRequests() async {
        for mode in [OverlayMode.appExpose, .unknown] {
            let (engine, _, _, poster, _) = makeEngine(
                snapshot: snapshot(currentA: 100),
                mode: mode
            )
            await engine.start()

            for source in [SpaceInputSource.gesture, .hotkey, .menu] {
                #expect(
                    await engine.submit(
                        SpaceSwitchRequest(
                            action: .step(.right),
                            source: source,
                            targetDisplayID: displayA,
                            wraps: false,
                            velocity: 100
                        )
                    ) == .unavailable
                )
            }
            #expect(poster.posts.isEmpty)
            await engine.stop()
        }
    }

    @Test("A captured gesture posting mode is rejected instead of reinterpreted")
    func requiredPostingModeDisagreementIsRejected() async {
        let overlays = TestOverlayDetector(mode: .missionControl)
        let (engine, _, _, poster, _) = makeEngine(
            snapshot: snapshot(currentA: 100),
            overlayDetector: overlays
        )
        await engine.start()

        let instantOutcome = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100,
                requiredMode: .instant
            )
        )
        #expect(instantOutcome == .unavailable)

        overlays.setMode(.none)
        let missionControlOutcome = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100,
                requiredMode: .missionControl
            )
        )
        #expect(missionControlOutcome == .unavailable)
        #expect(poster.posts.isEmpty)
    }

    @Test("A topology reorder cancels active work")
    func topologyReorderCancelsTransaction() async throws {
        let (engine, system, _, poster, sleeper) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .index(2),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 2)

        system.setSnapshot(snapshot(currentA: 100, spacesA: [100, 102, 101, 103]))
        await engine.refresh(reason: .passive)
        await sleeper.waitUntilEmpty()
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 2)
        #expect(
            presentation.snapshot?.topologiesByDisplay[displayA]?.spaceIDs
                == [100, 102, 101, 103].map(space))
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(100))
        #expect(presentation.lastSpaceByDisplay[displayA] == nil)
    }

    @Test("Removing a display discards its transaction and history")
    func displayRemovalDiscardsState() async throws {
        let (engine, system, _, poster, sleeper) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .index(3),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 3)

        system.setSnapshot(emptySnapshot())
        await engine.refresh(reason: .passive)
        await sleeper.waitUntilEmpty()
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 3)
        #expect(presentation.projectedSpaceByDisplay[displayA] == nil)
        #expect(presentation.lastSpaceByDisplay[displayA] == nil)
        #expect(presentation.snapshot?.topologiesByDisplay.isEmpty == true)
    }

    @Test("An idle external transition records Last Space")
    func idleExternalTransitionRecordsHistory() async {
        let (engine, system, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        system.setSnapshot(snapshot(currentA: 102))
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()

        #expect(poster.posts.isEmpty)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(102))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("Last Space resolves from request-time authoritative reconciliation")
    func lastSpaceUsesRequestTimeHistory() async {
        let (engine, system, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        system.setSnapshot(snapshot(currentA: 102))
        #expect(await engine.submit(SpaceSwitchRequest(
            action: .lastSpace,
            source: .hotkey,
            targetDisplayID: displayA,
            wraps: false,
            velocity: 100
        )) == .accepted)
        #expect(poster.posts.count == 1)
        #expect(poster.posts.allSatisfy { $0.direction == .left })
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(101))
    }

    @Test("Unexpected authoritative movement cancels the transaction")
    func unexpectedAuthoritativeMovementCancelsTransaction() async throws {
        let (engine, system, _, poster, sleeper) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .index(2),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 2)

        system.setSnapshot(snapshot(currentA: 103))
        await engine.refresh(reason: .activeSpaceChanged)
        await sleeper.waitUntilEmpty()
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 2)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(103))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("Posting failure rolls projection back to authoritative state")
    func postingFailureRollsBackProjection() async {
        let (engine, _, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        poster.fail(attempt: 1)
        await engine.start()

        let outcome = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        let presentation = await engine.presentation()

        #expect(outcome == .unavailable)
        #expect(poster.attempts == 1)
        #expect(poster.posts.isEmpty)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(100))
        #expect(presentation.lastSpaceByDisplay[displayA] == nil)
    }

    @Test("A partially posted window remains tracked and resumes after acknowledgement")
    func partialPostingFailureRemainsTracked() async throws {
        let recorder = TestDiagnosticRecorder()
        let spaces = Array(UInt64(100)...UInt64(104))
        let (engine, system, _, poster, _) = makeEngine(
            snapshot: snapshot(currentA: 100, spacesA: spaces),
            diagnosticRecorder: recorder
        )
        poster.fail(attempt: 3)
        await engine.start()

        let outcome = await engine.submit(
            SpaceSwitchRequest(
                action: .index(4),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )

        #expect(outcome == .accepted)
        #expect(poster.attempts == 3)
        #expect(poster.posts.count == 2)
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(104))
        #expect(recorder.messages.contains { $0.contains("partial-failure=true") })

        system.setSnapshot(snapshot(currentA: 102, spacesA: spaces))
        await engine.refresh(reason: .activeSpaceChanged)
        #expect(poster.attempts == 5)
        #expect(poster.posts.count == 4)

        system.setSnapshot(snapshot(currentA: 104, spacesA: spaces))
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(104))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("Intermediate acknowledgements preserve existing Last Space")
    func intermediateAcknowledgementsPreserveHistory() async throws {
        let (engine, system, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        system.setSnapshot(snapshot(currentA: 103))
        await engine.refresh(reason: .activeSpaceChanged)
        system.setSnapshot(snapshot(currentA: 100))
        await engine.refresh(reason: .activeSpaceChanged)
        #expect((await engine.presentation()).lastSpaceByDisplay[displayA] == space(103))

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .index(2),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 2)
        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        #expect(poster.posts.count == 2)

        let intermediate = await engine.presentation()
        #expect(intermediate.projectedSpaceByDisplay[displayA] == space(102))
        #expect(intermediate.lastSpaceByDisplay[displayA] == space(103))

        system.setSnapshot(snapshot(currentA: 102))
        await engine.refresh(reason: .activeSpaceChanged)
        let settled = await engine.presentation()
        #expect(settled.projectedSpaceByDisplay[displayA] == space(102))
        #expect(settled.lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("Returning to the transaction origin preserves prior history")
    func returningToOriginPreservesHistory() async throws {
        let (engine, system, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        system.setSnapshot(snapshot(currentA: 103))
        await engine.refresh(reason: .activeSpaceChanged)
        system.setSnapshot(snapshot(currentA: 100))
        await engine.refresh(reason: .activeSpaceChanged)

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .index(2),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 2)
        #expect(
            await engine.submit(
                SpaceSwitchRequest(
                    action: .index(0),
                    source: .menu,
                    targetDisplayID: displayA,
                    wraps: false,
                    velocity: 100
                )
            ) == .accepted
        )
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(100))

        system.setSnapshot(snapshot(currentA: 102))
        await engine.refresh(reason: .activeSpaceChanged)
        #expect(poster.posts.count == 4)
        #expect(poster.posts.map(\.direction) == [.right, .right, .left, .left])
        #expect((await engine.presentation()).lastSpaceByDisplay[displayA] == space(103))

        system.setSnapshot(snapshot(currentA: 100))
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(100))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(103))
    }

    @Test("Snapshot-load failures fail closed and roll back timed-out projection")
    func snapshotLoadFailureFailsClosed() async throws {
        let diagnostics = TestDiagnosticRecorder()
        let (engine, system, _, poster, sleeper) = makeEngine(
            snapshot: snapshot(currentA: 100),
            diagnosticRecorder: diagnostics
        )
        await engine.start()

        system.failNextLoad()
        let unavailable = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .hotkey,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(unavailable == .unavailable)
        #expect(poster.posts.isEmpty)

        #expect(
            await engine.submit(
                SpaceSwitchRequest(
                    action: .step(.right),
                    source: .hotkey,
                    targetDisplayID: displayA,
                    wraps: false,
                    velocity: 100
                )
            ) == .accepted
        )
        #expect(poster.posts.count == 1)
        await sleeper.waitForWaiter()

        system.failNextLoad()
        let failed = Task {
            await diagnostics.message(containing: "acknowledgement unverifiable")
        }
        await sleeper.resumeFirst()
        _ = await failed.value
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(100))
        #expect(poster.posts.count == 1)
        #expect((await engine.presentation()).lastSpaceByDisplay[displayA] == nil)
    }

    @Test("A timeout reconciles a fresh snapshot that already advanced")
    func timeoutReconcilesFreshAdvancedSnapshot() async throws {
        let (engine, system, _, poster, sleeper) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .index(2),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 2)
        await sleeper.waitForWaiter()

        system.setSnapshot(snapshot(currentA: 101))
        await sleeper.resumeFirst()
        await sleeper.waitForWaiter()
        #expect(poster.posts.map(\.direction) == [.right, .right])
        #expect((await engine.presentation()).lastSpaceByDisplay[displayA] == nil)

        system.setSnapshot(snapshot(currentA: 102))
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(102))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("A captured display is not retargeted when the cursor moves")
    func capturedDisplayIsNotRetargeted() async {
        let initial = snapshot(currentA: 100, currentB: 200)
        let (engine, _, display, poster, _) = makeEngine(snapshot: initial)
        await engine.start()
        let request = SpaceSwitchRequest(
            action: .step(.right),
            source: .hotkey,
            targetDisplayID: displayA,
            wraps: false,
            velocity: 100
        )

        display.setDisplayID(displayB)
        let outcome = await engine.submit(request)
        let presentation = await engine.presentation()

        #expect(outcome == .unavailable)
        #expect(poster.posts.isEmpty)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(100))
        #expect(presentation.projectedSpaceByDisplay[displayB] == space(200))
    }

    @Test("Presentation delivery is bounded and finishes with the latest state")
    func presentationsDeliverLatestState() async throws {
        let diagnostics = TestDiagnosticRecorder()
        let (engine, _, _, poster, sleeper) = makeEngine(
            snapshot: snapshot(currentA: 100),
            diagnosticRecorder: diagnostics
        )
        let valuesTask = Task { @MainActor in
            var values: [SpaceID?] = []
            for await presentation in engine.presentations {
                values.append(presentation.projectedSpaceByDisplay[self.displayA])
            }
            return values
        }

        await engine.start()
        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 1)
        await sleeper.waitForWaiter()
        let timeout = Task { await diagnostics.message(containing: "timeout display=") }
        await sleeper.resumeFirst()
        _ = await timeout.value
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(100))
        await engine.stop()

        let values = await valuesTask.value
        #expect(!values.isEmpty)
        #expect(values.last! == nil)
    }

    @Test("Stopping finishes the presentation stream")
    func stopFinishesPresentationStream() async {
        let (engine, _, _, _, _) = makeEngine(snapshot: snapshot(currentA: 100))
        let consumer = Task { @MainActor in
            var count = 0
            for await _ in engine.presentations {
                count += 1
            }
            return count
        }

        await engine.start()
        await engine.stop()

        let count = await consumer.value
        #expect((1...2).contains(count))
    }

    @Test("Stopping while acknowledgement is pending cancels all work")
    func stopCancelsPendingWork() async throws {
        let (engine, system, _, poster, sleeper) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .index(3),
                source: .menu,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 3)
        await sleeper.waitForWaiter()

        await engine.stop()
        await sleeper.waitUntilEmpty()
        system.setSnapshot(snapshot(currentA: 101))
        await sleeper.resumeAll()

        let presentation = await engine.presentation()
        #expect(poster.posts.count == 3)
        #expect(presentation.snapshot == nil)
        #expect(presentation.projectedSpaceByDisplay.isEmpty)
        #expect(presentation.lastSpaceByDisplay.isEmpty)
    }

    @Test("Engine lifecycle operations are idempotent")
    func lifecycleIsIdempotent() async throws {
        let (engine, _, _, poster, sleeper) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()
        await engine.start()
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(100))

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        #expect(poster.posts.count == 1)
        await engine.start()
        #expect(poster.posts.count == 1)

        await engine.stop()
        await engine.stop()
        await engine.refresh(reason: .passive)
        #expect(await engine.submit(SpaceSwitchRequest(
            action: .step(.right),
            source: .hotkey,
            targetDisplayID: displayA,
            wraps: false,
            velocity: 100
        )) == .unavailable)
        await sleeper.waitUntilEmpty()
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 1)
        #expect(presentation.snapshot == nil)
        #expect(presentation.projectedSpaceByDisplay.isEmpty)
    }
}
