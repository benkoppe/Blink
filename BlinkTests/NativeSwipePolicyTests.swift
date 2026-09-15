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
        #expect(policy.begin(.recognition))
        bypass = false
        #expect(policy.begin(.suppression))
        policy.end(.recognition)
        policy.end(.suppression)
        #expect(!policy.begin(.recognition))
    }

    @Test("Reset discards interrupted native gesture state")
    func reset() {
        let policy = NativeSwipePolicy()
        policy.shouldBypass = { true }
        #expect(policy.begin(.suppression))
        policy.reset()
        policy.shouldBypass = { false }
        #expect(!policy.begin(.recognition))
    }

    @Test("Source PID distinguishes native from app-posted input")
    func sourceClassification() throws {
        let event = try #require(CGEvent(source: nil))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
        #expect(!NativeSwipePolicy.isAppPosted(event))
        event.setIntegerValueField(.eventSourceUnixProcessID, value: 123)
        #expect(NativeSwipePolicy.isAppPosted(event))
    }
}
