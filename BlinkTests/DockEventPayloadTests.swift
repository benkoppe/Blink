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

    @Test("Production macOS 27 builder preserves phases, directions and bypass marker")
    func productionEvents() throws {
        for direction in [SpaceSwitchCoordinator.Direction.left, .right] {
            let sign: Int32 = direction == .right ? -1 : 1
            for phase: Int64 in [1, 2, 4] {
                let event = try #require(SpaceSwitcher.makeDockSwipeEvent(
                    phase: phase, direction: direction, velocity: 9_999,
                    requiresAugmentation: true
                ))
                #expect(event.getIntegerValueField(kSyntheticMarkerField) == kSyntheticMarkerValue)
                #expect(event.getIntegerValueField(phaseField) == phase)
                let payload = DockEventPayload.makePayload(for: event)
                #expect(payload.count == (phase == 4 ? 96 : 68))
                #expect(readUInt32(payload, at: 36) == UInt32(phase) << 24)
                #expect(readInt32(payload, at: 64) == sign * 65_536)
                if phase == 4 {
                    #expect(readInt32(payload, at: 84) == sign * 9_999 * 65_536)
                } else {
                    #expect(event.getDoubleValueField(velocityXField) == 0)
                }
            }
        }
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
