import CoreGraphics
import Testing

@testable import Blink

@MainActor
@Suite("Native swipe policy")
struct NativeSwipePolicyTests {
    @Test("Both streams share a decision until both finish")
    func sharedDecision() {
        let policy = NativeSwipePolicy()
        var bypass = true
        policy.shouldBypass = { bypass }
        let recognition = policy.begin(.recognition)
        #expect(recognition.bypass)
        bypass = false
        let suppression = policy.begin(.suppression)
        #expect(suppression == recognition)
        policy.end(.recognition, session: recognition)
        policy.end(.suppression, session: suppression)
        #expect(!policy.begin(.recognition).bypass)
    }

    @Test("Reset discards interrupted native gesture state")
    func reset() {
        let policy = NativeSwipePolicy()
        policy.shouldBypass = { true }
        #expect(policy.begin(.suppression).bypass)
        policy.reset()
        policy.shouldBypass = { false }
        #expect(!policy.begin(.recognition).bypass)
    }

    @Test("Stream ordering doesn't change the latched decision", arguments: [true, false])
    func streamOrder(recognitionFirst: Bool) {
        let policy = NativeSwipePolicy()
        var queries = 0
        policy.shouldBypass = { queries += 1; return true }
        let first: NativeSwipePolicy.Consumer = recognitionFirst ? .recognition : .suppression
        let second: NativeSwipePolicy.Consumer = recognitionFirst ? .suppression : .recognition
        let session = policy.begin(first)
        #expect(policy.begin(second) == session)
        policy.end(second, session: session)
        policy.end(first, session: session)
        #expect(queries == 1)
        #expect(policy.begin(first).generation != session.generation)
        #expect(queries == 2)
    }

    @Test("A missing terminal event cannot carry bypass into the next gesture")
    func missingEnd() {
        let policy = NativeSwipePolicy()
        policy.shouldBypass = { true }
        let old = policy.begin(.recognition)
        #expect(policy.begin(.suppression) == old)
        policy.end(.recognition, session: old)
        policy.shouldBypass = { false }
        let next = policy.begin(.recognition)
        #expect(!next.bypass)
        #expect(next.generation != old.generation)
        policy.end(.suppression, session: old)
        #expect(policy.begin(.suppression) == next)
    }

    @Test("Duplicate beginnings and shared resets invalidate queued generations")
    func invalidation() {
        let policy = NativeSwipePolicy()
        let first = policy.begin(.recognition)
        let second = policy.begin(.recognition)
        #expect(first.generation != second.generation)
        policy.reset()
        #expect(policy.generation != second.generation)
        let third = policy.begin(.suppression)
        policy.end(.recognition, session: second)
        #expect(policy.begin(.recognition) == third)
    }

    @Test("Source PID or a legacy marker distinguishes native from app-posted input")
    func sourceClassification() throws {
        let event = try #require(CGEvent(source: nil))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        #expect(!NativeSwipePolicy.isAppPosted(event))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 123)
        #expect(NativeSwipePolicy.isAppPosted(event))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        event.setIntegerValueField(
            NativeSwipePolicy.syntheticMarkerField,
            value: NativeSwipePolicy.syntheticMarkerValue
        )
        #expect(NativeSwipePolicy.isAppPosted(event))
    }

    @Test("A late Dock beginning cannot discard a recognized swipe", arguments: [true, false])
    func queuedSwipeSurvivesDockSession(recognitionFirst: Bool) {
        var pending: [@MainActor () -> Void] = []
        let delivery = SwipeActionDelivery(schedule: { pending.append($0) })
        let policy = NativeSwipePolicy()

        let recognition: NativeSwipePolicy.Session
        if recognitionFirst {
            recognition = policy.begin(.recognition)
        } else {
            let suppression = policy.begin(.suppression)
            recognition = policy.begin(.recognition)
            policy.end(.suppression, session: suppression)
        }
        var delivered = 0
        delivery.enqueue { delivered += 1 }
        policy.end(.recognition, session: recognition)

        _ = policy.begin(.suppression)
        #expect(policy.generation != recognition.generation)
        pending.removeFirst()()
        #expect(delivered == 1)
    }

    @Test("Stopping recognition invalidates queued swipes")
    func queuedSwipeInvalidation() {
        var pending: [@MainActor () -> Void] = []
        let delivery = SwipeActionDelivery(schedule: { pending.append($0) })
        var delivered = 0
        delivery.enqueue { delivered += 1 }
        delivery.invalidate()
        pending.removeFirst()()
        #expect(delivered == 0)

        delivery.enqueue { delivered += 1 }
        pending.removeFirst()()
        #expect(delivered == 1)
    }
}
