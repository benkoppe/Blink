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

nonisolated enum MissionControlPayloadStrategy: Equatable, Sendable {
    // Legacy progress trace selected explicitly for macOS 14–25. These releases
    // still require manual qualification on the validation matrix.
    case legacyProgress
    // Compact Dock-only trace selected for Tahoe (macOS 26) and later.
    case tahoeCompact
    case unsupported

    static func select(for version: OperatingSystemVersion) -> Self {
        if version.majorVersion >= 26 {
            return .tahoeCompact
        }
        if version.majorVersion >= 14 {
            return .legacyProgress
        }
        return .unsupported
    }
}

nonisolated struct MissionControlGesturePayload: Equatable, Sendable {
    let eventType: Int64
    let hidType: Int64?
    let phase: Int64?
    let scrollFlags: Int64?
    let swipeMotion: Int64?
    let scrollY: Double?
    let progress: Double?
    let velocityX: Double?
    let velocityY: Double?
    let zoomDeltaX: Double?
}

nonisolated struct DockGesturePoster: SpaceGesturePosting, Sendable {
    let missionControlStrategy: MissionControlPayloadStrategy

    init(
        operatingSystemVersion: OperatingSystemVersion = ProcessInfo.processInfo
            .operatingSystemVersion
    ) {
        missionControlStrategy = .select(for: operatingSystemVersion)
    }

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
        guard
            let began = makeDockEvents(
                phase: SyntheticGestureProtocol.began,
                direction: direction,
                velocity: velocity
            ),
            let changed = makeDockEvents(
                phase: SyntheticGestureProtocol.changed,
                direction: direction,
                velocity: velocity
            ),
            let ended = makeDockEvents(
                phase: SyntheticGestureProtocol.ended,
                direction: direction,
                velocity: velocity
            )
        else {
            return false
        }

        for events in [began, changed, ended] {
            events.dock.post(tap: .cgSessionEventTap)
            events.gesture.post(tap: .cgSessionEventTap)
        }
        return true
    }

    private func makeDockEvents(
        phase: Int64,
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> (dock: CGEvent, gesture: CGEvent)? {
        guard
            let gestureEvent = CGEvent(source: nil),
            let dockEvent = CGEvent(source: nil)
        else {
            return nil
        }

        let signedVelocity = direction == .right ? velocity : -velocity
        let flags = Self.flagBits(for: direction)

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

        return (dockEvent, gestureEvent)
    }

    private func postMissionControl(
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> Bool {
        guard
            let payloads = Self.missionControlPayloads(
                strategy: missionControlStrategy,
                direction: direction,
                velocity: velocity
            )
        else {
            return false
        }

        let events = payloads.compactMap(makeMissionControlEvent)
        guard events.count == payloads.count else { return false }
        events.forEach { $0.post(tap: .cgSessionEventTap) }
        return true
    }

    static func missionControlPayloads(
        strategy: MissionControlPayloadStrategy,
        direction: SpaceSwitchDirection,
        velocity: Double
    ) -> [MissionControlGesturePayload]? {
        switch strategy {
        case .tahoeCompact:
            return tahoePayloads(direction: direction, velocity: velocity)
        case .legacyProgress:
            return legacyPayloads(direction: direction)
        case .unsupported:
            return nil
        }
    }

    private static func tahoePayloads(
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
                eventType: SyntheticGestureProtocol.dockControlEventType,
                hidType: SyntheticGestureProtocol.dockSwipeHIDType,
                phase: $0,
                scrollFlags: nil,
                swipeMotion: SyntheticGestureProtocol.horizontalMotion,
                scrollY: nil,
                progress: signedProgress,
                velocityX: signedVelocity,
                velocityY: signedVelocity,
                zoomDeltaX: nil
            )
        }
    }

    private static func legacyPayloads(
        direction: SpaceSwitchDirection
    ) -> [MissionControlGesturePayload] {
        let sign = direction == .right ? 1.0 : -1.0
        let signedVelocity = sign * 200
        let flags = flagBits(for: direction)

        func gesture() -> MissionControlGesturePayload {
            MissionControlGesturePayload(
                eventType: SyntheticGestureProtocol.gestureEventType,
                hidType: nil,
                phase: nil,
                scrollFlags: nil,
                swipeMotion: nil,
                scrollY: nil,
                progress: nil,
                velocityX: nil,
                velocityY: nil,
                zoomDeltaX: nil
            )
        }

        func dock(
            phase: Int64,
            progress: Double? = nil,
            velocityX: Double? = nil
        ) -> MissionControlGesturePayload {
            MissionControlGesturePayload(
                eventType: SyntheticGestureProtocol.dockControlEventType,
                hidType: SyntheticGestureProtocol.dockSwipeHIDType,
                phase: phase,
                scrollFlags: flags,
                swipeMotion: SyntheticGestureProtocol.horizontalMotion,
                scrollY: 0,
                progress: progress,
                velocityX: velocityX,
                velocityY: velocityX == nil ? nil : 0,
                zoomDeltaX: Double(Float.leastNonzeroMagnitude)
            )
        }

        return [
            gesture(),
            dock(phase: SyntheticGestureProtocol.began),
            dock(
                phase: SyntheticGestureProtocol.changed, progress: sign * 0.25,
                velocityX: signedVelocity),
            dock(
                phase: SyntheticGestureProtocol.changed, progress: sign * 0.5,
                velocityX: signedVelocity),
            dock(
                phase: SyntheticGestureProtocol.changed, progress: sign * 0.75,
                velocityX: signedVelocity),
            gesture(),
            dock(
                phase: SyntheticGestureProtocol.ended, progress: sign * 1.05,
                velocityX: signedVelocity),
        ]
    }

    private func makeMissionControlEvent(
        payload: MissionControlGesturePayload
    ) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }

        event.setIntegerValueField(SyntheticGestureProtocol.eventType, value: payload.eventType)
        if let value = payload.hidType {
            event.setIntegerValueField(SyntheticGestureProtocol.hidType, value: value)
        }
        if let value = payload.phase {
            event.setIntegerValueField(SyntheticGestureProtocol.phase, value: value)
        }
        if let value = payload.scrollFlags {
            event.setIntegerValueField(SyntheticGestureProtocol.scrollFlags, value: value)
        }
        if let value = payload.swipeMotion {
            event.setIntegerValueField(SyntheticGestureProtocol.swipeMotion, value: value)
        }
        if let value = payload.scrollY {
            event.setDoubleValueField(SyntheticGestureProtocol.scrollY, value: value)
        }
        if let value = payload.progress {
            event.setDoubleValueField(SyntheticGestureProtocol.swipeProgress, value: value)
        }
        if let value = payload.velocityX {
            event.setDoubleValueField(SyntheticGestureProtocol.velocityX, value: value)
        }
        if let value = payload.velocityY {
            event.setDoubleValueField(SyntheticGestureProtocol.velocityY, value: value)
        }
        if let value = payload.zoomDeltaX {
            event.setDoubleValueField(SyntheticGestureProtocol.zoomDeltaX, value: value)
        }
        markSynthetic(event)
        return event
    }

    private static func flagBits(for direction: SpaceSwitchDirection) -> Int64 {
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
