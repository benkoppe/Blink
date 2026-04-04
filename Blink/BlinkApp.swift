//
//  BlinkApp.swift
//  Blink
//
//  Created by Ben on 3/23/26.
//

import MenuBarExtraAccess
import SwiftUI

@main
struct BlinkApp: App {
    @NSApplicationDelegateAdaptor var appDelegate: AppDelegate
    @State private var appState = AppState()

    @State private var isMenuPresented: Bool = false

    init() {
        appDelegate.assignAppState(appState)
    }

    var body: some Scene {
        MenuBarExtra {
            BlinkMenu(isMenuPresented: $isMenuPresented)
                .environment(appState)
        } label: {
            SpaceIconLabel(appState: appState)
        }
        .menuBarExtraAccess(isPresented: $isMenuPresented)
        .menuBarExtraStyle(.window)
        .windowResizability(.contentSize)

        Window(Constants.settingsWindowTitle, id: Constants.settingsWindowID) {
            SettingsView()
                .readWindow { window in
                    guard let window else { return }
                    appState.assignSettingsWindow(window)
                }
                .frame(minWidth: 825, minHeight: 500)
        }
        .commandsRemoved()
        .windowResizability(.contentSize)
        .defaultSize(width: 900, height: 625)
        .environment(appState)

        PermissionsWindow(appState: appState)
    }
}

@MainActor
func quit() {
    NSApplication.shared.terminate(nil)
}
