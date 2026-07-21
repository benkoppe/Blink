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
                postMissionControl(direction: direction)
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
        direction: SpaceSwitchDirection
    ) -> Bool {
        let progressSteps = [0.25, 0.5, 0.75]
        let signedProgress = direction == .right ? 1.05 : -1.05
        let signedVelocity = direction == .right ? 200.0 : -200.0

        guard
            let beginGesture = CGEvent(source: nil),
            let beginDock = missionControlEvent(
                phase: SyntheticGestureProtocol.began,
                direction: direction,
                progress: nil,
                velocity: nil
            )
        else {
            return false
        }

        beginGesture.setIntegerValueField(
            SyntheticGestureProtocol.eventType,
            value: SyntheticGestureProtocol.gestureEventType
        )
        markSynthetic(beginGesture)
        beginGesture.post(tap: .cgSessionEventTap)
        beginDock.post(tap: .cgSessionEventTap)

        for progress in progressSteps {
            guard
                let changed = missionControlEvent(
                    phase: SyntheticGestureProtocol.changed,
                    direction: direction,
                    progress: direction == .right ? progress : -progress,
                    velocity: signedVelocity
                )
            else {
                return false
            }
            changed.post(tap: .cgSessionEventTap)
        }

        guard
            let endGesture = CGEvent(source: nil),
            let endDock = missionControlEvent(
                phase: SyntheticGestureProtocol.ended,
                direction: direction,
                progress: signedProgress,
                velocity: signedVelocity
            )
        else {
            return false
        }

        endGesture.setIntegerValueField(
            SyntheticGestureProtocol.eventType,
            value: SyntheticGestureProtocol.gestureEventType
        )
        markSynthetic(endGesture)
        endGesture.post(tap: .cgSessionEventTap)
        endDock.post(tap: .cgSessionEventTap)
        return true
    }

    private func missionControlEvent(
        phase: Int64,
        direction: SpaceSwitchDirection,
        progress: Double?,
        velocity: Double?
    ) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }

        event.setIntegerValueField(
            SyntheticGestureProtocol.eventType,
            value: SyntheticGestureProtocol.dockControlEventType
        )
        event.setIntegerValueField(
            SyntheticGestureProtocol.hidType,
            value: SyntheticGestureProtocol.dockSwipeHIDType
        )
        event.setIntegerValueField(SyntheticGestureProtocol.phase, value: phase)
        event.setIntegerValueField(
            SyntheticGestureProtocol.scrollFlags,
            value: flagBits(for: direction)
        )
        event.setIntegerValueField(
            SyntheticGestureProtocol.swipeMotion,
            value: SyntheticGestureProtocol.horizontalMotion
        )
        event.setDoubleValueField(SyntheticGestureProtocol.scrollY, value: 0)
        event.setDoubleValueField(
            SyntheticGestureProtocol.zoomDeltaX,
            value: Double(Float.leastNonzeroMagnitude)
        )

        if let progress {
            event.setDoubleValueField(SyntheticGestureProtocol.swipeProgress, value: progress)
        }
        if let velocity {
            event.setDoubleValueField(SyntheticGestureProtocol.velocityX, value: velocity)
            event.setDoubleValueField(SyntheticGestureProtocol.velocityY, value: 0)
        }

        markSynthetic(event)
        return event
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
