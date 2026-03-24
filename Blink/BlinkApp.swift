//
//  BlinkApp.swift
//  Blink
//
//  Created by Ben on 3/23/26.
//

import SwiftUI

@main
struct BlinkApp: App {
    @State private var appModel = AppModel()

    var body: some Scene {
        MenuBarExtra {
            Text("Hello")
                .environment(appModel)
        } label: {
            SpaceIconLabel(info: appModel.spaceSwitcher.spaceInfo)
        }
    }
}
