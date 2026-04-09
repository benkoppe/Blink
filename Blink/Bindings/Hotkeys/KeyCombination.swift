//
//  KeyCombination.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import Carbon.HIToolbox
import Cocoa
import SwiftUI

struct KeyCombination: Hashable {
    let key: KeyCode
    let modifiers: Modifiers

    var stringValue: String {
        modifiers.symbolicValue + key.stringValue
    }

    init(key: KeyCode, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        let key = KeyCode(rawValue: Int(event.keyCode))
        let modifiers = Modifiers(nsEventFlags: event.modifierFlags)
        self.init(key: key, modifiers: modifiers)
    }
}

private func getSystemReservedKeyCombinations() -> [KeyCombination] {
    let supportedModifierMask = controlKey | optionKey | shiftKey | cmdKey

    var symbolicHotkeys: Unmanaged<CFArray>?
    let status = CopySymbolicHotKeys(&symbolicHotkeys)

    guard status == noErr else {
        Logger.keyCombination.error("CopySymbolicHotKeys returned invalid status: \(status)")
        return []
    }
    guard let reservedHotkeys = symbolicHotkeys?.takeRetainedValue() as? [[String: Any]] else {
        Logger.keyCombination.error("Failed to serialize symbolic hotkeys")
        return []
    }

    return reservedHotkeys.compactMap { hotkey in
        guard
            hotkey[kHISymbolicHotKeyEnabled] as? Bool == true,
            let keyCode = hotkey[kHISymbolicHotKeyCode] as? Int,
            let modifiers = hotkey[kHISymbolicHotKeyModifiers] as? Int,
            modifiers & ~supportedModifierMask == 0
        else {
            return nil
        }
        return KeyCombination(
            key: KeyCode(rawValue: keyCode),
            modifiers: Modifiers(carbonFlags: modifiers)
        )
    }
}

extension KeyCombination {
    /// Returns a Boolean value that indicates whether this key
    /// combination is reserved for system use.
    var isReservedBySystem: Bool {
        getSystemReservedKeyCombinations().contains(self)
    }
}

extension KeyCombination: Codable {
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        guard container.count == 2 else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected 2 encoded values, found \(container.count ?? 0)"
                )
            )
        }
        self.key = try KeyCode(rawValue: container.decode(Int.self))
        self.modifiers = try Modifiers(rawValue: container.decode(Int.self))
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(key.rawValue)
        try container.encode(modifiers.rawValue)
    }
}

// MARK - SwiftUI

extension KeyCombination {
    /// The SwiftUI key equivalent and modifier flags for this combination,
    /// or `nil` if the key cannot be represented as a SwiftUI keyboard shortcut.
    var swiftUIShortcut: (KeyEquivalent, SwiftUI.EventModifiers)? {
        guard let keyEquivalent = key.swiftUIKeyEquivalent else { return nil }
        return (keyEquivalent, modifiers.eventModifiers)
    }
}

extension View {
    /// Applies `.keyboardShortcut` using the given `KeyCombination`,
    /// or returns the view unchanged if the combination is `nil` or cannot
    /// be expressed as a SwiftUI shortcut.
    @ViewBuilder
    func keyboardShortcut(from combo: KeyCombination?) -> some View {
        if let (key, modifiers) = combo?.swiftUIShortcut {
            self.keyboardShortcut(key, modifiers: modifiers)
        } else {
            self
        }
    }
}

// MARK: - Logger

extension Logger {
    fileprivate static let keyCombination = Logger(category: "KeyCombination")
}
