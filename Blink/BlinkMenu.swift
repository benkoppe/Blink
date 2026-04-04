//
//  BlinkMenu.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import MacControlCenterUI
import MenuBarExtraAccess
import SwiftUI

struct BlinkMenu: View {
    @Environment(AppState.self) private var appState
    private var switcher: SpaceSwitcher { appState.spaceSwitcher }

    @Binding var isMenuPresented: Bool

    @State private var keyDispatcher = MenuKeyDispatcher()
    @State private var shortcutModifierColumnCount: Int = 0
    @State private var shortcutModifierSymbolWidth: CGFloat?
    @State private var shortcutKeyWidth: CGFloat?

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { appState.settingsManager.generalSettingsManager.bindingsEnabled },
            set: { newValue in
                withAnimation(.macControlCenterMenuResize) {
                    appState.settingsManager.generalSettingsManager.bindingsEnabled = newValue
                }
            }
        )
    }

    var body: some View {
        MacControlCenterMenu(isPresented: $isMenuPresented, width: .custom(200)) {
            MenuHeader("Enabled") {
                Toggle("", isOn: isEnabled)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }

            disabledSection

            switchSection

            swipeSection

            appInfoSection
        }
        .environment(keyDispatcher)
        .environment(\.menuIsPresented, $isMenuPresented)
        .environment(\.menuShortcutModifierColumnCount, shortcutModifierColumnCount)
        .environment(\.menuShortcutModifierSymbolWidth, shortcutModifierSymbolWidth)
        .environment(\.menuShortcutKeyWidth, shortcutKeyWidth)
        .onPreferenceChange(MenuShortcutModifierCountPreferenceKey.self) { count in
            if count > shortcutModifierColumnCount {
                shortcutModifierColumnCount = count
            }
        }
        .onPreferenceChange(MenuShortcutModifierSymbolWidthPreferenceKey.self) { width in
            guard width > 0 else { return }
            if shortcutModifierSymbolWidth.map({ abs($0 - width) > 0.5 }) ?? true {
                shortcutModifierSymbolWidth = width
            }
        }
        .onPreferenceChange(MenuShortcutKeyWidthPreferenceKey.self) { width in
            guard width > 0 else { return }
            if shortcutKeyWidth.map({ abs($0 - width) > 0.5 }) ?? true {
                shortcutKeyWidth = width
            }
        }
        .onChange(of: isMenuPresented) { _, newValue in
            keyDispatcher.isMenuPresented = newValue
        }
    }

    private var disabledSection: some View {
        // dissapearing menu content should always go inside a MenuSection to prevent glitching
        MenuSection(divider: false) {
            if !isEnabled.wrappedValue {
                HStack(spacing: 3) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("The engine is disabled.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func hotkey(for action: BoundAction) -> KeyCombination? {
        appState.settingsManager
            .hotkeySettingsManager
            .hotkey(withAction: action)?
            .keyCombination
    }

    @ViewBuilder private func actionButton(
        title: String,
        action boundAction: BoundAction,
    ) -> some View {
        if let combo = hotkey(for: boundAction) {
            MenuKeyboardCommand(
                key: combo.key,
                modifiers: combo.modifiers,
                action: { boundAction.execute(appState: appState) }
            ) {
                Text(title)
            }
        } else {
            MenuCommand(action: { boundAction.execute(appState: appState) }) {
                Text(title)
            }
        }
    }

    private var switchSection: some View {
        MenuSection("Switch", divider: true) {
            actionButton(
                title: "Left",
                action: .left
            )
            .disabled(!switcher.canMoveLeft())

            actionButton(
                title: "Right",
                action: .right
            )
            .disabled(!switcher.canMoveRight())
        }
    }

    private func swipeBinding(for fingerCount: Int) -> Binding<Bool> {
        Binding(
            get: {
                let gestureSettings = appState.settingsManager.gestureSettingsManager
                let leftID = SwipeGestureID(direction: .left, fingerCount: fingerCount)
                let rightID = SwipeGestureID(direction: .right, fingerCount: fingerCount)

                let leftEnabled = gestureSettings.gesture(withID: leftID)?.action == .left
                let rightEnabled = gestureSettings.gesture(withID: rightID)?.action == .right

                return leftEnabled && rightEnabled
            },
            set: { newValue in
                let gestureSettings = appState.settingsManager.gestureSettingsManager
                let leftID = SwipeGestureID(direction: .left, fingerCount: fingerCount)
                let rightID = SwipeGestureID(direction: .right, fingerCount: fingerCount)

                gestureSettings.gesture(withID: leftID)?.action = newValue ? .left : nil
                gestureSettings.gesture(withID: rightID)?.action = newValue ? .right : nil
            }
        )
    }

    private var swipeSection: some View {
        MenuSection("Swipe", divider: true) {
            HStack {
                MenuCircleToggle(
                    isOn: swipeBinding(for: 3),
                    controlSize: .prominent,
                    style: .init(
                        image: Image(systemName: "3.circle.fill"),
                        color: .blue
                    )
                ) { Text("3 Fingers") }

                MenuCircleToggle(
                    isOn: swipeBinding(for: 4),
                    controlSize: .prominent,
                    style: .init(
                        image: Image(systemName: "4.circle.fill"),
                        color: .blue
                    )
                ) { Text("4 Fingers") }
            }
            .frame(height: 70)
        }
    }

    private var appInfoSection: some View {
        MenuSection("\(Constants.appName) \(Constants.versionString)", divider: true) {
            MenuKeyboardCommand(
                key: .comma,
                modifiers: .command,
                action: { appState.appDelegate?.openSettingsWindow() }
            ) {
                Text("Settings")
            }

            MenuKeyboardCommand(
                key: .q,
                modifiers: .command,
                action: { quit() }
            ) {
                Text("Quit")
            }
        }
    }
}
