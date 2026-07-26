//
//  SystemSwipeSuppressor.swift
//  Blink
//
//  Created by Ben on 4/12/26.
//

import CoreGraphics

final class SystemSwipeSuppressor {
    private var eventTap: EventTap?
    private var suppressingNativeSwipe = false
    private var bypassingNativeSwipe = false

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
            types: [
                .gesture,
                CGEventType(rawValue: UInt32(SyntheticGestureProtocol.dockControlEventType))!,
            ],
            callback: { [weak self] _, type, cgEvent in
                guard let self else { return cgEvent }

                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    self.endGesture()
                    return cgEvent

                case .gesture:
                    return self.handleGestureEvent(cgEvent)

                default:
                    if type.rawValue == UInt32(SyntheticGestureProtocol.dockControlEventType) {
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

        let phase = event.getIntegerValueField(SyntheticGestureProtocol.phase)
        guard isHorizontalDockSwipe(event) else {
            if phase == SyntheticGestureProtocol.began
                || phase == SyntheticGestureProtocol.ended
                || phase == SyntheticGestureProtocol.cancelled
            {
                onPotentialOverlayTransition?()
            }
            return event
        }

        switch phase {
        case SyntheticGestureProtocol.mayBegin:
            onGestureMayBegin?()
            return event
        case SyntheticGestureProtocol.began:
            // Some macOS paths omit `mayBegin`. Preparation is idempotent and
            // starts an off-callback scan before the bounded context wait.
            onGestureMayBegin?()
            let context = contextForNewGesture?()
            let ownsGesture = context?.isAuthoritativeBlinkContext == true
            onContextSelected?(context)
            bypassingNativeSwipe = !ownsGesture
            suppressingNativeSwipe = ownsGesture
            return ownsGesture ? nil : event

        case SyntheticGestureProtocol.ended, SyntheticGestureProtocol.cancelled:
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
        onGestureEnded?()
    }

    private func isHorizontalDockSwipe(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(SyntheticGestureProtocol.swipeMotion)
            == SyntheticGestureProtocol.horizontalMotion
    }

    private func isDockSwipe(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(SyntheticGestureProtocol.hidType)
            == SyntheticGestureProtocol.dockSwipeHIDType
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
