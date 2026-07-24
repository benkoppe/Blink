import CoreGraphics
import Foundation

nonisolated enum SyntheticGestureProtocol {
    static let markerField = CGEventField(rawValue: 200)!
    static let markerValue: Int64 = 0x5353_5749_5045

    static let eventType = CGEventField(rawValue: 55)!
    static let hidType = CGEventField(rawValue: 110)!
    static let scrollY = CGEventField(rawValue: 119)!
    static let swipeMotion = CGEventField(rawValue: 123)!
    static let swipeProgress = CGEventField(rawValue: 124)!
    static let velocityX = CGEventField(rawValue: 129)!
    static let velocityY = CGEventField(rawValue: 130)!
    static let phase = CGEventField(rawValue: 132)!
    static let scrollFlags = CGEventField(rawValue: 135)!
    static let zoomDeltaX = CGEventField(rawValue: 139)!

    static let gestureEventType: Int64 = 29
    static let dockControlEventType: Int64 = 30
    static let dockSwipeHIDType: Int64 = 23
    static let horizontalMotion: Int64 = 1

    static let began: Int64 = 1
    static let changed: Int64 = 2
    static let ended: Int64 = 4
    static let cancelled: Int64 = 8
    static let mayBegin: Int64 = 128
}

nonisolated protocol SpaceGesturePosting: Sendable {
    func postStep(
        mode: SpaceSwitchMode,
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> Bool
}

nonisolated struct MissionControlGesturePayload: Equatable, Sendable {
    let phase: Int64
    let progress: Double
    let velocityX: Double
    let velocityY: Double
}

nonisolated struct DockGesturePoster: SpaceGesturePosting, Sendable {
    func postStep(
        mode: SpaceSwitchMode,
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> Bool {
        autoreleasepool {
            switch mode {
            case .instant:
                postInstant(direction: direction, velocity: velocity)
            case .missionControl:
                postMissionControl(direction: direction, velocity: velocity)
            }
        }
    }

    private func postInstant(
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> Bool {
        postDockEvent(
            phase: SyntheticGestureProtocol.began,
            direction: direction,
            velocity: velocity
        )
            && postDockEvent(
                phase: SyntheticGestureProtocol.changed,
                direction: direction,
                velocity: velocity
            )
            && postDockEvent(
                phase: SyntheticGestureProtocol.ended,
                direction: direction,
                velocity: velocity
            )
    }

    private func postDockEvent(
        phase: Int64,
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> Bool {
        guard
            let gestureEvent = CGEvent(source: nil),
            let dockEvent = CGEvent(source: nil)
        else {
            return false
        }

        let signedVelocity = direction == .right ? velocity : -velocity
        let flags = flagBits(for: direction)

        gestureEvent.setIntegerValueField(
            SyntheticGestureProtocol.eventType,
            value: SyntheticGestureProtocol.gestureEventType
        )
        markSynthetic(gestureEvent)

        dockEvent.setIntegerValueField(
            SyntheticGestureProtocol.eventType,
            value: SyntheticGestureProtocol.dockControlEventType
        )
        dockEvent.setIntegerValueField(
            SyntheticGestureProtocol.hidType,
            value: SyntheticGestureProtocol.dockSwipeHIDType
        )
        dockEvent.setIntegerValueField(SyntheticGestureProtocol.phase, value: phase)
        dockEvent.setIntegerValueField(SyntheticGestureProtocol.scrollFlags, value: flags)
        dockEvent.setIntegerValueField(
            SyntheticGestureProtocol.swipeMotion,
            value: SyntheticGestureProtocol.horizontalMotion
        )
        dockEvent.setDoubleValueField(SyntheticGestureProtocol.scrollY, value: 0)
        dockEvent.setDoubleValueField(
            SyntheticGestureProtocol.velocityX,
            value: signedVelocity
        )
        dockEvent.setDoubleValueField(SyntheticGestureProtocol.velocityY, value: 0)
        dockEvent.setDoubleValueField(
            SyntheticGestureProtocol.zoomDeltaX,
            value: Double(Float.leastNonzeroMagnitude)
        )
        markSynthetic(dockEvent)

        dockEvent.post(tap: .cgSessionEventTap)
        gestureEvent.post(tap: .cgSessionEventTap)
        return true
    }

    private func postMissionControl(
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> Bool {
        // Tahoe accepts the compact Dock-only trace while the older companion
        // gesture/progress sequence can conflict with Mission Control itself.
        for payload in Self.missionControlPayloads(
            direction: direction,
            velocity: velocity
        ) {
            guard let event = CGEvent(source: nil) else { return false }
            event.setIntegerValueField(
                SyntheticGestureProtocol.eventType,
                value: SyntheticGestureProtocol.dockControlEventType
            )
            event.setIntegerValueField(
                SyntheticGestureProtocol.hidType,
                value: SyntheticGestureProtocol.dockSwipeHIDType
            )
            event.setIntegerValueField(
                SyntheticGestureProtocol.phase,
                value: payload.phase
            )
            event.setIntegerValueField(
                SyntheticGestureProtocol.swipeMotion,
                value: SyntheticGestureProtocol.horizontalMotion
            )
            event.setDoubleValueField(
                SyntheticGestureProtocol.swipeProgress,
                value: payload.progress
            )
            event.setDoubleValueField(
                SyntheticGestureProtocol.velocityX,
                value: payload.velocityX
            )
            event.setDoubleValueField(
                SyntheticGestureProtocol.velocityY,
                value: payload.velocityY
            )
            markSynthetic(event)
            event.post(tap: .cgSessionEventTap)
        }
        return true
    }

    static func missionControlPayloads(
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> [MissionControlGesturePayload] {
        let sign = direction == .right ? 1.0 : -1.0
        let signedVelocity = sign * max(1, velocity)
        let signedProgress = sign * Double(Float.leastNonzeroMagnitude)

        return [
            SyntheticGestureProtocol.began,
            SyntheticGestureProtocol.changed,
            SyntheticGestureProtocol.ended,
        ].map {
            MissionControlGesturePayload(
                phase: $0,
                progress: signedProgress,
                velocityX: signedVelocity,
                velocityY: signedVelocity
            )
        }
    }

    private func flagBits(for direction: SpaceSwitchDirection) -> Int64 {
        var value = Float.leastNonzeroMagnitude
        if direction == .left {
            value.negate()
        }
        return Int64(Int32(bitPattern: value.bitPattern))
    }

    private func markSynthetic(_ event: CGEvent) {
        event.setIntegerValueField(
            SyntheticGestureProtocol.markerField,
            value: SyntheticGestureProtocol.markerValue
        )
    }
}
