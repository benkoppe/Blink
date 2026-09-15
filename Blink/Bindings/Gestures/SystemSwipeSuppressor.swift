//
//  SystemSwipeSuppressor.swift
//  Blink
//
//  Created by Ben on 4/12/26.
//

import CoreGraphics

private let kDockControlEventType = CGEventType(rawValue: 30)!
private let kGestureHIDTypeField = CGEventField(rawValue: 110)!
private let kGestureSwipeMotionField = CGEventField(rawValue: 123)!
private let kGesturePhaseField = CGEventField(rawValue: 132)!

private let kDockSwipeHIDType: Int64 = 23
private let kHorizontalGestureMotion: Int64 = 1

private let kGesturePhaseBegan: Int64 = 1
private let kGesturePhaseEnded: Int64 = 4
private let kGesturePhaseCancelled: Int64 = 8

final class SystemSwipeSuppressor {
    private var eventTap: EventTap?
    private var suppressingNativeSwipe = false
    private var bypassingNativeSwipe = false

    var policy = NativeSwipePolicy()

    func startMonitoring() {
        guard eventTap == nil else { return }

        let tap = EventTap(
            label: "SystemSwipeSuppressor",
            options: .defaultTap,
            location: .sessionEventTap,
            place: .headInsertEventTap,
            types: [.gesture, kDockControlEventType],
            callback: { [weak self] proxy, type, cgEvent in
                guard let self else { return cgEvent }

                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    self.policy.reset()
                    self.suppressingNativeSwipe = false
                    self.bypassingNativeSwipe = false
                    proxy.enable()
                    return cgEvent

                case .gesture:
                    return self.handleGestureEvent(cgEvent)

                default:
                    if type == kDockControlEventType {
                        return self.handleDockControlEvent(cgEvent)
                    }
                    return cgEvent
                }
            }
        )

        tap.enable()
        eventTap = tap
    }

    func stopMonitoring() {
        policy.reset()
        eventTap?.disable()
        eventTap = nil
        suppressingNativeSwipe = false
        bypassingNativeSwipe = false
    }

    private func handleGestureEvent(_ event: CGEvent) -> CGEvent? {
        guard !NativeSwipePolicy.isAppPosted(event) else {
            return event
        }

        if bypassingNativeSwipe {
            return event
        }

        return suppressingNativeSwipe ? nil : event
    }

    private func handleDockControlEvent(_ event: CGEvent) -> CGEvent? {
        guard !NativeSwipePolicy.isAppPosted(event) else {
            return event
        }

        guard isHorizontalDockSwipe(event) else {
            return event
        }

        let phase = event.getIntegerValueField(kGesturePhaseField)

        switch phase {
        case kGesturePhaseBegan:
            let shouldBypass = policy.begin(.suppression)
            bypassingNativeSwipe = shouldBypass
            suppressingNativeSwipe = !shouldBypass
            return shouldBypass ? event : nil

        case kGesturePhaseEnded, kGesturePhaseCancelled:
            let wasSuppressing = suppressingNativeSwipe
            policy.end(.suppression)
            bypassingNativeSwipe = false
            suppressingNativeSwipe = false
            return wasSuppressing ? nil : event

        default:
            if bypassingNativeSwipe {
                return event
            }
            return suppressingNativeSwipe ? nil : event
        }
    }

    private func isHorizontalDockSwipe(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(kGestureHIDTypeField) == kDockSwipeHIDType else {
            return false
        }

        return event.getIntegerValueField(kGestureSwipeMotionField) == kHorizontalGestureMotion
    }
}
