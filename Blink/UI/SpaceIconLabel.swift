//
//  SpaceIconLabel.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import SwiftUI

struct SpaceIconLabel: View {
    @Environment(\.colorScheme) var colorScheme

    let info: SpaceInfo?
    let settings: AppSettings

    var iconColor: Color { colorScheme == .dark ? .white : .black }

    func makeSpaceMenuBarImage(for displayText: String, isSelected: Bool) -> NSImage? {
        let iconSize = settings.iconSize
        let cornerRadius = settings.iconCornerRadius
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

        return image
    }

    func makeCombinedMenuBarImage(images: [NSImage]) -> NSImage? {
        guard !images.isEmpty else { return nil }

        let spacing = settings.iconSpacing
        let height = images.map { $0.size.height }.max() ?? 0
        let totalWidth =
            images.reduce(0) { $0 + $1.size.width } + spacing * CGFloat(images.count - 1)

        let combined = NSImage(size: .init(width: totalWidth, height: height))
        combined.lockFocus()

        var xOffset: CGFloat = 0

        for image in images {
            let yOffset = (height - image.size.height) / 2

            image.draw(
                in: NSRect(
                    x: xOffset, y: yOffset, width: image.size.width, height: image.size.height),
                from: .zero,
                operation: .sourceOver,
                fraction: 1.0
            )

            xOffset += image.size.width + spacing
        }

        combined.unlockFocus()
        combined.isTemplate = true

        return combined
    }

    func combinedSpacesImage(info: SpaceInfo) -> NSImage? {
        let images: [NSImage] = (0..<info.spaceCount).compactMap {
            let isSelected = $0 == info.currentIndex
            return makeSpaceMenuBarImage(for: String($0 + 1), isSelected: isSelected)
        }

        guard images.count == info.spaceCount else { return nil }

        return makeCombinedMenuBarImage(images: images)
    }

    @ViewBuilder
    func fallbackInfoTextView(info: SpaceInfo) -> some View {
        Text("\(info.displayNumber)")
    }

    var body: some View {
        if let info {
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
