//
//  BlinkMenu.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import SwiftUI

struct BlinkMenu: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        VStack {
            Button("Switch left") {
                appModel.spaceSwitcher.switchLeft()
            }
            Button("Switch right") {
                appModel.spaceSwitcher.switchRight()
            }
        }
    }
}

#Preview {
    BlinkMenu()
}
