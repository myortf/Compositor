import AppKit
import Testing
@testable import Compositor

@MainActor
struct RotateCanvasTests {
    private static let sizes = [CGSize(width: 300, height: 200), CGSize(width: 200, height: 300), CGSize(width: 37, height: 53)]

    private func image(_ width: Int, _ height: Int) throws -> ImportedImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Layer")
    }

    private func mask() throws -> LayerMask {
        let context = try BrushRaster.context(width: 4, height: 4, mask: true)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return LayerMask(asset: try LayerMask.asset(from: try #require(context.makeImage())))
    }

    /// A canvas of `size` with a tilted, flipped layer that has an unlinked, placed mask, a linked masked layer, and a
    /// folder with a placed mask.
    private func session(_ size: CGSize) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: Int(size.width), height: Int(size.height))
        var tilted = ImageLayer(asset: try image(10, 6), origin: .zero)
        tilted.transform = LayerTransform(origin: CGPoint(x: 3, y: 5), size: CGSize(width: 10, height: 6), rotation: 20, flipX: true)
        var unlinked = try mask()
        unlinked.isLinked = false
        unlinked.placement = LayerTransform(origin: CGPoint(x: 1, y: 2), size: CGSize(width: 7, height: 9), rotation: -35, flipY: true)
        tilted.mask = unlinked
        var linked = ImageLayer(asset: try image(8, 8), origin: CGPoint(x: 11, y: 4))
        linked.mask = try mask()
        var folder = ImageLayer(name: "Folder", blankSize: size)
        folder.isGroup = true
        var folderMask = try mask()
        folderMask.isLinked = false
        folderMask.placement = LayerTransform(origin: CGPoint(x: 2, y: 3), size: size, rotation: 90)
        folder.mask = folderMask
        session.document?.layers = [tilted, linked, folder]
        session.activeLayerID = tilted.id
        return session
    }

    private func close(_ lhs: CGAffineTransform, _ rhs: CGAffineTransform) -> Bool {
        [lhs.a - rhs.a, lhs.b - rhs.b, lhs.c - rhs.c, lhs.d - rhs.d, lhs.tx - rhs.tx, lhs.ty - rhs.ty].allSatisfy { abs($0) < 1e-9 }
    }

    @Test func quarterTurnsSwapTheSidesAndHalfTurnKeepsThem() throws {
        for size in Self.sizes {
            let session = try session(size)
            session.rotateCanvas(.clockwise)
            #expect(session.document?.size == CGSize(width: size.height, height: size.width))
            session.rotateCanvas(.counterclockwise)
            #expect(session.document?.size == size)
            session.rotateCanvas(.half)
            #expect(session.document?.size == size)
        }
    }

    @Test func everyLayerAndPlacedMaskLandsWhereTheCanvasTurnedIt() throws {
        for size in Self.sizes {
            for rotation in CanvasRotation.allCases {
                let session = try session(size)
                let before = try #require(session.document)
                session.rotateCanvas(rotation)
                let after = try #require(session.document)
                let matrix = rotation.matrix(for: size)
                #expect(after.layers.map(\.id) == before.layers.map(\.id))
                for (old, new) in zip(before.layers, after.layers) {
                    #expect(new.transform.size == old.transform.size)
                    #expect(new.transform.flipX == old.transform.flipX && new.transform.flipY == old.transform.flipY)
                    #expect(close(new.transform.unitToDocument, old.transform.unitToDocument.concatenating(matrix)))
                    #expect(abs(new.transform.rotation) <= 180)
                    #expect(new.mask?.isLinked == old.mask?.isLinked)
                    #expect(new.mask?.asset.image === old.mask?.asset.image)
                    if let placement = old.mask?.placement {
                        let turned = try #require(new.mask?.placement)
                        #expect(close(turned.unitToDocument, placement.unitToDocument.concatenating(matrix)))
                    } else {
                        #expect(new.mask?.placement == nil)
                    }
                }
            }
        }
    }

    @Test func fourQuarterTurnsAreTheIdentity() throws {
        for size in Self.sizes {
            for rotation in [CanvasRotation.clockwise, .counterclockwise] {
                let session = try session(size)
                session.addGuide(CanvasGuide(id: UUID(), axis: .vertical, position: 5))
                session.addGuide(CanvasGuide(id: UUID(), axis: .horizontal, position: 8))
                let before = try #require(session.document)
                for _ in 0..<4 { session.rotateCanvas(rotation) }
                #expect(session.document == before)
            }
            let session = try session(size)
            let before = try #require(session.document)
            session.rotateCanvas(.half)
            #expect(session.document != before)
            session.rotateCanvas(.half)
            #expect(session.document == before)
            session.rotateCanvas(.clockwise)
            session.rotateCanvas(.clockwise)
            session.rotateCanvas(.half)
            #expect(session.document == before)
        }
    }

    @Test func clockwiseThenCounterclockwiseCancels() throws {
        let session = try session(CGSize(width: 37, height: 53))
        let before = try #require(session.document)
        session.rotateCanvas(.clockwise)
        session.rotateCanvas(.counterclockwise)
        #expect(session.document == before)
    }

    @Test func aLayerAtTheTopLeftGoesToTheTopRightWhenTurnedClockwise() throws {
        let session = EditorSession()
        session.createDocument(width: 300, height: 200)
        var layer = ImageLayer(asset: try image(50, 20), origin: .zero)
        layer.transform = LayerTransform(origin: .zero, size: CGSize(width: 50, height: 20))
        session.document?.layers = [layer]
        session.rotateCanvas(.clockwise)
        let turned = try #require(session.document?.layers.first?.transform)
        #expect(turned.rotation == 90)
        #expect(turned.center == CGPoint(x: 190, y: 25))
        #expect(turned.origin == CGPoint(x: 165, y: 15))
        session.rotateCanvas(.counterclockwise)
        #expect(session.document?.layers.first?.transform == layer.transform)
    }

    @Test func oneUndoStepRestoresEverythingAndRedoTurnsAgain() throws {
        let session = try session(CGSize(width: 300, height: 200))
        session.addGuide(CanvasGuide(id: UUID(), axis: .vertical, position: 40))
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 10, y: 20, width: 30, height: 40), transform: nil))
        let before = try #require(session.document)
        let undoCount = session.history.undoCount
        for rotation in CanvasRotation.allCases {
            session.rotateCanvas(rotation)
            #expect(session.history.undoCount == undoCount + 1)
            #expect(session.history.undoName == rotation.undoName)
            let after = try #require(session.document)
            session.undo()
            #expect(session.document == before)
            #expect(session.history.undoCount == undoCount)
            session.redo()
            #expect(session.document == after)
            session.undo()
        }
    }

    @Test func undoNamesFollowThePhotoshopMenu() {
        #expect(CanvasRotation.clockwise.undoName == "Rotate Canvas 90° Clockwise")
        #expect(CanvasRotation.counterclockwise.undoName == "Rotate Canvas 90° Counterclockwise")
        #expect(CanvasRotation.half.undoName == "Rotate Canvas 180°")
    }

    @Test func guidesSwapAxesOnQuarterTurnsAndKeepTheirContent() {
        let vertical = CanvasGuide(id: UUID(), axis: .vertical, position: 40)
        let horizontal = CanvasGuide(id: UUID(), axis: .horizontal, position: 30)
        let canvas = CGSize(width: 300, height: 200)
        // Clockwise: (x, y) -> (200 - y, x).
        let cw = [vertical, horizontal].map { $0.rotated(.clockwise, in: canvas) }
        #expect(cw[0].axis == .horizontal && cw[0].position == 40 && cw[0].id == vertical.id)
        #expect(cw[1].axis == .vertical && cw[1].position == 170 && cw[1].id == horizontal.id)
        // Counterclockwise: (x, y) -> (y, 300 - x).
        let ccw = [vertical, horizontal].map { $0.rotated(.counterclockwise, in: canvas) }
        #expect(ccw[0].axis == .horizontal && ccw[0].position == 260)
        #expect(ccw[1].axis == .vertical && ccw[1].position == 30)
        let half = [vertical, horizontal].map { $0.rotated(.half, in: canvas) }
        #expect(half[0].axis == .vertical && half[0].position == 260)
        #expect(half[1].axis == .horizontal && half[1].position == 170)
    }

    @Test func sessionGuidesTurnWithTheCanvas() throws {
        let session = EditorSession()
        session.createDocument(width: 300, height: 200)
        session.addGuide(CanvasGuide(id: UUID(), axis: .vertical, position: 40))
        session.addGuide(CanvasGuide(id: UUID(), axis: .horizontal, position: 30))
        session.rotateCanvas(.clockwise)
        let guides = try #require(session.document?.guides)
        #expect(guides.count == 2)
        #expect(guides.first { $0.axis == .horizontal }?.position == 40)
        #expect(guides.first { $0.axis == .vertical }?.position == 170)
    }

    @Test func theSelectionTurnsWithTheCanvas() throws {
        let session = EditorSession()
        session.createDocument(width: 300, height: 200)
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 10, y: 20, width: 30, height: 40), transform: nil),
            antialiased: false, feather: 3)
        session.rotateCanvas(.clockwise)
        var selection = try #require(session.document?.selection)
        // (10…40, 20…60) -> x 200 - y, y x.
        #expect(selection.path.boundingBoxOfPath == CGRect(x: 140, y: 10, width: 40, height: 30))
        #expect(!selection.antialiased && selection.feather == 3)
        session.rotateCanvas(.half)
        selection = try #require(session.document?.selection)
        #expect(selection.path.boundingBoxOfPath == CGRect(x: 20, y: 260, width: 40, height: 30))
        session.rotateCanvas(.counterclockwise)
        selection = try #require(session.document?.selection)
        // Net half turn of the original 300 × 200 canvas.
        #expect(selection.path.boundingBoxOfPath == CGRect(x: 260, y: 140, width: 30, height: 40))
    }

    @Test func aTurnedCanvasStillSavesAndReopensWithItsMasks() throws {
        let session = try session(CGSize(width: 37, height: 53))
        session.rotateCanvas(.clockwise)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.manifest.width == 53 && snapshot.manifest.height == 37)
        #expect(snapshot.manifest.layers.allSatisfy { $0.transform.isValid })
        #expect(snapshot.manifest.layers.first?.maskLinked == false)
    }
}
