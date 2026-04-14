//
//  AppDelegate.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var appState: AppState?

    // MARK: NSApplicationDelegate Methods

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard let appState else {
            Logger.appDelegate.warning("Missing app state in applicationWillFinishLaunching")
            return
        }

        appState.assignAppDelegate(self)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let appState else {
            Logger.appDelegate.warning("Missing app state in applicationDidFinishLaunching")
            return
        }

        // Dismiss the windows
        appState.dismissSettingsWindow()
        appState.dismissPermissionsWindow()

        // Perform setup after a small delay to ensure that the settings window
        // has been assigned.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            guard !appState.isPreview else {
                return
            }
            // If we have the required permissions, set up the shared app state.
            // Otherwise, open the permissions window.
            switch appState.permissionsManager.permissionsState {
            case .hasAllPermissions, .hasRequiredPermissions:
                Logger.appDelegate.info("Has all permissions")
                appState.performSetup()
            case .missingPermissions:
                Logger.appDelegate.info("Missing permissions")
                appState.activate(withPolicy: .regular)
                appState.openPermissionsWindow()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Deactivate and set the policy to accessory when all windows are closed.
        appState?.deactivate(withPolicy: .accessory)
        return false
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        return true
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        guard let appState else {
            Logger.appDelegate.warning("Missing app state in applicationShouldHandleReopen")
            return false
        }
        switch appState.permissionsManager.permissionsState {
        case .hasAllPermissions, .hasRequiredPermissions:
            openSettingsWindow()
        case .missingPermissions:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                appState.activate(withPolicy: .regular)
                appState.openPermissionsWindow()
            }
        }
        return false
    }

    // MARK: - Other Methods

    /// Assigns the app state to the delegate.
    func assignAppState(_ appState: AppState) {
        guard self.appState == nil else {
            Logger.appDelegate.warning("Multiple attempts made to assign app state")
            return
        }
        self.appState = appState
    }

    /// Opens the settings window and activates the app.
    @objc func openSettingsWindow() {
        guard let appState else {
            Logger.appDelegate.error("Failed to open settings window")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            appState.activate(withPolicy: .regular)
            appState.openSettingsWindow()
        }
    }
}

// MARK: - Logger

extension Logger {
    fileprivate static let appDelegate = Logger(category: "AppDelegate")
}
