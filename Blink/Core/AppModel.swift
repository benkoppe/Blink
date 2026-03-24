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
    let bindingStore = BindingStore()
    private var hotkeyCoordinator: HotkeyCoordinator?
    private var swipeCoordinator: SwipeGestureCoordinator?

    init() {
        hotkeyCoordinator = HotkeyCoordinator(
            store: bindingStore,
            switcher: spaceSwitcher
        )
        swipeCoordinator = SwipeGestureCoordinator(
            store: bindingStore,
            switcher: spaceSwitcher
        )
    }
}
