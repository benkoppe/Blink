//
//  SwipeGestureMonitor.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import AppKit
import CoreGraphics
import Foundation

/// CGEventField rawValue carrying the synthetic-gesture sentinel.
/// Must match kSyntheticMarkerField in SpaceSwitcher.swift.
let kSyntheticMarkerField = CGEventField(rawValue: 200)!

/// Sentinel value written by SpaceSwitcher onto every synthetic CGEvent.
/// ASCII 'SSWIPE' = 0x535357495045.
let kSyntheticMarkerValue: Int64 = 0x5353_5749_5045

/// Private CGEventField carrying the number of touches active in a gesture event.
private let kTouchCountField = CGEventField(rawValue: 134)!

/// Minimum accumulated horizontal delta (points) required to fire a swipe.
private let kSwipeDeltaThreshold: Double = 0.06

/// Dominance of x-axis over y-axis for trigger
private let kSwipeDeltaXDominance: Double = 1.35

final class SwipeGestureMonitor {
    /// Parameters: (direction, fingerCount)
    var onSwipe: ((SwipeDirection, Int) -> Void)?

    /// Invert swipe direction
    var flipSwipeDirection: Bool = false

    /// When true, the same direction can fire multiple times within a single gesture.
    var allowSameDirectionRepeat: Bool = false

    /// Additional delta that must accumulate (beyond the base threshold) before the
    /// same direction can fire again. Only meaningful when `allowSameDirectionRepeat`
    /// is true. Same scale as `kSwipeDeltaThreshold` (0 = fires as easily as the
    /// first swipe, higher = harder to repeat).
    var sameDirectionRepeatSensitivity: Double = 0.06

    private var eventTap: EventTap?

    private struct GestureState {
        var isActive = false
        var lastFiredDirection: SwipeDirection?
        /// Accumulates delta in the same direction after a swipe fires, used to
        /// gate same-direction repeats. Reset to 0 each time a swipe fires.
        var postFireAccumulator: Double = 0
        var accumulatedDeltaX: Double = 0
        var accumulatedDeltaY: Double = 0
        var previousPositions: [String: CGPoint] = [:]

        mutating func reset() {
            // print("reset state")
            isActive = false
            lastFiredDirection = nil
            postFireAccumulator = 0
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
            previousPositions = [:]
        }
    }

    private var state = GestureState()

    // MARK - Monitoring lifecycle

    func startMonitoring() {
        guard eventTap == nil else { return }

        let tap = EventTap(
            label: "SwipeGestureMonitor",
            options: .defaultTap,
            location: .hidEventTap,
            place: .headInsertEventTap,
            types: [.gesture],
            callback: { [weak self] proxy, type, cgEvent in
                guard let self else { return cgEvent }

                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    self.state.reset()
                    proxy.enable()
                    return cgEvent

                case .gesture:
                    if let nsEvent = NSEvent(cgEvent: cgEvent) {
                        self.handleEvent(nsEvent)
                    }
                    return cgEvent

                default:
                    return cgEvent
                }
            }
        )
        tap.enable()
        self.eventTap = tap
    }

    func stopMonitoring() {
        eventTap?.disable()
        eventTap = nil
        state.reset()
    }

    // MARK: - Event handling

    private func handleEvent(_ event: NSEvent) {
        // Ignore synthetic events posted by SpaceSwitcher
        guard let cgEvent = event.cgEvent else { return }

        // Ignore synthetic events posted by SpaceSwitcher
        if cgEvent.getIntegerValueField(kSyntheticMarkerField) == kSyntheticMarkerValue {
            return
        }

        let touches = event.allTouches()
        guard !touches.isEmpty else {
            // print("touches empty")
            state.reset()
            return
        }

        let activeFingerCount =
            touches.allSatisfy { $0.phase == .ended || $0.phase == .cancelled } ? 0 : touches.count
        if activeFingerCount == 0 {
            // print("fingerCount 0")
            state.reset()
            return
        }

        var dx: CGFloat = 0
        var dy: CGFloat = 0
        for touch in event.allTouches() {
            let key = String(describing: touch.identity)
            let current = touch.normalizedPosition

            if let prev = state.previousPositions[key] {
                dx += current.x - prev.x
                dy += current.y - prev.y
            }

            if touch.phase == .ended {
                state.previousPositions.removeValue(forKey: key)
            } else {
                state.previousPositions[key] = current
            }
        }

        state.accumulatedDeltaX += dx
        state.accumulatedDeltaY += dy

        guard abs(state.accumulatedDeltaX) > abs(state.accumulatedDeltaY) * kSwipeDeltaXDominance,
            abs(state.accumulatedDeltaX) >= kSwipeDeltaThreshold
        else { return }

        let rawDirection: SwipeDirection = state.accumulatedDeltaX > 0 ? .right : .left
        let direction = flipSwipeDirection ? rawDirection.opposite : rawDirection

        if direction == state.lastFiredDirection {
            state.postFireAccumulator += abs(dx)
            guard allowSameDirectionRepeat,
                state.postFireAccumulator >= sameDirectionRepeatSensitivity
            else {
                state.accumulatedDeltaX = 0
                return
            }
        }

        state.lastFiredDirection = direction
        state.postFireAccumulator = 0
        state.accumulatedDeltaX = 0
        // print("firing with \(direction)")
        onSwipe?(direction, activeFingerCount)
    }
}
