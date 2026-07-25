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
    }

    func resumeAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.continuation.resume() }
    }

    private func resume(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume()
    }
}

private enum TestDependencyError: Error {
    case unavailable
}

private nonisolated final class TestSpaceSystem: SpaceSystemClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot: SystemSpaceSnapshot
    private var remainingFailures = 0

    init(snapshot: SystemSpaceSnapshot) {
        storedSnapshot = snapshot
    }

    func loadSnapshot() throws -> SystemSpaceSnapshot {
        try lock.withLock {
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

private enum EngineTestError: Error {
    case timedOut
}

@MainActor
@Suite("Space switch engine")
struct SpaceSwitchEngineTests {
    // The deleted optimistic four-step batching assertions are intentionally omitted:
    // the engine now permits exactly one synthetic step before acknowledgement.
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
        var values: [DisplayID: DisplayTopology] = [
            displayA: DisplayTopology(
                displayID: displayA,
                spaceIDs: spacesA.map(space),
                currentSpaceID: space(currentA),
                currentSpaceKind: .desktop
            )!
        ]
        if let currentB {
            values[displayB] = DisplayTopology(
                displayID: displayB,
                spaceIDs: [200, 201, 202].map(space),
                currentSpaceID: space(currentB),
                currentSpaceKind: .desktop
            )!
        }
        return SystemSpaceSnapshot(
            topologiesByDisplay: values,
            menuBarDisplayID: displayA,
            frontmostBundleID: "test.app"
        )
    }

    private func makeEngine(
        snapshot: SystemSpaceSnapshot,
        mode: OverlayMode = .none,
        overlayDetector: TestOverlayDetector? = nil,
        failureRecorder: TestFailureRecorder? = nil
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
                sleep: { try await sleeper.sleep($0) },
                missionControlDidFail: {
                    failureRecorder?.record()
                },
                publish: { _ in }
            )
        )
        return (engine, system, display, poster, sleeper)
    }

    private func emptySnapshot() -> SystemSpaceSnapshot {
        SystemSpaceSnapshot(
            topologiesByDisplay: [:],
            menuBarDisplayID: nil,
            frontmostBundleID: nil
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () async -> Bool
    ) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            await Task.yield()
        }
        throw EngineTestError.timedOut
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

        try await waitUntil { poster.posts.count == 1 }
        let presentation = await engine.presentation()
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(101))
        #expect(poster.posts.first?.direction == .right)
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
        try await waitUntil { poster.posts.count == 1 }

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.right),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        for _ in 0..<20 { await Task.yield() }
        #expect(poster.posts.count == 1)

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        try await waitUntil { poster.posts.count == 2 }

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
        try await waitUntil { poster.posts.count == 1 }

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(101))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("An unacknowledged post rolls projection back")
    func missingAcknowledgementRollsBack() async throws {
        let (engine, _, _, poster, sleeper) = makeEngine(snapshot: snapshot(currentA: 100))
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
        try await waitUntil { poster.posts.count == 1 }
        try await waitUntil { await sleeper.waitingCount == 1 }

        await sleeper.resumeFirst()
        try await waitUntil {
            let value = await engine.presentation()
            return value.projectedSpaceByDisplay[displayA] == space(100)
        }
    }

    @Test("Moving the cursor aborts after the in-flight acknowledgement")
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
        try await waitUntil { poster.posts.count == 1 }

        display.setDisplayID(displayB)
        system.setSnapshot(
            snapshot(
                currentA: 101,
                spacesA: Array(UInt64(100)...UInt64(107)),
                currentB: 200
            )
        )
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 1)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(101))
        #expect(presentation.lastSpaceByDisplay[displayA] == nil)
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
        try await waitUntil { poster.posts.count == 1 }

        _ = await engine.submit(
            SpaceSwitchRequest(
                action: .step(.left),
                source: .gesture,
                targetDisplayID: displayA,
                wraps: false,
                velocity: 100
            )
        )
        for _ in 0..<20 { await Task.yield() }
        #expect(poster.posts.count == 1)

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        try await waitUntil { poster.posts.count == 2 }
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
        try await waitUntil { poster.posts.count == 1 }
        #expect(poster.posts.first?.direction == .right)

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        for _ in 0..<20 { await Task.yield() }
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
        try await waitUntil { poster.posts.count == 1 }
        try await waitUntil { await sleeper.waitingCount == 1 }

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
        try await waitUntil { poster.posts.count == 2 }
        try await waitUntil { await sleeper.waitingCount == 1 }

        let leased = await engine.presentation()
        #expect(leased.projectedSpaceByDisplay[displayA] == space(100))
        #expect(leased.projectedSpaceByDisplay[displayB] == space(201))
        #expect(leased.lastSpaceByDisplay[displayA] == nil)

        system.setSnapshot(snapshot(currentA: 100, currentB: 201))
        await engine.refresh(reason: .activeSpaceChanged)
        try await waitUntil { await sleeper.waitingCount == 0 }
        await sleeper.resumeAll()

        let settled = await engine.presentation()
        #expect(poster.posts.count == 2)
        #expect(settled.projectedSpaceByDisplay[displayA] == space(100))
        #expect(settled.projectedSpaceByDisplay[displayB] == space(201))
        #expect(settled.lastSpaceByDisplay[displayA] == nil)
        #expect(settled.lastSpaceByDisplay[displayB] == space(200))
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
        try await waitUntil { poster.posts.count == 1 }
        #expect(poster.posts.first?.mode == .missionControl)

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        try await waitUntil { poster.posts.count == 2 }
    }

    @Test("Mission Control failure opens the native fallback circuit")
    func missionControlFailureReportsFallback() async throws {
        let recorder = TestFailureRecorder()
        let (engine, _, _, poster, sleeper) = makeEngine(
            snapshot: snapshot(currentA: 100),
            mode: .missionControl,
            failureRecorder: recorder
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
        try await waitUntil { poster.posts.count == 1 }
        try await waitUntil { await sleeper.waitingCount == 1 }
        await sleeper.resumeFirst()
        try await waitUntil { recorder.count == 1 }
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

    @Test("Wrapping left from the first Space advances right one acknowledgement at a time")
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
        try await waitUntil { poster.posts.count == 1 }
        #expect(outcome == .accepted)
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(103))

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        try await waitUntil { poster.posts.count == 2 }
        system.setSnapshot(snapshot(currentA: 102))
        await engine.refresh(reason: .activeSpaceChanged)
        try await waitUntil { poster.posts.count == 3 }
        system.setSnapshot(snapshot(currentA: 103))
        await engine.refresh(reason: .activeSpaceChanged)

        let presentation = await engine.presentation()
        #expect(poster.posts.map(\.direction) == [.right, .right, .right])
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(103))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(100))
    }

    @Test("Wrapping right from the last Space advances left one acknowledgement at a time")
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
        try await waitUntil { poster.posts.count == 1 }
        #expect(outcome == .accepted)
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(100))

        system.setSnapshot(snapshot(currentA: 102))
        await engine.refresh(reason: .activeSpaceChanged)
        try await waitUntil { poster.posts.count == 2 }
        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        try await waitUntil { poster.posts.count == 3 }
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
        try await waitUntil { poster.posts.count == 1 }

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
        #expect(poster.posts.count == 1)
        #expect((await engine.presentation()).projectedSpaceByDisplay[displayA] == space(101))

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 1)
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
        try await waitUntil { poster.posts.count == 1 }

        display.setDisplayID(nil)
        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 1)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(101))
        #expect(presentation.lastSpaceByDisplay[displayA] == nil)
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
        try await waitUntil { poster.posts.count == 1 }
        try await waitUntil { await sleeper.waitingCount == 1 }

        overlays.setMode(.missionControl)
        await engine.refresh(reason: .passive)
        try await waitUntil { await sleeper.waitingCount == 0 }
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 1)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(100))
        #expect(presentation.lastSpaceByDisplay[displayA] == nil)
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
        try await waitUntil { poster.posts.count == 1 }

        system.setSnapshot(snapshot(currentA: 100, spacesA: [100, 102, 101, 103]))
        await engine.refresh(reason: .passive)
        try await waitUntil { await sleeper.waitingCount == 0 }
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 1)
        #expect(presentation.snapshot?.topologiesByDisplay[displayA]?.spaceIDs == [100, 102, 101, 103].map(space))
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
        try await waitUntil { poster.posts.count == 1 }

        system.setSnapshot(emptySnapshot())
        await engine.refresh(reason: .passive)
        try await waitUntil { await sleeper.waitingCount == 0 }
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 1)
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
        try await waitUntil { poster.posts.count == 1 }

        system.setSnapshot(snapshot(currentA: 103))
        await engine.refresh(reason: .activeSpaceChanged)
        try await waitUntil { await sleeper.waitingCount == 0 }
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 1)
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

        #expect(outcome == .accepted)
        #expect(poster.attempts == 1)
        #expect(poster.posts.isEmpty)
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(100))
        #expect(presentation.lastSpaceByDisplay[displayA] == nil)
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
        try await waitUntil { poster.posts.count == 1 }
        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        try await waitUntil { poster.posts.count == 2 }

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
        try await waitUntil { poster.posts.count == 1 }
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

        system.setSnapshot(snapshot(currentA: 101))
        await engine.refresh(reason: .activeSpaceChanged)
        try await waitUntil { poster.posts.count == 2 }
        #expect(poster.posts.map(\.direction) == [.right, .left])
        #expect((await engine.presentation()).lastSpaceByDisplay[displayA] == space(103))

        system.setSnapshot(snapshot(currentA: 100))
        await engine.refresh(reason: .activeSpaceChanged)
        let presentation = await engine.presentation()
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(100))
        #expect(presentation.lastSpaceByDisplay[displayA] == space(103))
    }

    @Test("Snapshot-load failures fail closed and roll back timed-out projection")
    func snapshotLoadFailureFailsClosed() async throws {
        let (engine, system, _, poster, sleeper) = makeEngine(snapshot: snapshot(currentA: 100))
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
        try await waitUntil { poster.posts.count == 1 }
        try await waitUntil { await sleeper.waitingCount == 1 }

        system.failNextLoad()
        await sleeper.resumeFirst()
        try await waitUntil {
            (await engine.presentation()).projectedSpaceByDisplay[self.displayA]
                == self.space(100)
        }
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
        try await waitUntil { poster.posts.count == 1 }
        try await waitUntil { await sleeper.waitingCount == 1 }

        system.setSnapshot(snapshot(currentA: 101))
        await sleeper.resumeFirst()
        try await waitUntil { poster.posts.count == 2 }
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
        try await waitUntil { poster.posts.count == 1 }
        try await waitUntil { await sleeper.waitingCount == 1 }

        await engine.stop()
        try await waitUntil { await sleeper.waitingCount == 0 }
        system.setSnapshot(snapshot(currentA: 101))
        await sleeper.resumeAll()
        for _ in 0..<20 { await Task.yield() }

        let presentation = await engine.presentation()
        #expect(poster.posts.count == 1)
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
        try await waitUntil { poster.posts.count == 1 }
        await engine.start()
        #expect(poster.posts.count == 1)

        await engine.stop()
        await engine.stop()
        try await waitUntil { await sleeper.waitingCount == 0 }
        let presentation = await engine.presentation()
        #expect(poster.posts.count == 1)
        #expect(presentation.snapshot == nil)
        #expect(presentation.projectedSpaceByDisplay.isEmpty)
    }
}
