//
//  GestureSettingsPane.swift
//  Blink
//
//  Created by Ben on 4/8/26.
//

import SwiftUI

struct GestureSettingsPane: View {
    @Environment(AppState.self) private var appState

    private var manager: GestureSettingsManager {
        appState.settingsManager.gestureSettingsManager
    }

    var body: some View {
        BlinkForm {
            BlinkSection {
                gestures(for: 3)
                gestures(for: 4)
            }

            BlinkSection("Behavior") {
                disableSystemSwipeGestures
                flipSwipeDirection
            }

            BlinkSection("Multiswipe") {
                allowSameDirectionRepeat
                if manager.allowSameDirectionRepeat {
                    sameDirectionRepeatSensitivity
                }
            }
        }
    }

    private func swipeBinding(for fingerCount: Int) -> Binding<Bool> {
        Binding(
            get: {
                let leftID = SwipeGestureID(direction: .left, fingerCount: fingerCount)
                let rightID = SwipeGestureID(direction: .right, fingerCount: fingerCount)

                let leftEnabled = manager.gesture(withID: leftID)?.action == .left
                let rightEnabled = manager.gesture(withID: rightID)?.action == .right

                return leftEnabled && rightEnabled
            },
            set: { newValue in
                let leftID = SwipeGestureID(direction: .left, fingerCount: fingerCount)
                let rightID = SwipeGestureID(direction: .right, fingerCount: fingerCount)

                manager.gesture(withID: leftID)?.action = newValue ? .left : nil
                manager.gesture(withID: rightID)?.action = newValue ? .right : nil
            }
        )
    }

    private func gestures(for fingerCount: Int) -> some View {
        Toggle("\(fingerCount)-finger Swipes", isOn: swipeBinding(for: fingerCount))
            .annotation("Switch spaces with \(fingerCount) fingers")
    }

    @ViewBuilder
    private var disableSystemSwipeGestures: some View {
        @Bindable var manager = manager
        Toggle("Disable system swipe gestures", isOn: $manager.disableSystemSwipeGestures)
            .annotation("Consume macOS left/right swipe-between-spaces gestures so they do nothing")
    }

    @ViewBuilder
    private var flipSwipeDirection: some View {
        @Bindable var manager = manager
        Toggle("Flip swipe direction", isOn: $manager.flipSwipeDirection)
            .annotation("Swap left/right swipe direction")
    }

    @ViewBuilder
    private var allowSameDirectionRepeat: some View {
        @Bindable var manager = manager
        Toggle(isOn: $manager.allowSameDirectionRepeat) {
            HStack {
                Text("Allow repeated swipe direction")
                BetaBadge()
            }
        }
        .annotation("Swipe the same direction multiple times within a single gesture")
    }

    @ViewBuilder
    private var sameDirectionRepeatSensitivity: some View {
        @Bindable var manager = manager
        BlinkLabeledContent {
            BlinkSlider(
                LocalizedStringKey(manager.sameDirectionRepeatSensitivity.formatted()),
                value: $manager.sameDirectionRepeatSensitivity,
                in: 0...0.18,
                step: 0.01
            )
            .frame(height: 20)
        } label: {
            BlinkLabeledContent {
                ResetButton(
                    binding: $manager.sameDirectionRepeatSensitivity,
                    default: GestureSettingsManager.defaultSameDirectionRepeatSensitivity
                )
            } label: {
                Text("Sensitivity")
            }
        }
        .annotation(
            "How much additional travel is required before the same direction fires again",
            spacing: 3)
    }
}
