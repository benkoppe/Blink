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

    var body: some View {
        switchSection

        jumpToSpaceSection

        Divider()

        appInfoSection
    }

    private var switchSection: some View {
        VStack {
            Button("Switch left", systemImage: "arrow.left") {
                BoundAction.left.execute(appState: appState)
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Button("Switch right", systemImage: "arrow.right") {
                BoundAction.right.execute(appState: appState)
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
        }
    }

    private var jumpSelection: Binding<Int?> {
        Binding(
            get: { switcher.spaceInfo?.currentIndex },
            set: { newValue in
                guard let index = newValue else { return }
                _ = switcher.switchToIndex(index)
            }
        )
    }

    private var jumpToSpaceSection: some View {
        Group {
            if let info = switcher.spaceInfo, info.spaceCount > 0 {
                Divider()
                Picker("Jump to...", selection: jumpSelection) {
                    ForEach(0..<info.spaceCount, id: \.self) { index in
                        Label(
                            "Space \(index + 1)",
                            systemImage: "\(index + 1).circle.fill"
                        )
                        // .keyboardShortcut("p")
                        .tag(Optional(index))
                    }
                }
            }
        }
    }

    private var appInfoSection: some View {
        VStack {
            Text("\(Constants.appName) \(Constants.versionString)")

            Button("Settings...", systemImage: "gearshape.fill") {
                appState.appDelegate?.openSettingsWindow()
            }
            .keyboardShortcut(",")

            Button("Quit") {
                quit()
            }
            .keyboardShortcut("q")
        }
    }

    // private var appInfoSection: some View {
    //     MenuSection("\(Constants.appName) \(Constants.versionString)", divider: true) {
    //         MenuKeyboardCommand(
    //             key: .comma,
    //             modifiers: .command,
    //             action: { appState.appDelegate?.openSettingsWindow() }
    //         ) {
    //             Text("Settings")
    //         }
    //
    //         MenuKeyboardCommand(
    //             key: .q,
    //             modifiers: .command,
    //             action: { quit() }
    //         ) {
    //             Text("Quit")
    //         }
    //     }
    // }

    // private var switchSection: some View {
    //     MenuSection("Switch", divider: true) {
    //         actionButton(
    //             title: "Left",
    //             action: .left
    //         )
    //         .disabled(!switcher.canMoveLeft())
    //
    //         actionButton(
    //             title: "Right",
    //             action: .right
    //         )
    //         .disabled(!switcher.canMoveRight())
    //     }
    // }

    // @State private var keyDispatcher = MenuKeyDispatcher()
    // @State private var shortcutModifierColumnCount: Int = 0
    // @State private var shortcutModifierSymbolWidth: CGFloat?
    // @State private var shortcutKeyWidth: CGFloat?
    //
    // private var isEnabled: Binding<Bool> {
    //     Binding(
    //         get: { appState.settingsManager.generalSettingsManager.bindingsEnabled },
    //         set: { newValue in
    //             withAnimation(.macControlCenterMenuResize) {
    //                 appState.settingsManager.generalSettingsManager.bindingsEnabled = newValue
    //             }
    //         }
    //     )
    // }
    //
    // var body: some View {
    //     MacControlCenterMenu(isPresented: $isMenuPresented, width: .custom(200)) {
    //         enableToggle
    //
    //         disabledSection
    //
    //         switchSection
    //
    //         if let info = switcher.spaceInfo, info.spaceCount > 0 {
    //             jumpToIndexSection(spaceInfo: info)
    //         }
    //
    //         appInfoSection
    //     }
    //     .environment(keyDispatcher)
    //     .environment(\.menuIsPresented, $isMenuPresented)
    //     .environment(\.menuShortcutModifierColumnCount, shortcutModifierColumnCount)
    //     .environment(\.menuShortcutModifierSymbolWidth, shortcutModifierSymbolWidth)
    //     .environment(\.menuShortcutKeyWidth, shortcutKeyWidth)
    //     .onPreferenceChange(MenuShortcutModifierCountPreferenceKey.self) { count in
    //         if count > shortcutModifierColumnCount {
    //             shortcutModifierColumnCount = count
    //         }
    //     }
    //     .onPreferenceChange(MenuShortcutModifierSymbolWidthPreferenceKey.self) { width in
    //         guard width > 0 else { return }
    //         if shortcutModifierSymbolWidth.map({ abs($0 - width) > 0.5 }) ?? true {
    //             shortcutModifierSymbolWidth = width
    //         }
    //     }
    //     .onPreferenceChange(MenuShortcutKeyWidthPreferenceKey.self) { width in
    //         guard width > 0 else { return }
    //         if shortcutKeyWidth.map({ abs($0 - width) > 0.5 }) ?? true {
    //             shortcutKeyWidth = width
    //         }
    //     }
    //     .onChange(of: isMenuPresented) { _, newValue in
    //         keyDispatcher.isMenuPresented = newValue
    //     }
    // }
    //
    // private var enableToggle: some View {
    //     MenuHeader("Enabled") {
    //         Toggle("", isOn: isEnabled)
    //             .toggleStyle(.switch)
    //             .labelsHidden()
    //     }
    // }
    //
    // private var disabledSection: some View {
    //     // dissapearing menu content should always go inside a MenuSection to prevent glitching
    //     MenuSection(divider: false) {
    //         if !isEnabled.wrappedValue {
    //             HStack(spacing: 3) {
    //                 Image(systemName: "exclamationmark.triangle.fill")
    //                     .foregroundStyle(.red)
    //                 Text("The engine is disabled.")
    //                     .foregroundStyle(.secondary)
    //             }
    //         }
    //     }
    // }
    //
    // private func hotkey(for action: BoundAction) -> KeyCombination? {
    //     appState.settingsManager
    //         .hotkeySettingsManager
    //         .hotkey(withAction: action)?
    //         .keyCombination
    // }
    //
    // @ViewBuilder private func actionButton(
    //     title: String,
    //     action boundAction: BoundAction,
    // ) -> some View {
    //     if let combo = hotkey(for: boundAction) {
    //         MenuKeyboardCommand(
    //             key: combo.key,
    //             modifiers: combo.modifiers,
    //             action: { boundAction.execute(appState: appState) }
    //         ) {
    //             Text(title)
    //         }
    //     } else {
    //         MenuCommand(action: { boundAction.execute(appState: appState) }) {
    //             Text(title)
    //         }
    //     }
    // }
    //
    // private var switchSection: some View {
    //     MenuSection("Switch", divider: true) {
    //         actionButton(
    //             title: "Left",
    //             action: .left
    //         )
    //         .disabled(!switcher.canMoveLeft())
    //
    //         actionButton(
    //             title: "Right",
    //             action: .right
    //         )
    //         .disabled(!switcher.canMoveRight())
    //     }
    // }
    //
    // private struct JumpSpaceItem: Identifiable, Hashable {
    //     let id: Int
    //     let name: String
    //     let imageName: String
    // }
    //
    // private func jumpItems(for info: SpaceInfo) -> [JumpSpaceItem] {
    //     (0..<info.spaceCount).map { index in
    //         JumpSpaceItem(
    //             id: index,
    //             name: "Space \(index + 1)",
    //             imageName: "\(index + 1).circle.fill"
    //         )
    //     }
    // }
    //
    // private var jumpSelection: Binding<Int?> {
    //     Binding(
    //         get: { switcher.spaceInfo?.currentIndex },
    //         set: { newValue in
    //             guard let index = newValue else { return }
    //             _ = switcher.switchToIndex(index)
    //         }
    //     )
    // }
    //
    // @State private var isJumpToIndexExpanded = false
    // private func jumpToIndexSection(spaceInfo info: SpaceInfo) -> some View {
    //     MenuDisclosureSection(
    //         "Jump to Index",
    //         divider: true,
    //         isExpanded: $isJumpToIndexExpanded
    //     ) {
    //         MenuList(jumpItems(for: info), selection: jumpSelection) { item in
    //             MenuToggle(image: Image(systemName: item.imageName)) {
    //                 Text(item.name)
    //             }
    //         }
    //     }
    // }
    //
    // private var appInfoSection: some View {
    //     MenuSection("\(Constants.appName) \(Constants.versionString)", divider: true) {
    //         MenuKeyboardCommand(
    //             key: .comma,
    //             modifiers: .command,
    //             action: { appState.appDelegate?.openSettingsWindow() }
    //         ) {
    //             Text("Settings")
    //         }
    //
    //         MenuKeyboardCommand(
    //             key: .q,
    //             modifiers: .command,
    //             action: { quit() }
    //         ) {
    //             Text("Quit")
    //         }
    //     }
    // }
}
