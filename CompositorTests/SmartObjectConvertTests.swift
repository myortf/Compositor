import Testing
import AppKit
@testable import Compositor

@MainActor
struct SmartObjectConvertTests {
    static func image(_ width: Int, _ height: Int) throws -> ImportedImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Pixels")
    }

    @Test func convertingAPlainLayerKeepsItsPixelsAndUndoes() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        let asset = try Self.image(8, 6)
        session.document?.layers.append(ImageLayer(asset: asset, origin: CGPoint(x: 5, y: 5)))
        session.activeLayerID = session.document?.layers.last?.id
        session.selectedLayerIDs = [try #require(session.activeLayerID)]
        #expect(session.canConvertToSmartObject)
        session.convertToSmartObject()
        let layer = try #require(session.activeLayer)
        #expect(layer.asset?.image === asset.image)
        let smart = try #require(layer.liveSmartObject)
        #expect(smart.content.width == 8 && smart.content.height == 6)
        #expect(smart.content.layers.count == 1)
        #expect(smart.content.layers[0].transform.origin == .zero)
        #expect(!session.canConvertToSmartObject)
        session.undo()
        #expect(session.activeLayer?.smartObject == nil)
    }

    @Test func convertIsUnavailableForGroupsEmptyLayersAndSeveralLayers() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        session.addBlankLayer()
        #expect(!session.canConvertToSmartObject)
        let a = ImageLayer(asset: try Self.image(4, 4), origin: .zero)
        let b = ImageLayer(asset: try Self.image(4, 4), origin: .zero)
        session.document?.layers.append(contentsOf: [a, b])
        session.selectLayers([a.id, b.id], primary: b.id)
        #expect(!session.canConvertToSmartObject)
    }
}
