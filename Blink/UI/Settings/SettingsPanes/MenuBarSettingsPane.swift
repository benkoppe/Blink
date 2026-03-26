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

    var body: some View {
        BlinkForm {
            BlinkSection("Style") {
                barStyleToggle
            }
            BlinkSection("Appearance") {
                barAppearanceEditor
            }
        }
    }

    var barStyleToggle: some View {
        Text("Hello")
    }

    var barAppearanceEditor: some View {
        @Bindable var settings = appState.settings

        return VStack {
            Group {
                if let image = SpaceIconImage(text: "1", isSelected: true, appState: appState) {
                    Image(nsImage: image.image)
                } else {
                    Image(systemName: "questionmark.app")
                }
            }
            .frame(height: 30)

            Divider()

            BlinkLabeledContent {
                BlinkSlider(
                    LocalizedStringKey(settings.iconSize.formatted()),
                    value: $settings.iconSize,
                    in: 10...40,
                    step: 1
                )
                .frame(height: 20)
            } label: {
                Text("Size")
                    .frame(minWidth: maxSliderLabelWidth, alignment: .leading)
                    .onFrameChange { frame in
                        maxSliderLabelWidth = max(maxSliderLabelWidth, frame.width)
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
                Text("Corner radius")
                    .frame(minWidth: maxSliderLabelWidth, alignment: .leading)
                    .onFrameChange { frame in
                        maxSliderLabelWidth = max(maxSliderLabelWidth, frame.width)
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
                Text("Spacing")
                    .frame(minWidth: maxSliderLabelWidth, alignment: .leading)
                    .onFrameChange { frame in
                        maxSliderLabelWidth = max(maxSliderLabelWidth, frame.width)
                    }
            }
        }
    }
}

#Preview {
    MenuBarSettingsPane()
}
