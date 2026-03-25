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
        @Bindable var settings = appState.settings

        Toggle("Enable", isOn: $settings.bindingsEnabled)

        Divider()

        Button("Switch Left") {
            switcher.switchLeft()
        }
        .disabled(!switcher.canMoveLeft())

        Button("Switch Right") {
            switcher.switchRight()
        }
        .disabled(!switcher.canMoveRight())

        Divider()

        if let info = switcher.spaceInfo, info.spaceCount > 0 {
            ForEach(0..<info.spaceCount, id: \.self) { index in
                Button("Space \(index + 1)\(index == info.currentIndex ? " ✓" : "")") {
                    switcher.switchToIndex(index)
                }
            }
        } else {
            Text("No space info available")
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Settings...") {
            appState.appDelegate?.openSettingsWindow()
        }

        Divider()

        Button("Quit Blink") {
            NSApplication.shared.terminate(nil)
        }
    }
}

#Preview {
    BlinkMenu()
}
