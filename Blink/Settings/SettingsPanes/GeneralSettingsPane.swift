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

    private var instantGestureSpeedPresetBinding: Binding<InstantGestureSpeedPreset> {
        Binding(
            get: { manager.instantGestureSpeed.preset },
            set: { newValue in
                var setting = manager.instantGestureSpeed
                setting.preset = newValue
                manager.instantGestureSpeed = setting
            }
        )
    }

    private var instantGestureCustomValueBinding: Binding<Double> {
        Binding(
            get: { manager.instantGestureSpeed.customValue },
            set: { newValue in
                var setting = manager.instantGestureSpeed
                setting.customValue = max(1, newValue)
                manager.instantGestureSpeed = setting
            }
        )
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
                instantGestureSpeed
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
    private var instantGestureSpeed: some View {
        BlinkLabeledContent {
            HStack {
                let presetVelocity = manager.instantGestureSpeed.preset.presetVelocity

                TextField(
                    "Velocity",
                    value: presetVelocity != nil
                        ? .constant(presetVelocity!) : instantGestureCustomValueBinding,
                    format: .number.precision(.fractionLength(0...0))
                )
                .disabled(presetVelocity != nil)
                .textFieldStyle(.roundedBorder)
                .frame(width: 90)
                .multilineTextAlignment(.trailing)

                Picker("Speed", selection: instantGestureSpeedPresetBinding) {
                    ForEach(InstantGestureSpeedPreset.allCases, id: \.self) { preset in
                        Text(preset.displayName).tag(preset)
                    }
                }
                .pickerStyle(.menu)
                .buttonStyle(.bordered)
                .labelsHidden()
                .fixedSize()
            }
        } label: {
            Text("Instant switch speed")
        }
        .annotation("Animation velocity for instant switching and multi-space jumps")
    }
}

#Preview {
    GeneralSettingsPane()
}
