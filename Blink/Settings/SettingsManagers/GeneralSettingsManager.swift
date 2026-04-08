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
    var bindingsEnabled: Bool = true
}
