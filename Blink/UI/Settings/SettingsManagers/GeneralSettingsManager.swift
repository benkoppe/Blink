//
//  GeneralSettingsManager.swift
//  Blink
//
//  Created by Ben on 3/31/26.
//

import Foundation
import ObservableUserDefault
import Observation

@MainActor @Observable
final class GeneralSettingsManager {
    @ObservableUserDefault(
        .init(key: "settings.bindingsEnabled", defaultValue: true, store: .standard))
    @ObservationIgnored
    var bindingsEnabled: Bool
}
