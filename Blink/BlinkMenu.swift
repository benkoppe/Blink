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
            Button("Switch Left") {
                appModel.spaceSwitcher.switchLeft()
            }
            .disabled(!appModel.spaceSwitcher.canMoveLeft())

            Button("Switch Right") {
                appModel.spaceSwitcher.switchRight()
            }
            .disabled(!appModel.spaceSwitcher.canMoveRight())
        }
    }
}

#Preview {
    BlinkMenu()
}
