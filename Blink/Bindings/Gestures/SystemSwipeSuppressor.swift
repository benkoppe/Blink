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
    private var activeContext: GestureSessionContext?

    var contextForNewGesture: (() -> GestureSessionContext?)?
    var onGestureMayBegin: (() -> Void)?
    var onPotentialOverlayTransition: (() -> Void)?
    var onContextSelected: ((GestureSessionContext?) -> Void)?
    var onGestureEnded: (() -> Void)?

    func startMonitoring() {
        if let eventTap, eventTap.isHealthy { return }

        if eventTap != nil {
            eventTap?.disable()
            endGesture()
        }

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
                    self.endGesture()
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

    func ensureMonitoring() {
        guard eventTap != nil else { return }
        startMonitoring()
    }

    func stopMonitoring() {
        eventTap?.disable()
        eventTap = nil
        endGesture()
    }

    private func handleGestureEvent(_ event: CGEvent) -> CGEvent? {
        guard !isSyntheticOrAppPosted(event) else {
            return event
        }

        if bypassingNativeSwipe {
            return event
        }

        return suppressingNativeSwipe ? nil : event
    }

    private func handleDockControlEvent(_ event: CGEvent) -> CGEvent? {
        guard !isSyntheticOrAppPosted(event) else {
            return event
        }

        guard isDockSwipe(event) else {
            return event
        }

        let phase = event.getIntegerValueField(kGesturePhaseField)
        guard isHorizontalDockSwipe(event) else {
            if phase == kGesturePhaseBegan
                || phase == kGesturePhaseEnded
                || phase == kGesturePhaseCancelled
            {
                onPotentialOverlayTransition?()
            }
            return event
        }

        switch phase {
        case SyntheticGestureProtocol.mayBegin:
            onGestureMayBegin?()
            return event
        case kGesturePhaseBegan:
            let context = contextForNewGesture?()
            let route = context?.route ?? .system
            activeContext = context
            onContextSelected?(context)
            bypassingNativeSwipe = route == .system
            suppressingNativeSwipe = route == .blink
            return route == .system ? event : nil

        case kGesturePhaseEnded, kGesturePhaseCancelled:
            let isBypassing = bypassingNativeSwipe
            endGesture()
            if isBypassing {
                onPotentialOverlayTransition?()
            }
            return isBypassing ? event : nil

        default:
            if bypassingNativeSwipe {
                return event
            }
            return suppressingNativeSwipe ? nil : event
        }
    }

    private func endGesture() {
        suppressingNativeSwipe = false
        bypassingNativeSwipe = false
        activeContext = nil
        onGestureEnded?()
    }

    private func isHorizontalDockSwipe(_ event: CGEvent) -> Bool {
        return event.getIntegerValueField(kGestureSwipeMotionField) == kHorizontalGestureMotion
    }

    private func isDockSwipe(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(kGestureHIDTypeField) == kDockSwipeHIDType
    }

    private func isSyntheticOrAppPosted(_ event: CGEvent) -> Bool {
        if event.getIntegerValueField(SyntheticGestureProtocol.markerField)
            == SyntheticGestureProtocol.markerValue
        {
            return true
        }
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        return sourcePID != 0
    }
}
