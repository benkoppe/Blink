//
//  AppSettings.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import Foundation
import ObservableUserDefault
import Observation

@Observable
final class AppSettings {
    @ObservableUserDefault(
        .init(key: "settings.bindingsEnabled", defaultValue: true, store: .standard))
    @ObservationIgnored
    var bindingsEnabled: Bool
}
