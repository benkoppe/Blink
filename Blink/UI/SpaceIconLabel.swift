//
//  SpaceIconLabel.swift
//  Blink
//
//  Created by Ben on 3/24/26.
//

import SwiftUI

enum MenuBarIconStyle: String, CaseIterable {
    case currDisplaySpace
    case currDisplayAllSpaces

    var displayName: String {
        switch self {
        case .currDisplaySpace: "Current active space"
        case .currDisplayAllSpaces: "All display spaces"
        }
    }
}

struct SpaceIconRenderModel: Equatable {
    let spaceCount: Int
    let selectedIndex: Int
    let style: MenuBarIconStyle
    let iconSize: Double
    let spacing: Double
    let cornerRadius: Double

    var size: NSSize {
        let count = style == .currDisplayAllSpaces ? spaceCount : 1
        return NSSize(width: Double(count) * iconSize + Double(count - 1) * spacing, height: iconSize)
    }

    static func current(appState: AppState) -> Self? {
        guard let info = appState.spaceSwitcher.spaceInfo,
              let selectedIndex = appState.spaceSwitcher.menuBarSpaceIndex else { return nil }
        let settings = appState.settingsManager.menuBarSettingsManager
        return Self(
            spaceCount: info.spaceCount, selectedIndex: selectedIndex, style: settings.iconStyle,
            iconSize: settings.iconSize, spacing: settings.iconSpacing, cornerRadius: settings.iconCornerRadius
        )
    }
}

enum SpaceIconRenderer {
    static func image(for model: SpaceIconRenderModel) -> NSImage? {
        guard model.spaceCount > 0, (0..<model.spaceCount).contains(model.selectedIndex),
              model.iconSize.isFinite, model.iconSize > 0,
              model.spacing.isFinite, model.spacing >= 0,
              model.cornerRadius.isFinite else { return nil }
        switch model.style {
        case .currDisplaySpace:
            return SpaceIconImage(
                text: String(model.selectedIndex + 1), isSelected: true,
                iconSize: model.iconSize, cornerRadius: model.cornerRadius
            )?.image
        case .currDisplayAllSpaces:
            let images = (0..<model.spaceCount).compactMap { index in
                SpaceIconImage(text: String(index + 1), isSelected: index == model.selectedIndex,
                               iconSize: model.iconSize, cornerRadius: model.cornerRadius)
            }
            guard images.count == model.spaceCount else { return nil }
            return images.combine(spacing: model.spacing)
        }
    }
}

private struct SpaceIconImage {
    let image: NSImage

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
    fileprivate func combine(spacing: Double) -> NSImage? {
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

struct PreviewSpaceIconLabel: View {
    let appState: AppState
    let style: MenuBarIconStyle

    var body: some View {
        let settings = appState.settingsManager.menuBarSettingsManager
        let model = SpaceIconRenderModel(
            spaceCount: 4, selectedIndex: 1, style: style, iconSize: settings.iconSize,
            spacing: settings.iconSpacing, cornerRadius: settings.iconCornerRadius
        )
        if let image = SpaceIconRenderer.image(for: model) {
            Image(nsImage: image)
        } else {
            Image(systemName: Constants.sfSymbol)
        }
    }
}
