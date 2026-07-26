import CoreGraphics
import Foundation

struct HotkeyKeyEvent: Equatable {
    let keyCombination: KeyCombination
    let isAutorepeat: Bool
}

struct HotkeyEventMatcher {
    enum RegistrationError: Error, Equatable {
        case duplicate(existingRegistrationID: UInt32)
    }

    enum Decision: Equatable {
        case passThrough
        case invoke(registrationID: UInt32)
        case suppress
    }

    private var registrationsByCombination: [KeyCombination: UInt32] = [:]
    private var combinationsByRegistration: [UInt32: KeyCombination] = [:]

    mutating func register(
        _ combination: KeyCombination,
        registrationID: UInt32
    ) -> Result<Void, RegistrationError> {
        if let existingID = registrationsByCombination[combination] {
            return .failure(.duplicate(existingRegistrationID: existingID))
        }
        registrationsByCombination[combination] = registrationID
        combinationsByRegistration[registrationID] = combination
        return .success(())
    }

    mutating func unregister(_ registrationID: UInt32) {
        guard let combination = combinationsByRegistration.removeValue(
            forKey: registrationID
        ) else { return }
        registrationsByCombination.removeValue(forKey: combination)
    }

    func decision(for event: HotkeyKeyEvent) -> Decision {
        guard let registrationID = registrationsByCombination[event.keyCombination] else {
            return .passThrough
        }
        return event.isAutorepeat ? .suppress : .invoke(registrationID: registrationID)
    }
}

nonisolated enum HotkeyMonitoringFailure: Equatable, Sendable {
    case eventTapUnavailable

    var description: String {
        switch self {
        case .eventTapUnavailable:
            "Blink could not start keyboard monitoring. Check Accessibility permission."
        }
    }
}

nonisolated enum HotkeyMonitoringState: Equatable, Sendable {
    case disabled
    case active
    case failed(HotkeyMonitoringFailure)
}

@MainActor
protocol HotkeyEventMonitoring: AnyObject {
    var isHealthy: Bool { get }
    func enable()
    func disable()
    func recoverIfNeeded()
}

extension EventTap: HotkeyEventMonitoring {}

@MainActor
final class HotkeyRegistry {
    enum RegistrationError: Error, Equatable {
        case notConfigured
        case duplicate(existingRegistrationID: UInt32)
        case monitoringFailed(HotkeyMonitoringFailure)
    }

    typealias MonitorFactory = @MainActor (
        _ callback: @MainActor @escaping (CGEventType, CGEvent) -> CGEvent?
    ) -> any HotkeyEventMonitoring

    private struct Registration {
        let handler: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var matcher = HotkeyEventMatcher()
    private var nextID: UInt32 = 1
    private var eventMonitor: (any HotkeyEventMonitoring)?
    private let monitorFactory: MonitorFactory

    private(set) var monitoringState: HotkeyMonitoringState = .disabled {
        didSet {
            guard monitoringState != oldValue else { return }
            onMonitoringStateChanged?(monitoringState)
        }
    }

    var onMonitoringStateChanged: ((HotkeyMonitoringState) -> Void)?

    init() {
        self.monitorFactory = { callback in
            EventTap(
                label: "HotkeyRegistry",
                options: .defaultTap,
                location: .hidEventTap,
                place: .headInsertEventTap,
                types: [.keyDown],
                callback: { _, type, event in callback(type, event) }
            )
        }
    }

    init(monitorFactory: @escaping MonitorFactory) {
        self.monitorFactory = monitorFactory
    }

    deinit {
        MainActor.assumeIsolated {
            eventMonitor?.disable()
        }
    }

    func register(
        hotkey: Hotkey,
        handler: @escaping () -> Void
    ) -> Result<UInt32, RegistrationError> {
        guard let combination = hotkey.keyCombination else {
            return .failure(.notConfigured)
        }
        return register(keyCombination: combination, handler: handler)
    }

    func register(
        keyCombination: KeyCombination,
        handler: @escaping () -> Void
    ) -> Result<UInt32, RegistrationError> {
        let id = nextID
        switch matcher.register(keyCombination, registrationID: id) {
        case .failure(.duplicate(let existingID)):
            return .failure(.duplicate(existingRegistrationID: existingID))
        case .success:
            break
        }

        guard startMonitoring() else {
            matcher.unregister(id)
            return .failure(.monitoringFailed(.eventTapUnavailable))
        }

        nextID &+= 1
        registrations[id] = Registration(handler: handler)
        return .success(id)
    }

    func unregister(_ id: UInt32) {
        guard registrations.removeValue(forKey: id) != nil else {
            Logger.hotkeyRegistry.error("No registered key combination for id \(id)")
            return
        }
        matcher.unregister(id)

        if registrations.isEmpty {
            eventMonitor?.disable()
            eventMonitor = nil
            monitoringState = .disabled
        }
    }

    /// Revalidates the shared tap after wake, unlock, or a system disablement.
    @discardableResult
    func ensureMonitoring() -> Bool {
        guard !registrations.isEmpty else {
            monitoringState = .disabled
            return false
        }
        return startMonitoring()
    }

    private func startMonitoring() -> Bool {
        if eventMonitor == nil {
            let monitor = monitorFactory { [weak self] type, event in
                guard let self else { return event }
                switch type {
                case .tapDisabledByTimeout, .tapDisabledByUserInput:
                    self.handleTapDisabled()
                    return event
                case .keyDown:
                    return self.handleKeyDown(event) ? nil : event
                default:
                    return event
                }
            }
            eventMonitor = monitor
            // A newly-created CGEvent tap can report itself enabled before its
            // run-loop source has been installed. Always call enable() once so
            // events are actually delivered.
            monitor.enable()
        } else {
            eventMonitor?.recoverIfNeeded()
        }

        guard eventMonitor?.isHealthy == true else {
            monitoringState = .failed(.eventTapUnavailable)
            Logger.hotkeyRegistry.error("Hotkey HID event tap is unavailable")
            return false
        }

        monitoringState = .active
        return true
    }

    func stopMonitoring() {
        guard registrations.isEmpty else { return }
        eventMonitor?.disable()
        eventMonitor = nil
        monitoringState = .disabled
    }

    /// Returns whether the event must be removed from the system event stream.
    /// Matching repeats are consumed but intentionally do not invoke the action.
    func handleKeyEvent(_ event: HotkeyKeyEvent) -> Bool {
        switch matcher.decision(for: event) {
        case .passThrough:
            return false
        case .suppress:
            return true
        case .invoke(let registrationID):
            registrations[registrationID]?.handler()
            return true
        }
    }

    func handleTapDisabled() {
        eventMonitor?.recoverIfNeeded()
        if eventMonitor?.isHealthy == true {
            monitoringState = .active
        } else {
            monitoringState = .failed(.eventTapUnavailable)
        }
    }

    private func handleKeyDown(_ event: CGEvent) -> Bool {
        handleKeyEvent(
            HotkeyKeyEvent(
                keyCombination: KeyCombination(cgEvent: event),
                isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            )
        )
    }
}

extension Logger {
    fileprivate static let hotkeyRegistry = Logger(category: "HotkeyRegistry")
}
