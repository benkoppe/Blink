//
//  BlinkForm.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import SwiftUI

struct BlinkForm<Content: View>: View {
    @Environment(\.isScrollEnabled) private var isScrollEnabled
    @State private var contentFrame = CGRect.zero

    private let alignment: HorizontalAlignment
    private let padding: EdgeInsets
    private let spacing: CGFloat
    private let content: Content

    init(
        alignment: HorizontalAlignment = .center,
        padding: EdgeInsets,
        spacing: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.alignment = alignment
        self.padding = padding
        self.spacing = spacing
        self.content = content()
    }

    init(
        alignment: HorizontalAlignment = .center,
        padding: CGFloat = 20,
        spacing: CGFloat = 10,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            alignment: alignment,
            padding: EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding),
            spacing: spacing
        ) {
            content()
        }
    }

    var body: some View {
        if isScrollEnabled {
            GeometryReader { geo in
                if contentFrame.height > geo.size.height {
                    ScrollView {
                        contentStack
                    }
                    .scrollContentBackground(.hidden)
                } else {
                    contentStack
                }
            }
        } else {
            contentStack
        }
    }

    @ViewBuilder
    private var contentStack: some View {
        VStack(alignment: alignment, spacing: spacing) {
            content
                .toggleStyle(BlinkFormToggleStyle())
        }
        .padding(padding)
        .onFrameChange(update: $contentFrame)
    }
}

private struct BlinkFormToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        BlinkLabeledContent {
            Toggle(isOn: configuration.$isOn) {
                configuration.label
            }
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        } label: {
            configuration.label
        }
    }
}
