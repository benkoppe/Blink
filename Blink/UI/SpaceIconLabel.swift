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

    var iconColor: Color { colorScheme == .dark ? .white : .black }

    @ViewBuilder
    func infoIconView(info: SpaceInfo) -> some View {
        Image(systemName: "\(info.displayNumber).square.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 40, height: 40)
            .foregroundStyle(iconColor)
            .symbolRenderingMode(.monochrome)
    }

    @ViewBuilder
    func allSpacesInlineInfoIconView(info: SpaceInfo) -> some View {
        HStack(spacing: 4) {
            ForEach(0..<info.spaceCount, id: \.self) { index in
                let number = index + 1
                let isSelected = index == info.currentIndex

                Image(systemName: "\(number).square\(isSelected ? ".fill" : "")")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 40, height: 40)
                    .foregroundStyle(iconColor)
                    .symbolRenderingMode(.monochrome)
            }
        }
    }

    @ViewBuilder
    func fallbackInfoTextView(info: SpaceInfo) -> some View {
        Text("\(info.displayNumber)")
    }

    // normally, swiftui puts too much padding around menu bar icons
    // to fix this, we must convert into an image and scale up
    func resizedMenuBarImage<Content: View>(content: Content) -> Image? {
        let renderer = ImageRenderer(content: content)
        guard let cgImage = renderer.cgImage else { return nil }
        return Image(cgImage, scale: 2.0, orientation: .up, label: Text(""))
            .renderingMode(.template)

    }

    var body: some View {
        if let info {
            if let image = resizedMenuBarImage(content: infoIconView(info: info)) {
                image
            } else {
                fallbackInfoTextView(info: info)
            }
        } else {
            Image(systemName: "rectangle.3.group")
        }
    }
}
