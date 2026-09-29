import Testing
import AppKit
@testable import Compositor

@MainActor
struct MaskFeatherTests {
    /// A 40×40 layer whose mask is white on the left half and black on the right half.
    static func session() throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 40, height: 40)
        let context = try BrushRaster.context(width: 40, height: 40, mask: false)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        let pixels = try #require(context.makeImage())
        let asset = ImportedImage(image: pixels, thumbnail: pixels, name: "Pixels")
        session.document?.layers.append(ImageLayer(asset: asset, origin: .zero))
        let index = try #require(session.document?.layers.count) - 1
        let id = try #require(session.document?.layers.last?.id)
        session.activeLayerID = id
        session.selectedLayerIDs = [id]
        let mask = try BrushRaster.context(width: 40, height: 40, mask: true)
        mask.setFillColor(gray: 0, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        mask.setFillColor(gray: 1, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: 20, height: 40))
        let image = try #require(mask.makeImage())
        let layerMask = LayerMask(asset: try LayerMask.asset(from: image))
        session.document?.layers[index].mask = layerMask
        session.selectLayerTarget(id, mask: true)
        return session
    }

    static func value(_ image: CGImage, x: Int, y: Int) throws -> Int {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return Int(data[y * context.bytesPerRow + x])
    }

    @Test func featheringSoftensTheEdgeAndKeepsTheFarSides() async throws {
        let session = try Self.session()
        #expect(session.canFeatherMask)
        await session.featherMask(by: 8)
        let image = try #require(session.activeLayer?.mask?.asset.image)
        #expect(LayerMask.isValid(image))
        let edge = try Self.value(image, x: 20, y: 20)
        #expect(edge > 30 && edge < 225)
        #expect(try Self.value(image, x: 0, y: 20) > 240)
        #expect(try Self.value(image, x: 39, y: 20) < 15)
    }

    @Test func featheringIsOneUndoStep() async throws {
        let session = try Self.session()
        let before = session.activeLayer?.mask?.asset.image
        await session.featherMask(by: 4)
        #expect(session.activeLayer?.mask?.asset.image !== before)
        session.undo()
        #expect(session.activeLayer?.mask?.asset.image === before)
    }

    @Test func aUniformMaskCannotBeFeathered() throws {
        let session = EditorSession()
        session.createDocument(width: 20, height: 20)
        session.addBlankLayer()
        session.addLayerMask(revealing: true)
        #expect(session.activeLayer?.mask != nil)
        #expect(!session.canFeatherMask)
    }

    @Test func invertMaskFlipsTheMask() async throws {
        let session = try Self.session()
        await session.invertPixels()
        let image = try #require(session.activeLayer?.mask?.asset.image)
        #expect(try Self.value(image, x: 0, y: 20) < 15)
        #expect(try Self.value(image, x: 39, y: 20) > 240)
    }
}
