//
//  EventTap.swift
//  Blink
//
//  Created by Ben on 3/30/26.
//

import Cocoa
import Darwin
import os.log

/// A type that receives system events from various locations within the
/// event stream.
@MainActor
final class EventTap {
    /// Constants that specify the possible tapping locations for events.
    enum Location {
        /// The location where HID system events enter the window server.
        case hidEventTap

        /// The location where HID system and remote control events enter
        /// a login session.
        case sessionEventTap

        /// The location where session events have been annotated to flow
        /// to an application.
        case annotatedSessionEventTap

        /// The location where annotated events are delivered to a specific
        /// process.
        case pid(pid_t)

        var logString: String {
            switch self {
            case .hidEventTap: "HID event tap"
            case .sessionEventTap: "session event tap"
            case .annotatedSessionEventTap: "annotated session event tap"
            case .pid(let pid): "PID \(pid)"
            }
        }
    }

    /// A proxy for an event tap.
    ///
    /// Event tap proxies are passed to an event tap's callback, and can be
    /// used to post additional events to the tap before the callback returns
    /// or to disable the tap from within the callback.
    @MainActor
    struct Proxy {
        private let tap: EventTap
        private let pointer: CGEventTapProxy

        /// The label associated with the event tap.
        var label: String {
            tap.label
        }

        /// A Boolean value that indicates whether the event tap is enabled.
        var isEnabled: Bool {
            tap.isEnabled
        }

        fileprivate init(tap: EventTap, pointer: CGEventTapProxy) {
            self.tap = tap
            self.pointer = pointer
        }

        /// Posts an event into the event stream from the location of this tap.
        func postEvent(_ event: CGEvent) {
            event.tapPostEvent(pointer)
        }

        /// Enables the event tap.
        func enable() {
            tap.enable()
        }

        /// Enables the event tap with the given timeout.
        func enable(timeout: Duration, onTimeout: @escaping () -> Void) {
            tap.enable(timeout: timeout, onTimeout: onTimeout)
        }

        /// Disables the event tap.
        func disable() {
            tap.disable()
        }
    }

    private let runLoop = CFRunLoopGetCurrent()
    private let mode: CFRunLoopMode = .commonModes
    private let options: CGEventTapOptions
    private let location: Location
    private let place: CGEventTapPlacement
    private let eventMask: CGEventMask
    private nonisolated let callback:
        (EventTap, CGEventTapProxy, CGEventType, CGEvent) -> Unmanaged<CGEvent>?

    private var machPort: CFMachPort?
    private var source: CFRunLoopSource?

    /// A copy of the mach port stored without actor isolation so that the C
    /// event tap callback can re-enable the tap synchronously on timeout without
    /// waiting for the main actor. Recovery mutates this property on the tap's
    /// run loop after the current callback returns.
    fileprivate nonisolated(unsafe) var tapMachPort: CFMachPort?

    #if DEBUG
    fileprivate nonisolated let debugCallbackDelayMicroseconds: useconds_t
    #endif

    /// The label associated with the event tap.
    let label: String

    /// A Boolean value that indicates whether the event tap is enabled.
    var isEnabled: Bool {
        guard let machPort else { return false }
        return CGEvent.tapIsEnabled(tap: machPort)
    }

    var isValid: Bool {
        guard let machPort, let source else { return false }
        return CFMachPortIsValid(machPort) && CFRunLoopSourceIsValid(source)
    }

    var isHealthy: Bool {
        isValid && isEnabled
    }

    /// Creates a new event tap.
    ///
    /// - Parameters:
    ///   - label: The label associated with the tap.
    ///   - kind: The kind of tap to create.
    ///   - location: The location to listen for events.
    ///   - placement: The placement of the tap relative to other active taps.
    ///   - types: The event types to listen for.
    ///   - callback: A callback function to perform when the tap receives events.
    init(
        label: String = #function,
        options: CGEventTapOptions,
        location: Location,
        place: CGEventTapPlacement,
        types: [CGEventType],
        callback:
            @MainActor @escaping (_ proxy: Proxy, _ type: CGEventType, _ event: CGEvent) -> CGEvent?
    ) {
        self.label = label
        #if DEBUG
        let milliseconds = Int(
            ProcessInfo.processInfo.environment["BLINK_EVENT_TAP_DELAY_MS"] ?? "0"
        ) ?? 0
        self.debugCallbackDelayMicroseconds = useconds_t(
            min(max(milliseconds, 0), 10_000) * 1_000
        )
        #endif
        self.options = options
        self.location = location
        self.place = place
        self.eventMask = types.reduce(into: 0) { $0 |= 1 << $1.rawValue }
        self.callback = { @MainActor tap, pointer, type, event in
            callback(Proxy(tap: tap, pointer: pointer), type, event).map(Unmanaged.passUnretained)
        }
        installComponents()
    }

    deinit {
        guard let machPort else { return }
        CFRunLoopRemoveSource(runLoop, source, mode)
        CGEvent.tapEnable(tap: machPort, enable: false)
        CFMachPortInvalidate(machPort)
    }

    fileprivate nonisolated static func performCallback(
        for eventTap: EventTap,
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        let callback = eventTap.callback
        return callback(eventTap, proxy, type, event)
    }

    private static func createTapMachPort(
        location: Location,
        place: CGEventTapPlacement,
        options: CGEventTapOptions,
        eventsOfInterest: CGEventMask,
        callback: CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer?
    ) -> CFMachPort? {
        if case .pid(let pid) = location {
            return CGEvent.tapCreateForPid(
                pid: pid,
                place: place,
                options: options,
                eventsOfInterest: eventsOfInterest,
                callback: callback,
                userInfo: userInfo
            )
        }

        let tap: CGEventTapLocation? =
            switch location {
            case .hidEventTap: .cghidEventTap
            case .sessionEventTap: .cgSessionEventTap
            case .annotatedSessionEventTap: .cgAnnotatedSessionEventTap
            case .pid: nil
            }

        guard let tap else { return nil }

        return CGEvent.tapCreate(
            tap: tap,
            place: place,
            options: options,
            eventsOfInterest: eventsOfInterest,
            callback: callback,
            userInfo: userInfo
        )
    }

    private func withUnwrappedComponents(
        body: @MainActor (CFRunLoop, CFRunLoopSource, CFMachPort) -> Void
    ) {
        guard let runLoop else {
            Logger.eventTap.error("Missing run loop for event tap \"\(self.label)\"")
            return
        }
        guard let source else {
            Logger.eventTap.error("Missing run loop source for event tap \"\(self.label)\"")
            return
        }
        guard let machPort else {
            Logger.eventTap.error("Missing mach port for event tap \"\(self.label)\"")
            return
        }
        body(runLoop, source, machPort)
    }

    @discardableResult
    private func installComponents() -> Bool {
        guard
            let machPort = Self.createTapMachPort(
                location: location,
                place: place,
                options: options,
                eventsOfInterest: eventMask,
                callback: handleEvent,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            )
        else {
            Logger.eventTap.error("Error creating mach port for event tap \"\(label)\"")
            Task {
                await DiagnosticsStore.shared.record(
                    "event-tap",
                    "\(label) creation failed"
                )
            }
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(nil, machPort, 0) else {
            CFMachPortInvalidate(machPort)
            Logger.eventTap.error("Error creating run loop source for event tap \"\(label)\"")
            Task {
                await DiagnosticsStore.shared.record(
                    "event-tap",
                    "\(label) run loop source creation failed"
                )
            }
            return false
        }

        self.machPort = machPort
        self.tapMachPort = machPort
        self.source = source
        Task {
            await DiagnosticsStore.shared.record("event-tap", "\(label) created")
        }
        return true
    }

    private func removeComponents() {
        if let source {
            CFRunLoopRemoveSource(runLoop, source, mode)
        }
        if let machPort {
            CGEvent.tapEnable(tap: machPort, enable: false)
            CFMachPortInvalidate(machPort)
        }

        source = nil
        machPort = nil
        tapMachPort = nil
    }

    /// Enables the event tap.
    func enable() {
        if !isValid {
            removeComponents()
            guard installComponents() else { return }
        }

        withUnwrappedComponents { runLoop, source, machPort in
            CFRunLoopAddSource(runLoop, source, mode)
            CGEvent.tapEnable(tap: machPort, enable: true)
        }
    }

    func recoverIfNeeded() {
        guard !isHealthy else { return }

        if isValid {
            enable()
        }

        guard !isHealthy else { return }
        Logger.eventTap.warning("Recreating unhealthy event tap \"\(label)\"")
        Task {
            await DiagnosticsStore.shared.record("event-tap", "\(label) recreated")
        }
        removeComponents()
        enable()
    }

    /// Enables the event tap with the given timeout.
    func enable(timeout: Duration, onTimeout: @escaping () -> Void) {
        enable()
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            if self?.isEnabled == true {
                onTimeout()
            }
        }
    }

    /// Disables the event tap.
    func disable() {
        withUnwrappedComponents { runLoop, source, machPort in
            CFRunLoopRemoveSource(runLoop, source, mode)
            CGEvent.tapEnable(tap: machPort, enable: false)
        }
    }
}

// MARK: - Handle Event
private nonisolated func handleEvent(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else {
        return Unmanaged.passRetained(event)
    }
    let eventTap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()

    #if DEBUG
    if eventTap.debugCallbackDelayMicroseconds > 0,
        type != .tapDisabledByTimeout,
        type != .tapDisabledByUserInput
    {
        usleep(eventTap.debugCallbackDelayMicroseconds)
    }
    #endif

    // When macOS disables the tap due to a timeout or user-input event, we must
    // re-enable it *synchronously* here in the C callback before returning.
    // Relying solely on the @MainActor callback to call proxy.enable() is unsafe:
    // the actor hop is asynchronous, and by the time the main actor runs the
    // closure the kernel's re-enable window has already closed, leaving the tap
    // permanently dead until the next explicit enable() call (which never comes).
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let port = eventTap.tapMachPort {
            os_log(
                .error,
                log: OSLog(subsystem: "Blink", category: "EventTap"),
                "Event tap \"%{public}@\" disabled by system (type: %u); re-enabling synchronously.",
                eventTap.label,
                type.rawValue
            )
            CGEvent.tapEnable(tap: port, enable: true)
        }
        Task { @MainActor in
            await DiagnosticsStore.shared.record(
                "event-tap",
                "\(eventTap.label) disabled by system type=\(type.rawValue)"
            )
            eventTap.recoverIfNeeded()
        }
        // Still dispatch to the @MainActor callback so callers can reset state.
    }

    return EventTap.performCallback(for: eventTap, proxy: proxy, type: type, event: event)
}

// MARK: - CGEventType extension
extension CGEventType {
    static let gesture = CGEventType(rawValue: 29)!
}

// MARK: - Logger
extension Logger {
    fileprivate static let eventTap = Logger(category: "EventTap")
}
