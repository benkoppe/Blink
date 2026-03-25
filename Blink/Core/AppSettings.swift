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

    @ObservableUserDefault(.init(key: "settings.iconSize", defaultValue: 20.0, store: .standard))
    @ObservationIgnored
    var iconSize: Double

    @ObservableUserDefault(.init(key: "settings.iconSpacing", defaultValue: 2.0, store: .standard))
    @ObservationIgnored
    var iconSpacing: Double

    @ObservableUserDefault(
        .init(key: "settings.iconCornerRadius", defaultValue: 6.0, store: .standard))
    @ObservationIgnored
    var iconCornerRadius: Double
}
