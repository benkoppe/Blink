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
            .fixedSize(horizontal: false, vertical: true)
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
            backgroundShape
                .fill(isHighlighted ? highlightColor : .clear)
                .padding([.leading, .trailing], -(14 - highlightInset))

            HStack {
                label
                Spacer()
                HStack(spacing: 0) {
                    Text(modifiers.symbolicValue)
                    Text(key.stringValue.uppercased())
                        .frame(width: 16, alignment: .leading)
                }
                Text(shortcutLabel)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 22)
        }
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
