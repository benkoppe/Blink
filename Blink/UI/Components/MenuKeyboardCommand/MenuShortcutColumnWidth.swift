//
//  MenuShortcutColumnWidth.swift
//  Blink
//

import SwiftUI

enum MenuShortcutModifierCountPreferenceKey: PreferenceKey {
    static let defaultValue: Int = 0

    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = max(value, nextValue())
    }
}

enum MenuShortcutModifierSymbolWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

enum MenuShortcutKeyWidthPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private enum MenuShortcutModifierColumnCountEnvironmentKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

private enum MenuShortcutModifierSymbolWidthEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

private enum MenuShortcutKeyWidthEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var menuShortcutModifierColumnCount: Int {
        get { self[MenuShortcutModifierColumnCountEnvironmentKey.self] }
        set { self[MenuShortcutModifierColumnCountEnvironmentKey.self] = newValue }
    }

    var menuShortcutModifierSymbolWidth: CGFloat? {
        get { self[MenuShortcutModifierSymbolWidthEnvironmentKey.self] }
        set { self[MenuShortcutModifierSymbolWidthEnvironmentKey.self] = newValue }
    }

    var menuShortcutKeyWidth: CGFloat? {
        get { self[MenuShortcutKeyWidthEnvironmentKey.self] }
        set { self[MenuShortcutKeyWidthEnvironmentKey.self] = newValue }
    }
}

extension View {
    func reportMenuShortcutModifierCount(_ count: Int) -> some View {
        preference(key: MenuShortcutModifierCountPreferenceKey.self, value: count)
    }

    func reportMenuShortcutModifierSymbolWidth() -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: MenuShortcutModifierSymbolWidthPreferenceKey.self,
                    value: geo.size.width
                )
            }
        }
    }

    func reportMenuShortcutKeyWidth() -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(
                    key: MenuShortcutKeyWidthPreferenceKey.self,
                    value: geo.size.width
                )
            }
        }
    }
}
