import CoreGraphics
import Foundation
import Testing

@testable import Blink

@MainActor
@Suite("Dock event payload")
struct DockEventPayloadTests {
    private let eventTypeField = CGEventField(rawValue: 55)!
    private let phaseField = CGEventField(rawValue: 132)!
    private let motionField = CGEventField(rawValue: 123)!
    private let progressField = CGEventField(rawValue: 124)!
    private let positionXField = CGEventField(rawValue: 125)!
    private let velocityXField = CGEventField(rawValue: 129)!

    @Test("Fixed-point conversion preserves small and bounded values")
    func fixedPointConversion() {
        #expect(DockEventPayload.fixedPoint1616(0) == 0)
        #expect(DockEventPayload.fixedPoint1616(0.000001) == 1)
        #expect(DockEventPayload.fixedPoint1616(-0.000001) == -1)
        #expect(DockEventPayload.fixedPoint1616(.nan) == 0)
        #expect(DockEventPayload.fixedPoint1616(.infinity) == 0)
        #expect(DockEventPayload.fixedPoint1616(0.000016) == 1)
        #expect(DockEventPayload.fixedPoint1616(-0.000016) == -1)
        #expect(DockEventPayload.fixedPoint1616(1.5) == 98_304)
        #expect(
            DockEventPayload.fixedPoint1616(Double(Int32.max))
                == Int32.max
        )
        #expect(
            DockEventPayload.fixedPoint1616(-Double(Int32.max))
                == Int32.min
        )
    }

    @Test("Payload contains fluid touch and velocity records")
    func payloadLayout() {
        let event = CGEvent(source: nil)!
        event.setIntegerValueField(eventTypeField, value: 30)
        event.setIntegerValueField(phaseField, value: 4)
        event.setIntegerValueField(motionField, value: 1)
        event.setDoubleValueField(progressField, value: -0.000016)
        event.setDoubleValueField(positionXField, value: 0.1)
        event.setDoubleValueField(velocityXField, value: -1_000)

        let payload = DockEventPayload.makePayload(for: event)

        #expect(payload.count == 96)
        guard payload.count >= 96 else { return }
        #expect(readUInt32(payload, at: 24) == 2)
        #expect(readUInt32(payload, at: 28) == 40)
        #expect(readUInt32(payload, at: 32) == 23)
        #expect(readUInt32(payload, at: 36) == 0x0400_0000)
        #expect(readInt32(payload, at: 44) == 6_553)
        #expect(readInt32(payload, at: 64) == -1)
        #expect(readUInt32(payload, at: 68) == 28)
        #expect(readUInt32(payload, at: 72) == 9)
        #expect(readInt32(payload, at: 84) == -65_536_000)
    }

    @Test("Augmentation reconstructs the event and preserves its fields")
    func augmentationLayout() {
        let event = CGEvent(source: nil)!
        event.timestamp = 1_000_000
        event.setIntegerValueField(eventTypeField, value: 30)
        event.setIntegerValueField(phaseField, value: 1)
        event.setIntegerValueField(motionField, value: 1)
        event.setDoubleValueField(progressField, value: 0.000016)

        let payload = DockEventPayload.makePayload(for: event)
        let originalData = event.__data(allocator: nil) as Data?
        let rawAugmentedData = DockEventPayload.augmentedData(for: event)
        let augmented = DockEventPayload.augment(event)
        let augmentedData = augmented?.__data(allocator: nil) as Data?

        #expect(originalData != nil)
        #expect(rawAugmentedData != nil)
        #expect(augmented != nil)
        #expect(augmentedData != nil)

        guard
            let originalData,
            let rawAugmentedData,
            let augmented
        else {
            return
        }

        let tagOffset = originalData.count
        #expect(rawAugmentedData.count == tagOffset + 4 + payload.count)
        guard rawAugmentedData.count >= tagOffset + 4 + payload.count else {
            return
        }
        #expect(readUInt16(rawAugmentedData, at: tagOffset) == payload.count)
        #expect(readUInt16(rawAugmentedData, at: tagOffset + 2) == 4_205)
        #expect(
            Array(rawAugmentedData.suffix(payload.count)) == Array(payload)
        )
        #expect(augmented.getIntegerValueField(phaseField) == 1)
        #expect(augmented.getIntegerValueField(eventTypeField) == 30)
    }

    @Test(
        "Final macOS 27 events contain horizontal motion, ordered phases and bounded velocity",
        arguments: [0.0, 1.0, 80.25, -80.25, 2_000.0, 999_999.0, .infinity, .nan]
    )
    func productionEvents(velocity: Double) throws {
        let transport = DockSwipeTransport(backend: .serialized)
        for direction in [SpaceSwitchCoordinator.Direction.left, .right] {
            let sign: Int32 = direction == .right ? -1 : 1
            for mode in [SpaceSwitchCoordinator.GestureMode.instant, .missionControl] {
                let gesture = try #require(
                    transport.prepare(mode: mode, direction: direction, velocity: velocity)
                )
                let serialized = gesture.serializedEvents
                try #require(serialized.count == 3)
                for (index, data) in serialized.enumerated() {
                    let phase = [1, 2, 4][index]
                    let event = try #require(CGEvent(withDataAllocator: nil, data: data as CFData))
                    #expect(NativeSwipePolicy.isAppPosted(event))
                    #expect(event.getIntegerValueField(eventTypeField) == 30)
                    let payload = try #require(SerializedGestureData.payload(from: data))
                    #expect(payload.count == (phase == 4 ? 96 : 68))
                    #expect(readUInt32(payload, at: 24) == (phase == 4 ? 2 : 1))
                    #expect(readUInt32(payload, at: 36) == UInt32(phase) << 24)
                    #expect(readUInt32(payload, at: 60) == 0x0003_0001)  // flavor 3, horizontal 1
                    #expect(readInt32(payload, at: 64) == sign)  // 0.000016 in 16.16, truncated
                    if phase == 4 {
                        let speed = velocity.isFinite ? min(max(abs(velocity), 1), 2_000) : 2_000
                        #expect(readInt32(payload, at: 84) == sign * Int32(speed * 65_536))
                    }
                }
            }
        }
    }

    @Test("Serialized payload parser rejects malformed data")
    func malformedPayload() {
        #expect(SerializedGestureData.payload(from: Data()) == nil)
        #expect(SerializedGestureData.payload(from: Data([0, 0, 0, 1])) == nil)
        #expect(SerializedGestureData.payload(from: Data([0, 0, 0, 2, 0, 68, 0x10, 0x6d])) == nil)
    }

    @Test("Legacy gestures remain separate from serialized gestures")
    func legacySequence() throws {
        let transport = DockSwipeTransport(backend: .legacy)
        let gesture = try #require(transport.prepare(mode: .instant, direction: .right, velocity: 100))
        let types = try gesture.serializedEvents.map { data in
            try #require(CGEvent(withDataAllocator: nil, data: data as CFData)).getIntegerValueField(eventTypeField)
        }
        #expect(types == [30, 29, 30, 29, 30, 29])
    }

    @Test("Legacy Mission Control preserves phases, velocity and companion order", arguments: [true, false])
    func legacyMissionControl(right: Bool) throws {
        let transport = DockSwipeTransport(backend: .legacy)
        let gesture = try #require(transport.prepare(mode: .missionControl, direction: right ? .right : .left, velocity: 999_999))
        let events = try gesture.serializedEvents.map {
            try #require(CGEvent(withDataAllocator: nil, data: $0 as CFData))
        }
        #expect(events.map { $0.getIntegerValueField(eventTypeField) } == [29, 30, 30, 30, 30, 29, 30])
        let dock = events.filter { $0.getIntegerValueField(eventTypeField) == 30 }
        #expect(dock.map { $0.getIntegerValueField(phaseField) } == [1, 2, 2, 2, 4])
        let sign = right ? 1.0 : -1.0
        // Private progress/scroll-flag aliases have different readback semantics
        // on macOS 27. Preserve the pre-27 write sequence; don't rewrite it to
        // make the modern OS's legacy-field getters report a different value.
        for event in dock.dropFirst() {
            #expect(event.getDoubleValueField(velocityXField) == sign * 200)
            #expect(event.getIntegerValueField(motionField) == 1)
            #expect(NativeSwipePolicy.isAppPosted(event))
        }
        #expect(gesture.serializedEvents.allSatisfy { SerializedGestureData.payload(from: $0) == nil })
    }

    @Test("Legacy instant fields retain their direction encoding", arguments: [true, false])
    func legacyInstantFields(right: Bool) throws {
        let transport = DockSwipeTransport(backend: .legacy)
        let gesture = try #require(transport.prepare(mode: .instant, direction: right ? .right : .left, velocity: 123.5))
        for data in gesture.serializedEvents {
            let event = try #require(CGEvent(withDataAllocator: nil, data: data as CFData))
            #expect(NativeSwipePolicy.isAppPosted(event))
            guard event.getIntegerValueField(eventTypeField) == 30 else { continue }
            #expect(event.getDoubleValueField(velocityXField) == (right ? 123.5 : -123.5))
            #expect(event.getIntegerValueField(motionField) == 1)
            let expectedFlags = (right ? Float.leastNonzeroMagnitude : -Float.leastNonzeroMagnitude).bitPattern
            let flags = UInt32(truncatingIfNeeded: event.getIntegerValueField(CGEventField(rawValue: 135)!))
            #expect(flags == expectedFlags)
        }
    }

    @Test("An unavailable connection never posts and a later request can recover")
    func connectionRecovery() {
        let failed = SessionConnection(canEnable: false)
        let working = SessionConnection(canEnable: true)
        var attempts = 0
        var posts = 0
        let transport = DockSwipeTransport(backend: .serialized, makeSessionConnection: {
            attempts += 1
            return attempts == 1 ? failed : working
        }, postGesture: { _ in posts += 1 })
        #expect(transport.submit(mode: .instant, direction: .right, velocity: 100) == .unavailable)
        #expect(posts == 0)
        #expect(transport.submit(mode: .instant, direction: .right, velocity: 100) == .submitted)
        #expect(posts == 1)
        working.isEnabled = false
        #expect(transport.submit(mode: .instant, direction: .left, velocity: 100) == .submitted)
        #expect(attempts == 2)
        #expect(working.enableCount == 2)
        #expect(posts == 2)
    }

    private func readUInt16(_ data: Data, at offset: Int) -> Int {
        Int(data[offset]) << 8 | Int(data[offset + 1])
    }

    private func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(into: UInt32(0)) { result, index in
            result |= UInt32(data[offset + index]) << UInt32(index * 8)
        }
    }

    private func readInt32(_ data: Data, at offset: Int) -> Int32 {
        Int32(bitPattern: readUInt32(data, at: offset))
    }
}

@MainActor
private final class SessionConnection: DockSwipeSessionConnection {
    var isEnabled = false
    var enableCount = 0
    let canEnable: Bool

    init(canEnable: Bool) { self.canEnable = canEnable }
    func enable() {
        enableCount += 1
        isEnabled = canEnable
    }
}

/// Inspect the final serialized event independently of the production encoder.
private enum SerializedGestureData {
    static func payload(from data: Data) -> Data? {
        guard data.starts(with: [0, 0, 0, 2]) else { return nil }
        var offset = 4

        while offset + 4 <= data.count {
            let words = Int(data[offset]) << 8 | Int(data[offset + 1])
            let tag = Int(data[offset + 2]) << 8 | Int(data[offset + 3])
            let type = tag >> 14
            guard words > 0, type != 2 else { return nil }

            let size = type == 0 ? (words == 1 ? 8 : (words + 3) & ~3) : words * 4
            offset += 4
            guard size <= data.count - offset else { return nil }

            if tag & 0x3FFF == 4_205 {
                guard type == 0, words > 1 else { return nil }
                return data.subdata(in: offset..<offset + words)
            }
            offset += size
        }

        return nil
    }
}
