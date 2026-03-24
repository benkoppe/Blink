//
//  HotkeyCoordinator.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import Foundation
import Observation

/// Observes HotkeyStore for changes and keeps HotkeyManager registrations in sync
/// Uses withObservationTracking to re-register whenever any hotkey or enabled state changes.
final class HotkeyCoordinator {
    private let store: BindingStore
    private let manager: HotkeyManager
    private let switcher: SpaceSwitcher

    init(
        store: BindingStore,
        manager: HotkeyManager = .shared,
        switcher: SpaceSwitcher
    ) {
        self.store = store
        self.manager = manager
        self.switcher = switcher
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
        for action in BoundAction.allCases {
            guard store.isHotkeyEnabled(action) else {
                manager.unregister(action: action)
                continue
            }

            let combination = store.hotkeyCombo(for: action)
            guard combination.isValid else {
                manager.unregister(action: action)
                continue
            }

            manager.register(action: action, combination: combination) { [weak self] in
                guard let self else { return }
                action.execute(on: self.switcher)
            }
        }
    }
}
