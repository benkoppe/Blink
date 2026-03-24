//
//  HotkeyConfiguration.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import AppKit
import Carbon
import Foundation

struct HotkeyCombination: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var displayKey: String
    var keyEquivalent: String

    var displayString: String {
        HotkeyCombination.symbols(for: modifiers) + displayKey
    }

    var cocoaModifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        return flags
    }

    var isValid: Bool {
        modifiers != 0 && displayKey.isEmpty
    }

    // MARK: - Defaults

    static let defaultLeft = HotkeyCombination(
        keyCode: UInt32(kVK_LeftArrow),
        modifiers: defaultModifierMask,
        displayKey: "←",
        keyEquivalent: arrowKeyEquivalent(.leftArrow)
    )

    static let defaultRight = HotkeyCombination(
        keyCode: UInt32(kVK_RightArrow),
        modifiers: defaultModifierMask,
        displayKey: "→",
        keyEquivalent: arrowKeyEquivalent(.rightArrow)
    )

    static func defaultForSpace(_ number: Int) -> HotkeyCombination {
        let keyCode: UInt32
        let displayKey: String
        let keyEquivalent: String

        switch number {
        case 1:
            keyCode = UInt32(kVK_ANSI_1)
            displayKey = "1"
            keyEquivalent = "1"
        case 2:
            keyCode = UInt32(kVK_ANSI_2)
            displayKey = "2"
            keyEquivalent = "2"
        case 3:
            keyCode = UInt32(kVK_ANSI_3)
            displayKey = "3"
            keyEquivalent = "3"
        case 4:
            keyCode = UInt32(kVK_ANSI_4)
            displayKey = "4"
            keyEquivalent = "4"
        case 5:
            keyCode = UInt32(kVK_ANSI_5)
            displayKey = "5"
            keyEquivalent = "5"
        case 6:
            keyCode = UInt32(kVK_ANSI_6)
            displayKey = "6"
            keyEquivalent = "6"
        case 7:
            keyCode = UInt32(kVK_ANSI_7)
            displayKey = "7"
            keyEquivalent = "7"
        case 8:
            keyCode = UInt32(kVK_ANSI_8)
            displayKey = "8"
            keyEquivalent = "8"
        case 9:
            keyCode = UInt32(kVK_ANSI_9)
            displayKey = "9"
            keyEquivalent = "9"
        case 10:
            keyCode = UInt32(kVK_ANSI_0)
            displayKey = "0"
            keyEquivalent = "0"
        default: fatalError("Invalid space number: \(number)")
        }
        return HotkeyCombination(
            keyCode: keyCode,
            modifiers: defaultModifierMask,
            displayKey: displayKey,
            keyEquivalent: keyEquivalent
        )
    }

    // MARK - Construction from events

    static func from(event: NSEvent) -> HotkeyCombination? {
        let modifiers = event.modifierFlags.carbonMask
        guard modifiers != 0 else { return nil }

        let keyCode = UInt32(event.keyCode)

        if let special = event.specialKey, let symbol = arrowSymbol(for: special) {
            return HotkeyCombination(
                keyCode: keyCode,
                modifiers: modifiers,
                displayKey: symbol,
                keyEquivalent: arrowKeyEquivalent(special)
            )
        }

        guard let characters = event.charactersIgnoringModifiers,
            let first = characters.first
        else { return nil }

        return HotkeyCombination(
            keyCode: keyCode,
            modifiers: modifiers,
            displayKey: String(first).uppercased(),
            keyEquivalent: String(first).lowercased()
        )
    }

    static func arrowSymbol(for specialKey: NSEvent.SpecialKey) -> String? {
        switch specialKey {
        case .leftArrow: return "←"
        case .rightArrow: return "→"
        case .upArrow: return "↑"
        case .downArrow: return "↓"
        default: return nil
        }
    }

    // MARK: - Private helpers

    private static func arrowKeyEquivalent(_ specialKey: NSEvent.SpecialKey) -> String {
        switch specialKey {
        case .leftArrow: return String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
        case .rightArrow: return String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
        case .upArrow: return String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
        case .downArrow: return String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
        default: return ""
        }
    }

    private static func symbols(for modifiers: UInt32) -> String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result
    }

    private static var defaultModifierMask: UInt32 {
        UInt32(cmdKey) | UInt32(optionKey) | UInt32(controlKey)
    }
}

// MARK: - HotkeyIdentifier

enum HotkeyIdentifier: String, CaseIterable {
    case left
    case right
    case space1, space2, space3, space4, space5
    case space6, space7, space8, space9, space10

    var displayName: String {
        switch self {
        case .left: return "Switch Left"
        case .right: return "Switch Right"
        case .space1: return "Space 1"
        case .space2: return "Space 2"
        case .space3: return "Space 3"
        case .space4: return "Space 4"
        case .space5: return "Space 5"
        case .space6: return "Space 6"
        case .space7: return "Space 7"
        case .space8: return "Space 8"
        case .space9: return "Space 9"
        case .space10: return "Space 10"
        }
    }
}

// MARK: - Extensions

extension UserDefaults {
    func hotkey(forKey key: String) -> HotkeyCombination? {
        guard let data = data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(HotkeyCombination.self, from: data)
    }

    func setHotkey(_ hotkey: HotkeyCombination, forKey key: String) {
        if let data = try? JSONEncoder().encode(hotkey) {
            set(data, forKey: key)
        }
    }
}

extension NSEvent.ModifierFlags {
    fileprivate var carbonMask: UInt32 {
        var mask: UInt32 = 0
        if contains(.command) { mask |= UInt32(cmdKey) }
        if contains(.option) { mask |= UInt32(optionKey) }
        if contains(.control) { mask |= UInt32(controlKey) }
        if contains(.shift) { mask |= UInt32(shiftKey) }
        return mask
    }
}
