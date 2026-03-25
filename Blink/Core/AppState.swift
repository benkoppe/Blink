//
//  AppState.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import Foundation
import Observation

@Observable @MainActor
final class AppState {
    let settings = AppSettings()
    let spaceSwitcher = SpaceSwitcher()
    let bindingStore = BindingStore()

    @ObservationIgnored
    private lazy var hotkeyCoordinator = HotkeyCoordinator(appState: self)
    @ObservationIgnored
    private lazy var swipeCoordinator = SwipeGestureCoordinator(appState: self)
}
