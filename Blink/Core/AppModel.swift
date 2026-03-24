//
//  AppModel.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import Foundation
import Observation

@Observable
final class AppModel {
    let spaceSwitcher = SpaceSwitcher()
    let hotkeyStore = HotkeyStore()

    // Coordinator must be held strongly for the app's lifetime
    private var coordinator: HotkeyCoordinator?

    init() {
        coordinator = HotkeyCoordinator(
            store: hotkeyStore,
            switcher: spaceSwitcher
        )
    }
}
