import Foundation
import Testing

@testable import Blink

private actor ControlledSleeper {
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waitingCount: Int {
        waiters.count
    }

    func sleep(_ duration: Duration) async throws {
        _ = duration

        try Task.checkCancellation()

        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in

            waiters.append(continuation)
        }

        try Task.checkCancellation()
    }

    func resumeFirst() {
        guard !waiters.isEmpty else {
            return
        }

        waiters.removeFirst().resume()
    }

    func resumeAll() {
        let currentWaiters = waiters
        waiters.removeAll()

        for continuation in currentWaiters {
            continuation.resume()
        }
    }
}

private enum HarnessError: Error {
    case invalidTopology
    case missingContext(String)
    case conditionTimedOut
    case sleeperTimedOut
}

@MainActor
private final class CoordinatorHarness {
    nonisolated struct Post: Equatable, Sendable {
        let displayIdentifier: String
        let gestureMode: SpaceSwitchCoordinator.GestureMode
        let direction: SpaceSwitchCoordinator.Direction
        let velocity: Double
    }

    let sleeper = ControlledSleeper()

    var cursorDisplayIdentifier = "display-a"

    private(set) var contexts: [String: SpaceSwitchCoordinator.Context] = [:]

    private(set) var posts: [Post] = []
    private(set) var postAttempts = 0

    var failingPostAttempt: Int?

    lazy var coordinator = SpaceSwitchCoordinator(
        dependencies: .init(
            loadContext: { [weak self] displayIdentifier in
                guard
                    let self,
                    self.cursorDisplayIdentifier == displayIdentifier
                else {
                    return nil
                }

                return self.contexts[displayIdentifier]
            },
            postStep: {
                [weak self]
                gestureMode,
                direction,
                velocity in

                guard let self else { return false }

                self.postAttempts += 1

                if self.postAttempts == self.failingPostAttempt {
                    return false
                }

                self.posts.append(
                    Post(
                        displayIdentifier:
                            self.cursorDisplayIdentifier,
                        gestureMode: gestureMode,
                        direction: direction,
                        velocity: velocity
                    )
                )

                return true
            },
            sleep: { [weak self] duration in
                guard let self else {
                    throw CancellationError()
                }

                try await self.sleeper.sleep(duration)
            }
        )
    )

    func configureDisplay(
        _ displayIdentifier: String,
        spaceIDs: [UInt64],
        currentSpaceID: UInt64,
        gestureMode:
            SpaceSwitchCoordinator.GestureMode = .instant,
        reason:
            SpaceSwitchCoordinator.ReconciliationReason = .passiveRefresh
    ) throws {
        guard
            let topology =
                SpaceSwitchCoordinator.Topology(
                    displayIdentifier: displayIdentifier,
                    spaceIDs: spaceIDs,
                    currentSpaceID: currentSpaceID
                )
        else {
            throw HarnessError.invalidTopology
        }

        contexts[displayIdentifier] =
            SpaceSwitchCoordinator.Context(
                topology: topology,
                gestureMode: gestureMode
            )

        reconcile(reason: reason)
    }

    func context(
        for displayIdentifier: String
    ) throws -> SpaceSwitchCoordinator.Context {
        guard let context = contexts[displayIdentifier] else {
            throw HarnessError.missingContext(
                displayIdentifier
            )
        }

        return context
    }

    func topology(
        for displayIdentifier: String
    ) throws -> SpaceSwitchCoordinator.Topology {
        try context(for: displayIdentifier).topology
    }

    func makeContextUnavailable(
        for displayIdentifier: String
    ) {
        contexts.removeValue(forKey: displayIdentifier)
    }

    func changeModeWithoutReconciliation(
        for displayIdentifier: String,
        to gestureMode:
            SpaceSwitchCoordinator.GestureMode
    ) throws {
        let existingContext = try context(
            for: displayIdentifier
        )

        contexts[displayIdentifier] =
            SpaceSwitchCoordinator.Context(
                topology: existingContext.topology,
                gestureMode: gestureMode
            )
    }

    func removeDisplay(
        _ displayIdentifier: String,
        reason:
            SpaceSwitchCoordinator.ReconciliationReason = .passiveRefresh
    ) {
        contexts.removeValue(forKey: displayIdentifier)
        reconcile(reason: reason)
    }

    func reconcile(
        reason:
            SpaceSwitchCoordinator.ReconciliationReason
    ) {
        coordinator.reconcile(
            topologies: contexts.mapValues(\.topology),
            reason: reason
        )
    }
}

@MainActor
@Suite("Space switch coordinator")
struct SpaceSwitchCoordinatorTests {
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<2_000 {
            if condition() {
                return
            }

            await Task.yield()
        }

        throw HarnessError.conditionTimedOut
    }

    private func waitForSleeper(
        _ sleeper: ControlledSleeper,
        count: Int
    ) async throws {
        for _ in 0..<2_000 {
            if await sleeper.waitingCount == count {
                return
            }

            await Task.yield()
        }

        throw HarnessError.sleeperTimedOut
    }

    @Test("Topology rejects invalid values")
    func topologyRejectsInvalidValues() async {
        #expect(
            SpaceSwitchCoordinator.Topology(
                displayIdentifier: "",
                spaceIDs: [100],
                currentSpaceID: 100
            ) == nil
        )

        #expect(
            SpaceSwitchCoordinator.Topology(
                displayIdentifier: "display-a",
                spaceIDs: [],
                currentSpaceID: 100
            ) == nil
        )

        #expect(
            SpaceSwitchCoordinator.Topology(
                displayIdentifier: "display-a",
                spaceIDs: [100, 100],
                currentSpaceID: 100
            ) == nil
        )

        #expect(
            SpaceSwitchCoordinator.Topology(
                displayIdentifier: "display-a",
                spaceIDs: [100, 101],
                currentSpaceID: 999
            ) == nil
        )

        #expect(
            SpaceSwitchCoordinator.Topology(
                displayIdentifier: "display-a",
                spaceIDs: [100, 101],
                currentSpaceID: 100
            ) != nil
        )
    }

    @Test("A one-Space display cannot move")
    func oneSpaceDisplayCannotMove() throws {
        let harness = CoordinatorHarness()

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100],
            currentSpaceID: 100
        )

        let topology = try harness.topology(
            for: "display-a"
        )

        #expect(
            !harness.coordinator.canMove(
                .left,
                in: topology,
                wrap: false
            )
        )

        #expect(
            !harness.coordinator.canMove(
                .right,
                in: topology,
                wrap: true
            )
        )

        #expect(
            !harness.coordinator.submitStep(
                .right,
                context: try harness.context(
                    for: "display-a"
                ),
                wrap: true,
                baseVelocity: 100
            )
        )
    }

    @Test("Repeated directions accumulate from the desired endpoint")
    func repeatedDirectionsUseDesiredEndpoint() async throws {
        let harness = CoordinatorHarness()

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102, 103],
            currentSpaceID: 100
        )

        let context = try harness.context(
            for: "display-a"
        )

        #expect(
            harness.coordinator.submitStep(
                .right,
                context: context,
                wrap: false,
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 1
        }

        #expect(
            harness.coordinator.desiredSpaceID(
                for: "display-a"
            ) == 101
        )

        #expect(
            harness.coordinator.submitStep(
                .right,
                context: context,
                wrap: false,
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 2
        }

        #expect(
            harness.coordinator.desiredSpaceID(
                for: "display-a"
            ) == 102
        )

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 102
        )

        #expect(
            harness.posts.map(\.direction)
                == [.right, .right]
        )
    }

    @Test("Instant jumps post no more than four steps per batch")
    func instantJumpsUseFourStepBatches()
        async throws
    {
        let harness = CoordinatorHarness()
        let spaces = Array(UInt64(100)...UInt64(106))

        try harness.configureDisplay(
            "display-a",
            spaceIDs: spaces,
            currentSpaceID: 100
        )

        #expect(
            harness.coordinator.submitTarget(
                106,
                context: try harness.context(
                    for: "display-a"
                ),
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 4
        }

        try await waitForSleeper(
            harness.sleeper,
            count: 1
        )

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 104
        )

        #expect(
            harness.coordinator.desiredSpaceID(
                for: "display-a"
            ) == 106
        )

        #expect(
            harness.posts.allSatisfy {
                $0.direction == .right
                    && $0.velocity == 600
            }
        )

        await harness.sleeper.resumeFirst()

        try await waitUntil {
            harness.posts.count == 6
        }

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 106
        )

        #expect(
            Array(harness.posts.suffix(2))
                .allSatisfy {
                    $0.velocity == 200
                }
        )
    }

    @Test("Mission Control posts one step per interval")
    func missionControlPostsOneStepPerInterval()
        async throws
    {
        let harness = CoordinatorHarness()

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102, 103],
            currentSpaceID: 100,
            gestureMode: .missionControl
        )

        #expect(
            harness.coordinator.submitTarget(
                103,
                context: try harness.context(
                    for: "display-a"
                ),
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 1
        }

        try await waitForSleeper(
            harness.sleeper,
            count: 1
        )

        #expect(
            harness.posts.allSatisfy {
                $0.gestureMode == .missionControl
            }
        )

        await harness.sleeper.resumeFirst()

        try await waitUntil {
            harness.posts.count == 2
        }

        try await waitForSleeper(
            harness.sleeper,
            count: 1
        )

        await harness.sleeper.resumeFirst()

        try await waitUntil {
            harness.posts.count == 3
        }

        #expect(
            harness.posts.map(\.direction)
                == [.right, .right, .right]
        )
    }

    @Test("A direct target supersedes queued work")
    func directTargetSupersedesQueuedWork()
        async throws
    {
        let harness = CoordinatorHarness()
        let spaces = Array(UInt64(100)...UInt64(107))

        try harness.configureDisplay(
            "display-a",
            spaceIDs: spaces,
            currentSpaceID: 100
        )

        let context = try harness.context(
            for: "display-a"
        )

        #expect(
            harness.coordinator.submitTarget(
                107,
                context: context,
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 4
        }

        try await waitForSleeper(
            harness.sleeper,
            count: 1
        )

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 104
        )

        #expect(
            harness.coordinator.submitTarget(
                101,
                context: context,
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 7
        }

        #expect(
            Array(harness.posts.prefix(4))
                .map(\.direction)
                == [.right, .right, .right, .right]
        )

        #expect(
            Array(harness.posts.suffix(3))
                .map(\.direction)
                == [.left, .left, .left]
        )

        #expect(
            harness.coordinator.desiredSpaceID(
                for: "display-a"
            ) == 101
        )

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 101
        )

        let postCount = harness.posts.count
        await harness.sleeper.resumeAll()

        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(harness.posts.count == postCount)
    }

    @Test("Moving the cursor cancels remaining work")
    func cursorMovementCancelsRemainingWork()
        async throws
    {
        let harness = CoordinatorHarness()
        let spaces = Array(UInt64(100)...UInt64(107))

        try harness.configureDisplay(
            "display-a",
            spaceIDs: spaces,
            currentSpaceID: 100
        )

        #expect(
            harness.coordinator.submitTarget(
                107,
                context: try harness.context(
                    for: "display-a"
                ),
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 4
        }

        try await waitForSleeper(
            harness.sleeper,
            count: 1
        )

        harness.cursorDisplayIdentifier = "display-b"
        await harness.sleeper.resumeFirst()

        try await waitUntil {
            !harness.coordinator.hasActiveCommand(
                for: "display-a"
            )
        }

        #expect(harness.posts.count == 4)

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 100
        )
    }

    @Test("Missing fresh context cancels remaining work")
    func missingFreshContextCancelsRemainingWork()
        async throws
    {
        let harness = CoordinatorHarness()
        let spaces = Array(UInt64(100)...UInt64(107))

        try harness.configureDisplay(
            "display-a",
            spaceIDs: spaces,
            currentSpaceID: 100
        )

        #expect(
            harness.coordinator.submitTarget(
                107,
                context: try harness.context(
                    for: "display-a"
                ),
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 4
        }

        try await waitForSleeper(
            harness.sleeper,
            count: 1
        )

        harness.makeContextUnavailable(
            for: "display-a"
        )

        await harness.sleeper.resumeFirst()

        try await waitUntil {
            !harness.coordinator.hasActiveCommand(
                for: "display-a"
            )
        }

        #expect(harness.posts.count == 4)

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 100
        )
    }

    @Test("Changing gesture mode cancels an active command")
    func gestureModeChangeCancelsCommand()
        async throws
    {
        let harness = CoordinatorHarness()
        let spaces = Array(UInt64(100)...UInt64(107))

        try harness.configureDisplay(
            "display-a",
            spaceIDs: spaces,
            currentSpaceID: 100
        )

        #expect(
            harness.coordinator.submitTarget(
                107,
                context: try harness.context(
                    for: "display-a"
                ),
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 4
        }

        try await waitForSleeper(
            harness.sleeper,
            count: 1
        )

        try harness.changeModeWithoutReconciliation(
            for: "display-a",
            to: .missionControl
        )

        await harness.sleeper.resumeFirst()

        try await waitUntil {
            !harness.coordinator.hasActiveCommand(
                for: "display-a"
            )
        }

        #expect(harness.posts.count == 4)
    }

    @Test("Only one display can own the posting worker")
    func postingIsSerializedAcrossDisplays()
        async throws
    {
        let harness = CoordinatorHarness()
        let spacesA = Array(UInt64(100)...UInt64(107))
        let spacesB: [UInt64] = [200, 201, 202]

        try harness.configureDisplay(
            "display-a",
            spaceIDs: spacesA,
            currentSpaceID: 100
        )

        try harness.configureDisplay(
            "display-b",
            spaceIDs: spacesB,
            currentSpaceID: 200
        )

        #expect(
            harness.coordinator.submitTarget(
                107,
                context: try harness.context(
                    for: "display-a"
                ),
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 4
        }

        try await waitForSleeper(
            harness.sleeper,
            count: 1
        )

        harness.cursorDisplayIdentifier = "display-b"

        #expect(
            harness.coordinator.submitTarget(
                201,
                context: try harness.context(
                    for: "display-b"
                ),
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 5
        }

        #expect(
            !harness.coordinator.hasActiveCommand(
                for: "display-a"
            )
        )

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 100
        )

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-b"
            ) == 201
        )

        #expect(
            harness.posts.last?.displayIdentifier
                == "display-b"
        )

        let postCount = harness.posts.count
        await harness.sleeper.resumeAll()

        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(harness.posts.count == postCount)
    }

    @Test("Intermediate acknowledgements do not change Last Space")
    func intermediateAcknowledgementsPreserveHistory()
        async throws
    {
        let harness = CoordinatorHarness()

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102],
            currentSpaceID: 100
        )

        #expect(
            harness.coordinator.submitTarget(
                102,
                context: try harness.context(
                    for: "display-a"
                ),
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 2
        }

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102],
            currentSpaceID: 101,
            reason: .activeSpaceChanged
        )

        #expect(
            harness.coordinator.hasActiveCommand(
                for: "display-a"
            )
        )

        #expect(
            harness.coordinator.lastSpaceID(
                for: try harness.topology(
                    for: "display-a"
                )
            ) == nil
        )

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102],
            currentSpaceID: 102,
            reason: .activeSpaceChanged
        )

        #expect(
            !harness.coordinator.hasActiveCommand(
                for: "display-a"
            )
        )

        #expect(
            harness.coordinator.lastSpaceID(
                for: try harness.topology(
                    for: "display-a"
                )
            ) == 100
        )
    }

    @Test("An idle external transition records Last Space")
    func externalTransitionRecordsLastSpace() throws {
        let harness = CoordinatorHarness()

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102],
            currentSpaceID: 100
        )

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102],
            currentSpaceID: 101,
            reason: .activeSpaceChanged
        )

        #expect(
            harness.coordinator.lastSpaceID(
                for: try harness.topology(
                    for: "display-a"
                )
            ) == 100
        )
    }

    @Test("Unexpected authoritative movement cancels the command")
    func unexpectedMovementCancelsCommand()
        async throws
    {
        let harness = CoordinatorHarness()

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102, 103],
            currentSpaceID: 100
        )

        #expect(
            harness.coordinator.submitTarget(
                102,
                context: try harness.context(
                    for: "display-a"
                ),
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 2
        }

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102, 103],
            currentSpaceID: 103,
            reason: .activeSpaceChanged
        )

        #expect(
            !harness.coordinator.hasActiveCommand(
                for: "display-a"
            )
        )

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 103
        )

        #expect(
            harness.coordinator.lastSpaceID(
                for: try harness.topology(
                    for: "display-a"
                )
            ) == 100
        )
    }

    @Test("Topology reorder cancels active work")
    func topologyReorderCancelsCommand()
        async throws
    {
        let harness = CoordinatorHarness()

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102],
            currentSpaceID: 100
        )

        #expect(
            harness.coordinator.submitTarget(
                102,
                context: try harness.context(
                    for: "display-a"
                ),
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 2
        }

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 102, 101],
            currentSpaceID: 100,
            reason: .passiveRefresh
        )

        #expect(
            !harness.coordinator.hasActiveCommand(
                for: "display-a"
            )
        )

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 100
        )
    }

    @Test("Display removal discards coordinator state")
    func displayRemovalDiscardsState()
        async throws
    {
        let harness = CoordinatorHarness()
        let spaces = Array(UInt64(100)...UInt64(107))

        try harness.configureDisplay(
            "display-a",
            spaceIDs: spaces,
            currentSpaceID: 100
        )

        #expect(
            harness.coordinator.submitTarget(
                107,
                context: try harness.context(
                    for: "display-a"
                ),
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 4
        }

        try await waitForSleeper(
            harness.sleeper,
            count: 1
        )

        harness.removeDisplay("display-a")

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == nil
        )

        #expect(
            harness.coordinator.desiredSpaceID(
                for: "display-a"
            ) == nil
        )

        #expect(
            !harness.coordinator.hasActiveCommand(
                for: "display-a"
            )
        )
    }

    @Test("Wrapping left from the first Space travels right")
    func leftWrapTravelsRight() async throws {
        let harness = CoordinatorHarness()

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102, 103],
            currentSpaceID: 100
        )

        #expect(
            harness.coordinator.submitStep(
                .left,
                context: try harness.context(
                    for: "display-a"
                ),
                wrap: true,
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 3
        }

        #expect(
            harness.posts.map(\.direction)
                == [.right, .right, .right]
        )

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 103
        )
    }

    @Test("Wrapping right from the last Space travels left")
    func rightWrapTravelsLeft() async throws {
        let harness = CoordinatorHarness()

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102, 103],
            currentSpaceID: 103
        )

        #expect(
            harness.coordinator.submitStep(
                .right,
                context: try harness.context(
                    for: "display-a"
                ),
                wrap: true,
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 3
        }

        #expect(
            harness.posts.map(\.direction)
                == [.left, .left, .left]
        )

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 100
        )
    }

    @Test("Posting failure clears optimistic state")
    func postingFailureClearsProjection()
        async throws
    {
        let harness = CoordinatorHarness()

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101],
            currentSpaceID: 100
        )

        harness.failingPostAttempt = 1

        #expect(
            harness.coordinator.submitTarget(
                101,
                context: try harness.context(
                    for: "display-a"
                ),
                baseVelocity: 100
            )
        )

        try await waitUntil {
            !harness.coordinator.hasActiveCommand(
                for: "display-a"
            )
        }

        #expect(harness.postAttempts == 1)
        #expect(harness.posts.isEmpty)

        #expect(
            harness.coordinator.projectedSpaceID(
                for: "display-a"
            ) == 100
        )
    }

    @Test("Returning to the transaction origin preserves prior history")
    func returningToOriginPreservesHistory()
        async throws
    {
        let harness = CoordinatorHarness()

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102, 103],
            currentSpaceID: 100
        )

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102, 103],
            currentSpaceID: 103,
            reason: .activeSpaceChanged
        )

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102, 103],
            currentSpaceID: 100,
            reason: .activeSpaceChanged
        )

        #expect(
            harness.coordinator.lastSpaceID(
                for: try harness.topology(
                    for: "display-a"
                )
            ) == 103
        )

        let context = try harness.context(
            for: "display-a"
        )

        #expect(
            harness.coordinator.submitTarget(
                102,
                context: context,
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 2
        }

        #expect(
            harness.coordinator.submitTarget(
                100,
                context: context,
                baseVelocity: 100
            )
        )

        try await waitUntil {
            harness.posts.count == 4
        }

        try harness.configureDisplay(
            "display-a",
            spaceIDs: [100, 101, 102, 103],
            currentSpaceID: 100,
            reason: .activeSpaceChanged
        )

        #expect(
            !harness.coordinator.hasActiveCommand(
                for: "display-a"
            )
        )

        #expect(
            harness.coordinator.lastSpaceID(
                for: try harness.topology(
                    for: "display-a"
                )
            ) == 103
        )
    }
}
