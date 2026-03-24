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

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private struct GestureState {
        var isActive = false
        var lastFiredDirection: SwipeDirection?
        var accumulatedDeltaX: Double = 0
        var accumulatedDeltaY: Double = 0
        var previousPositions: [String: CGPoint] = [:]

        mutating func reset() {
            print("reset state")
            isActive = false
            lastFiredDirection = nil
            accumulatedDeltaX = 0
            accumulatedDeltaY = 0
            previousPositions = [:]
        }
    }

    private var state = GestureState()

    func startMonitoring() {
        guard eventTap == nil else { return }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cghidEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: NSEvent.EventTypeMask.gesture.rawValue,
                callback: { _, _, cgEvent, userInfo -> Unmanaged<CGEvent>? in
                    guard let userInfo else { return nil }
                    let monitor = Unmanaged<SwipeGestureMonitor>
                        .fromOpaque(userInfo)
                        .takeUnretainedValue()
                    if let event = NSEvent(cgEvent: cgEvent) {
                        monitor.handleEvent(event)
                    }
                    return Unmanaged.passUnretained(cgEvent)
                },
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else { return }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        print("started monitoring...")
    }

    func stopMonitoring() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            eventTap = nil
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        state.reset()
    }

    // MARK: - Event handling

    private func handleEvent(_ event: NSEvent) {
        // Ignore synthetic events posted by SpaceSwitcher
        guard let cgEvent = event.cgEvent else { return }
        if cgEvent.getIntegerValueField(kSyntheticMarkerField) == kSyntheticMarkerValue {
            print("ignoring synthetic event")
            return
        }

        let touches = event.allTouches()
        guard !touches.isEmpty else {
            print("touches empty")
            state.reset()
            return
        }

        let activeFingerCount =
            touches.allSatisfy { $0.phase == .ended || $0.phase == .cancelled } ? 0 : touches.count
        if activeFingerCount == 0 {
            print("fingerCount 0")
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

        let direction: SwipeDirection = state.accumulatedDeltaX > 0 ? .right : .left

        if direction == state.lastFiredDirection {
            state.accumulatedDeltaX = 0
            return
        }

        state.lastFiredDirection = direction
        state.accumulatedDeltaX = 0
        print("firing with \(direction)")
        onSwipe?(direction, activeFingerCount)
    }
}
