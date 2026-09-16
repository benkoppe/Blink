import AppKit
import Testing

@testable import Blink

@MainActor
@Suite("Space icon rendering")
struct SpaceIconRendererTests {
    @Test("Rendered images and reserved layout use identical dimensions", arguments: MenuBarIconStyle.allCases)
    func dimensions(style: MenuBarIconStyle) throws {
        let model = SpaceIconRenderModel(spaceCount: 12, selectedIndex: 10, style: style,
                                         iconSize: 20, spacing: 3, cornerRadius: 6)
        let image = try #require(SpaceIconRenderer.image(for: model))
        #expect(image.size == model.size)
        #expect(image.size.width == (style == .currDisplayAllSpaces ? 273 : 20))
        #expect(image.isTemplate)
    }

    @Test("Unknown selection is not rendered as a false first Space")
    func invalidSelection() {
        let model = SpaceIconRenderModel(spaceCount: 3, selectedIndex: -1, style: .currDisplayAllSpaces,
                                         iconSize: 20, spacing: 2, cornerRadius: 6)
        #expect(SpaceIconRenderer.image(for: model) == nil)
    }

    @Test("Changing selection changes the image without changing layout")
    func selection() throws {
        let first = SpaceIconRenderModel(spaceCount: 3, selectedIndex: 0, style: .currDisplayAllSpaces,
                                         iconSize: 20, spacing: 2, cornerRadius: 6)
        let second = SpaceIconRenderModel(spaceCount: 3, selectedIndex: 1, style: .currDisplayAllSpaces,
                                          iconSize: 20, spacing: 2, cornerRadius: 6)
        let firstImage = try #require(SpaceIconRenderer.image(for: first))
        let secondImage = try #require(SpaceIconRenderer.image(for: second))
        #expect(firstImage.size == secondImage.size)
        #expect(try #require(firstImage.tiffRepresentation) != #require(secondImage.tiffRepresentation))
    }
}
