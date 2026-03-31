//
//  MenuBarSettingsManager.swift
//  Blink
//
//  Created by Ben on 3/31/26.
//

import Foundation
import ObservableUserDefault
import Observation

@MainActor @Observable
final class MenuBarSettingsManager {
    @ObservableUserDefault(
        .init(
            key: "settings.iconSize",
            defaultValue: MenuBarSettingsManager.defaultIconSize,
            store: .standard
        ))
    @ObservationIgnored
    var iconSize: Double
    static let defaultIconSize = 20.0

    @ObservableUserDefault(
        .init(
            key: "settings.iconSpacing",
            defaultValue: MenuBarSettingsManager.defaultIconSpacing,
            store: .standard
        ))
    @ObservationIgnored
    var iconSpacing: Double
    static let defaultIconSpacing = 2.0

    @ObservableUserDefault(
        .init(
            key: "settings.iconCornerRadius",
            defaultValue: MenuBarSettingsManager.defaultIconCornerRadius,
            store: .standard
        ))
    @ObservationIgnored
    var iconCornerRadius: Double
    static let defaultIconCornerRadius = 6.0
}
