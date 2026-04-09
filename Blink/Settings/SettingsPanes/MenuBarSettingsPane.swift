//
//  MenuBarSettingsPane.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import CompactSlider
import SwiftUI

struct MenuBarSettingsPane: View {
    @Environment(AppState.self) private var appState

    @State private var maxSliderLabelWidth: CGFloat = 0

    @State private var resetAllConfirmationPresented = false

    private var menuBarSettingsManager: MenuBarSettingsManager {
        appState.settingsManager.menuBarSettingsManager
    }

    var body: some View {
        BlinkForm {
            previewSection

            BlinkSection("Style") {
                stylePicker
            }

            BlinkSection("Appearance") {
                barAppearanceEditor
            }

            BlinkSection {
                Button("Reset All to Defaults") {
                    resetAllConfirmationPresented = true
                }
            }
        }
        .confirmationDialog(
            "Reset menu bar appearance to default?",
            isPresented: $resetAllConfirmationPresented
        ) {
            Button("Reset", role: .destructive) {
                menuBarSettingsManager.resetAll()
            }
        } message: {
            Text("This will replace every menu bar setting with its default.")
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        BlinkSection("Preview") {
            PreviewSpaceIconLabel(appState: appState, style: menuBarSettingsManager.iconStyle)
                .frame(height: 30)
        }
    }

    @ViewBuilder
    private var stylePicker: some View {
        @Bindable var settings = menuBarSettingsManager
        BlinkLabeledContent {
            Picker("Display", selection: $settings.iconStyle) {
                ForEach(MenuBarIconStyle.allCases, id: \.self) { style in
                    HStack(spacing: 7) {
                        PreviewSpaceIconLabel(appState: appState, style: style)
                        Text(style.displayName)
                        Spacer()
                    }
                    .padding(.leading, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 5)
                    .tag(style)
                }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
        } label: {
            HStack {
                Text("Display")
                Spacer()
            }
        }
    }

    @ViewBuilder
    private var barAppearanceEditor: some View {
        @Bindable var settings = menuBarSettingsManager
        VStack {
            BlinkLabeledContent {
                BlinkSlider(
                    LocalizedStringKey(settings.iconSize.formatted()),
                    value: $settings.iconSize,
                    in: 10...40,
                    step: 1
                )
                .frame(height: 20)
            } label: {
                BlinkLabeledContent {
                    ResetButton(
                        binding: $settings.iconSize, default: MenuBarSettingsManager.defaultIconSize
                    )
                } label: {
                    Text("Size")
                        .frame(minWidth: maxSliderLabelWidth, alignment: .leading)
                        .onFrameChange { frame in
                            maxSliderLabelWidth = max(maxSliderLabelWidth, frame.width)
                        }
                }
            }

            BlinkLabeledContent {
                BlinkSlider(
                    LocalizedStringKey(settings.iconCornerRadius.formatted()),
                    value: $settings.iconCornerRadius,
                    in: 0...20,
                    step: 1
                )
                .frame(height: 20)
            } label: {
                BlinkLabeledContent {
                    ResetButton(
                        binding: $settings.iconCornerRadius,
                        default: MenuBarSettingsManager.defaultIconCornerRadius)
                } label: {
                    Text("Corner radius")
                        .frame(minWidth: maxSliderLabelWidth, alignment: .leading)
                        .onFrameChange { frame in
                            maxSliderLabelWidth = max(maxSliderLabelWidth, frame.width)
                        }
                }
            }

            BlinkLabeledContent {
                BlinkSlider(
                    LocalizedStringKey(settings.iconSpacing.formatted()),
                    value: $settings.iconSpacing,
                    in: 0...10,
                    step: 0.5
                )
                .frame(height: 20)
            } label: {
                BlinkLabeledContent {
                    ResetButton(
                        binding: $settings.iconSpacing,
                        default: MenuBarSettingsManager.defaultIconSpacing)
                } label: {
                    Text("Spacing")
                        .frame(minWidth: maxSliderLabelWidth, alignment: .leading)
                        .onFrameChange { frame in
                            maxSliderLabelWidth = max(maxSliderLabelWidth, frame.width)
                        }
                }
            }
        }
    }
}

#Preview {
    MenuBarSettingsPane()
}
