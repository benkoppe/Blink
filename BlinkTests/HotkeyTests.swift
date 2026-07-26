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
        withCleanHotkeyDefaults { defaults in
            let monitor = FakeHotkeyMonitor(isHealthy: true)
            let registry = HotkeyRegistry { _ in monitor }
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: GeneralSettingsManager(userDefaults: defaults),
                userDefaults: defaults
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
    func recordingSuspendsAndRestoresBinding() async {
        await withCleanHotkeyDefaults { defaults in
            let monitor = FakeHotkeyMonitor(isHealthy: true)
            let registry = HotkeyRegistry { _ in monitor }
            let generalSettings = GeneralSettingsManager(userDefaults: defaults)
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: generalSettings,
                userDefaults: defaults
            )
            manager.performSetup()
            let left = BoundAction.left.defaultKeyCombination!
            let right = BoundAction.right.defaultKeyCombination!
            #expect(registry.handleKeyEvent(event(left)))
            #expect(registry.handleKeyEvent(event(right)))

            var recorded: [KeyCombination] = []
            #expect(manager.beginRecording(action: .left) {
                recorded.append($0.keyCombination)
            })
            #expect(registry.handleKeyEvent(event(left)))
            #expect(registry.handleKeyEvent(event(right)))
            await registry.waitForPendingRecordingDelivery()
            #expect(recorded == [left, right])
            #expect(manager.hotkey(withAction: .left)?.registrationState == .disabled)

            manager.endRecording(action: .left)
            #expect(registry.handleKeyEvent(event(left)))
            #expect(manager.hotkey(withAction: .left)?.registrationState == .active)
        }
    }

    @Test("Only the recorder that owns capture can end it")
    func recordingHasSingleOwner() async {
        await withCleanHotkeyDefaults { defaults in
            let registry = HotkeyRegistry { _ in FakeHotkeyMonitor(isHealthy: true) }
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: GeneralSettingsManager(userDefaults: defaults),
                userDefaults: defaults
            )
            manager.performSetup()

            var captured: [KeyCombination] = []
            #expect(manager.beginRecording(action: .left) {
                captured.append($0.keyCombination)
            })
            #expect(!manager.beginRecording(action: .right) { _ in })

            manager.endRecording(action: .right)
            let right = BoundAction.right.defaultKeyCombination!
            #expect(registry.handleKeyEvent(event(right)))
            await registry.waitForPendingRecordingDelivery()
            #expect(captured == [right])

            manager.endRecording(action: .left)
            #expect(manager.hotkey(withAction: .left)?.registrationState == .active)
        }
    }

    @Test("Queued recorder delivery cannot outlive its owner")
    func queuedRecordingDeliveryHonorsOwnershipEpoch() async {
        let registry = HotkeyRegistry { _ in FakeHotkeyMonitor(isHealthy: true) }
        var captured: [KeyCombination] = []
        #expect(registry.beginRecording { captured.append($0.keyCombination) })
        let left = BoundAction.left.defaultKeyCombination!
        let right = BoundAction.right.defaultKeyCombination!

        #expect(registry.handleKeyEvent(event(left)))
        #expect(registry.handleKeyEvent(event(right)))
        registry.endRecording()
        await registry.waitForPendingRecordingDelivery()

        #expect(captured.isEmpty)
    }

    @Test("Global binding enablement unregisters and restores hotkeys")
    func globalEnablementControlsRegistrations() {
        withCleanHotkeyDefaults { defaults in
            let registry = HotkeyRegistry { _ in FakeHotkeyMonitor(isHealthy: true) }
            let generalSettings = GeneralSettingsManager(userDefaults: defaults)
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: generalSettings,
                userDefaults: defaults
            )
            manager.performSetup()
            let left = BoundAction.left.defaultKeyCombination!
            #expect(registry.handleKeyEvent(event(left)))

            generalSettings.bindingsEnabled = false
            #expect(manager.beginRecording(action: .left) { _ in })
            manager.endRecording(action: .left)
            #expect(!registry.handleKeyEvent(event(left)))
            #expect(manager.monitoringState == .disabled)
            #expect(manager.hotkey(withAction: .left)?.registrationState == .disabled)

            generalSettings.bindingsEnabled = true
            #expect(manager.beginRecording(action: .left) { _ in })
            manager.endRecording(action: .left)
            #expect(registry.handleKeyEvent(event(left)))
            #expect(manager.monitoringState == .active)
        }
    }

    @Test("Manager exposes shared monitor failure per configured binding")
    func managerExposesMonitorFailure() {
        withCleanHotkeyDefaults { defaults in
            let registry = HotkeyRegistry { _ in FakeHotkeyMonitor(isHealthy: false) }
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: GeneralSettingsManager(userDefaults: defaults),
                userDefaults: defaults
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
        withCleanHotkeyDefaults { defaults in
            let monitor = FakeHotkeyMonitor(isHealthy: true)
            let registry = HotkeyRegistry { _ in monitor }
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: GeneralSettingsManager(userDefaults: defaults),
                userDefaults: defaults
            )
            manager.performSetup()
            let combination = BoundAction.left.defaultKeyCombination!
            manager.hotkey(withAction: .right)?.keyCombination = combination
            #expect(manager.beginRecording(action: .right) { _ in })
            manager.endRecording(action: .right)

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

    @Test("A failed shared monitor is created once per reconfiguration pass")
    func failedMonitorCreationIsBatched() {
        withCleanHotkeyDefaults { defaults in
            var creationCount = 0
            let registry = HotkeyRegistry { _ in
                creationCount += 1
                return FakeHotkeyMonitor(isHealthy: false)
            }
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: GeneralSettingsManager(userDefaults: defaults),
                userDefaults: defaults
            )
            manager.performSetup()

            #expect(creationCount == 1)
        }
    }

    @Test("Recorder captures an existing Blink shortcut before its action and swaps owners")
    func recorderCapturesAndSwapsExistingShortcut() async {
        await withCleanHotkeyDefaults { defaults in
            let registry = HotkeyRegistry { _ in FakeHotkeyMonitor(isHealthy: true) }
            let manager = HotkeySettingsManager(
                registry: registry,
                dispatcher: makeDispatcher(),
                generalSettings: GeneralSettingsManager(userDefaults: defaults),
                userDefaults: defaults
            )
            manager.performSetup()
            let left = BoundAction.left.defaultKeyCombination!
            let right = BoundAction.right.defaultKeyCombination!

            #expect(manager.beginRecording(action: .left) { event in
                manager.assignRecordedCombination(event.keyCombination, to: .left)
                manager.endRecording(action: .left)
            })
            #expect(registry.handleKeyEvent(event(right)))
            await registry.waitForPendingRecordingDelivery()

            #expect(manager.hotkey(withAction: .left)?.keyCombination == right)
            #expect(manager.hotkey(withAction: .right)?.keyCombination == left)
            #expect(registry.handleKeyEvent(event(right)))
            #expect(registry.handleKeyEvent(event(left)))
        }
    }

    @Test("Recorder suppresses but rejects reserved system shortcuts")
    func recorderRejectsReservedShortcut() {
        let original = BoundAction.left.defaultKeyCombination!
        let reserved = KeyCombination(key: .space, modifiers: .command)
        let hotkey = Hotkey(keyCombination: original, action: .left)
        var handler: ((HotkeyKeyEvent) -> Void)?
        var assignments: [KeyCombination] = []
        let recorder = HotkeyRecorderModel(
            hotkey: hotkey,
            beginRecording: {
                handler = $0
                return true
            },
            endRecording: {},
            assignCombination: { assignments.append($0) },
            loadReservedCombinations: { Set([reserved]) }
        )

        recorder.startRecording()
        handler?(event(reserved))

        #expect(recorder.isRecording)
        #expect(recorder.isPresentingReservedByMacOSError)
        #expect(assignments.isEmpty)
        #expect(hotkey.keyCombination == original)
        recorder.stopRecording()
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
            beginRecording: { _ in
                transitions.append(true)
                return true
            },
            endRecording: { transitions.append(false) },
            assignCombination: { hotkey.keyCombination = $0 },
            loadReservedCombinations: { [] }
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

    private func withCleanHotkeyDefaults(
        _ body: (UserDefaults) async -> Void
    ) async {
        let suiteName = "com.thekoppe.BlinkTests.hotkeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        await body(defaults)
    }

    private func withCleanHotkeyDefaults(_ body: (UserDefaults) -> Void) {
        let suiteName = "com.thekoppe.BlinkTests.hotkeys.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(defaults)
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
