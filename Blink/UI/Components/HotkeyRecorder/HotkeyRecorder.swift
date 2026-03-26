//
//  HotkeyRecorder.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import SwiftUI

struct HotkeyRecorder<Label: View>: View {

    private let label: Label

    init(@ViewBuilder label: () -> Label) {
        self.label = label()
    }

    var body: some View {
        BlinkLabeledContent {
            HStack(spacing: 1) {

            }
            .frame(width: 132, height: 24)
            .alignmentGuide(.firstTextBaseline) { dimension in
                dimension[VerticalAlignment.center]
            }
        } label: {
            label
                .alignmentGuide(.firstTextBaseline) { dimension in
                    dimension[VerticalAlignment.center]
                }
        }
    }
}
