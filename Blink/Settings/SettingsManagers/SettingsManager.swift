import Foundation
import Observation

@MainActor @Observable
final class SettingsManager {
    let generalSettingsManager: GeneralSettingsManager
    let hotkeySettingsManager: HotkeySettingsManager
    let gestureSettingsManager: GestureSettingsManager
    let menuBarSettingsManager: MenuBarSettingsManager

    init(
        registry: HotkeyRegistry,
        dispatcher: ActionDispatcher,
        spaceSwitcher: SpaceSwitcher,
        userDefaults: UserDefaults = .standard
    ) {
        let generalSettings = GeneralSettingsManager(userDefaults: userDefaults)
        self.generalSettingsManager = generalSettings
        self.menuBarSettingsManager = MenuBarSettingsManager(userDefaults: userDefaults)
        self.hotkeySettingsManager = HotkeySettingsManager(
            registry: registry,
            dispatcher: dispatcher,
            generalSettings: generalSettings,
            userDefaults: userDefaults
        )
        self.gestureSettingsManager = GestureSettingsManager(
            dispatcher: dispatcher,
            generalSettings: generalSettings,
            missionControlCapability: spaceSwitcher.missionControlSyntheticCapability,
            userDefaults: userDefaults
        )
        spaceSwitcher.setConfigurationProvider { [weak generalSettings] in
            guard let generalSettings else { return .defaultValue }
            return SpaceSwitchConfiguration(
                wraps: generalSettings.wrapSpaceSwitching,
                velocity: generalSettings.instantGestureSpeed.velocity
            )
        }
    }

    func performSetup() {
        hotkeySettingsManager.performSetup()
        gestureSettingsManager.performSetup()
    }

    func shutdown() async {
        // Interception owns the input boundary and must be gone before queued
        // dispatch or Space execution is torn down.
        hotkeySettingsManager.shutdown()
        await gestureSettingsManager.shutdown()
    }
}
