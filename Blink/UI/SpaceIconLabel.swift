//
//  SpaceIconLabel.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import SwiftUI

struct SpaceIconImage {
    let image: NSImage

    init?(
        text displayText: String,
        isSelected: Bool,
        appState: AppState
    ) {
        self.init(
            text: displayText,
            isSelected: isSelected,
            iconSize: appState.settings.iconSize,
            cornerRadius: appState.settings.iconCornerRadius
        )
    }

    init?(
        text displayText: String,
        isSelected: Bool,
        iconSize: Double,
        cornerRadius: Double
    ) {
        let lineWidth: CGFloat = 0.8

        let image = NSImage(size: NSSize(width: iconSize, height: iconSize))
        image.lockFocus()

        guard let context = NSGraphicsContext.current?.cgContext else {
            image.unlockFocus()
            return nil
        }

        let rect = NSRect(x: 0, y: 0, width: iconSize, height: iconSize)

        let inset = lineWidth / 2
        let adjustedRect = rect.insetBy(dx: inset, dy: inset)

        let path = NSBezierPath(
            roundedRect: adjustedRect,
            xRadius: cornerRadius - inset,
            yRadius: cornerRadius - inset
        )

        let font = NSFont.systemFont(ofSize: iconSize * 0.6, weight: .bold)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black,
        ]

        let textSize = displayText.size(withAttributes: attributes)
        let textRect = NSRect(
            x: (iconSize - textSize.width) / 2,
            y: (iconSize - textSize.height) / 2,
            width: textSize.width,
            height: textSize.height
        )

        if isSelected {
            // filled background, knockout text
            context.beginTransparencyLayer(auxiliaryInfo: nil)

            NSColor.black.setFill()
            path.fill()

            context.setBlendMode(.destinationOut)
            displayText.draw(in: textRect, withAttributes: attributes)

            context.endTransparencyLayer()
        } else {
            // outline, normal text
            NSColor.black.setStroke()
            path.lineWidth = lineWidth
            path.stroke()

            displayText.draw(in: textRect, withAttributes: attributes)
        }

        image.unlockFocus()
        image.isTemplate = true

        self.image = image
    }
}

extension [SpaceIconImage] {
    func combine(appState: AppState) -> NSImage? {
        return combine(spacing: appState.settings.iconSpacing)
    }

    func combine(spacing: Double) -> NSImage? {
        guard !self.isEmpty else { return nil }

        let height = self.map { $0.image.size.height }.max() ?? 0
        let totalWidth =
            self.reduce(0) { $0 + $1.image.size.width } + spacing * CGFloat(self.count - 1)

        let combined = NSImage(size: .init(width: totalWidth, height: height))
        combined.lockFocus()

        var xOffset: CGFloat = 0

        for item in self {
            let yOffset = (height - item.image.size.height) / 2

            item.image.draw(
                in: NSRect(
                    x: xOffset,
                    y: yOffset,
                    width: item.image.size.width,
                    height: item.image.size.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )

            xOffset += item.image.size.width + spacing
        }

        combined.unlockFocus()
        combined.isTemplate = true

        return combined
    }
}

struct SpaceIconLabel: View {
    @Environment(\.colorScheme) var colorScheme

    let appState: AppState

    var iconColor: Color { colorScheme == .dark ? .white : .black }

    func combinedSpacesImage(info: SpaceInfo) -> NSImage? {
        let images: [SpaceIconImage] = (0..<info.spaceCount).compactMap {
            let isSelected = $0 == info.currentIndex
            return .init(text: String($0 + 1), isSelected: isSelected, appState: appState)
        }

        guard images.count == info.spaceCount else { return nil }

        return images.combine(appState: appState)
    }

    @ViewBuilder
    func fallbackInfoTextView(info: SpaceInfo) -> some View {
        Text("\(info.displayNumber)")
    }

    var body: some View {
        if let info = appState.spaceSwitcher.spaceInfo {
            if let combined = combinedSpacesImage(info: info) {
                Image(nsImage: combined)
            } else {
                fallbackInfoTextView(info: info)
            }
        } else {
            Image(systemName: "rectangle.3.group")
        }
    }
}
