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

    var shouldBypass: () -> Bool = { false }
    private var consumers: Set<Consumer> = []
    private var bypass = false

    func begin(_ consumer: Consumer) -> Bool {
        if consumers.contains(consumer) {
            reset()
        }
        if consumers.isEmpty {
            bypass = shouldBypass()
        }
        consumers.insert(consumer)
        return bypass
    }

    func end(_ consumer: Consumer) {
        consumers.remove(consumer)
        if consumers.isEmpty {
            bypass = false
        }
    }

    func reset() {
        consumers.removeAll()
        bypass = false
    }

    static func isAppPosted(_ event: CGEvent) -> Bool {
        // Native gestures originate from HID (PID 0); no synthetic tag is needed.
        event.getIntegerValueField(.eventSourceUnixProcessID) != 0
    }
}
