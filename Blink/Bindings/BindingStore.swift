//
//  BindingStore.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import AppKit
import Carbon
import Foundation
import Observation

@Observable
final class BindingStore {

    // MARK: - Hotkey combinations (one per BoundAction)

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
    private(set) var hotkeyEnabledStates: [BoundAction: Bool] = [:]

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

        var states: [BoundAction: Bool] = [:]
        for action in BoundAction.allCases {
            states[action] =
                defaults.object(forKey: "enabled.\(action.rawValue)") as? Bool ?? true
        }
        hotkeyEnabledStates = states
    }

    // MARK: - Hotkey read

    func hotkeyCombo(for action: BoundAction) -> HotkeyCombination {
        switch action {
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

    func isHotkeyEnabled(_ action: BoundAction) -> Bool {
        hotkeyEnabledStates[action] ?? true
    }

    // MARK: - Hotkey write

    func updateHotkey(_ combo: HotkeyCombination, for action: BoundAction) {
        switch action {
        case .left:
            guard combo != leftHotkey else { return }
            leftHotkey = combo
            defaults.setHotkey(combo, forKey: "hotkey.left")
        case .right:
            guard combo != rightHotkey else { return }
            rightHotkey = combo
            defaults.setHotkey(combo, forKey: "hotkey.right")
        case .space1:
            guard combo != space1Hotkey else { return }
            space1Hotkey = combo
            defaults.setHotkey(combo, forKey: "hotkey.space1")
        case .space2:
            guard combo != space2Hotkey else { return }
            space2Hotkey = combo
            defaults.setHotkey(combo, forKey: "hotkey.space2")
        case .space3:
            guard combo != space3Hotkey else { return }
            space3Hotkey = combo
            defaults.setHotkey(combo, forKey: "hotkey.space3")
        case .space4:
            guard combo != space4Hotkey else { return }
            space4Hotkey = combo
            defaults.setHotkey(combo, forKey: "hotkey.space4")
        case .space5:
            guard combo != space5Hotkey else { return }
            space5Hotkey = combo
            defaults.setHotkey(combo, forKey: "hotkey.space5")
        case .space6:
            guard combo != space6Hotkey else { return }
            space6Hotkey = combo
            defaults.setHotkey(combo, forKey: "hotkey.space6")
        case .space7:
            guard combo != space7Hotkey else { return }
            space7Hotkey = combo
            defaults.setHotkey(combo, forKey: "hotkey.space7")
        case .space8:
            guard combo != space8Hotkey else { return }
            space8Hotkey = combo
            defaults.setHotkey(combo, forKey: "hotkey.space8")
        case .space9:
            guard combo != space9Hotkey else { return }
            space9Hotkey = combo
            defaults.setHotkey(combo, forKey: "hotkey.space9")
        case .space10:
            guard combo != space10Hotkey else { return }
            space10Hotkey = combo
            defaults.setHotkey(combo, forKey: "hotkey.space10")
        }
    }

    func setHotkeyEnabled(_ enabled: Bool, for action: BoundAction) {
        hotkeyEnabledStates[action] = enabled
        defaults.set(enabled, forKey: "enabled.\(action.rawValue)")
    }

    func resetHotkeysToDefaults() {
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
        for action in BoundAction.allCases {
            defaults.setHotkey(hotkeyCombo(for: action), forKey: "hotkey.\(action.rawValue)")
        }
    }
}

// MARK: - UserDefaults helpers
extension UserDefaults {
    fileprivate func hotkey(forKey key: String) -> HotkeyCombination? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotkeyCombination.self, from: data)
    }

    fileprivate func setHotkey(_ hotkey: HotkeyCombination, forKey key: String) {
        if let data = try? JSONEncoder().encode(hotkey) {
            set(data, forKey: key)
        }
    }
}
