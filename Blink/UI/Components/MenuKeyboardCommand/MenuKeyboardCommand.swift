//
//  MenuKeyboardCommand.swift
//  Blink
//
//  Created by Ben on 4/4/26.
//

import AppKit
import SwiftUI

struct MenuKeyboardCommand<Label: View>: View {
    let key: KeyCode
    let modifiers: Modifiers
    var dismissesMenu: Bool = true
    var activatesApp: Bool = false
    let action: () -> Void
    @ViewBuilder let label: Label

    @Environment(AppState.self) private var appState
    @Environment(MenuKeyDispatcher.self) private var dispatcher
    @Environment(\.menuIsPresented) private var isMenuPresented
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.menuShortcutModifierColumnCount) private var shortcutModifierColumnCount
    @Environment(\.menuShortcutModifierSymbolWidth) private var shortcutModifierSymbolWidth
    @Environment(\.menuShortcutKeyWidth) private var shortcutKeyWidth

    @State private var isHovering = false
    @State private var forcedHighlight: Bool?
    @State private var pressTask: Task<Void, Never>?
    @State private var registrationID = UUID()

    private var isHighlighted: Bool {
        forcedHighlight ?? isHovering
    }

    private var highlightColor: Color {
        colorScheme == .dark ? .white.opacity(0.16) : .black.opacity(0.12)
    }

    private var highlightInset: CGFloat {
        if #available(macOS 26, *) { return 6 } else { return 4 }
    }

    private var shortcutLabel: String {
        modifiers.symbolicValue + key.stringValue.uppercased()
    }

    private var modifierSymbols: [String] {
        modifiers.symbolicValue.map(String.init)
    }

    private var keyLabel: String {
        key.stringValue.uppercased()
    }

    private func register() {
        dispatcher.register(
            .init(
                id: registrationID,
                key: key,
                modifiers: modifiers,
                isEnabled: isEnabled,
                action: { activate(viaKeyboard: true) }
            )
        )

    }

    var body: some View {
        itemBody
            .padding([.top, .bottom], -4)
            .contentShape(Rectangle())
            .allowsHitTesting(isEnabled)
            .onHover { isHovering = $0 }
            .onTapGesture {
                guard isEnabled else { return }
                activate(viaKeyboard: false)
            }
            .onAppear {
                register()
            }
            .onDisappear {
                dispatcher.unregister(id: registrationID)
                pressTask?.cancel()
                pressTask = nil
                forcedHighlight = nil
            }
            // Keep the registration's isEnabled in sync
            .onChange(of: isEnabled) { _, _ in
                register()
            }
    }

    private var itemBody: some View {
        ZStack {
            invisibleShortcutText

            backgroundShape
                .fill(isHighlighted ? highlightColor : .clear)
                .padding([.leading, .trailing], -(14 - highlightInset))

            HStack {
                label
                Spacer(minLength: 0)
                visibleShortcutText
            }
            .frame(height: 22)
        }
    }

    private var visibleShortcutText: some View {
        HStack(spacing: 0) {
            let padding = shortcutModifierColumnCount - modifierSymbols.count

            ForEach(0..<shortcutModifierColumnCount, id: \.self) { index in
                if index >= padding {
                    let symbolIndex = index - padding
                    Text(modifierSymbols[symbolIndex])
                        .frame(width: shortcutModifierSymbolWidth, alignment: .center)
                } else {
                    Text(" ")
                        .opacity(0)
                        .frame(width: shortcutModifierSymbolWidth, alignment: .center)
                }
            }

            Text(keyLabel)
                .frame(width: shortcutKeyWidth, alignment: .center)
        }
        .foregroundStyle(.secondary)
    }

    private var invisibleShortcutText: some View {
        HStack(spacing: 0) {
            // Measure a single modifier symbol cell (all modifier symbols are
            // the same glyph width in SF Pro, so one measurement covers all).
            Text("⌘")
                .reportMenuShortcutModifierSymbolWidth()
                .hidden()

            Text(keyLabel)
                .reportMenuShortcutKeyWidth()
                .hidden()
        }
        .reportMenuShortcutModifierCount(modifierSymbols.count)
        .hidden()
    }

    private var backgroundShape: some Shape {
        if #available(macOS 26, *) {
            RoundedRectangle(
                cornerSize: .init(width: 10, height: 10),
                style: .continuous
            )
        } else {
            RoundedRectangle(cornerSize: .init(width: 5, height: 5))
        }
    }

    private func activate(viaKeyboard: Bool) {
        pressTask?.cancel()
        pressTask = Task { @MainActor in
            defer { forcedHighlight = nil }

            if viaKeyboard {
                if isHovering {
                    forcedHighlight = false
                    try? await Task.sleep(for: .milliseconds(80))
                    forcedHighlight = true
                    try? await Task.sleep(for: .milliseconds(80))
                } else {
                    forcedHighlight = true
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } else {
                forcedHighlight = false
                try? await Task.sleep(for: .milliseconds(80))
                forcedHighlight = true
                try? await Task.sleep(for: .milliseconds(80))
            }

            if activatesApp {
                appState.activate(withPolicy: .regular)
            }

            if dismissesMenu {
                isMenuPresented?.wrappedValue = false
                try? await Task.sleep(for: .milliseconds(100))
            }

            action()
        }
    }
}
