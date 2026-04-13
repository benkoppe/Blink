//
//  BlinkMenu.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

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

    private func hotkey(for action: BoundAction) -> KeyCombination? {
        appState.settingsManager.hotkeySettingsManager.hotkey(withAction: action)?.keyCombination
    }

    private var switchSection: some View {
        VStack {
            Button("Switch left", systemImage: "arrow.left") {
                BoundAction.left.execute(appState: appState)
            }
            .keyboardShortcut(from: hotkey(for: .left))

            Button("Switch right", systemImage: "arrow.right") {
                BoundAction.right.execute(appState: appState)
            }
            .keyboardShortcut(from: hotkey(for: .right))
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
                Picker(
                    "Jump to...", systemImage: "square.and.line.vertical.and.square",
                    selection: jumpSelection
                ) {
                    ForEach(0..<info.spaceCount, id: \.self) { index in
                        Text("Space \(index + 1)")
                            .keyboardShortcut(
                                from: BoundAction.indexedSpaceActions.indices.contains(index)
                                    ? hotkey(for: BoundAction.indexedSpaceActions[index])
                                    : nil
                            )
                            .tag(Optional(index))
                    }
                }
            }
        }
    }

    private var isEnabled: Binding<Bool> {
        Binding(
            get: { appState.settingsManager.generalSettingsManager.bindingsEnabled },
            set: { newValue in
                appState.settingsManager.generalSettingsManager.bindingsEnabled = newValue
            }
        )
    }

    private var appInfoSection: some View {
        VStack {
            Text("\(Constants.appName) \(Constants.versionString)")

            Button("Settings...", systemImage: "gearshape") {
                appState.appDelegate?.openSettingsWindow()
            }
            .keyboardShortcut(",")

            Button(
                isEnabled.wrappedValue ? "Disable" : "Enable"
            ) {
                isEnabled.wrappedValue.toggle()
            }
            .keyboardShortcut("e")

            Button("Quit") {
                quit()
            }
            .keyboardShortcut("q")
        }
    }
}
