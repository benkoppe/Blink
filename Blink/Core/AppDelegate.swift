//
//  AppDelegate.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()

    // MARK: NSApplicationDelegate Methods

    func applicationWillFinishLaunching(_ notification: Notification) {
        appState.assignAppDelegate(self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Dismiss the windows
        appState.dismissSettingsWindow()
        appState.dismissPermissionsWindow()

        // Perform setup after a small delay to ensure that the settings window
        // has been assigned.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard !self.appState.isPreview else {
                return
            }
            // If we have the required permissions, set up the shared app state.
            // Otherwise, open the permissions window.
            switch self.appState.permissionsManager.permissionsState {
            case .hasAllPermissions, .hasRequiredPermissions:
                Logger.appDelegate.info("Has all permissions")
                self.appState.performSetup()
            case .missingPermissions:
                Logger.appDelegate.info("Missing permissions")
                self.appState.activate(withPolicy: .regular)
                self.appState.openPermissionsWindow()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Deactivate and set the policy to accessory when all windows are closed.
        appState.deactivate(withPolicy: .accessory)
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        switch appState.permissionsManager.permissionsState {
        case .hasAllPermissions, .hasRequiredPermissions:
            openSettingsWindow()
        case .missingPermissions:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.appState.activate(withPolicy: .regular)
                self.appState.openPermissionsWindow()
            }
        }
        return false
    }

    // MARK: - Other Methods

    /// Opens the settings window and activates the app.
    @objc func openSettingsWindow() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.appState.activate(withPolicy: .regular)
            self.appState.openSettingsWindow()
        }
    }
}

// MARK: - Logger

extension Logger {
    fileprivate static let appDelegate = Logger(category: "AppDelegate")
}
