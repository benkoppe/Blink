//
//  GeneralSettingsManager.swift
//  Blink
//
//  Created by Ben on 3/31/26.
//

import Foundation
import ObservableDefaults
import Observation

enum InstantGestureSpeedPreset: String, CaseIterable, Codable {
    case normal
    case fast
    case faster
    case fastest
    case instant
    case custom

    var displayName: String {
        switch self {
        case .normal: "Normal"
        case .fast: "Fast"
        case .faster: "Faster"
        case .fastest: "Fastest"
        case .instant: "Instant"
        case .custom: "Custom"
        }
    }

    var presetVelocity: Double? {
        switch self {
        case .normal: 40
        case .fast: 50
        case .faster: 60
        case .fastest: 80
        case .instant: 999_999
        case .custom: nil
        }
    }
}

struct InstantGestureSpeedSetting: Codable, Equatable {
    static let defaultPreset: InstantGestureSpeedPreset = .instant
    static let defaultCustomValue = 60.0

    var preset: InstantGestureSpeedPreset = defaultPreset
    var customValue: Double = defaultCustomValue

    var velocity: Double {
        preset.presetVelocity ?? max(1, customValue)
    }
}

@MainActor @ObservableDefaults
final class GeneralSettingsManager {
    @ObservableOnly
    var bindingsEnabled: Bool = true

    @DefaultsKey(userDefaultsKey: "settings.wrapSpaceSwitching")
    var wrapSpaceSwitching: Bool = false

    @DefaultsKey(userDefaultsKey: "settings.instantGestureSpeed")
    var instantGestureSpeed: InstantGestureSpeedSetting = .init()
}
