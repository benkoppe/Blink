import Foundation
import Testing

@testable import Blink

@MainActor
private final class IndicatorClock {
    private(set) var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { waiters.append($0) }
    }

    func resumeFirst() {
        waiters.removeFirst().resume()
    }
}

@MainActor
@Suite("Space indicator presentation")
struct SpaceIndicatorPresentationTests {
    private func topology(
        current: UInt64,
        spaces: [UInt64] = [1, 2, 3]
    ) -> SpaceSwitchCoordinator.Topology {
        SpaceSwitchCoordinator.Topology(
            displayIdentifier: "display",
            spaceIDs: spaces,
            currentSpaceID: current
        )!
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() {
                return
            }
            await Task.yield()
        }
        throw WaitError.timedOut
    }

    private enum WaitError: Error {
        case timedOut
    }

    @Test("Prediction is synchronous and survives interleaved system observations")
    func staleObservations() async throws {
        let clock = IndicatorClock()
        var refreshes = 0
        let presentation = SpaceIndicatorPresentation(
            waitForSettling: { await clock.wait() },
            refreshObservedState: { refreshes += 1 }
        )
        presentation.predict(spaceID: 2, for: "display")
        #expect(presentation.displayedSpaceIndex(in: topology(current: 1)) == 1)
        presentation.discardInvalidPredictions(in: ["display": topology(current: 2)])
        presentation.discardInvalidPredictions(in: ["display": topology(current: 1)])
        #expect(presentation.displayedSpaceIndex(in: topology(current: 1)) == 1)
        try await eventually { clock.waiters.count == 1 }
        clock.resumeFirst()
        try await eventually { refreshes == 1 }
        #expect(presentation.displayedSpaceIndex(in: topology(current: 1)) == 0)
        presentation.cancelAll()
    }

    @Test("An older deadline cannot undo a newer reversal")
    func rapidReversal() async throws {
        let clock = IndicatorClock()
        var refreshes = 0
        let presentation = SpaceIndicatorPresentation(
            waitForSettling: { await clock.wait() },
            refreshObservedState: { refreshes += 1 }
        )
        presentation.predict(spaceID: 2, for: "display")
        try await eventually { clock.waiters.count == 1 }
        presentation.predict(spaceID: 1, for: "display")
        #expect(presentation.displayedSpaceIndex(in: topology(current: 2)) == 0)
        try await eventually { clock.waiters.count == 2 }
        clock.resumeFirst()
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(refreshes == 0)
        #expect(presentation.displayedSpaceIndex(in: topology(current: 2)) == 0)
        clock.resumeFirst()
        try await eventually { refreshes == 1 }
        #expect(presentation.displayedSpaceIndex(in: topology(current: 1)) == 0)
        presentation.cancelAll()
    }

    @Test("Removed target invalidates presentation without waiting for its deadline")
    func removedSpace() async throws {
        let clock = IndicatorClock()
        let presentation = SpaceIndicatorPresentation(
            waitForSettling: { await clock.wait() },
            refreshObservedState: {}
        )
        presentation.predict(spaceID: 2, for: "display")
        try await eventually { clock.waiters.count == 1 }
        let observed = topology(current: 1, spaces: [1, 3])
        presentation.discardInvalidPredictions(in: ["display": observed])
        #expect(presentation.displayedSpaceIndex(in: observed) == 0)
        clock.resumeFirst()
        presentation.cancelAll()
    }
}
