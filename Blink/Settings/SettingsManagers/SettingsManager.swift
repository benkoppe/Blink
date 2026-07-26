import Foundation
import Observation

@MainActor @Observable
final class SettingsManager {
    let generalSettingsManager: GeneralSettingsManager
    let hotkeySettingsManager: HotkeySettingsManager
    let gestureSettingsManager: GestureSettingsManager
    let menuBarSettingsManager = MenuBarSettingsManager()

    private let spaceSwitcher: SpaceSwitcher

    init(
        registry: HotkeyRegistry,
        dispatcher: ActionDispatcher,
        spaceSwitcher: SpaceSwitcher
    ) {
        let generalSettings = GeneralSettingsManager()
        self.generalSettingsManager = generalSettings
        self.spaceSwitcher = spaceSwitcher
        self.hotkeySettingsManager = HotkeySettingsManager(
            registry: registry,
            dispatcher: dispatcher,
            generalSettings: generalSettings
        )
        self.gestureSettingsManager = GestureSettingsManager(
            dispatcher: dispatcher,
            generalSettings: generalSettings,
            missionControlCapability: spaceSwitcher.missionControlSyntheticCapability
        )
    }

    func performSetup() {
        observeSwitchConfiguration()
        hotkeySettingsManager.performSetup()
        gestureSettingsManager.performSetup()
    }

    func shutdown() async {
        // Interception owns the input boundary and must be gone before queued
        // dispatch or Space execution is torn down.
        hotkeySettingsManager.shutdown()
        await gestureSettingsManager.shutdown()
    }

    private func observeSwitchConfiguration() {
        withObservationTracking {
            spaceSwitcher.applyConfiguration(
                wraps: generalSettingsManager.wrapSpaceSwitching,
                velocity: generalSettingsManager.instantGestureSpeed.velocity
            )
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeSwitchConfiguration()
            }
        }
    }
}
