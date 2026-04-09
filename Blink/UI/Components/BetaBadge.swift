//
//  BetaBadge.swift
//  Blink
//
//  Created by Ben on 4/8/26.
//

import SwiftUI

/// A view that displays a badge indicating a beta feature.
struct BetaBadge: View {
    var body: some View {
        Text("BETA")
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .background {
                Capsule(style: .circular)
                    .stroke()
            }
            .foregroundStyle(.green)
    }
}
