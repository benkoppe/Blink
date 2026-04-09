//
//  GeneralSettingsPane.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import LaunchAtLogin
import SwiftUI

struct GeneralSettingsPane: View {
    @Environment(AppState.self) private var appState

    private var manager: GeneralSettingsManager {
        appState.settingsManager.generalSettingsManager
    }

    var body: some View {
        BlinkForm {
            BlinkSection {
                launchAtLogin
            }

            BlinkSection {
                enableBindings
            }

            BlinkSection("Behavior") {
                wrapSpaceSwitching
            }
        }
    }

    @ViewBuilder
    private var launchAtLogin: some View {
        LaunchAtLogin.Toggle()
    }

    @ViewBuilder
    private var enableBindings: some View {
        @Bindable var manager = manager
        Toggle("Enable bindings", isOn: $manager.bindingsEnabled)
            .annotation("Fully disable all gestures and hotkeys")
    }

    @ViewBuilder
    private var wrapSpaceSwitching: some View {
        @Bindable var manager = manager
        Toggle("Wrap spaces", isOn: $manager.wrapSpaceSwitching)
            .annotation(
                "Going left from Space 1 jumps to the last space, and vice versa (a little clunky)")
    }
}

#Preview {
    GeneralSettingsPane()
}
