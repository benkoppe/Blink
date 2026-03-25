//
//  RemoveSidebarToggle.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import SwiftUI

extension View {
    /// Removes the sidebar toggle button from the toolbar.
    func removeSidebarToggle() -> some View {
        toolbar(removing: .sidebarToggle)
            .toolbar {
                Color.clear
            }
    }
}
