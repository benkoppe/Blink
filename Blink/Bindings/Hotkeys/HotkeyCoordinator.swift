//
//  HotkeyCoordinator.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import Foundation
import Observation

/// Observes BindingStore for changes and keeps HotkeyManager registrations in sync
/// Uses withObservationTracking to re-register whenever any hotkey or enabled state changes.
final class HotkeyCoordinator {
    private weak var appState: AppState?
    private let manager: HotkeyManager

    init(
        appState: AppState,
        manager: HotkeyManager = .shared,
    ) {
        self.appState = appState
        self.manager = manager
        trackAndRegisterAll()
    }

    // MARK: - Private

    private func trackAndRegisterAll() {
        withObservationTracking {
            registerAll()
        } onChange: { [weak self] in
            // marshal to main thread
            guard let self else { return }
            Task { @MainActor [self] in
                self.trackAndRegisterAll()  // re-register and re-arm tracking
            }
        }
    }

    private func registerAll() {
        guard let appState else {
            Logger.hotkeyCoordinator.error("Error registering all hotkeys: Missing app state")
            return
        }

        guard appState.settings.bindingsEnabled else {
            manager.unregisterAll()
            return
        }

        for action in BoundAction.allCases {
            guard appState.bindingStore.isHotkeyEnabled(action) else {
                manager.unregister(action: action)
                continue
            }

            let combination = appState.bindingStore.hotkeyCombo(for: action)
            guard combination.isValid else {
                manager.unregister(action: action)
                continue
            }

            manager.register(action: action, combination: combination) { [weak self] in
                guard let self, let appState = self.appState else { return }
                action.execute(appState: appState)
            }
        }
    }
}

// MARK: - Logger

extension Logger {
    fileprivate static let hotkeyCoordinator = Logger(category: "HotkeyCoordinator")
}
