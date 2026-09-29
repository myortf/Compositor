import Testing
import AppKit
@testable import Compositor

@MainActor
struct NonSquareMaskTests {
    static let sizes: [(Int, Int)] = [(30, 20), (20, 30), (37, 53), (53, 37), (200, 133), (133, 200), (1, 40), (40, 1)]

    static func layerSession(_ w: Int, _ h: Int) throws -> (EditorSession, UUID) {
        let session = EditorSession()
        session.createDocument(width: w, height: h)
        let context = try BrushRaster.context(width: w, height: h, mask: false)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let pixels = try #require(context.makeImage())
        session.document?.layers.append(ImageLayer(asset: ImportedImage(image: pixels, thumbnail: pixels, name: "P"), origin: .zero))
        let id = try #require(session.document?.layers.last?.id)
        session.activeLayerID = id
        session.selectedLayerIDs = [id]
        return (session, id)
    }

    @Test(arguments: sizes) func maskWithSelectionInvertFeatherAndRender(size: (Int, Int)) async throws {
        let (w, h) = size
        let (session, id) = try Self.layerSession(w, h)
        session.selectLayerTarget(id, mask: false)
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: max(1, w / 2), height: h), transform: nil), antialiased: false, feather: 0)
        session.addMask(revealing: true)
        let mask = try #require(session.activeLayer?.mask)
        #expect(mask.asset.image.width == w && mask.asset.image.height == h)
        await session.invertPixels()
        if w > 1 || h > 1, w > 2 { await session.featherMask(by: 3) }
        let after = try #require(session.activeLayer?.mask)
        #expect(after.asset.image.width == w && after.asset.image.height == h)
        #expect(LayerMask.isValid(after.asset.image))
        let doc = try #require(session.document)
        let context = try BrushRaster.context(width: w, height: h, mask: false)
        session.drawLiveComposite(doc, in: context)
        #expect(context.makeImage() != nil)
    }

    @Test(arguments: sizes) func smartObjectRoundTrip(size: (Int, Int)) throws {
        let (w, h) = size
        let (session, id) = try Self.layerSession(w, h)
        session.selectLayerTarget(id, mask: false)
        #expect(session.canConvertToSmartObject)
        session.convertToSmartObject()
        let so = try #require(session.activeLayer?.liveSmartObject)
        #expect(so.content.width == w && so.content.height == h)
        session.addLayerMask(revealing: false)
        #expect(session.activeLayer?.mask != nil)
    }
}
