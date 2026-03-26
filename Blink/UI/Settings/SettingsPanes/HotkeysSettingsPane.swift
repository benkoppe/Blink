//
//  HotkeysSettingsPane.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import SwiftUI

struct HotkeysSettingsPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        BlinkForm {
            BlinkSection("Change Spaces") {

            }
            BlinkSection("Jump to Index") {

            }
        }
    }
}

#Preview {
    HotkeysSettingsPane()
}
