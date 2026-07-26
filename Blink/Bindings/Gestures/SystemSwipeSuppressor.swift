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

    mutating func finish() -> Bool {
        let shouldSuppress = shouldSuppress
        route = .undecided
        return shouldSuppress
    }

    mutating func reset() {
        route = .undecided
    }
}

nonisolated struct SuppressorOperationalHealth: Equatable, Sendable {
    private(set) var state: EventTapOperationalState = .disabled
    private(set) var epoch: UInt64 = 0

    mutating func update(
        configured: Bool,
        tapIsHealthy: Bool,
        interrupted: Bool = false
    ) -> Bool {
        let next: EventTapOperationalState = configured
            ? (tapIsHealthy && !interrupted ? .armed : .degraded)
            : .disabled
        guard interrupted || next != state else { return false }
        state = next
        epoch &+= 1
        return true
    }
}

nonisolated struct DockSegmentLifetimeState: Equatable, Sendable {
    private enum State: Equatable, Sendable {
        case idle
        case prepared(id: UInt64, activityToken: UInt64)
        case active(id: UInt64, activityToken: UInt64)
    }

    private var state: State = .idle
    private var nextID: UInt64 = 0
    private var nextActivityToken: UInt64 = 0

    var segmentID: UInt64? {
        switch state {
        case .prepared(let id, _), .active(let id, _): id
        case .idle: nil
        }
    }

    var activityToken: UInt64? {
        switch state {
        case .prepared(_, let token), .active(_, let token): token
        case .idle: nil
        }
    }

    mutating func prepare() -> (ended: UInt64?, began: UInt64) {
        let ended = segmentID
        nextID &+= 1
        nextActivityToken &+= 1
        state = .prepared(id: nextID, activityToken: nextActivityToken)
        return (ended, nextID)
    }

    mutating func begin() -> (id: UInt64, needsBoundary: Bool) {
        if case .prepared(let id, _) = state {
            nextActivityToken &+= 1
            state = .active(id: id, activityToken: nextActivityToken)
            return (id, false)
        }
        let id = prepare().began
        nextActivityToken &+= 1
        state = .active(id: id, activityToken: nextActivityToken)
        return (id, true)
    }

    mutating func observeActivity() -> UInt64? {
        guard case .active(let id, _) = state else { return nil }
        nextActivityToken &+= 1
        state = .active(id: id, activityToken: nextActivityToken)
        return id
    }

    mutating func finish() -> UInt64? {
        let ended = segmentID
        state = .idle
        return ended
    }

    mutating func expire(activityToken: UInt64) -> UInt64? {
        guard self.activityToken == activityToken else { return nil }
        return finish()
    }

    mutating func reset() -> UInt64? {
        finish()
    }
}

@MainActor
final class SystemSwipeSuppressor {
    private var eventTap: EventTap?
    private var routingState = NativeSwipeRoutingState()
    private var segmentLifetime = DockSegmentLifetimeState()
    private var health = SuppressorOperationalHealth()
    private var segmentInactivityTask: Task<Void, Never>?
    private let segmentInactivityDuration: Duration

    var contextForNewGesture: ((UInt64) -> GestureSessionContext?)?
    var onDockSegmentMayBegin: ((UInt64) -> Void)?
    var onDockSegmentEnded: ((UInt64) -> Void)?
    var onPotentialOverlayTransition: (() -> Void)?
    var onContextSelected: ((GestureSessionContext?) -> Void)?
    var onMonitoringInterrupted: (() -> Void)?
    var onOperationalStateChanged: ((EventTapOperationalState, UInt64) -> Void)?

    var operationalState: EventTapOperationalState {
        guard health.state != .disabled else { return .disabled }
        return health.state == .armed && eventTap?.isHealthy == true
            ? .armed
            : .degraded
    }
    var operationalEpoch: UInt64 { health.epoch }

    init(segmentInactivityDuration: Duration = .seconds(1)) {
        self.segmentInactivityDuration = segmentInactivityDuration
    }

    func startMonitoring() {
        if let eventTap, eventTap.isHealthy {
            updateHealth(configured: true, tapIsHealthy: true)
            return
        }

        if eventTap != nil {
            eventTap?.disable()
            interruptMonitoring()
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
                    self.interruptMonitoring()
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        self.eventTap?.recoverIfNeeded()
                        self.reconcileHealth()
                    }
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
        reconcileHealth()
    }

    func ensureMonitoring() {
        guard eventTap != nil else { return }
        startMonitoring()
    }

    func stopMonitoring() {
        let wasConfigured = eventTap != nil || health.state != .disabled
        eventTap?.disable()
        eventTap = nil
        resetDockSegment()
        updateHealth(configured: false, tapIsHealthy: false)
        if wasConfigured { onMonitoringInterrupted?() }
    }

    /// Releases destructive ownership for the current segment while leaving a
    /// healthy tap armed for a future physical contact.
    func failOpenCurrentSegment() {
        resetDockSegment()
    }

    private func handleGestureEvent(_ event: CGEvent) -> CGEvent? {
        guard !isSyntheticOrAppPosted(event) else { return event }
        guard isArmed else { return event }
        return routingState.shouldSuppress ? nil : event
    }

    private func handleDockControlEvent(_ event: CGEvent) -> CGEvent? {
        guard !isSyntheticOrAppPosted(event), isDockSwipe(event) else {
            return event
        }

        guard isArmed else {
            interruptMonitoringIfUnhealthy()
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
            let transition = segmentLifetime.prepare()
            if let ended = transition.ended { endDockSegment(ended) }
            routingState.reset()
            onDockSegmentMayBegin?(transition.began)
            scheduleSegmentInactivity()
            return event
        case SyntheticGestureProtocol.began:
            let beginning = segmentLifetime.begin()
            if beginning.needsBoundary {
                onDockSegmentMayBegin?(beginning.id)
            }
            let context = contextForNewGesture?(beginning.id)
            let ownsGesture = context?.isAuthoritativeBlinkContext == true
            onContextSelected?(context)
            routingState.begin(ownedByBlink: ownsGesture)
            scheduleSegmentInactivity()
            return ownsGesture ? nil : event
        case SyntheticGestureProtocol.ended, SyntheticGestureProtocol.cancelled:
            let suppressesTerminal = routingState.finish()
            if let ended = segmentLifetime.finish() { endDockSegment(ended) }
            return suppressesTerminal ? nil : event
        default:
            _ = segmentLifetime.observeActivity()
            scheduleSegmentInactivity()
            return routingState.shouldSuppress ? nil : event
        }
    }

    private var isArmed: Bool {
        let healthy = eventTap?.isHealthy == true
        if health.state == .armed, !healthy {
            updateHealth(configured: true, tapIsHealthy: false, interrupted: true)
        }
        return health.state == .armed && healthy
    }

    private func reconcileHealth() {
        updateHealth(
            configured: eventTap != nil,
            tapIsHealthy: eventTap?.isHealthy == true
        )
    }

    private func updateHealth(
        configured: Bool,
        tapIsHealthy: Bool,
        interrupted: Bool = false
    ) {
        guard health.update(
            configured: configured,
            tapIsHealthy: tapIsHealthy,
            interrupted: interrupted
        ) else { return }
        onOperationalStateChanged?(health.state, health.epoch)
    }

    private func interruptMonitoringIfUnhealthy() {
        guard eventTap?.isHealthy != true else { return }
        interruptMonitoring()
    }

    private func interruptMonitoring() {
        resetDockSegment()
        updateHealth(configured: true, tapIsHealthy: false, interrupted: true)
        onMonitoringInterrupted?()
    }

    private func scheduleSegmentInactivity() {
        segmentInactivityTask?.cancel()
        guard let activityToken = segmentLifetime.activityToken else {
            segmentInactivityTask = nil
            return
        }
        let duration = segmentInactivityDuration
        segmentInactivityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            guard let ended = segmentLifetime.expire(
                activityToken: activityToken
            ) else { return }
            segmentInactivityTask = nil
            routingState.reset()
            endDockSegment(ended)
        }
    }

    private func resetDockSegment() {
        segmentInactivityTask?.cancel()
        segmentInactivityTask = nil
        routingState.reset()
        if let ended = segmentLifetime.reset() { endDockSegment(ended) }
    }

    private func endDockSegment(_ id: UInt64) {
        onDockSegmentEnded?(id)
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
        return event.getIntegerValueField(.eventSourceUnixProcessID) != 0
    }
}
