//
//  MenuBarSettingsManager.swift
//  Blink
//
//  Created by Ben on 3/31/26.
//

import Foundation
import ObservableDefaults
import Observation

@MainActor @ObservableDefaults
final class MenuBarSettingsManager {
    @DefaultsKey(userDefaultsKey: "settings.iconSize")
    var iconSize: Double = defaultIconSize
    static let defaultIconSize = 20.0

    @DefaultsKey(userDefaultsKey: "settings.iconSpacing")
    var iconSpacing: Double = defaultIconSpacing
    static let defaultIconSpacing = 2.0

    @DefaultsKey(userDefaultsKey: "settings.iconCornerRadius")
    var iconCornerRadius: Double = defaultIconCornerRadius
    static let defaultIconCornerRadius = 6.0
}
