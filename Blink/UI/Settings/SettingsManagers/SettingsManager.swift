//
//  SettingsManager.swift
//  Blink
//
//  Created by Ben on 3/29/26.
//

import Foundation
import Observation

@MainActor @Observable
final class SettingsManager {
    let generalSettingsManager: GeneralSettingsManager = .init()
    let hotkeySettingsManager: HotkeySettingsManager
    let gestureSettingsManager: GestureSettingsManager
    let menuBarSettingsManager: MenuBarSettingsManager = .init()

    @ObservationIgnored private(set) weak var appState: AppState?

    init(appState: AppState) {
        self.hotkeySettingsManager = .init(appState: appState)
        self.gestureSettingsManager = .init(appState: appState)
        self.appState = appState
    }

    func performSetup() {
        hotkeySettingsManager.performSetup()
        gestureSettingsManager.performSetup()
    }
}
