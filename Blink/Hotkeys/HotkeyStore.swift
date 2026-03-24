//
//  HotkeyStore.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import AppKit
import Carbon
import Foundation
import Observation

@Observable
final class HotkeyStore {

    // MARK: - Stored hotkeys

    private(set) var leftHotkey: HotkeyCombination
    private(set) var rightHotkey: HotkeyCombination
    private(set) var space1Hotkey: HotkeyCombination
    private(set) var space2Hotkey: HotkeyCombination
    private(set) var space3Hotkey: HotkeyCombination
    private(set) var space4Hotkey: HotkeyCombination
    private(set) var space5Hotkey: HotkeyCombination
    private(set) var space6Hotkey: HotkeyCombination
    private(set) var space7Hotkey: HotkeyCombination
    private(set) var space8Hotkey: HotkeyCombination
    private(set) var space9Hotkey: HotkeyCombination
    private(set) var space10Hotkey: HotkeyCombination
    private(set) var enabledStates: [HotkeyIdentifier: Bool] = [:]

    private let defaults: UserDefaults

    // MARK: - Init

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        leftHotkey = defaults.hotkey(forKey: "hotkey.left") ?? .defaultLeft
        rightHotkey = defaults.hotkey(forKey: "hotkey.right") ?? .defaultRight
        space1Hotkey = defaults.hotkey(forKey: "hotkey.space1") ?? .defaultForSpace(1)
        space2Hotkey = defaults.hotkey(forKey: "hotkey.space2") ?? .defaultForSpace(2)
        space3Hotkey = defaults.hotkey(forKey: "hotkey.space3") ?? .defaultForSpace(3)
        space4Hotkey = defaults.hotkey(forKey: "hotkey.space4") ?? .defaultForSpace(4)
        space5Hotkey = defaults.hotkey(forKey: "hotkey.space5") ?? .defaultForSpace(5)
        space6Hotkey = defaults.hotkey(forKey: "hotkey.space6") ?? .defaultForSpace(6)
        space7Hotkey = defaults.hotkey(forKey: "hotkey.space7") ?? .defaultForSpace(7)
        space8Hotkey = defaults.hotkey(forKey: "hotkey.space8") ?? .defaultForSpace(8)
        space9Hotkey = defaults.hotkey(forKey: "hotkey.space9") ?? .defaultForSpace(9)
        space10Hotkey = defaults.hotkey(forKey: "hotkey.space10") ?? .defaultForSpace(10)

        var states: [HotkeyIdentifier: Bool] = [:]
        for identifier in HotkeyIdentifier.allCases {
            states[identifier] =
                defaults.object(forKey: "enabled.\(identifier.rawValue)") as? Bool ?? true
        }
        enabledStates = states
    }

    // MARK: - Read
    func combination(for identifier: HotkeyIdentifier) -> HotkeyCombination {
        switch identifier {
        case .left: return leftHotkey
        case .right: return rightHotkey
        case .space1: return space1Hotkey
        case .space2: return space2Hotkey
        case .space3: return space3Hotkey
        case .space4: return space4Hotkey
        case .space5: return space5Hotkey
        case .space6: return space6Hotkey
        case .space7: return space7Hotkey
        case .space8: return space8Hotkey
        case .space9: return space9Hotkey
        case .space10: return space10Hotkey
        }
    }
    func isEnabled(_ identifier: HotkeyIdentifier) -> Bool {
        enabledStates[identifier] ?? true
    }

    // MARK: - Write

    func update(_ combination: HotkeyCombination, for identifier: HotkeyIdentifier) {
        switch identifier {
        case .left:
            guard combination != leftHotkey else { return }
            leftHotkey = combination
            defaults.setHotkey(combination, forKey: "hotkey.left")
        case .right:
            guard combination != rightHotkey else { return }
            rightHotkey = combination
            defaults.setHotkey(combination, forKey: "hotkey.right")
        case .space1:
            guard combination != space1Hotkey else { return }
            space1Hotkey = combination
            defaults.setHotkey(combination, forKey: "hotkey.space1")
        case .space2:
            guard combination != space2Hotkey else { return }
            space2Hotkey = combination
            defaults.setHotkey(combination, forKey: "hotkey.space2")
        case .space3:
            guard combination != space3Hotkey else { return }
            space3Hotkey = combination
            defaults.setHotkey(combination, forKey: "hotkey.space3")
        case .space4:
            guard combination != space4Hotkey else { return }
            space4Hotkey = combination
            defaults.setHotkey(combination, forKey: "hotkey.space4")
        case .space5:
            guard combination != space5Hotkey else { return }
            space5Hotkey = combination
            defaults.setHotkey(combination, forKey: "hotkey.space5")
        case .space6:
            guard combination != space6Hotkey else { return }
            space6Hotkey = combination
            defaults.setHotkey(combination, forKey: "hotkey.space6")
        case .space7:
            guard combination != space7Hotkey else { return }
            space7Hotkey = combination
            defaults.setHotkey(combination, forKey: "hotkey.space7")
        case .space8:
            guard combination != space8Hotkey else { return }
            space8Hotkey = combination
            defaults.setHotkey(combination, forKey: "hotkey.space8")
        case .space9:
            guard combination != space9Hotkey else { return }
            space9Hotkey = combination
            defaults.setHotkey(combination, forKey: "hotkey.space9")
        case .space10:
            guard combination != space10Hotkey else { return }
            space10Hotkey = combination
            defaults.setHotkey(combination, forKey: "hotkey.space10")
        }
    }

    func setEnabled(_ enabled: Bool, for identifier: HotkeyIdentifier) {
        enabledStates[identifier] = enabled
        defaults.set(enabled, forKey: "enabled.\(identifier.rawValue)")
    }

    func resetToDefaults() {
        leftHotkey = .defaultLeft
        rightHotkey = .defaultRight
        space1Hotkey = .defaultForSpace(1)
        space2Hotkey = .defaultForSpace(2)
        space3Hotkey = .defaultForSpace(3)
        space4Hotkey = .defaultForSpace(4)
        space5Hotkey = .defaultForSpace(5)
        space6Hotkey = .defaultForSpace(6)
        space7Hotkey = .defaultForSpace(7)
        space8Hotkey = .defaultForSpace(8)
        space9Hotkey = .defaultForSpace(9)
        space10Hotkey = .defaultForSpace(10)
        defaults.setHotkey(leftHotkey, forKey: "hotkey.left")
        defaults.setHotkey(rightHotkey, forKey: "hotkey.right")
        defaults.setHotkey(space1Hotkey, forKey: "hotkey.space1")
        defaults.setHotkey(space2Hotkey, forKey: "hotkey.space2")
        defaults.setHotkey(space3Hotkey, forKey: "hotkey.space3")
        defaults.setHotkey(space4Hotkey, forKey: "hotkey.space4")
        defaults.setHotkey(space5Hotkey, forKey: "hotkey.space5")
        defaults.setHotkey(space6Hotkey, forKey: "hotkey.space6")
        defaults.setHotkey(space7Hotkey, forKey: "hotkey.space7")
        defaults.setHotkey(space8Hotkey, forKey: "hotkey.space8")
        defaults.setHotkey(space9Hotkey, forKey: "hotkey.space9")
        defaults.setHotkey(space10Hotkey, forKey: "hotkey.space10")
    }
}
