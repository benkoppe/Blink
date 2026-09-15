//
//  NativeSwipePolicy.swift
//  Blink
//

import CoreGraphics

/// Shares one bypass decision across the touch and Dock event streams.
@MainActor
final class NativeSwipePolicy {
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
        // A consumer beginning again denotes a new physical gesture, even if
        // the other stream lost its terminal event. Don't reuse its old bypass.
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
        // A late end from the old stream must not release a newer gesture.
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
        // Native gestures originate from HID (PID 0); no synthetic tag is needed.
        event.getIntegerValueField(.eventSourceUnixProcessID) != 0
    }
}
