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
    let hotkeySettingsManager: HotkeySettingsManager

    @ObservationIgnored private(set) weak var appState: AppState?

    init(appState: AppState) {
        self.hotkeySettingsManager = .init(appState: appState)
        self.appState = appState
    }

    func performSetup() {
        hotkeySettingsManager.performSetup()
    }
}
