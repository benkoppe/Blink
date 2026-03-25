//
//  SettingsView.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var settings = appModel.settings

        Form {
            Section("Menu Bar Icon") {
                LabeledContent("Icon Size") {
                    Slider(value: $settings.iconSize, in: 10...40, step: 1)
                    Stepper(
                        "\(Int(settings.iconSize)) pt", value: $settings.iconSize, in: 10...40,
                        step: 1)
                }

                LabeledContent("Icon Spacing") {
                    Slider(value: $settings.iconSpacing, in: 0...10, step: 0.5)
                    Stepper(
                        String(format: "%.1f pt", settings.iconSpacing),
                        value: $settings.iconSpacing, in: 0...10, step: 0.5)
                }
                LabeledContent("Corner Radius") {
                    Slider(value: $settings.iconCornerRadius, in: 0...20, step: 1)
                    Stepper(
                        "\(Int(settings.iconCornerRadius)) pt", value: $settings.iconCornerRadius,
                        in: 0...20, step: 1)
                }
            }
            .formStyle(.grouped)
            .frame(width: 400)
            .padding()
        }
    }
}

#Preview {
    SettingsView()
}
