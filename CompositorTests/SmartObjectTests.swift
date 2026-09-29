import Testing
import AppKit
@testable import Compositor

@MainActor
struct SmartObjectTests {
    static func image(_ width: Int, _ height: Int, gray: CGFloat = 0.5) throws -> ImportedImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Pixels")
    }

    @Test func smartObjectIsLiveOnlyWhileItsPixelsAreUntouched() throws {
        let asset = try Self.image(8, 6)
        var layer = ImageLayer(asset: asset, origin: .zero)
        let inner = ImageLayer(asset: asset, origin: .zero)
        layer.smartObject = LayerSmartObject(content: SmartObjectContent(width: 8, height: 6, resolution: 72, layers: [inner]), image: asset.image)
        #expect(layer.liveSmartObject != nil)
        layer.asset = try Self.image(8, 6, gray: 0.2)
        #expect(layer.liveSmartObject == nil)
    }
}
