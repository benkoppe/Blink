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
                instantCmdTabSpaceSwitching
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
        Toggle("Wrap-around spaces", isOn: $manager.wrapSpaceSwitching)
            .annotation(
                "Going left from Space 1 jumps to the last space, and vice versa")
    }

    @ViewBuilder
    private var instantCmdTabSpaceSwitching: some View {
        @Bindable var manager = manager
        Toggle("Instant Cmd-Tab space switching", isOn: $manager.instantCmdTabSpaceSwitching)
            .annotation("When Cmd-Tab activates an app on another space, Blink jumps there instantly")
    }
}

#Preview {
    GeneralSettingsPane()
}
