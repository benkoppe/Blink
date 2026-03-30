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
        }
    }

    @ViewBuilder
    private func hotkeyRecorder(forAction action: BoundAction) -> some View {
        if let hotkey = hotkeySettingsManager.hotkey(withAction: action) {
            HotkeyRecorder(hotkey: hotkey, appState: appState) {
                Text(action.displayName)
            }
        }
    }
}

#Preview {
    HotkeysSettingsPane()
}
