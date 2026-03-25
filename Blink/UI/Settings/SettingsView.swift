//
//  SettingsView.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import SwiftUI

/// A type that represents an identifier used for navigation in a user interface.
protocol NavigationIdentifier: CaseIterable, Hashable, Identifiable, RawRepresentable {
    /// A localized description of the identifier that can be presented to the user.
    var localized: LocalizedStringKey { get }
}

extension NavigationIdentifier where ID == Int {
    var id: Int { hashValue }
}

extension NavigationIdentifier where RawValue == String {
    var localized: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

enum SettingsNavigationIdentifier: String, NavigationIdentifier {
    case general = "General"
    case hotkeys = "Hotkeys"
    case menuBar = "Menu Bar"
    case about = "About"
}

struct SettingsView: View {
    @Environment(\.sidebarRowSize) var sidebarRowSize

    @State private var navigationIdentifier: SettingsNavigationIdentifier = .general

    private var sidebarWidth: CGFloat {
        switch sidebarRowSize {
        case .small: 190
        case .medium: 210
        case .large: 230
        @unknown default: 210
        }
    }

    private var sidebarItemHeight: CGFloat {
        switch sidebarRowSize {
        case .small: 26
        case .medium: 32
        case .large: 34
        @unknown default: 32
        }
    }

    private var sidebarItemFontSize: CGFloat {
        switch sidebarRowSize {
        case .small: 13
        case .medium: 15
        case .large: 16
        @unknown default: 15
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detailView
        }
        .navigationTitle(navigationIdentifier.localized)
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: $navigationIdentifier) {
            Section {
                ForEach(SettingsNavigationIdentifier.allCases, id: \.self) { identifier in
                    sidebarItem(for: identifier)
                }
            } header: {
                Text("Blink")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.vertical, 5)
            }
            .collapsible(false)
        }
        .scrollDisabled(true)
        .navigationSplitViewColumnWidth(sidebarWidth)
    }

    @ViewBuilder
    private var detailView: some View {
        switch navigationIdentifier {
        case .general:
            GeneralSettingsPane()
        case .menuBar:
            MenuBarSettingsPane()
        case .hotkeys:
            HotkeysSettingsPane()
        case .about:
            AboutSettingsPane()
        }
    }

    @ViewBuilder
    private func sidebarItem(for identifier: SettingsNavigationIdentifier) -> some View {
        Label {
            Text(identifier.localized)
                .font(.system(size: sidebarItemFontSize))
                .padding(.leading, 2)
        } icon: {
            Image(systemName: "app")
        }
        .frame(height: sidebarItemHeight)
    }
}

#Preview {
    SettingsView()
}
