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

private struct SpaceIconImage {
    let image: NSImage

    init?(
        text displayText: String,
        isSelected: Bool,
        appState: AppState
    ) {
        let menuBarSettingsManager = appState.settingsManager.menuBarSettingsManager

        self.init(
            text: displayText,
            isSelected: isSelected,
            iconSize: menuBarSettingsManager.iconSize,
            cornerRadius: menuBarSettingsManager.iconCornerRadius
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
    fileprivate func combine(appState: AppState) -> NSImage? {
        return combine(spacing: appState.settingsManager.menuBarSettingsManager.iconSpacing)
    }

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

struct SingleSpaceIconLabel: View {
    @Environment(\.colorScheme) var colorScheme

    let text: String
    let isSelected: Bool
    let iconSize: Double
    let cornerRadius: Double

    init(
        text: String,
        isSelected: Bool,
        iconSize: Double,
        cornerRadius: Double
    ) {
        self.text = text
        self.isSelected = isSelected
        self.iconSize = iconSize
        self.cornerRadius = cornerRadius
    }

    init(
        text: String,
        isSelected: Bool,
        appState: AppState
    ) {
        let settings = appState.settingsManager.menuBarSettingsManager
        self.init(
            text: text,
            isSelected: isSelected,
            iconSize: settings.iconSize,
            cornerRadius: settings.iconCornerRadius
        )
    }

    init(
        appState: AppState,
        spaceInfo info: SpaceInfo
    ) {
        self.init(
            text: String(info.currentIndex + 1),
            isSelected: true,
            appState: appState
        )
    }

    var iconColor: Color { colorScheme == .dark ? .white : .black }

    fileprivate var iconImage: SpaceIconImage? {
        .init(text: text, isSelected: isSelected, iconSize: iconSize, cornerRadius: cornerRadius)
    }

    var body: some View {
        Group {
            if let iconImage {
                Image(nsImage: iconImage.image)
            } else {
                fallback
            }
        }
    }

    var fallback: some View {
        Text(text)
    }
}

struct MultiSpaceIconLabel: View {
    @Environment(\.colorScheme) var colorScheme

    struct Value {
        let text: String
        let isSelected: Bool
    }

    let values: [Value]
    let iconSize: Double
    let cornerRadius: Double
    let spacing: Double

    init(
        values: [Value],
        iconSize: Double,
        cornerRadius: Double,
        spacing: Double
    ) {
        self.values = values
        self.iconSize = iconSize
        self.cornerRadius = cornerRadius
        self.spacing = spacing
    }

    init(
        values: [Value],
        appState: AppState
    ) {
        let settings = appState.settingsManager.menuBarSettingsManager
        self.init(
            values: values,
            iconSize: settings.iconSize,
            cornerRadius: settings.iconCornerRadius,
            spacing: settings.iconSpacing
        )
    }

    init(
        appState: AppState,
        spaceInfo info: SpaceInfo
    ) {
        let values = (0..<info.spaceCount).compactMap {
            let isSelected = $0 == info.currentIndex
            return Value(text: String($0 + 1), isSelected: isSelected)
        }
        self.init(values: values, appState: appState)
    }

    var iconColor: Color { colorScheme == .dark ? .white : .black }

    var iconImage: NSImage? {
        let images: [SpaceIconImage] = values.compactMap {
            return .init(
                text: $0.text,
                isSelected: $0.isSelected,
                iconSize: self.iconSize,
                cornerRadius: self.cornerRadius
            )
        }
        guard images.count == values.count else { return nil }
        return images.combine(spacing: self.spacing)
    }

    var body: some View {
        Group {
            if let iconImage {
                Image(nsImage: iconImage)
            } else {
                fallback
            }
        }
    }

    var fallback: some View {
        let selectedValue = values.first { $0.isSelected }
        return Text(selectedValue?.text ?? "?")
    }
}

struct SpaceIconLabel: View {
    let appState: AppState

    var body: some View {
        if let info = appState.spaceSwitcher.spaceInfo {
            switch appState.settingsManager.menuBarSettingsManager.iconStyle {
            case .currDisplayAllSpaces:
                MultiSpaceIconLabel(appState: appState, spaceInfo: info)
            case .currDisplaySpace:
                SingleSpaceIconLabel(appState: appState, spaceInfo: info)
            }
        } else {
            Image(systemName: "rectangle.3.group")
        }
    }
}

struct PreviewSpaceIconLabel: View {
    let appState: AppState
    let style: MenuBarIconStyle

    var body: some View {
        switch style {
        case .currDisplayAllSpaces:
            MultiSpaceIconLabel(
                values: [
                    .init(text: "1", isSelected: false),
                    .init(text: "2", isSelected: true),
                    .init(text: "3", isSelected: false),
                    .init(text: "4", isSelected: false),
                ],
                appState: appState
            )
        case .currDisplaySpace:
            SingleSpaceIconLabel(text: "2", isSelected: true, appState: appState)
        }
    }
}
