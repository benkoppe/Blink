//
//  BlinkApp.swift
//  Blink
//
//  Created by Ben on 3/23/26.
//

import SwiftUI

@main
struct BlinkApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            BlinkMenu()
                .environment(appState)
        } label: {
            SpaceIconLabel(
                info: appState.spaceSwitcher.spaceInfo,
                settings: appState.settings
            )
        }

        Window(Constants.settingsWindowTitle, id: Constants.settingsWindowID) {
            SettingsView()
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 625)
        .environment(appState)
    }
}
