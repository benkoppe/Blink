//
//  GeneralSettingsManager.swift
//  Blink
//
//  Created by Ben on 3/31/26.
//

import Foundation
import ObservableDefaults
import Observation

@MainActor @ObservableDefaults
final class GeneralSettingsManager {
    @ObservableOnly
    var bindingsEnabled: Bool = true

    @DefaultsKey(userDefaultsKey: "settings.wrapSpaceSwitching")
    var wrapSpaceSwitching: Bool = false

    @DefaultsKey(userDefaultsKey: "settings.instantCmdTabSpaceSwitching")
    var instantCmdTabSpaceSwitching: Bool = false
}
