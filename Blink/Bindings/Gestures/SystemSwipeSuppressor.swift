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
                    self.suppressingNativeSwipe = false
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
        eventTap?.disable()
        eventTap = nil
        suppressingNativeSwipe = false
    }

    private func handleGestureEvent(_ event: CGEvent) -> CGEvent? {
        guard !isSyntheticOrAppPosted(event) else {
            return event
        }

        return suppressingNativeSwipe ? nil : event
    }

    private func handleDockControlEvent(_ event: CGEvent) -> CGEvent? {
        guard !isSyntheticOrAppPosted(event) else {
            return event
        }

        guard isHorizontalDockSwipe(event) else {
            return event
        }

        let phase = event.getIntegerValueField(kGesturePhaseField)

        switch phase {
        case kGesturePhaseBegan:
            suppressingNativeSwipe = true

        case kGesturePhaseEnded, kGesturePhaseCancelled:
            suppressingNativeSwipe = false

        default:
            break
        }

        return nil
    }

    private func isHorizontalDockSwipe(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(kGestureHIDTypeField) == kDockSwipeHIDType else {
            return false
        }

        return event.getIntegerValueField(kGestureSwipeMotionField) == kHorizontalGestureMotion
    }

    private func isSyntheticOrAppPosted(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(kSyntheticMarkerField) == kSyntheticMarkerValue {
            return true
        }
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        return sourcePID != 0
    }
}
