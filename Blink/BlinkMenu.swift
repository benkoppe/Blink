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
        let actionContext = switcher.captureMenuActionContext()
        switchSection(actionContext)

        jumpToSpaceSection(actionContext)

        Divider()

        appInfoSection
    }

    private func hotkey(for action: BoundAction) -> KeyCombination? {
        guard
            let hotkey = appState.settingsManager.hotkeySettingsManager.hotkey(withAction: action),
            hotkey.registrationState == .active
        else { return nil }
        return hotkey.keyCombination
    }

    private func switchSection(_ context: SpaceActionContext?) -> some View {
        VStack {
            Button("Switch left", systemImage: "arrow.left") {
                guard let context else { return }
                appState.actionDispatcher.dispatch(
                    context.request(for: .step(.left), source: .menu)
                )
            }
            .keyboardShortcut(from: hotkey(for: .left))
            .disabled(context?.canSubmit(.step(.left)) != true)

            Button("Switch right", systemImage: "arrow.right") {
                guard let context else { return }
                appState.actionDispatcher.dispatch(
                    context.request(for: .step(.right), source: .menu)
                )
            }
            .keyboardShortcut(from: hotkey(for: .right))
            .disabled(context?.canSubmit(.step(.right)) != true)
        }
    }

    enum JumpSelection: Hashable {
        case lastSpace
        case index(_ index: Int)
    }

    private func jumpSelection(
        _ context: SpaceActionContext
    ) -> Binding<JumpSelection?> {
        Binding(
            get: {
                .index(context.topology.currentIndex)
            },
            set: { newValue in
                guard let selection = newValue else { return }
                switch selection {
                case .lastSpace:
                    appState.actionDispatcher.dispatch(
                        context.request(for: .lastSpace, source: .menu)
                    )
                case .index(let index):
                    appState.actionDispatcher.dispatch(
                        context.request(for: .index(index), source: .menu)
                    )
                }
            }
        )
    }

    private func jumpToSpaceSection(_ context: SpaceActionContext?) -> some View {
        Group {
            if let context, context.spaceInfo.spaceCount > 0 {
                Divider()
                Picker(
                    "Jump to...", systemImage: "square.and.line.vertical.and.square",
                    selection: jumpSelection(context)
                ) {
                    Text("Last Space")
                        .selectionDisabled(!context.canSubmit(.lastSpace))
                        .keyboardShortcut(from: hotkey(for: BoundAction.lastSpace))
                        .tag(Optional(JumpSelection.lastSpace))

                    Divider()

                    ForEach(0..<context.spaceInfo.spaceCount, id: \.self) { index in
                        Text(context.title(forSpaceAt: index))
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

            Button("Copy Diagnostics", systemImage: "doc.on.doc") {
                appState.diagnosticsController.copyReport()
            }

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
