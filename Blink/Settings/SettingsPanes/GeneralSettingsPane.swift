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

    var manager: GeneralSettingsManager {
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

            BlinkSection {
                wrapSpaceSwitching
            }

            BlinkSection("Gestures") {
                gestures(for: 3)
                gestures(for: 4)
                allowSameDirectionRepeat
                if appState.settingsManager.gestureSettingsManager.allowSameDirectionRepeat {
                    sameDirectionRepeatSensitivity
                }
            }
        }
    }

    var launchAtLogin: some View {
        LaunchAtLogin.Toggle()
    }

    var enableBindings: some View {
        @Bindable var manager = manager

        return Toggle("Enable bindings", isOn: $manager.bindingsEnabled)
            .annotation("Fully disable all gestures and hotkeys")
    }

    var wrapSpaceSwitching: some View {
        @Bindable var manager = manager

        return Toggle("Wrap spaces", isOn: $manager.wrapSpaceSwitching)
            .annotation(
                "Going left from Space 1 jumps to the last space, and vice versa (a little clunky)")
    }

    private func swipeBinding(for fingerCount: Int) -> Binding<Bool> {
        Binding(
            get: {
                let gestureSettings = appState.settingsManager.gestureSettingsManager
                let leftID = SwipeGestureID(direction: .left, fingerCount: fingerCount)
                let rightID = SwipeGestureID(direction: .right, fingerCount: fingerCount)

                let leftEnabled = gestureSettings.gesture(withID: leftID)?.action == .left
                let rightEnabled = gestureSettings.gesture(withID: rightID)?.action == .right

                return leftEnabled && rightEnabled
            },
            set: { newValue in
                let gestureSettings = appState.settingsManager.gestureSettingsManager
                let leftID = SwipeGestureID(direction: .left, fingerCount: fingerCount)
                let rightID = SwipeGestureID(direction: .right, fingerCount: fingerCount)

                gestureSettings.gesture(withID: leftID)?.action = newValue ? .left : nil
                gestureSettings.gesture(withID: rightID)?.action = newValue ? .right : nil
            }
        )
    }

    func gestures(for fingerCount: Int) -> some View {
        Toggle("\(fingerCount)-finger Swipes", isOn: swipeBinding(for: fingerCount))
            .annotation("Switch spaces with \(fingerCount) fingers")
    }

    var allowSameDirectionRepeat: some View {
        @Bindable var manager = appState.settingsManager.gestureSettingsManager

        return Toggle("Allow repeated swipe direction", isOn: $manager.allowSameDirectionRepeat)
            .annotation("Swipe the same direction multiple times within a single gesture")
    }

    var sameDirectionRepeatSensitivity: some View {
        @Bindable var manager = appState.settingsManager.gestureSettingsManager

        return Slider(value: $manager.sameDirectionRepeatSensitivity, in: 0...0.18) {
            Text("Sensitivity")
        } minimumValueLabel: {
            Text("Low")
        } maximumValueLabel: {
            Text("High")
        }
        .annotation("How much additional travel is required before the same direction fires again")
    }
}

#Preview {
    GeneralSettingsPane()
}
