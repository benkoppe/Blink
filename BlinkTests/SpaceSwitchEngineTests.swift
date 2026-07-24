import CoreGraphics
import Foundation
import Testing

@testable import Blink

private actor ControlledSleeper {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int { continuations.count }

    func sleep(_ duration: Duration) async throws {
        _ = duration
        try Task.checkCancellation()
        await withCheckedContinuation { continuations.append($0) }
        try Task.checkCancellation()
    }

    func resumeFirst() {
        guard !continuations.isEmpty else { return }
        continuations.removeFirst().resume()
    }

    func resumeAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private nonisolated final class TestSpaceSystem: SpaceSystemClient, @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot: SystemSpaceSnapshot

    init(snapshot: SystemSpaceSnapshot) {
        storedSnapshot = snapshot
    }

    func loadSnapshot() throws -> SystemSpaceSnapshot {
        lock.withLock { storedSnapshot }
    }

    func setSnapshot(_ snapshot: SystemSpaceSnapshot) {
        lock.withLock { storedSnapshot = snapshot }
    }
}

private nonisolated final class TestDisplayLocator: DisplayLocating, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDisplayID: DisplayID

    init(displayID: DisplayID) {
        storedDisplayID = displayID
    }

    func cursorDisplayID() throws -> DisplayID {
        lock.withLock { storedDisplayID }
    }

    func bounds(for displayID: DisplayID) -> CGRect? {
        _ = displayID
        return CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    func setDisplayID(_ displayID: DisplayID) {
        lock.withLock { storedDisplayID = displayID }
    }
}

private nonisolated struct TestOverlayDetector: OverlayDetecting, Sendable {
    let mode: OverlayMode

    func detect(on displayID: DisplayID) -> OverlayMode {
        _ = displayID
        return mode
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
    var shouldSucceed = true

    var posts: [Post] {
        lock.withLock { storedPosts }
    }

    func postStep(
        mode: SpaceSwitchMode,
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> Bool {
        lock.withLock {
            guard shouldSucceed else { return false }
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
                overlays: TestOverlayDetector(mode: mode),
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
            action: .step(.right),
            source: .gesture,
            wraps: false,
            velocity: 100
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
            action: .step(.right),
            source: .gesture,
            wraps: false,
            velocity: 100
        )
        try await waitUntil { poster.posts.count == 1 }

        _ = await engine.submit(
            action: .step(.right),
            source: .gesture,
            wraps: false,
            velocity: 100
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
            action: .step(.right),
            source: .hotkey,
            wraps: false,
            velocity: 100
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
            action: .step(.right),
            source: .gesture,
            wraps: false,
            velocity: 100
        )
        try await waitUntil { poster.posts.count == 1 }
        try await waitUntil { await sleeper.waitingCount == 1 }

        await sleeper.resumeFirst()
        try await waitUntil {
            let value = await engine.presentation()
            return value.projectedSpaceByDisplay[displayA] == space(100)
        }
    }

    @Test("Moving the cursor aborts remaining batches")
    func cursorMovementAbortsWork() async throws {
        let initial = snapshot(
            currentA: 100,
            spacesA: Array(UInt64(100)...UInt64(107)),
            currentB: 200
        )
        let (engine, system, display, poster, _) = makeEngine(snapshot: initial)
        await engine.start()

        _ = await engine.submit(
            action: .index(7),
            source: .menu,
            wraps: false,
            velocity: 100
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
        for _ in 0..<20 { await Task.yield() }
        #expect(poster.posts.count == 1)
    }

    @Test("A reversal waits for the in-flight step to be acknowledged")
    func reversalWaitsForAcknowledgement() async throws {
        let (engine, system, _, poster, _) = makeEngine(snapshot: snapshot(currentA: 100))
        await engine.start()

        _ = await engine.submit(
            action: .step(.right),
            source: .gesture,
            wraps: false,
            velocity: 100
        )
        try await waitUntil { poster.posts.count == 1 }

        _ = await engine.submit(
            action: .step(.left),
            source: .gesture,
            wraps: false,
            velocity: 100
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
                action: .step(direction),
                source: .gesture,
                wraps: false,
                velocity: 100
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

    @Test("A request on another display supersedes an unacknowledged transaction")
    func crossDisplayRequestSupersedesTransaction() async throws {
        let initial = snapshot(currentA: 100, currentB: 200)
        let (engine, _, display, poster, _) = makeEngine(snapshot: initial)
        await engine.start()

        _ = await engine.submit(
            action: .step(.right),
            source: .gesture,
            wraps: false,
            velocity: 100
        )
        try await waitUntil { poster.posts.count == 1 }

        display.setDisplayID(displayB)
        _ = await engine.submit(
            action: .step(.right),
            source: .hotkey,
            wraps: false,
            velocity: 100
        )
        try await waitUntil { poster.posts.count == 2 }

        let presentation = await engine.presentation()
        #expect(presentation.projectedSpaceByDisplay[displayA] == space(100))
        #expect(presentation.projectedSpaceByDisplay[displayB] == space(201))
    }

    @Test("Mission Control uses one post per batch")
    func missionControlUsesSingleStepBatches() async throws {
        let (engine, system, _, poster, _) = makeEngine(
            snapshot: snapshot(currentA: 100),
            mode: .missionControl
        )
        await engine.start()

        _ = await engine.submit(
            action: .index(3),
            source: .menu,
            wraps: false,
            velocity: 100
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
            action: .step(.right),
            source: .gesture,
            wraps: false,
            velocity: 100
        )
        try await waitUntil { poster.posts.count == 1 }
        try await waitUntil { await sleeper.waitingCount == 1 }
        await sleeper.resumeFirst()
        try await waitUntil { recorder.count == 1 }
    }
}
