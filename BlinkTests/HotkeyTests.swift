import CoreGraphics
import Foundation
import Testing

@testable import Blink

@MainActor
@Suite("Hotkeys")
struct HotkeyTests {
    @Test("Matching events invoke once and are suppressed")
    func matchingEventInvokesAndSuppresses() {
        let monitor = FakeHotkeyMonitor(isHealthy: true)
        let registry = HotkeyRegistry { _ in monitor }
        var invocationCount = 0
        let combination = KeyCombination(key: .leftArrow, modifiers: .control)

        #expect(registry.register(keyCombination: combination) {
            invocationCount += 1
        }.isSuccess)
        #expect(monitor.enableCount == 1)
        #expect(registry.handleKeyEvent(event(combination)) == true)
        #expect(invocationCount == 1)
    }

    @Test("Every native default hotkey is registered and suppressed")
    func defaultHotkeysAreSuppressed() {
        withCleanHotkeyDefaults {
            let monitor = FakeHotkeyMonitor(isHealthy: true)
            let registry = HotkeyRegistry { _ in monitor }
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: GeneralSettingsManager()
            )
            manager.performSetup()

            for action in BoundAction.allCases {
                let combination = action.defaultKeyCombination!
                #expect(registry.handleKeyEvent(event(combination)))
                #expect(registry.handleKeyEvent(event(combination, isAutorepeat: true)))
                #expect(manager.hotkey(withAction: action)?.registrationState == .active)
            }
        }
    }

    @Test("Unmatched events pass through")
    func unmatchedEventPassesThrough() {
        let monitor = FakeHotkeyMonitor(isHealthy: true)
        let registry = HotkeyRegistry { _ in monitor }
        let left = KeyCombination(key: .leftArrow, modifiers: .control)
        let right = KeyCombination(key: .rightArrow, modifiers: .control)
        #expect(registry.register(keyCombination: left) {}.isSuccess)

        #expect(registry.handleKeyEvent(event(right)) == false)
    }

    @Test("Autorepeat is suppressed without repeated actions")
    func autorepeatIsOnlySuppressed() {
        let monitor = FakeHotkeyMonitor(isHealthy: true)
        let registry = HotkeyRegistry { _ in monitor }
        var invocationCount = 0
        let combination = KeyCombination(key: .leftArrow, modifiers: .control)
        #expect(registry.register(keyCombination: combination) {
            invocationCount += 1
        }.isSuccess)

        #expect(registry.handleKeyEvent(event(combination, isAutorepeat: true)) == true)
        #expect(invocationCount == 0)
    }

    @Test("Duplicate matcher registrations are rejected deterministically")
    func duplicateMatcherRegistrationIsRejected() {
        var matcher = HotkeyEventMatcher()
        let combination = KeyCombination(key: .one, modifiers: [.control, .option])
        #expect(matcher.register(combination, registrationID: 7).isSuccess)
        let duplicateResult = matcher.register(combination, registrationID: 9)
        guard case .failure(.duplicate(existingRegistrationID: 7)) = duplicateResult else {
            Issue.record("Expected the first registration to win")
            return
        }
        #expect(
            matcher.decision(for: event(combination))
                == .invoke(registrationID: 7)
        )
    }

    @Test("Unregistering disables the shared monitor")
    func unregisterDisablesMonitoring() throws {
        let monitor = FakeHotkeyMonitor(isHealthy: true)
        let registry = HotkeyRegistry { _ in monitor }
        let result = registry.register(
            keyCombination: KeyCombination(key: .leftArrow, modifiers: .control)
        ) {}
        let id = try result.get()
        #expect(registry.monitoringState == .active)

        registry.unregister(id)
        #expect(registry.monitoringState == .disabled)
        #expect(monitor.disableCount == 1)
    }

    @Test("Monitor creation failure remains visible and preserves configuration")
    func monitorFailureIsVisible() {
        let monitor = FakeHotkeyMonitor(isHealthy: false)
        let registry = HotkeyRegistry { _ in monitor }
        let hotkey = Hotkey(
            keyCombination: KeyCombination(key: .leftArrow, modifiers: .control),
            action: .left
        )

        #expect(registry.register(hotkey: hotkey) {} == .failure(
            .monitoringFailed(.eventTapUnavailable)
        ))
        #expect(registry.monitoringState == .failed(.eventTapUnavailable))
        #expect(hotkey.isConfigured)
        #expect(hotkey.registrationState == .disabled)
    }

    @Test("Tap disablement recovers without losing registrations")
    func tapDisablementRecovers() {
        let monitor = FakeHotkeyMonitor(isHealthy: true)
        let registry = HotkeyRegistry { _ in monitor }
        var invocationCount = 0
        let combination = KeyCombination(key: .rightArrow, modifiers: .control)
        #expect(registry.register(keyCombination: combination) {
            invocationCount += 1
        }.isSuccess)

        monitor.isHealthy = false
        monitor.recoverMakesHealthy = true
        registry.handleTapDisabled()

        #expect(monitor.recoverCount >= 1)
        #expect(registry.monitoringState == .active)
        #expect(registry.handleKeyEvent(event(combination)))
        #expect(invocationCount == 1)
    }

    @Test("Configured and operational state are transient and distinct")
    func configuredAndOperationalStateAreDistinct() throws {
        let original = Hotkey(
            keyCombination: KeyCombination(key: .grave, modifiers: [.control, .option]),
            action: .lastSpace
        )
        original.setRegistrationState(.failed(.monitoringUnavailable(.eventTapUnavailable)))
        #expect(original.isConfigured)

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Hotkey.self, from: data)
        #expect(decoded.isConfigured)
        #expect(decoded.registrationState == .disabled)
    }

    @Test("Recording suspends and restores only the edited binding")
    func recordingSuspendsAndRestoresBinding() {
        withCleanHotkeyDefaults {
            let monitor = FakeHotkeyMonitor(isHealthy: true)
            let registry = HotkeyRegistry { _ in monitor }
            let generalSettings = GeneralSettingsManager()
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: generalSettings
            )
            manager.performSetup()
            let left = BoundAction.left.defaultKeyCombination!
            let right = BoundAction.right.defaultKeyCombination!
            #expect(registry.handleKeyEvent(event(left)))
            #expect(registry.handleKeyEvent(event(right)))

            manager.setRecording(true, action: .left)
            #expect(!registry.handleKeyEvent(event(left)))
            #expect(registry.handleKeyEvent(event(right)))
            #expect(manager.hotkey(withAction: .left)?.registrationState == .disabled)

            manager.setRecording(false, action: .left)
            #expect(registry.handleKeyEvent(event(left)))
            #expect(manager.hotkey(withAction: .left)?.registrationState == .active)
        }
    }

    @Test("Global binding enablement unregisters and restores hotkeys")
    func globalEnablementControlsRegistrations() {
        withCleanHotkeyDefaults {
            let registry = HotkeyRegistry { _ in FakeHotkeyMonitor(isHealthy: true) }
            let generalSettings = GeneralSettingsManager()
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: generalSettings
            )
            manager.performSetup()
            let left = BoundAction.left.defaultKeyCombination!
            #expect(registry.handleKeyEvent(event(left)))

            generalSettings.bindingsEnabled = false
            manager.setRecording(false, action: .left)
            #expect(!registry.handleKeyEvent(event(left)))
            #expect(manager.monitoringState == .disabled)
            #expect(manager.hotkey(withAction: .left)?.registrationState == .disabled)

            generalSettings.bindingsEnabled = true
            manager.setRecording(false, action: .left)
            #expect(registry.handleKeyEvent(event(left)))
            #expect(manager.monitoringState == .active)
        }
    }

    @Test("Manager exposes shared monitor failure per configured binding")
    func managerExposesMonitorFailure() {
        withCleanHotkeyDefaults {
            let registry = HotkeyRegistry { _ in FakeHotkeyMonitor(isHealthy: false) }
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: GeneralSettingsManager()
            )
            manager.performSetup()

            #expect(manager.monitoringState == .failed(.eventTapUnavailable))
            #expect(manager.hotkey(withAction: .left)?.isConfigured == true)
            #expect(
                manager.hotkey(withAction: .left)?.registrationState
                    == .failed(.monitoringUnavailable(.eventTapUnavailable))
            )
        }
    }

    @Test("Duplicate configured actions are both disabled")
    func duplicateConfiguredActionsAreBothDisabled() {
        withCleanHotkeyDefaults {
            let monitor = FakeHotkeyMonitor(isHealthy: true)
            let registry = HotkeyRegistry { _ in monitor }
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: GeneralSettingsManager()
            )
            manager.performSetup()
            let combination = BoundAction.left.defaultKeyCombination!
            manager.hotkey(withAction: .right)?.keyCombination = combination
            manager.setRecording(false, action: .right)

            #expect(!registry.handleKeyEvent(event(combination)))
            guard
                case .failed(.duplicateBinding) = manager.hotkey(withAction: .left)?.registrationState,
                case .failed(.duplicateBinding) = manager.hotkey(withAction: .right)?.registrationState
            else {
                Issue.record("Both duplicate actions must expose a conflict")
                return
            }
        }
    }

    @Test("Recorder teardown restores a suspended binding")
    func recorderTeardownRestoresState() {
        let hotkey = Hotkey(
            keyCombination: BoundAction.left.defaultKeyCombination,
            action: .left
        )
        var transitions: [Bool] = []
        var recorder: HotkeyRecorderModel? = HotkeyRecorderModel(
            hotkey: hotkey,
            onRecordingChanged: { transitions.append($0) }
        )
        recorder?.startRecording()
        #expect(transitions == [true])

        recorder = nil
        #expect(transitions == [true, false])
        #expect(hotkey.keyCombination == BoundAction.left.defaultKeyCombination)
    }

    private func event(
        _ combination: KeyCombination,
        isAutorepeat: Bool = false
    ) -> HotkeyKeyEvent {
        HotkeyKeyEvent(keyCombination: combination, isAutorepeat: isAutorepeat)
    }

    private func makeDispatcher() -> ActionDispatcher {
        ActionDispatcher(
            captureRequest: { _, _ in nil },
            submitRequest: { _ in .unavailable }
        )
    }

    private func withCleanHotkeyDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "hotkeys")
        defaults.removeObject(forKey: "hotkeys")
        defer {
            if let saved {
                defaults.set(saved, forKey: "hotkeys")
            } else {
                defaults.removeObject(forKey: "hotkeys")
            }
        }
        body()
    }
}

@MainActor
private final class FakeHotkeyMonitor: HotkeyEventMonitoring {
    var isHealthy: Bool
    var recoverMakesHealthy = false
    private(set) var enableCount = 0
    private(set) var disableCount = 0
    private(set) var recoverCount = 0

    init(isHealthy: Bool) {
        self.isHealthy = isHealthy
    }

    func enable() {
        enableCount += 1
    }

    func disable() {
        disableCount += 1
        isHealthy = false
    }

    func recoverIfNeeded() {
        recoverCount += 1
        if recoverMakesHealthy {
            isHealthy = true
        }
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
