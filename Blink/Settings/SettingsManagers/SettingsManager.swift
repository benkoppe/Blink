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
            spaceSwitcher: spaceSwitcher,
            generalSettings: generalSettings
        )
    }

    func performSetup() {
        observeSwitchConfiguration()
        hotkeySettingsManager.performSetup()
        gestureSettingsManager.performSetup()
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
