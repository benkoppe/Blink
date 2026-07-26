//
//  AppState.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import Combine
import Observation
import SwiftUI

@MainActor
struct ApplicationShutdownSequence {
    let stopInput: () async -> Void
    let stopDispatcher: () async -> Void
    let stopSpaceEngine: () async -> Void

    func run() async {
        await stopInput()
        await stopDispatcher()
        await stopSpaceEngine()
    }
}

@Observable @MainActor
final class AppState {
    @ObservationIgnored
    private(set) lazy var spaceSwitcher = SpaceSwitcher()

    @ObservationIgnored
    private(set) lazy var actionDispatcher = ActionDispatcher(
        spaceSwitcher: spaceSwitcher
    )

    @ObservationIgnored
    private(set) lazy var permissionsManager = PermissionsManager(appState: self)

    @ObservationIgnored
    private(set) lazy var settingsManager = SettingsManager(
        registry: hotkeyRegistry,
        dispatcher: actionDispatcher,
        spaceSwitcher: spaceSwitcher
    )

    @ObservationIgnored
    private(set) lazy var updatesManager = UpdatesManager(appState: self)

    @ObservationIgnored
    private(set) lazy var userNotificationManager = UserNotificationManager(appState: self)

    /// The app's delegate.
    @ObservationIgnored private(set) weak var appDelegate: AppDelegate?

    /// The window that contains the settings interface.
    @ObservationIgnored private(set) weak var settingsWindow: NSWindow?

    /// The window that contains the permissions interface.
    @ObservationIgnored private(set) weak var permissionsWindow: NSWindow?

    /// The app's hotkey registry.
    let hotkeyRegistry = HotkeyRegistry()

    /// Creates support reports without coupling views to diagnostics storage.
    let diagnosticsController = DiagnosticsController()

    let isPreview: Bool = {
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            let key = "XCODE_RUNNING_FOR_PREVIEWS"
            return environment[key] != nil
        #else
            return false
        #endif
    }()

    @ObservationIgnored private var didPerformSetup = false

    /// Sets up the app state.
    func performSetup() {
        guard !didPerformSetup else { return }
        didPerformSetup = true
        permissionsManager.stopAllChecks()
        settingsManager.performSetup()
        updatesManager.performSetup()
        userNotificationManager.performSetup()
    }

    func shutdown() async {
        // Do not initialize lazy input or switching subsystems merely to stop an
        // app that never completed setup.
        guard didPerformSetup else { return }
        didPerformSetup = false
        await ApplicationShutdownSequence(
            stopInput: { [settingsManager] in
                await settingsManager.shutdown()
            },
            stopDispatcher: { [actionDispatcher] in
                await actionDispatcher.shutdown()
            },
            stopSpaceEngine: { [spaceSwitcher] in
                await spaceSwitcher.shutdown()
            }
        ).run()
    }

    /// Assigns the app delegate to the app state.
    func assignAppDelegate(_ appDelegate: AppDelegate) {
        guard self.appDelegate == nil else {
            Logger.appState.warning("Multiple attempts made to assign app delegate")
            return
        }
        self.appDelegate = appDelegate
    }

    /// Assigns the settings window to the app state.
    func assignSettingsWindow(_ window: NSWindow) {
        guard window.identifier?.rawValue == Constants.settingsWindowID else {
            Logger.appState.warning(
                "Window \(window.identifier?.rawValue ?? "<NIL>") is not the settings window!")
            return
        }
        settingsWindow = window
    }

    /// Assigns the permissions window to the app state.
    func assignPermissionsWindow(_ window: NSWindow) {
        guard window.identifier?.rawValue == Constants.permissionsWindowID else {
            Logger.appState.warning(
                "Window \(window.identifier?.rawValue ?? "<NIL>") is not the permissions window!")
            return
        }
        permissionsWindow = window
    }

    /// Opens the settings window.
    func openSettingsWindow() {
        with(EnvironmentValues()) { environment in
            environment.openWindow(id: Constants.settingsWindowID)
        }
    }

    /// Dismisses the settings window.
    func dismissSettingsWindow() {
        with(EnvironmentValues()) { environment in
            environment.dismissWindow(id: Constants.settingsWindowID)
        }
    }

    /// Opens the permissions window.
    func openPermissionsWindow() {
        with(EnvironmentValues()) { environment in
            environment.openWindow(id: Constants.permissionsWindowID)
        }
    }

    /// Dismisses the permissions window.
    func dismissPermissionsWindow() {
        with(EnvironmentValues()) { environment in
            environment.dismissWindow(id: Constants.permissionsWindowID)
        }
    }

    /// Activates the app and sets its activation policy to the given value.
    func activate(withPolicy policy: NSApplication.ActivationPolicy) {
        // Store whether the app has previously activated inside an internal
        // context to keep it isolated.
        enum Context {
            static let hasActivated = ObjectStorage<Bool>()
        }

        func activate() {
            if let frontApp = NSWorkspace.shared.frontmostApplication {
                NSRunningApplication.current.activate(from: frontApp)
            } else {
                NSApp.activate()
            }
            NSApp.setActivationPolicy(policy)
        }

        if Context.hasActivated.value(for: self) == true {
            activate()
        } else {
            Context.hasActivated.set(true, for: self)
            Logger.appState.debug("First time activating app, so going through Dock")
            // Hack to make sure the app properly activates for the first time.
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first?
                .activate()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                activate()
            }
        }
    }

    /// Deactivates the app and sets its activation policy to the given value.
    func deactivate(withPolicy policy: NSApplication.ActivationPolicy) {
        if let nextApp = NSWorkspace.shared.runningApplications.first(where: { $0 != .current }) {
            NSApp.yieldActivation(to: nextApp)
        } else {
            NSApp.deactivate()
        }
        NSApp.setActivationPolicy(policy)
    }
}

// MARK: - Logger

extension Logger {
    fileprivate static let appState = Logger(category: "AppState")
}
