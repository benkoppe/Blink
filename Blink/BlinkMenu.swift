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
            .disabled(!switcher.canMoveLeft())

            Button("Switch right", systemImage: "arrow.right") {
                BoundAction.right.execute(appState: appState)
            }
            .keyboardShortcut(from: hotkey(for: .right))
            .disabled(!switcher.canMoveRight())
        }
    }

    enum JumpSelection: Hashable {
        case lastSpace
        case index(_ index: Int)
    }

    private var jumpSelection: Binding<JumpSelection?> {
        Binding(
            get: {
                guard let index = switcher.spaceInfo?.currentIndex else { return nil }
                return .index(index)
            },
            set: { newValue in
                guard let selection = newValue else { return }
                switch selection {
                case .lastSpace: switcher.switchToLastSpace()
                case .index(let index): switcher.switchToIndex(index)
                }
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
                    Text("Last Space")
                        .selectionDisabled(!switcher.canSwitchToLastSpace())
                        .keyboardShortcut(from: hotkey(for: BoundAction.lastSpace))
                        .tag(Optional(JumpSelection.lastSpace))

                    Divider()

                    ForEach(0..<info.spaceCount, id: \.self) { index in
                        Text("Space \(index + 1)")
                            .keyboardShortcut(
                                from: BoundAction.indexedSpaceActions.indices.contains(index)
                                    ? hotkey(for: BoundAction.indexedSpaceActions[index])
                                    : nil
                            )
                            .tag(Optional(JumpSelection.index(index)))
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
