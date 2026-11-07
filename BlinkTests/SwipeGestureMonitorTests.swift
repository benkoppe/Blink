import CoreGraphics
import Foundation
import Testing

@testable import Blink

@MainActor
@Suite("Swipe gesture monitor")
struct SwipeGestureMonitorTests {
    struct Swipe: Equatable, CustomStringConvertible {
        let direction: SwipeDirection
        let fingers: Int

        var description: String { "\(direction) x\(fingers)" }
    }

    @Test(
        "Each recorded swipe fires once per replay with its finger count",
        arguments: [
            ("three-finger-left", Swipe(direction: .left, fingers: 3)),
            ("three-finger-right", Swipe(direction: .right, fingers: 3)),
            ("four-finger-left", Swipe(direction: .left, fingers: 4)),
            ("firm-three-finger-right", Swipe(direction: .right, fingers: 3)),
        ]
    )
    func recordedSwipe(fixture: String, expected: Swipe) async throws {
        let swipes = try await replay(fixture, times: 2)
        #expect(swipes == [expected, expected])
    }

    @Test(
        "Recorded gestures with fewer than three fingers fire no multi-finger swipe",
        arguments: ["two-finger-scroll-left", "one-finger-click"]
    )
    func recordedNonSwipe(fixture: String) async throws {
        let multiFingerSwipes = try await replay(fixture).filter { $0.fingers >= 3 }
        #expect(multiFingerSwipes == [])
    }

    private func replay(_ fixture: String, times: Int = 1) async throws -> [Swipe] {
        let monitor = SwipeGestureMonitor()
        var swipes: [Swipe] = []
        monitor.onSwipe = { swipes.append(Swipe(direction: $0, fingers: $1)) }
        let events = try RecordedEvents.load(fixture)
        for _ in 0..<times {
            for event in events {
                monitor.process(event)
            }
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        return swipes
    }
}

/// Gesture events recorded from a real trackpad as length-prefixed `CGEvent` data.
enum RecordedEvents {
    private final class BundleToken {}

    static func load(_ name: String) throws -> [CGEvent] {
        let bundle = Bundle(for: BundleToken.self)
        let url = try #require(
            bundle.url(forResource: name, withExtension: "events")
                ?? bundle.url(forResource: name, withExtension: "events", subdirectory: "Fixtures")
        )
        let data = try Data(contentsOf: url)
        var events: [CGEvent] = []
        var offset = data.startIndex
        while offset + 4 <= data.endIndex {
            let length = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            try #require(offset + length <= data.endIndex)
            let record = data[offset..<offset + length]
            offset += length
            let event = try #require(CGEvent(withDataAllocator: nil, data: Data(record) as CFData))
            // Decoding stamps the event with this process ID. The recorder kept only HID events, which have ID 0.
            event.setIntegerValueField(.eventSourceUnixProcessID, value: 0)
            events.append(event)
        }
        try #require(offset == data.endIndex)
        return events
    }
}
