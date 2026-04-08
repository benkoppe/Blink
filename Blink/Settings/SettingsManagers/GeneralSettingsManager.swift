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
    @DefaultsKey(userDefaultsKey: "settings.bindingsEnabled")
    var bindingsEnabled: Bool = true
}
