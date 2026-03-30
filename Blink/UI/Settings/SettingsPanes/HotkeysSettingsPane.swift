//
//  HotkeysSettingsPane.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import SwiftUI

struct HotkeysSettingsPane: View {
    @Environment(AppState.self) private var appState

    private var hotkeySettingsManager: HotkeySettingsManager {
        appState.settingsManager.hotkeySettingsManager
    }

    @State private var resetAllConfirmationPresented = false
    @State private var resetActionConfirmationTarget: BoundAction? = nil

    var body: some View {
        BlinkForm {
            BlinkSection("Change Spaces") {
                hotkeyRecorder(forAction: .left)
                hotkeyRecorder(forAction: .right)
            }
            BlinkSection("Jump to Index") {
                hotkeyRecorder(forAction: .space1)
                hotkeyRecorder(forAction: .space2)
                hotkeyRecorder(forAction: .space3)
                hotkeyRecorder(forAction: .space4)
                hotkeyRecorder(forAction: .space5)
                hotkeyRecorder(forAction: .space6)
                hotkeyRecorder(forAction: .space7)
                hotkeyRecorder(forAction: .space8)
                hotkeyRecorder(forAction: .space9)
                hotkeyRecorder(forAction: .space10)
            }
            BlinkSection {
                Button("Reset All to Defaults") {
                    resetAllConfirmationPresented = true
                }
            }
        }
        .confirmationDialog(
            "Reset all hotkeys to their defaults?",
            isPresented: $resetAllConfirmationPresented
        ) {
            Button("Reset All", role: .destructive) {
                hotkeySettingsManager.resetAllHotkeys()
            }
        } message: {
            Text("This will replace every hotkey with its default binding.")
        }
        .confirmationDialog(
            "Reset this hotkey to its default?",
            isPresented: Binding(
                get: { resetActionConfirmationTarget != nil },
                set: { if !$0 { resetActionConfirmationTarget = nil } }
            ),
            presenting: resetActionConfirmationTarget
        ) { action in
            Button("Reset", role: .destructive) {
                hotkeySettingsManager.resetHotkey(withAction: action)
            }
        } message: { action in
            if let combo = action.defaultKeyCombination {
                Text("This will set \(action.displayName) back to \(combo.stringValue)")
            }
        }
    }

    @ViewBuilder
    private func hotkeyRecorder(forAction action: BoundAction) -> some View {
        if let hotkey = hotkeySettingsManager.hotkey(withAction: action) {
            HotkeyRecorder(hotkey: hotkey, appState: appState) {
                HStack {
                    Text(action.displayName)
                    if hotkey.keyCombination != action.defaultKeyCombination {
                        Spacer()
                        Button {
                            resetActionConfirmationTarget = action
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}

#Preview {
    HotkeysSettingsPane()
}
