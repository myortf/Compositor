import Testing
import AppKit
@testable import Compositor

/// Masks together with the other things a layer goes through: smart objects, duplicates, groups, merges, moves and
/// the document-size commands. The masked layer is a 160 × 100 red rectangle at (20, 50) whose mask, on the layer's
/// own grid rather than the document's, shows its left half only.
@MainActor
struct MaskLayerComboTests {
    typealias Stability = MaskBrushStabilityTests

    static func session(smartObject: Bool = false) throws -> EditorSession {
        let session = try Stability.session(Stability.placements[0], solidMask: false)
        let id = try #require(session.activeLayerID)
        let mask = try BrushRaster.context(width: 160, height: 100, mask: true)
        mask.setFillColor(gray: 0, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: 160, height: 100))
        mask.setFillColor(gray: 1, alpha: 1)
        mask.fill(CGRect(x: 0, y: 0, width: 80, height: 100))
        session.document?.layers[0].mask = LayerMask(asset: try LayerMask.asset(from: try #require(mask.makeImage())))
        session.selectLayerTarget(id, mask: false)
        if smartObject { session.convertToSmartObject() }
        return session
    }

    /// Whether the layer shows where the half mask says it should, the picture shifted by (dx, dy).
    static func expectHalfMasked(_ alpha: [[Int]], dx: Int = 0, dy: Int = 0, _ label: String) {
        for (x, y, shown) in [(40, 100, true), (90, 100, true), (110, 100, false), (170, 100, false), (60, 60, true), (60, 140, true),
                              (10, 100, false), (60, 30, false), (60, 170, false)] {
            let value = alpha[y + dy][x + dx]
            #expect(shown ? value == 255 : value == 0, "\(label): (\(x), \(y)) is \(value)")
        }
    }

    // MARK: 3. Mask with smart objects, duplicates, groups and merges

    @Test(arguments: [false, true]) func moveCarriesALinkedMaskAndAnUnlinkedOneStays(smartObject: Bool) async throws {
        let session = try Self.session(smartObject: smartObject)
        let id = try #require(session.activeLayerID)
        try Self.expectHalfMasked(await Stability.alphas(session), "start")
        session.nudgeLayer(dx: 10, dy: 20)
        try Self.expectHalfMasked(await Stability.alphas(session), dx: 10, dy: 20, "linked")
        session.undo()
        try Self.expectHalfMasked(await Stability.alphas(session), "undone")
        session.toggleMaskLink(id)
        session.nudgeLayer(dx: 30, dy: 0)
        // The layer now covers x 50…210, the mask still shows x 20…100: what's left is x 50…100.
        let alpha = try await Stability.alphas(session)
        #expect(alpha[100][60] == 255 && alpha[100][95] == 255 && alpha[100][30] == 0 && alpha[100][110] == 0 && alpha[100][150] == 0)
        session.undo()
        session.undo()
        try Self.expectHalfMasked(await Stability.alphas(session), "unlinked, then undone")
        #expect(session.activeLayer?.mask?.isLinked == true)
    }

    @Test(arguments: [false, true]) func aDuplicateKeepsTheMaskAndTheSmartObject(smartObject: Bool) async throws {
        let session = try Self.session(smartObject: smartObject)
        let id = try #require(session.activeLayerID)
        session.duplicateLayers([id])
        let copy = try #require(session.document?.layers.first { $0.name.hasSuffix("copy") })
        #expect(copy.mask == session.document?.layers.first { $0.id == id }?.mask)
        #expect((copy.liveSmartObject != nil) == smartObject)
        // Hidden original: the copy alone draws the same thing.
        session.document?.layers[0].isVisible = false
        try Self.expectHalfMasked(await Stability.alphas(session), "copy")
        // Moving the copy leaves the original's mask where it was.
        session.document?.layers[0].isVisible = true
        session.selectLayerTarget(copy.id, mask: false)
        session.nudgeLayer(dx: 0, dy: 40)
        let original = try #require(session.document?.layers.first { $0.id == id })
        #expect(original.mask?.placement == nil && original.transform.origin == CGPoint(x: 20, y: 50))
        let alpha = try await Stability.alphas(session)
        #expect(alpha[60][60] == 255 && alpha[180][60] == 255 && alpha[60][150] == 0 && alpha[180][150] == 0)
    }

    @Test(arguments: [false, true]) func groupingAndMergingKeepTheMask(smartObject: Bool) async throws {
        let session = try Self.session(smartObject: smartObject)
        let id = try #require(session.activeLayerID)
        session.groupSelectedLayers()
        let group = try #require(session.document?.layers.first { $0.isGroup })
        #expect(session.document?.layers.first { $0.id == id }?.mask != nil)
        try Self.expectHalfMasked(await Stability.alphas(session), "grouped")
        // A mask on the folder as well.
        session.selectLayerTarget(group.id, mask: false)
        session.addLayerMask(revealing: true)
        try Self.expectHalfMasked(await Stability.alphas(session), "folder mask")
        session.mergeLayers()
        let merged = try #require(session.activeLayer)
        #expect(!merged.isGroup && merged.mask == nil)
        try Self.expectHalfMasked(await Stability.alphas(session), "merged")
        session.undo()
        try Self.expectHalfMasked(await Stability.alphas(session), "merge undone")
        #expect(session.document?.layers.first { $0.id == id }?.mask != nil)
    }

    @Test func mergeDownBakesTheMaskIntoThePixels() async throws {
        let session = try Self.session()
        let id = try #require(session.activeLayerID)
        session.addBlankLayer()
        session.document?.layers.swapAt(0, 1)
        session.selectLayerTarget(id, mask: false)
        #expect(session.canMergeLayers)
        session.mergeLayers()
        let layer = try #require(session.activeLayer)
        #expect(layer.mask == nil)
        try Self.expectHalfMasked(await Stability.alphas(session), "merged down")
    }

    // MARK: 5. Invert, feather, disable, delete

    @Test func invertFeatherDisableAndDeleteAreEachOneUndoStep() async throws {
        let session = try Self.session()
        let id = try #require(session.activeLayerID)
        let original = try #require(session.activeLayer?.mask)
        session.selectLayerTarget(id, mask: true)
        await session.invertPixels()
        var alpha = try await Stability.alphas(session)
        #expect(alpha[100][40] == 0 && alpha[100][150] == 255 && alpha[10][10] == 0)
        session.undo()
        #expect(session.activeLayer?.mask == original)
        await session.featherMask(by: 10)
        alpha = try await Stability.alphas(session)
        #expect(alpha[100][30] == 255 && alpha[100][170] == 0 && (10...245).contains(alpha[100][100]))
        session.undo()
        #expect(session.activeLayer?.mask == original)
        session.toggleLayerMask()
        alpha = try await Stability.alphas(session)
        #expect(alpha[100][40] == 255 && alpha[100][150] == 255 && alpha[100][190] == 0)
        session.toggleLayerMask()
        try Self.expectHalfMasked(await Stability.alphas(session), "enabled again")
        session.deleteLayerMask()
        alpha = try await Stability.alphas(session)
        #expect(alpha[100][150] == 255 && !session.isMaskSelected)
        session.undo()
        #expect(session.activeLayer?.mask == original)
        try Self.expectHalfMasked(await Stability.alphas(session), "delete undone")
    }

    @Test func aDisabledMaskRefusesTheBrushClearly() async throws {
        let session = try Self.session()
        let id = try #require(session.activeLayerID)
        session.selectLayerTarget(id, mask: true)
        session.toggleLayerMask()
        session.selectTool(.brush)
        session.maskPaintWhite = false
        session.brushSettings = BrushSettings(diameter: 30, hardness: 1, opacity: 1)
        let before = try #require(session.activeLayer?.mask)
        session.beginBrush(at: CGPoint(x: 50, y: 100))
        #expect(session.brushError != nil)
        #expect(session.brushStroke == nil && session.activeLayer?.mask == before)
    }

    // MARK: 4. A mask whose grid differs from the document's, through document-size commands

    @Test(arguments: [1, 4, 8]) func canvasSizeKeepsTheMaskUnderTheLayer(anchor: Int) async throws {
        let session = try Self.session()
        let input = try #require(session.projectSnapshot())
        let options = CanvasSizeOptions(width: 260, height: 240, anchor: anchor)
        let offset = options.offset(fromWidth: 200, height: 200)
        let output = try await CanvasResizer.shared.resize(input, to: options)
        session.applyDocumentSize(output, actionName: "Canvas Size")
        let alpha = try await Stability.alphas(session)
        Self.expectHalfMasked(alpha, dx: Int(offset.x), dy: Int(offset.y), "anchor \(anchor)")
        session.undo()
        #expect(session.document?.width == 200)
        try Self.expectHalfMasked(await Stability.alphas(session), "undone")
    }

    @Test(arguments: [false, true]) func cropKeepsTheMaskUnderTheLayer(smartObject: Bool) async throws {
        let session = try Self.session(smartObject: smartObject)
        let input = try #require(session.projectSnapshot())
        // What Crop does: a smaller canvas, the content moved by the crop's origin.
        let options = CanvasSizeOptions(width: 100, height: 120, contentOffset: CGPoint(x: -50, y: -40))
        let output = try await CanvasResizer.shared.resize(input, to: options)
        session.applyDocumentSize(output, actionName: "Crop")
        let alpha = try await Stability.alphas(session)
        #expect(alpha.count == 120 && alpha[0].count == 100)
        // Layer x 20…180 becomes -30…130 and the mask shows -30…50; y 50…150 becomes 10…110.
        #expect(alpha[60][10] == 255 && alpha[60][45] == 255 && alpha[60][60] == 0 && alpha[5][10] == 0 && alpha[115][10] == 0)
        #expect(session.activeLayer?.mask != nil)
    }

    @Test(arguments: [1.0, 2.0, 0.5]) func imageSizeKeepsTheMaskUnderTheLayer(scale: Double) async throws {
        let session = try Self.session()
        let input = try #require(session.projectSnapshot())
        let size = Int(200 * scale)
        let output = try await ImageResizer.shared.resize(input, to: ImageSizeOptions(width: size, height: size, resolution: 72))
        session.applyImageSize(output)
        let alpha = try await Stability.alphas(session)
        let s = { (value: Int) in Int(Double(value) * scale) }
        for (x, y, shown) in [(40, 100, true), (90, 100, true), (112, 100, false), (170, 100, false), (60, 60, true), (60, 140, true), (10, 100, false), (60, 30, false)] {
            #expect(shown ? alpha[s(y)][s(x)] >= 250 : alpha[s(y)][s(x)] <= 5, "scale \(scale) (\(x), \(y)): \(alpha[s(y)][s(x)])")
        }
        let mask = try #require(session.activeLayer?.mask)
        #expect(LayerMask.isValid(mask.asset.image))
        guard scale != 1 else { return }
        session.undo()
        #expect(session.document?.width == 200)
        try Self.expectHalfMasked(await Stability.alphas(session), "undone")
    }

    @Test func anUnlinkedMaskSurvivesCanvasSize() async throws {
        let session = try Self.session()
        let id = try #require(session.activeLayerID)
        // Unlinked, the layer moves alone and the mask keeps its own placement.
        session.toggleMaskLink(id)
        session.nudgeLayer(dx: 0, dy: 20)
        let before = try await Stability.alphas(session)
        let output = try await CanvasResizer.shared.resize(try #require(session.projectSnapshot()), to: CanvasSizeOptions(width: 300, height: 300, anchor: 8))
        session.applyDocumentSize(output, actionName: "Canvas Size")
        let after = try await Stability.alphas(session)
        for y in stride(from: 0, to: 200, by: 7) { for x in stride(from: 0, to: 200, by: 7) {
            #expect(after[y + 100][x + 100] == before[y][x], "(\(x), \(y))")
        } }
    }

    @Test func canvasSizeKeepsWhatMakesALayerLive() async throws {
        let session = try Self.session(smartObject: true)
        var effects = LayerEffects()
        effects.stroke = StrokeEffect()
        session.document?.layers[0].effects = effects
        let input = try #require(session.projectSnapshot())
        let output = try await CanvasResizer.shared.resize(input, to: CanvasSizeOptions(width: 260, height: 240))
        session.applyDocumentSize(output, actionName: "Canvas Size")
        let layer = try #require(session.activeLayer)
        #expect(layer.liveSmartObject != nil, "Canvas Size turned the smart object into pixels")
        #expect(layer.effects == effects, "Canvas Size dropped the layer's effects")
        #expect(layer.mask != nil)
        session.undo()
        #expect(session.activeLayer?.liveSmartObject != nil && session.activeLayer?.effects == effects)
    }
}
