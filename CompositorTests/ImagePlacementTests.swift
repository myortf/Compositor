import CoreGraphics
import Foundation
import Testing
@testable import Compositor

@MainActor
struct ImagePlacementTests {
    private func asset(width: Int, height: Int) throws -> ImportedImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Fixture")
    }

    private func session(width: Int = 400, height: Int = 300) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: width, height: height)
        return session
    }

    @Test func smallImageIsCenteredAtActualSize() throws {
        let session = session()
        session.insert(try asset(width: 100, height: 60))
        let transform = try #require(session.activeLayer?.transform)
        #expect(transform.origin == CGPoint(x: 150, y: 120))
        #expect(transform.size == CGSize(width: 100, height: 60))
    }

    @Test(arguments: [(1000, 500), (500, 1000), (401, 20), (20, 301), (4000, 4000)])
    func bigImageIsScaledToFitAndCentered(width: Int, height: Int) throws {
        let session = session()
        session.insert(try asset(width: width, height: height))
        let transform = try #require(session.activeLayer?.transform)
        #expect(transform.size.width <= 400 && transform.size.height <= 300)
        // One side touches the canvas, and the shape is kept to within a pixel of rounding.
        #expect(transform.size.width == 400 || transform.size.height == 300)
        #expect(abs(transform.size.width / transform.size.height - CGFloat(width) / CGFloat(height)) < 0.05 * CGFloat(width) / CGFloat(height) + 0.02)
        #expect(abs(transform.center.x - 200) <= 1 && abs(transform.center.y - 150) <= 1)
        #expect(session.activeLayer?.asset?.image.width == width)
    }

    @Test func addingOntoATransformedLayerStillCenters() throws {
        let session = session()
        session.insert(try asset(width: 100, height: 100))
        let below = try #require(session.activeLayerID)
        session.beginTransform(persistent: false)
        session.previewTransform(LayerTransform(origin: CGPoint(x: -80, y: 240), size: CGSize(width: 500, height: 500), rotation: 30))
        session.commitTransform()
        #expect(session.document?.layers.first { $0.id == below }?.transform.rotation == 30)
        session.insert(try asset(width: 200, height: 100))
        let added = try #require(session.activeLayer?.transform)
        #expect(added.origin == CGPoint(x: 100, y: 100))
        #expect(added.size == CGSize(width: 200, height: 100))
        #expect(session.document?.layers.count == 2)
    }

    @Test func droppedImageSnapsToCanvasCenterAndEdges() throws {
        let session = session()
        session.snapToLayers = false
        defer { session.snapToLayers = true }
        // A few pixels off center lands on the center.
        session.insert(try asset(width: 100, height: 60), centeredAt: CGPoint(x: 203, y: 148))
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 150, y: 120))
        // Near the top-left corner: its edges land on the canvas edges.
        session.insert(try asset(width: 100, height: 60), centeredAt: CGPoint(x: 54, y: 33))
        #expect(session.activeLayer?.transform.origin == .zero)
        // Far from everything: stays where it was dropped.
        session.insert(try asset(width: 20, height: 20), centeredAt: CGPoint(x: 300, y: 220))
        #expect(session.activeLayer?.transform.origin == CGPoint(x: 290, y: 210))
    }

    @Test func droppedImageSnapsToGuidesAndTurnsOff() throws {
        let session = session()
        session.snapToLayers = false
        defer { session.snapToLayers = true }
        session.addGuide(CanvasGuide(id: UUID(), axis: .vertical, position: 300))
        session.insert(try asset(width: 20, height: 20), centeredAt: CGPoint(x: 311, y: 100))
        #expect(session.activeLayer?.transform.origin.x == 300)
        session.snappingEnabled = false
        session.insert(try asset(width: 20, height: 20), centeredAt: CGPoint(x: 311, y: 100))
        #expect(session.activeLayer?.transform.origin.x == 301)
    }

    @Test func droppedOversizedImageIsFittedBeforeSnapping() throws {
        let session = session()
        session.insert(try asset(width: 1200, height: 900), centeredAt: CGPoint(x: 190, y: 160))
        let transform = try #require(session.activeLayer?.transform)
        #expect(transform.size == CGSize(width: 400, height: 300))
        #expect(transform.origin == .zero)
    }
}
