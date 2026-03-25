//
//  BlinkSection.swift
//  Blink
//
//  Created by Ben on 3/25/26.
//

import SwiftUI

struct BlinkSectionOptions: OptionSet {
    let rawValue: Int

    static let isBordered = BlinkSectionOptions(rawValue: 1 << 0)
    static let hasDividers = BlinkSectionOptions(rawValue: 1 << 1)

    static let plain: BlinkSectionOptions = []
    static let `default`: BlinkSectionOptions = [.isBordered, .hasDividers]
}

struct BlinkSection<Header: View, Content: View, Footer: View>: View {
    private let header: Header
    private let content: Content
    private let footer: Footer
    private let spacing: CGFloat
    private let options: BlinkSectionOptions

    private var isBordered: Bool { options.contains(.isBordered) }
    private var hasDividers: Bool { options.contains(.hasDividers) }

    init(
        spacing: CGFloat = 10,
        options: BlinkSectionOptions = .default,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) {
        self.spacing = spacing
        self.options = options
        self.header = header()
        self.content = content()
        self.footer = footer()
    }

    init(
        spacing: CGFloat = 10,
        options: BlinkSectionOptions = .default,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) where Header == EmptyView {
        self.init(spacing: spacing, options: options) {
            EmptyView()
        } content: {
            content()
        } footer: {
            footer()
        }
    }

    init(
        spacing: CGFloat = 10,
        options: BlinkSectionOptions = .default,
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) where Footer == EmptyView {
        self.init(spacing: spacing, options: options) {
            header()
        } content: {
            content()
        } footer: {
            EmptyView()
        }
    }

    init(
        spacing: CGFloat = 10,
        options: BlinkSectionOptions = .default,
        @ViewBuilder content: () -> Content
    ) where Header == EmptyView, Footer == EmptyView {
        self.init(spacing: spacing, options: options) {
            EmptyView()
        } content: {
            content()
        } footer: {
            EmptyView()
        }
    }

    init(
        _ title: LocalizedStringKey,
        spacing: CGFloat = 10,
        options: BlinkSectionOptions = .default,
        @ViewBuilder content: () -> Content
    ) where Header == Text, Footer == EmptyView {
        self.init(spacing: spacing, options: options) {
            Text(title)
                .font(.headline)
        } content: {
            content()
        }
    }

    var body: some View {
        if isBordered {
            BlinkGroupBox(padding: spacing) {
                header
            } content: {
                dividedContent
            } footer: {
                footer
            }
        } else {
            VStack(alignment: .leading) {
                header
                dividedContent
                footer
            }
        }
    }

    @ViewBuilder
    private var dividedContent: some View {
        if hasDividers {
            _VariadicView.Tree(BlinkSectionLayout(spacing: spacing)) {
                content
                    .frame(maxWidth: .infinity)
            }
        } else {
            content
                .frame(maxWidth: .infinity)
        }
    }
}

private struct BlinkSectionLayout: _VariadicView_UnaryViewRoot {
    let spacing: CGFloat

    @ViewBuilder
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(children) { child in
                child
                if child.id != last {
                    Divider()
                }
            }
        }
    }
}
