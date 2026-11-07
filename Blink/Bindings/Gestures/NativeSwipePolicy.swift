//
//  NativeSwipePolicy.swift
//  Blink
//

import CoreGraphics

/// Shares one bypass decision across the touch and Dock event streams.
@MainActor
final class NativeSwipePolicy {
    // Marker used by the legacy Dock event sequence on macOS before 27.
    static let syntheticMarkerField = CGEventField.eventSourceUserData
    static let syntheticMarkerValue: Int64 = 0x5353_5749_5045

    enum Consumer: Hashable {
        case recognition
        case suppression
    }

    struct Session: Equatable {
        let generation: UInt64
        let bypass: Bool
    }

    var shouldBypass: () -> Bool = { false }
    private(set) var generation: UInt64 = 0
    private var consumers: Set<Consumer> = []
    private var completedConsumers: Set<Consumer> = []
    private var session: Session?

    func begin(_ consumer: Consumer) -> Session {
        // A repeated consumer starts a new gesture, even after a lost end.
        if consumers.contains(consumer) || completedConsumers.contains(consumer) {
            reset()
        }
        let current: Session
        if let session {
            current = session
        } else {
            generation &+= 1
            current = Session(generation: generation, bypass: shouldBypass())
            session = current
        }
        consumers.insert(consumer)
        return current
    }

    func end(_ consumer: Consumer, session endingSession: Session?) {
        // Ignore terminal events from older sessions.
        guard let endingSession, session == endingSession else { return }
        consumers.remove(consumer)
        completedConsumers.insert(consumer)
        if consumers.isEmpty {
            session = nil
            completedConsumers.removeAll()
        }
    }

    func reset() {
        generation &+= 1
        consumers.removeAll()
        completedConsumers.removeAll()
        session = nil
    }

    static func isAppPosted(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(syntheticMarkerField) == syntheticMarkerValue
            || event.getIntegerValueField(.eventSourceUnixProcessID) != 0
    }
}
