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

    @ObservableUserDefault(
        .init(key: "settings.iconSize", defaultValue: AppSettings.defaultIconSize, store: .standard)
    )
    @ObservationIgnored
    var iconSize: Double
    static let defaultIconSize = 20.0

    @ObservableUserDefault(
        .init(
            key: "settings.iconSpacing", defaultValue: AppSettings.defaultIconSpacing,
            store: .standard))
    @ObservationIgnored
    var iconSpacing: Double
    static let defaultIconSpacing = 2.0

    @ObservableUserDefault(
        .init(
            key: "settings.iconCornerRadius", defaultValue: AppSettings.defaultIconCornerRadius,
            store: .standard))
    @ObservationIgnored
    var iconCornerRadius: Double
    static let defaultIconCornerRadius = 6.0
}
