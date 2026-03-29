//
//  PermissionsWindow.swift
//  Blink
//
//  Created by Ben on 3/29/26.
//

import SwiftUI

struct PermissionsWindow: Scene {
    var appState: AppState

    var body: some Scene {
        Window(Constants.permissionsWindowTitle, id: Constants.permissionsWindowID) {
            PermissionsView()
                .readWindow { window in
                    guard let window else { return }
                    appState.assignPermissionsWindow(window)
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .environment(appState)
    }
}
