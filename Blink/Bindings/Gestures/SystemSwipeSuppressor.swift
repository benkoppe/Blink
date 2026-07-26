//
//  SystemSwipeSuppressor.swift
//  Blink
//
//  Created by Ben on 4/12/26.
//

import CoreGraphics

nonisolated struct NativeSwipeRoutingState: Equatable, Sendable {
    private enum Route: Equatable, Sendable {
        case undecided
        case blink
        case system
    }

    private var route: Route = .undecided

    var shouldSuppress: Bool { route == .blink }

    mutating func begin(ownedByBlink: Bool) {
        route = ownedByBlink ? .blink : .system
    }

    /// Ends the segment and returns whether its terminal event is Blink-owned.
    mutating func finish() -> Bool {
        let shouldSuppress = shouldSuppress
        route = .undecided
        return shouldSuppress
    }

    mutating func reset() {
        route = .undecided
    }
}

final class SystemSwipeSuppressor {
    private var eventTap: EventTap?
    private var routingState = NativeSwipeRoutingState()

    var contextForNewGesture: (() -> GestureSessionContext?)?
    var onPotentialOverlayTransition: (() -> Void)?
    var onContextSelected: ((GestureSessionContext?) -> Void)?
    var onMonitoringInterrupted: (() -> Void)?

    func startMonitoring() {
        if let eventTap, eventTap.isHealthy { return }

        if eventTap != nil {
            eventTap?.disable()
            resetDockSegment()
            onMonitoringInterrupted?()
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
                    self.resetDockSegment()
                    self.onMonitoringInterrupted?()
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
        let wasMonitoring = eventTap != nil
        eventTap?.disable()
        eventTap = nil
        resetDockSegment()
        if wasMonitoring { onMonitoringInterrupted?() }
    }

    private func handleGestureEvent(_ event: CGEvent) -> CGEvent? {
        guard !isSyntheticOrAppPosted(event) else {
            return event
        }

        return routingState.shouldSuppress ? nil : event
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
            return event
        case SyntheticGestureProtocol.began:
            let context = contextForNewGesture?()
            let ownsGesture = context?.isAuthoritativeBlinkContext == true
            onContextSelected?(context)
            routingState.begin(ownedByBlink: ownsGesture)
            return ownsGesture ? nil : event

        case SyntheticGestureProtocol.ended, SyntheticGestureProtocol.cancelled:
            return routingState.finish() ? nil : event

        default:
            return routingState.shouldSuppress ? nil : event
        }
    }

    private func resetDockSegment() {
        routingState.reset()
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
