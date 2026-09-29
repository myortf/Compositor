import Testing
import AppKit
@testable import Compositor

@MainActor
struct MaskBrushStabilityTests {
    struct Placement: CustomTestStringConvertible, Sendable {
        let name: String
        let pixels: (Int, Int)
        let transform: LayerTransform
        /// Whether one layer pixel is at least a document pixel, so a soft edge can be judged pixel by pixel.
        let fine: Bool
        var testDescription: String { name }
    }
    static let placements: [Placement] = [
        Placement(name: "plain", pixels: (160, 100), transform: LayerTransform(origin: CGPoint(x: 20, y: 50), size: CGSize(width: 160, height: 100)), fine: true),
        Placement(name: "scaled down", pixels: (320, 200), transform: LayerTransform(origin: CGPoint(x: 20, y: 50), size: CGSize(width: 160, height: 100)), fine: true),
        Placement(name: "scaled up", pixels: (80, 50), transform: LayerTransform(origin: CGPoint(x: 20, y: 50), size: CGSize(width: 160, height: 100)), fine: false),
        Placement(name: "flipped", pixels: (160, 100), transform: LayerTransform(origin: CGPoint(x: 20, y: 50), size: CGSize(width: 160, height: 100), flipX: true, flipY: true), fine: true),
        Placement(name: "rotated 90", pixels: (160, 100), transform: LayerTransform(origin: CGPoint(x: 20, y: 50), size: CGSize(width: 160, height: 100), rotation: 90), fine: true),
        Placement(name: "rotated 37", pixels: (160, 100), transform: LayerTransform(origin: CGPoint(x: 20, y: 50), size: CGSize(width: 160, height: 100), rotation: 37), fine: true),
        Placement(name: "scaled, rotated, flipped", pixels: (200, 125), transform: LayerTransform(origin: CGPoint(x: 20, y: 50), size: CGSize(width: 160, height: 100), rotation: 30, flipX: true), fine: true),
    ]

    /// A 200 × 200 document with one opaque red layer placed as `placement` says and a mask (all white, or a
    /// full-resolution white one), with the mask selected and the brush set up to paint black on it.
    static func session(_ placement: Placement, solidMask: Bool = true, diameter: CGFloat = 60, hardness: CGFloat = 1, opacity: CGFloat = 1) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 200, height: 200)
        let (w, h) = placement.pixels
        let context = try BrushRaster.context(width: w, height: h, mask: false)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let image = try #require(context.makeImage())
        var layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Layer"), origin: .zero)
        layer.transform = placement.transform
        session.document?.layers.append(layer)
        session.activeLayerID = layer.id
        session.selectedLayerIDs = [layer.id]
        if solidMask { session.addLayerMask(revealing: true) } else {
            let mask = try BrushRaster.context(width: w, height: h, mask: true)
            mask.setFillColor(gray: 1, alpha: 1)
            mask.fill(CGRect(x: 0, y: 0, width: w, height: h))
            session.document?.layers[0].mask = LayerMask(asset: try LayerMask.asset(from: try #require(mask.makeImage())))
        }
        session.selectLayerTarget(layer.id, mask: true)
        session.selectTool(.brush)
        session.maskPaintWhite = false
        session.brushSettings = BrushSettings(diameter: diameter, hardness: hardness, opacity: opacity)
        return session
    }

    static func stroke(_ session: EditorSession, _ points: [CGPoint]) {
        session.beginBrush(at: points[0])
        for point in points.dropFirst() { session.continueBrush(at: point) }
        #expect(session.finishBrushImmediately())
    }

    /// The layer's alpha over the whole document: opaque red times its mask.
    static func alphas(_ session: EditorSession) async throws -> [[Int]] {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        return try alphas(of: image)
    }
    static func alphas(of image: CGImage) throws -> [[Int]] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).map { y in (0..<image.width).map { x in Int(bytes[(y * image.width + x) * 4 + 3]) } }
    }
    static func maskBytes(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: true, context: context)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<image.height).flatMap { y in (0..<image.width).map { data[y * context.bytesPerRow + $0] } }
    }

    // MARK: 1. Where a mask stroke lands, and how soft it is

    @Test(arguments: placements, [0.0, 0.5, 1.0] as [CGFloat])
    func aDabLandsUnderTheCursorWithASmoothEdge(placement: Placement, hardness: CGFloat) async throws {
        for solid in [true, false] {
            let session = try Self.session(placement, solidMask: solid, diameter: 60, hardness: hardness)
            let clean = try await Self.alphas(session)
            Self.stroke(session, [CGPoint(x: 100, y: 100)])
            let alpha = try await Self.alphas(session)
            // Where the layer isn't painted it shows in full; the centroid of what was hidden is the dab's center.
            var weight = 0.0, sumX = 0.0, sumY = 0.0
            for y in 0..<200 { for x in 0..<200 where alpha[y][x] < 255 {
                let hidden = Double(255 - alpha[y][x]) / 255
                weight += hidden; sumX += hidden * (Double(x) + 0.5); sumY += hidden * (Double(y) + 0.5)
            } }
            #expect(weight > 30, "\(placement.name) hardness \(hardness) solid \(solid): the dab left no mark")
            #expect(abs(sumX / weight - 100) < 1.5 && abs(sumY / weight - 100) < 1.5,
                    "\(placement.name) hardness \(hardness) solid \(solid): centroid \(sumX / weight), \(sumY / weight)")
            #expect(alpha[100][100] < 8, "\(placement.name) hardness \(hardness): center \(alpha[100][100])")
            #expect(alpha[100][160] == clean[100][160] && alpha[100][40] == clean[100][40] && alpha[60][100] == clean[60][100] && alpha[140][100] == clean[140][100],
                    "\(placement.name) hardness \(hardness): paint beyond the brush's radius")
            guard placement.fine else { continue }
            // Along both axes: a smooth ramp, no steps, symmetric about the cursor.
            let allowed = hardness >= 1 ? 255 : Int(14 / max(0.25, 1 - hardness)) + 6
            let tolerance = placement.transform.rotation.truncatingRemainder(dividingBy: 90) == 0 ? 10 : 30
            for horizontal in [true, false] {
                func value(_ offset: Int) -> Int { horizontal ? alpha[100][100 + offset] : alpha[100 + offset][100] }
                var previous = value(0)
                var stepUp = 0
                for k in 1...36 {
                    let current = value(k)
                    #expect(current >= previous - tolerance, "\(placement.name) h\(hardness) k\(k): not monotonic \(previous) -> \(current)")
                    stepUp = max(stepUp, current - previous)
                    previous = current
                }
                if hardness < 1 {
                    #expect(stepUp <= allowed + (tolerance > 10 ? 30 : 0), "\(placement.name) h\(hardness) \(horizontal): step \(stepUp) of \(allowed) allowed")
                } else {
                    let edge = (0...36).filter { (10...245).contains(value($0)) }.count
                    #expect(edge <= 3, "\(placement.name) hard edge is \(edge) pixels wide")
                }
                for k in 0..<34 {
                    let a = value(k), b = horizontal ? alpha[100][99 - k] : alpha[99 - k][100]
                    // A hard edge may fall on either side of a pixel boundary.
                    #expect(abs(a - b) <= tolerance || hardness >= 1 && abs(k - 30) <= 1,
                            "\(placement.name) h\(hardness) k\(k): asymmetric \(a) vs \(b)")
                }
            }
        }
    }

    @Test(arguments: placements, [0.0, 1.0] as [CGFloat])
    func opacityCapsAMaskStroke(placement: Placement, hardness: CGFloat) async throws {
        let session = try Self.session(placement, diameter: 50, hardness: hardness, opacity: 0.5)
        let clean = try await Self.alphas(session)
        Self.stroke(session, [CGPoint(x: 70, y: 100), CGPoint(x: 130, y: 100)])
        let alpha = try await Self.alphas(session)
        for x in [70, 85, 100, 115, 130] { #expect(abs(alpha[100][x] - 128) <= 6, "\(placement.name) x \(x): \(alpha[100][x])") }
        #expect(alpha[100][170] == clean[100][170] && alpha[20][100] == clean[20][100])
    }

    @Test(arguments: [1.0, 3.0, 10.0, 199.0, 400.0] as [CGFloat])
    func brushSizesFromOnePixelToBiggerThanTheLayer(diameter: CGFloat) async throws {
        let placement = Self.placements[0]
        for hardness: CGFloat in [0, 1] {
            let session = try Self.session(placement, diameter: diameter, hardness: hardness)
            let clean = try await Self.alphas(session)
            Self.stroke(session, [CGPoint(x: 100, y: 100)])
            let alpha = try await Self.alphas(session)
            let hidden = zip(clean.joined(), alpha.joined()).reduce(0) { $0 + Double($1.0 - $1.1) / 255 }
            if diameter == 1 && hardness == 1 { #expect(hidden > 0.5 && hidden < 2, "a one pixel brush hid \(hidden) pixels") }
            if diameter >= 10 { #expect(alpha[100][100] < 20, "diameter \(diameter) hardness \(hardness): center \(alpha[100][100])") }
            if diameter <= 10 { #expect(alpha[100][150] == 255 && alpha[60][100] == 255) }
            let mask = try #require(session.activeLayer?.mask)
            #expect(LayerMask.isValid(mask.asset.image))
        }
    }

    @Test func aStrokePastTheLayersEdgeGrowsTheMaskWithoutMovingIt() async throws {
        // The mask is painted beyond the layer, on the canvas (as Photoshop does), and stays under the cursor.
        for placement in [Self.placements[0], Self.placements[5]] {
            let session = try Self.session(placement, solidMask: false, diameter: 40, hardness: 1)
            let before = try await Self.alphas(session)
            Self.stroke(session, [CGPoint(x: 30, y: 100), CGPoint(x: 5, y: 100)])
            let after = try await Self.alphas(session)
            for x in [10, 25, 30] where placement.transform.contains(CGPoint(x: Double(x) + 0.5, y: 100.5)) {
                #expect(after[100][x] < 20, "\(placement.name) x \(x): \(after[100][x])")
            }
            // Nowhere else changed.
            #expect(after[100][150] == before[100][150] && after[20][100] == before[20][100] && after[190][190] == before[190][190])
        }
    }

    // MARK: 2. Undo and redo of a mask stroke are exact

    @Test(arguments: placements, [0.0, 0.5, 1.0] as [CGFloat])
    func undoAndRedoOfAMaskStrokeReturnExactPixels(placement: Placement, hardness: CGFloat) async throws {
        for solid in [true, false] {
            let session = try Self.session(placement, solidMask: solid, diameter: 50, hardness: hardness, opacity: 0.8)
            let original = try #require(session.activeLayer?.mask)
            let clean = try await Self.alphas(session)
            Self.stroke(session, [CGPoint(x: 60, y: 90), CGPoint(x: 100, y: 110), CGPoint(x: 140, y: 100)])
            let painted = try await Self.alphas(session)
            #expect(painted != clean)
            let paintedMask = try #require(session.activeLayer?.mask)
            let paintedBytes = try Self.maskBytes(paintedMask.asset.image)
            session.undo()
            #expect(try await Self.alphas(session) == clean)
            #expect(session.activeLayer?.mask == original)
            session.redo()
            #expect(try await Self.alphas(session) == painted)
            #expect(try Self.maskBytes(try #require(session.activeLayer?.mask).asset.image) == paintedBytes)
            // A second stroke, then everything back and forth again.
            Self.stroke(session, [CGPoint(x: 100, y: 60), CGPoint(x: 100, y: 140)])
            let twice = try await Self.alphas(session)
            session.undo(); session.undo()
            #expect(try await Self.alphas(session) == clean)
            session.redo(); session.redo()
            #expect(try await Self.alphas(session) == twice)
        }
    }

    // MARK: 6. Painting on a smart object

    @Test func aBrushStrokeOnASmartObjectRasterizesItAndKeepsTheMask() async throws {
        let session = try Self.session(Self.placements[0], diameter: 30, hardness: 1)
        session.selectLayerTarget(try #require(session.activeLayerID), mask: false)
        session.convertToSmartObject()
        #expect(session.activeLayer?.liveSmartObject != nil)
        session.selectLayerTarget(try #require(session.activeLayerID), mask: true)
        Self.stroke(session, [CGPoint(x: 100, y: 100)])
        let masked = try await Self.alphas(session)
        #expect(masked[100][100] < 8)
        // Now paint the smart object's pixels.
        session.selectLayerTarget(try #require(session.activeLayerID), mask: false)
        session.brushSettings.red = 0; session.brushSettings.green = 1
        session.maskPaintWhite = true
        let before = try #require(session.document)
        session.beginBrush(at: CGPoint(x: 50, y: 100))
        session.continueBrush(at: CGPoint(x: 60, y: 100))
        #expect(session.finishBrushImmediately())
        let layer = try #require(session.activeLayer)
        if layer.liveSmartObject != nil {
            // Refused clearly: nothing changed.
            #expect(session.document == before)
            #expect(session.brushError != nil)
        } else {
            #expect(layer.mask != nil, "the mask survives rasterizing")
            #expect(layer.mask?.asset.image === before.layers[0].mask?.asset.image)
            let alpha = try await Self.alphas(session)
            #expect(alpha[100][100] == masked[100][100])
            #expect(alpha[100][55] == 255)
            session.undo()
            #expect(session.document == before)
            #expect(session.activeLayer?.liveSmartObject != nil)
        }
    }

    @Test func eraserOnAMaskedLayerAndOnAMaskAreDifferentThings() async throws {
        let session = try Self.session(Self.placements[0], diameter: 30, hardness: 1)
        // With the mask targeted the eraser tool paints the mask like the brush would; it never punches through pixels.
        session.brushMode = .erase
        let pixelsBefore = try #require(session.activeLayer?.asset?.image)
        Self.stroke(session, [CGPoint(x: 100, y: 100)])
        #expect(session.activeLayer?.asset?.image === pixelsBefore)
        let alpha = try await Self.alphas(session)
        #expect(alpha[100][100] < 8)
        // On the pixels it erases them, the mask untouched.
        session.selectLayerTarget(try #require(session.activeLayerID), mask: false)
        let maskBefore = try #require(session.activeLayer?.mask)
        Self.stroke(session, [CGPoint(x: 60, y: 100)])
        #expect(session.activeLayer?.mask == maskBefore)
        let erased = try await Self.alphas(session)
        #expect(erased[100][60] < 8 && erased[100][100] == alpha[100][100])
    }
}
