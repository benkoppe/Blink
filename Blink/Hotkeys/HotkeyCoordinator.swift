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
    private let store: HotkeyStore
    private let manager: HotkeyManager
    private let switcher: SpaceSwitcher

    init(
        store: HotkeyStore,
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
            Task { @MainActor in
                self?.trackAndRegisterAll()  // re-register and re-arm tracking
            }
        }
    }

    private func registerAll() {
        for identifier in HotkeyIdentifier.allCases {
            guard store.isEnabled(identifier) else {
                manager.unregister(identifier: identifier)
                continue
            }

            let combination = store.combination(for: identifier)
            guard combination.isValid else {
                manager.unregister(identifier: identifier)
                continue
            }

            manager.register(identifier: identifier, combination: combination) { [weak self] in
                self?.handle(identifier)
            }
        }
    }

    private func handle(_ identifier: HotkeyIdentifier) {
        switch identifier {
        case .left: switcher.switchLeft()
        case .right: switcher.switchRight()
        case .space1: switcher.switchToIndex(0)
        case .space2: switcher.switchToIndex(1)
        case .space3: switcher.switchToIndex(2)
        case .space4: switcher.switchToIndex(3)
        case .space5: switcher.switchToIndex(4)
        case .space6: switcher.switchToIndex(5)
        case .space7: switcher.switchToIndex(6)
        case .space8: switcher.switchToIndex(7)
        case .space9: switcher.switchToIndex(8)
        case .space10: switcher.switchToIndex(9)
        }
    }
}
