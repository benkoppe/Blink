//
//  DockSwipeTransport.swift
//  Blink
//

import CoreGraphics
import Darwin
import Foundation

/// Submission does not confirm that the Dock changed Spaces.
enum GestureSubmission {
    case submitted
    case unavailable
}

@MainActor
protocol DockSwipeSessionConnection: AnyObject {
    var isEnabled: Bool { get }
    func enable()
}

extension EventTap: DockSwipeSessionConnection {}

@MainActor
final class DockSwipeTransport {
    nonisolated enum Backend: Sendable {
        case legacy
        case serialized

        static var current: Self {
            if #available(macOS 27, *) {
                return .serialized
            }
            return .legacy
        }
    }

    /// Keeps reconstructed events immutable until they are posted.
    struct PreparedGesture {
        fileprivate let events: [CGEvent]

        var serializedEvents: [Data] {
            events.compactMap { $0.__data(allocator: nil) as Data? }
        }

        fileprivate func post() {
            for event in events {
                event.post(tap: .cgSessionEventTap)
            }
        }
    }

    private static let serializedVelocityCeiling = 2_000.0
    private static let serializedProgress = 0.000016

    private let backend: Backend
    private var sessionTap: (any DockSwipeSessionConnection)?
    private let makeSessionConnection: @MainActor () -> any DockSwipeSessionConnection
    private let postGesture: @MainActor (PreparedGesture) -> Void

    init(
        backend: Backend = .current,
        makeSessionConnection: (@MainActor () -> any DockSwipeSessionConnection)? = nil,
        postGesture: (@MainActor (PreparedGesture) -> Void)? = nil
    ) {
        self.backend = backend
        self.makeSessionConnection = makeSessionConnection ?? {
            EventTap(
                label: "DockSwipeTransport", options: .listenOnly,
                location: .sessionEventTap, place: .tailAppendEventTap,
                types: [CGEventType(rawValue: UInt32(EventType.dockControl))!],
                callback: { _, _, event in event }
            )
        }
        self.postGesture = postGesture ?? { $0.post() }
    }

    // MARK: - Submission

    func submit(
        mode: SpaceSwitchCoordinator.GestureMode,
        direction: SpaceSwitchCoordinator.Direction,
        velocity: Double
    ) -> GestureSubmission {
        guard ensureSessionConnection() else { return .unavailable }
        guard let gesture = prepare(mode: mode, direction: direction, velocity: velocity) else {
            Logger.dockSwipeTransport.error("Gesture encoding failed: backend=\(backend), direction=\(direction)")
            return .unavailable
        }

        postGesture(gesture)
        return .submitted
    }

    private func ensureSessionConnection() -> Bool {
        guard backend == .serialized else { return true }
        if sessionTap?.isEnabled == true { return true }

        // macOS 27 requires a resident event connection.
        if let sessionTap {
            sessionTap.enable()
            if sessionTap.isEnabled { return true }
        }
        let tap = makeSessionConnection()
        tap.enable()
        sessionTap = tap.isEnabled ? tap : nil
        if sessionTap == nil {
            Logger.dockSwipeTransport.error("Resident Dock event connection unavailable")
        }
        return sessionTap != nil
    }

    // MARK: - Event construction

    func prepare(
        mode: SpaceSwitchCoordinator.GestureMode,
        direction: SpaceSwitchCoordinator.Direction,
        velocity: Double
    ) -> PreparedGesture? {
        switch backend {
        case .serialized:
            return makeSerializedGesture(direction: direction, velocity: velocity)
        case .legacy:
            return makeLegacyGesture(mode: mode, direction: direction, velocity: velocity)
        }
    }

    private func makeSerializedGesture(
        direction: SpaceSwitchCoordinator.Direction,
        velocity: Double
    ) -> PreparedGesture? {
        // Based on ISS bf32cf9. Field 119 clears horizontal motion on macOS 27.
        // Reconstructed events must remain immutable.
        let sign = direction == .right ? -1.0 : 1.0
        let speed = velocity.isFinite
            ? min(max(abs(velocity), 1), Self.serializedVelocityCeiling)
            : Self.serializedVelocityCeiling
        var events: [CGEvent] = []

        for phase in GesturePhase.allCases {
            guard let event = CGEvent(source: nil) else { return nil }
            event.setIntegerValueField(GestureField.eventType, value: EventType.dockControl)
            event.setIntegerValueField(GestureField.hidType, value: kDockSwipeHIDType)
            event.setIntegerValueField(GestureField.phase, value: phase.rawValue)
            event.setIntegerValueField(GestureField.swipeMotion, value: kHorizontalGestureMotion)
            event.setDoubleValueField(GestureField.swipeProgress, value: sign * Self.serializedProgress)
            event.setIntegerValueField(GestureField.phaseAlias, value: phase.rawValue)
            event.setDoubleValueField(GestureField.zoomDeltaY, value: Double(kDockPrimaryGestureFlavor))
            event.setDoubleValueField(
                GestureField.sourceUnixProcessIDAlias,
                value: Double(mach_absolute_time())
            )
            event.setDoubleValueField(GestureField.positionX, value: 0.1)

            if phase == .ended {
                event.setDoubleValueField(GestureField.velocityX, value: sign * speed)
            }

            guard let augmentedEvent = DockEventPayload.augment(event) else { return nil }
            events.append(augmentedEvent)
        }

        return PreparedGesture(events: events)
    }

    private func makeLegacyGesture(
        mode: SpaceSwitchCoordinator.GestureMode,
        direction: SpaceSwitchCoordinator.Direction,
        velocity: Double
    ) -> PreparedGesture? {
        let sign = direction == .right ? 1.0 : -1.0
        var events: [CGEvent] = []

        switch mode {
        case .instant:
            for phase in GesturePhase.allCases {
                guard
                    let dockEvent = makeLegacyDockEvent(phase: phase, sign: sign, velocity: velocity),
                    let companionEvent = makeCompanionEvent()
                else { return nil }
                events.append(contentsOf: [dockEvent, companionEvent])
            }

        case .missionControl:
            let velocity = 200.0
            guard
                let beganEvent = makeLegacyDockEvent(phase: .began, sign: sign, velocity: nil),
                let beganCompanion = makeCompanionEvent()
            else { return nil }
            events.append(contentsOf: [beganCompanion, beganEvent])

            for progress in [0.25, 0.5, 0.75] {
                guard let changedEvent = makeLegacyDockEvent(
                    phase: .changed,
                    sign: sign,
                    velocity: velocity,
                    progress: sign * progress
                ) else { return nil }
                events.append(changedEvent)
            }

            guard
                let endedEvent = makeLegacyDockEvent(
                    phase: .ended,
                    sign: sign,
                    velocity: velocity,
                    progress: sign * 1.05
                ),
                let endedCompanion = makeCompanionEvent()
            else { return nil }
            events.append(contentsOf: [endedCompanion, endedEvent])
        }

        return PreparedGesture(events: events)
    }

    private func makeCompanionEvent() -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(GestureField.eventType, value: EventType.gesture)
        return event
    }

    private func makeLegacyDockEvent(
        phase: GesturePhase,
        sign: Double,
        velocity: Double?,
        progress: Double? = nil
    ) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        event.setIntegerValueField(GestureField.eventType, value: EventType.dockControl)
        event.setIntegerValueField(GestureField.hidType, value: kDockSwipeHIDType)
        event.setIntegerValueField(GestureField.phase, value: phase.rawValue)
        event.setIntegerValueField(GestureField.swipeMotion, value: kHorizontalGestureMotion)
        event.setDoubleValueField(GestureField.scrollY, value: 0)

        if let progress {
            event.setDoubleValueField(GestureField.swipeProgress, value: progress)
        }

        let flags = (Float.leastNonzeroMagnitude * Float(sign)).bitPattern
        event.setIntegerValueField(GestureField.scrollFlags, value: Int64(Int32(bitPattern: flags)))
        event.setDoubleValueField(GestureField.zoomDeltaX, value: Double(Float.leastNonzeroMagnitude))

        if let velocity {
            event.setDoubleValueField(GestureField.velocityX, value: sign * velocity)
            event.setDoubleValueField(GestureField.velocityY, value: 0)
        }

        return event
    }
}

// MARK: - Private gesture fields

private enum GestureField {
    static let eventType = CGEventField(rawValue: 55)!
    static let hidType = CGEventField(rawValue: 110)!
    static let swipeMask = CGEventField(rawValue: 115)!
    static let scrollY = CGEventField(rawValue: 119)!
    static let swipeMotion = CGEventField(rawValue: 123)!
    static let swipeProgress = CGEventField(rawValue: 124)!
    static let positionX = CGEventField(rawValue: 125)!
    static let positionY = CGEventField(rawValue: 126)!
    static let velocityX = CGEventField(rawValue: 129)!
    static let velocityY = CGEventField(rawValue: 130)!
    static let phase = CGEventField(rawValue: 132)!
    static let phaseAlias = CGEventField(rawValue: 134)!
    static let scrollFlags = CGEventField(rawValue: 135)!
    static let zoomDeltaY = CGEventField(rawValue: 138)!
    static let zoomDeltaX = CGEventField(rawValue: 139)!
    static let sourceUnixProcessIDAlias = CGEventField(rawValue: 169)!
}

private enum EventType {
    static let gesture: Int64 = 29
    static let dockControl: Int64 = 30
}

private enum GesturePhase: Int64, CaseIterable {
    case began = 1
    case changed = 2
    case ended = 4
}

private let kDockSwipeHIDType: Int64 = 23
private let kHorizontalGestureMotion: Int64 = 1
private let kDockPrimaryGestureFlavor: UInt16 = 3

// MARK: - Serialized IOHID payload

enum DockEventPayload {
    private static let fieldID: UInt16 = 4_205

    static func fixedPoint1616(_ value: Double) -> Int32 {
        guard value.isFinite else { return 0 }
        let scaled = min(max(value * 65_536, Double(Int32.min)), Double(Int32.max))
        let fixed = Int32(scaled.rounded(.towardZero))
        return fixed == 0 && value != 0 ? (value < 0 ? -1 : 1) : fixed
    }

    static func makePayload(for event: CGEvent) -> Data {
        let phase = event.getIntegerValueField(GestureField.phase)
        let velocityX = event.getDoubleValueField(GestureField.velocityX)
        let velocityY = event.getDoubleValueField(GestureField.velocityY)
        let includesVelocity = velocityX != 0 || velocityY != 0 || phase == GesturePhase.ended.rawValue
        var data = Data()

        // IOHIDSystemQueueElementHeader
        data.appendLittleEndian(event.timestamp == 0 ? mach_absolute_time() : event.timestamp)
        data.appendLittleEndian(UInt64(0))  // sender ID
        data.appendLittleEndian(UInt32(0))  // options
        data.appendLittleEndian(UInt32(0))  // attribute length
        data.appendLittleEndian(UInt32(includesVelocity ? 2 : 1))

        // IOHIDFluidTouchGestureData
        data.appendLittleEndian(UInt32(40))  // record size
        data.appendLittleEndian(UInt32(kDockSwipeHIDType))
        data.appendLittleEndian(UInt32(truncatingIfNeeded: (phase & 0xFF) << 24))
        data.appendLittleEndian(UInt32(0))  // depth and padding
        data.appendLittleEndian(fixedPoint1616(event.getDoubleValueField(GestureField.positionX)))
        data.appendLittleEndian(fixedPoint1616(event.getDoubleValueField(GestureField.positionY)))
        data.appendLittleEndian(Int32(0))  // position Z
        data.appendLittleEndian(UInt32(truncatingIfNeeded: event.getIntegerValueField(GestureField.swipeMask)))
        data.appendLittleEndian(UInt16(truncatingIfNeeded: event.getIntegerValueField(GestureField.swipeMotion)))
        data.appendLittleEndian(kDockPrimaryGestureFlavor)
        data.appendLittleEndian(fixedPoint1616(event.getDoubleValueField(GestureField.swipeProgress)))

        if includesVelocity {
            // IOHIDVelocityEventData
            data.appendLittleEndian(UInt32(28))  // record size
            data.appendLittleEndian(UInt32(9))  // velocity type
            data.appendLittleEndian(UInt32(0))  // options
            data.appendLittleEndian(UInt32(1))  // child depth and padding
            data.appendLittleEndian(fixedPoint1616(velocityX))
            data.appendLittleEndian(fixedPoint1616(velocityY))
            data.appendLittleEndian(Int32(0))  // velocity Z
        }

        return data
    }

    static func augmentedData(for event: CGEvent) -> Data? {
        guard
            var data = event.__data(allocator: nil) as Data?,
            data.starts(with: [0, 0, 0, 2])
        else { return nil }

        let payload = makePayload(for: event)
        guard payload.count <= Int(UInt16.max) else { return nil }

        // CGEvent tags are big-endian; the embedded IOHID records are little-endian.
        data.append(contentsOf: [
            UInt8(payload.count >> 8), UInt8(payload.count & 0xFF),
            UInt8(fieldID >> 8), UInt8(fieldID & 0xFF),
        ])
        data.append(payload)
        return data
    }

    static func augment(_ event: CGEvent) -> CGEvent? {
        guard let data = augmentedData(for: event) else { return nil }
        return CGEvent(withDataAllocator: nil, data: data as CFData)
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var value = value.littleEndian
        Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) }
    }
}

// MARK: - Logger

extension Logger {
    fileprivate static let dockSwipeTransport = Logger(category: "DockSwipeTransport")
}
