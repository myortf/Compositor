import AppKit
import Testing
import simd
@testable import Compositor

@MainActor
struct ColorTransferTests {
    private static let sizes = [(30, 20), (20, 30), (37, 53)]
    private static let methods = ColorTransferMethod.allCases

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }

    /// Builds an image from a function of position returning straight RGBA in 0...1, top row first.
    private func make(_ width: Int, _ height: Int, _ color: (Int, Int) -> (Double, Double, Double, Double)) throws -> CGImage {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b, a) = color(x, y)
                func level(_ v: Double) -> UInt8 { UInt8((min(1, max(0, v)) * a * 255).rounded()) }
                let i = (y * width + x) * 4
                bytes[i] = level(r); bytes[i + 1] = level(g)
                bytes[i + 2] = level(b); bytes[i + 3] = UInt8((a * 255).rounded())
            }
        }
        let provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func solid(_ width: Int, _ height: Int, _ r: Double, _ g: Double, _ b: Double) throws -> CGImage {
        try make(width, height) { _, _ in (r, g, b, 1) }
    }

    /// A smooth, varied picture: colors drift across and down.
    private func gradient(_ width: Int, _ height: Int, base: (Double, Double, Double) = (0.25, 0.45, 0.3)) throws -> CGImage {
        try make(width, height) { x, y in
            let u = Double(x) / Double(max(1, width - 1)), v = Double(y) / Double(max(1, height - 1))
            return (base.0 + 0.4 * u, base.1 + 0.3 * v, base.2 + 0.3 * (1 - u) * v, 1)
        }
    }

    private func run(_ source: CGImage, reference: CGImage?, _ change: (inout ColorTransferSettings) -> Void) throws -> CGImage {
        var settings = FilterSettings()
        change(&settings.colorTransfer)
        var job = FilterJob(kind: .colorTransfer, image: source, settings: settings, scale: 1, selection: nil, mapping: .identity)
        job.reference = reference
        return try PixelFilter.run(job)
    }

    /// Mean straight RGB over pixels that have alpha, in 0...1, within the rows and columns given.
    private func mean(_ image: CGImage, x: Range<Int>? = nil, y: Range<Int>? = nil) throws -> SIMD3<Double> {
        let data = try pixels(image)
        var sum = SIMD3<Double>.zero, count = 0.0
        for row in (y ?? 0..<image.height) {
            for column in (x ?? 0..<image.width) {
                let i = (row * image.width + column) * 4
                guard data[i + 3] > 0 else { continue }
                let scale = 255 / Double(data[i + 3])
                sum += SIMD3(Double(data[i]), Double(data[i + 1]), Double(data[i + 2])) * scale / 255
                count += 1
            }
        }
        return sum / max(1, count)
    }

    private func distance(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let d = a - b
        return (d.x * d.x + d.y * d.y + d.z * d.z).squareRoot()
    }

    // MARK: Color space

    @Test func labMatchesPublishedValuesAndRoundTrips() {
        let white = LabSpace.lab(red: 1, green: 1, blue: 1)
        #expect(abs(white.x - 100) < 0.05 && abs(white.y) < 0.05 && abs(white.z) < 0.05)
        let red = LabSpace.lab(red: 1, green: 0, blue: 0)
        #expect(abs(red.x - 53.24) < 0.1 && abs(red.y - 80.09) < 0.15 && abs(red.z - 67.20) < 0.15)
        for r in stride(from: 0, through: 255, by: 15) {
            for g in stride(from: 0, through: 255, by: 15) {
                for b in stride(from: 0, through: 255, by: 15) {
                    let lab = LabSpace.lab(red: LabSpace.linear[r], green: LabSpace.linear[g], blue: LabSpace.linear[b])
                    let back = LabSpace.srgb(lab)
                    #expect(abs(Double(back.x) * 255 - Double(r)) < 0.6 && abs(Double(back.y) * 255 - Double(g)) < 0.6
                            && abs(Double(back.z) * 255 - Double(b)) < 0.6)
                }
            }
        }
    }

    // MARK: Transfer

    @Test(arguments: methods, sizes) func identicalReferenceChangesAlmostNothing(method: ColorTransferMethod, size: (Int, Int)) throws {
        let source = try gradient(size.0, size.1)
        let result = try run(source, reference: source) { $0.method = method; $0.matchRegions = false }
        #expect(result.width == size.0 && result.height == size.1)
        let before = try pixels(source), after = try pixels(result)
        let worst = zip(before, after).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(worst <= 4, "\(method.rawValue) moved a pixel by \(worst) levels")
    }

    @Test(arguments: methods) func solidReferenceMovesTheMeanTowardItsColor(method: ColorTransferMethod) throws {
        let source = try gradient(60, 40)
        let target = SIMD3(0.85, 0.35, 0.15)
        let reference = try solid(16, 16, target.x, target.y, target.z)
        let before = try mean(source)
        let after = try mean(try run(source, reference: reference) { $0.method = method; $0.matchRegions = false })
        #expect(distance(after, target) < distance(before, target) * 0.3,
                "\(method.rawValue): \(distance(before, target)) -> \(distance(after, target))")
        let half = try mean(try run(source, reference: reference) { $0.method = method; $0.matchRegions = false; $0.strength = 50 })
        #expect(distance(half, target) < distance(before, target) && distance(half, target) > distance(after, target))
    }

    @Test(arguments: methods, sizes) func strengthZeroIsTheOriginal(method: ColorTransferMethod, size: (Int, Int)) throws {
        let source = try gradient(size.0, size.1)
        let reference = try gradient(size.1, size.0, base: (0.6, 0.2, 0.1))
        let result = try run(source, reference: reference) { $0.method = method; $0.strength = 0 }
        #expect(try pixels(result) == pixels(source))
    }

    @Test(arguments: methods, sizes) func alphaIsKept(method: ColorTransferMethod, size: (Int, Int)) throws {
        let source = try make(size.0, size.1) { x, y in
            (0.3 + 0.4 * Double(x) / Double(size.0), 0.5, 0.4, [0, 0.25, 0.6, 1][(x + y) % 4])
        }
        let reference = try gradient(20, 20, base: (0.7, 0.3, 0.2))
        let result = try run(source, reference: reference) { $0.method = method }
        let before = try pixels(source), after = try pixels(result)
        for i in stride(from: 3, to: before.count, by: 4) { #expect(before[i] == after[i]) }
        // Fully transparent pixels stay empty.
        for i in stride(from: 0, to: before.count, by: 4) where before[i + 3] == 0 { #expect(after[i] == 0 && after[i + 1] == 0 && after[i + 2] == 0) }
    }

    @Test(arguments: methods) func transparentPixelsDoNotCountInEitherImage(method: ColorTransferMethod) throws {
        let green = (0.2, 0.7, 0.3)
        let solidGreen = try solid(20, 20, green.0, green.1, green.2)
        let halfGreen = try make(20, 20) { x, _ in x < 10 ? (green.0, green.1, green.2, 1) : (0, 0, 0, 0) }
        let source = try gradient(40, 30)
        let full = try run(source, reference: solidGreen) { $0.method = method; $0.matchRegions = false }
        let half = try run(source, reference: halfGreen) { $0.method = method; $0.matchRegions = false }
        #expect(try pixels(full) == pixels(half))

        // And the source: its empty half is not part of what is measured.
        let opaque = try make(30, 30) { x, _ in (0.2 + 0.5 * Double(x) / 30, 0.4, 0.3, 1) }
        let padded = try make(60, 30) { x, _ in x < 30 ? (0.2 + 0.5 * Double(x) / 30, 0.4, 0.3, 1) : (0, 0, 0, 0) }
        let reference = try gradient(20, 20, base: (0.6, 0.25, 0.2))
        let a = try run(opaque, reference: reference) { $0.method = method; $0.matchRegions = false }
        let b = try run(padded, reference: reference) { $0.method = method; $0.matchRegions = false }
        let left = try pixels(a), right = try pixels(b)
        for y in 0..<30 { for x in 0..<30 {
            for c in 0..<4 { #expect(abs(Int(left[(y * 30 + x) * 4 + c]) - Int(right[(y * 60 + x) * 4 + c])) <= 2) }
        } }
    }

    @Test func mongeKantorovichMatchesTheReferenceCovariance() throws {
        let source = try gradient(64, 48, base: (0.2, 0.4, 0.3))
        let reference = try make(64, 48) { x, y in
            let u = Double(x) / 63, v = Double(y) / 47
            return (0.55 + 0.2 * v, 0.25 + 0.3 * u, 0.3 + 0.2 * u * v, 1)
        }
        let result = try run(source, reference: reference) { $0.method = .monge; $0.matchRegions = false }
        func moments(_ image: CGImage) throws -> Moments {
            let raster = try Raster.make(image, maxSide: 512)
            let field = LabField(raster)
            return Moments(field, field.alpha)
        }
        let made = try moments(result), wanted = try moments(reference)
        for c in 0..<3 {
            #expect(abs(made.mean[c] - wanted.mean[c]) < 1.5, "mean \(c)")
            #expect(abs(made.covariance[c * 4] - wanted.covariance[c * 4]) < 0.15 * wanted.covariance[c * 4] + 2, "variance \(c)")
        }
    }

    @Test(arguments: methods) func preserveLuminanceKeepsLightness(method: ColorTransferMethod) throws {
        let source = try gradient(40, 30)
        let reference = try gradient(30, 40, base: (0.7, 0.2, 0.15))
        let result = try run(source, reference: reference) { $0.method = method; $0.preserveLuminance = true; $0.matchRegions = false }
        let before = try pixels(source), after = try pixels(result)
        for i in stride(from: 0, to: before.count, by: 4) {
            let l0 = LabSpace.lab(fromPremultiplied: before[i], before[i + 1], before[i + 2], before[i + 3]).x
            let l1 = LabSpace.lab(fromPremultiplied: after[i], after[i + 1], after[i + 2], after[i + 3]).x
            #expect(abs(l0 - l1) < 2)
        }
        #expect(try mean(result) != mean(source))
    }

    // MARK: Regions

    /// The top half of any raster is sky, the bottom foliage.
    private struct HalvesSegmenter: RegionSegmenter {
        func candidates(for raster: Raster) -> [RegionLabel: [Float]] {
            let half = raster.height / 2
            return [.sky: (0..<raster.width * raster.height).map { $0 / raster.width < half ? 1 : 0 },
                    .foliage: (0..<raster.width * raster.height).map { $0 / raster.width >= half ? 1 : 0 }]
        }
    }

    private func bands(_ width: Int, _ height: Int, top: (Double, Double, Double), bottom: (Double, Double, Double)) throws -> CGImage {
        try make(width, height) { _, y in y < height / 2 ? (top.0, top.1, top.2, 1) : (bottom.0, bottom.1, bottom.2, 1) }
    }

    @Test(arguments: methods, [(60, 40), (40, 60), (37, 53)]) func matchingRegionsSendsEachBandToItsCounterpart(method: ColorTransferMethod, size: (Int, Int)) throws {
        let (w, h) = size
        let orange = SIMD3(0.95, 0.55, 0.15), purple = SIMD3(0.5, 0.2, 0.6)
        let source = try bands(w, h, top: (0.3, 0.5, 0.9), bottom: (0.25, 0.6, 0.25))
        let reference = try bands(w, h, top: (orange.x, orange.y, orange.z), bottom: (purple.x, purple.y, purple.z))
        var settings = ColorTransferSettings()
        settings.method = method
        let regional = try ColorTransfer.apply(source, reference: reference, settings: settings, segmenter: HalvesSegmenter())
        settings.matchRegions = false
        let global = try ColorTransfer.apply(source, reference: reference, settings: settings)
        let top = 0..<(h / 8 + 1), bottom = (h - h / 8 - 1)..<h
        let regionalTop = try mean(regional, y: top), regionalBottom = try mean(regional, y: bottom)
        #expect(distance(regionalTop, orange) < 0.08, "\(method.rawValue) top \(regionalTop)")
        #expect(distance(regionalBottom, purple) < 0.08, "\(method.rawValue) bottom \(regionalBottom)")
        let globalTop = try mean(global, y: top), globalBottom = try mean(global, y: bottom)
        #expect(distance(regionalTop, orange) < distance(globalTop, orange))
        #expect(distance(regionalBottom, purple) < distance(globalBottom, purple))
    }

    @Test func regionsBlendWithoutASeam() throws {
        // A source that changes smoothly, so any step in the result comes from the mix and not from the picture.
        let source = try make(60, 60) { _, y in
            let v = Double(y) / 59
            return (0.3 - 0.05 * v, 0.5 + 0.1 * v, 0.9 - 0.65 * v, 1)
        }
        let reference = try bands(60, 60, top: (0.95, 0.55, 0.15), bottom: (0.5, 0.2, 0.6))
        let result = try ColorTransfer.apply(source, reference: reference, settings: ColorTransferSettings(), segmenter: HalvesSegmenter())
        let data = try pixels(result)
        var step = 0
        for y in 1..<60 { step = max(step, abs(Int(data[(y * 60 + 30) * 4]) - Int(data[((y - 1) * 60 + 30) * 4]))) }
        let jump = abs(Int(data[(5 * 60 + 30) * 4]) - Int(data[(55 * 60 + 30) * 4]))
        #expect(step * 4 < jump, "largest step \(step) of a \(jump) level change: \((0..<60).map { data[($0 * 60 + 30) * 4] })")
    }

    private func field(_ width: Int, _ height: Int) throws -> LabField {
        LabField(try Raster.make(try gradient(width, height), maxSide: 512))
    }

    @Test func labelsMissingFromEitherImageFallBackToTheGlobalMapping() throws {
        let source = try field(40, 40), reference = try field(40, 40)
        let count = 40 * 40
        func region(_ rows: Range<Int>) -> [Float] { (0..<count).map { rows.contains($0 / 40) ? 1 : 0 } }
        let sourceRegions: [RegionLabel: [Float]] = [.sky: region(0..<20), .foliage: region(20..<40)]
        let referenceRegions: [RegionLabel: [Float]] = [.sky: region(0..<20), .rest: region(20..<40)]
        let settings = ColorTransferSettings()
        let paired = try #require(RegionTransfer.pair(source: source, sourceRegions: sourceRegions, reference: reference,
                                                      referenceRegions: referenceRegions, settings: settings))
        #expect(Set(paired.transforms.keys) == [.sky])
        // Nothing in common at all: no regional transfer.
        #expect(RegionTransfer.pair(source: source, sourceRegions: [.person: region(0..<20)], reference: reference,
                                    referenceRegions: [.sky: region(0..<20)], settings: settings) == nil)
        // Deep in the unpaired area, the mix is the global mapping.
        let global = try #require(ColorTransfer.transform(source, weights: source.alpha, reference: reference,
                                                          referenceWeights: reference.alpha, settings: settings))
        let lab = SIMD3<Float>(50, 10, -20)
        var scratch = [Float](repeating: 0, count: RegionLabel.allCases.count)
        let blended = paired.blended(lab, x: 20, y: 38, width: 40, height: 40, global: global, weights: &scratch)
        let expected = global.apply(lab)
        #expect(simd_length(blended - expected) < 0.01)
    }

    @Test func tinyRegionsAreNotPaired() throws {
        let source = try field(50, 50), reference = try field(50, 50)
        let count = 2500
        let small = (0..<count).map { $0 < 50 ? Float(1) : 0 }   // 2% is 50 pixels: this is exactly 1 row
        let big = (0..<count).map { $0 < 500 ? Float(1) : 0 }
        let tiny = (0..<count).map { $0 < 20 ? Float(1) : 0 }
        let settings = ColorTransferSettings()
        #expect(RegionTransfer.pair(source: source, sourceRegions: [.sky: big], reference: reference,
                                    referenceRegions: [.sky: tiny], settings: settings) == nil)
        #expect(RegionTransfer.pair(source: source, sourceRegions: [.sky: tiny], reference: reference,
                                    referenceRegions: [.sky: big], settings: settings) == nil)
        #expect(RegionTransfer.pair(source: source, sourceRegions: [.sky: big], reference: reference,
                                    referenceRegions: [.sky: small], settings: settings) != nil)
    }

    @Test func resolvePrefersMoreSpecificRegionsAndLeavesTheRestToRest() {
        let masks = RegionTransfer.resolve([.sky: [1, 1, 0, 0], .person: [0, 1, 1, 0]], count: 4)
        #expect(masks[.person] == [0, 1, 1, 0] && masks[.sky] == [1, 0, 0, 0] && masks[.rest] == [0, 0, 0, 1])
        #expect(masks[.foliage] == nil)
    }

    @Test(arguments: [(60, 40), (40, 60), (37, 53)]) func heuristicsFindSkyAndFoliage(size: (Int, Int)) throws {
        let (w, h) = size
        let scene = try bands(w, h, top: (0.35, 0.55, 0.95), bottom: (0.2, 0.6, 0.25))
        let found = HeuristicRegionSegmenter().candidates(for: try Raster.make(scene, maxSide: 512))
        let sky = try #require(found[.sky]), foliage = try #require(found[.foliage])
        #expect(sky[1 * w + w / 2] == 1 && sky[(h - 2) * w + w / 2] == 0)
        #expect(foliage[(h - 2) * w + w / 2] == 1 && foliage[1 * w + w / 2] == 0)
        // An orange top is not sky, and blue at the bottom of the frame is not either.
        let sunset = try bands(w, h, top: (0.95, 0.55, 0.15), bottom: (0.5, 0.2, 0.6))
        let none = HeuristicRegionSegmenter().candidates(for: try Raster.make(sunset, maxSide: 512))
        #expect(none[.sky] == nil && none[.foliage] == nil)
        let lake = try bands(w, h, top: (0.5, 0.3, 0.3), bottom: (0.3, 0.5, 0.9))
        #expect(HeuristicRegionSegmenter().candidates(for: try Raster.make(lake, maxSide: 512))[.sky] == nil)
    }

    @Test func aTexturedBlueAreaIsNotSky() throws {
        let noisy = try make(40, 40) { x, y in (x + y) % 2 == 0 ? (0.2, 0.3, 0.95, 1) : (0.7, 0.8, 1, 1) }
        #expect(HeuristicRegionSegmenter().candidates(for: try Raster.make(noisy, maxSide: 512))[.sky] == nil)
    }

    @Test func visionFindingNothingIsNotAnError() throws {
        let scene = try bands(48, 32, top: (0.35, 0.55, 0.95), bottom: (0.2, 0.6, 0.25))
        _ = VisionRegionSegmenter().candidates(for: try Raster.make(scene, maxSide: 512))
        let result = try run(scene, reference: scene) { $0.matchRegions = true }
        #expect(result.width == 48 && result.height == 32)
    }

    // MARK: Undo

    @Test func colorTransferIsOneUndoStepAndDoesNothingWithoutAReference() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        let image = try gradient(40, 30)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        session.beginFilter(.colorTransfer)
        #expect(session.filterEdit != nil)
        let count = session.history.undoCount
        await session.commitFilter()
        #expect(session.filterEdit == nil && session.history.undoCount == count)

        session.beginFilter(.colorTransfer)
        let reference = try solid(20, 20, 0.9, 0.3, 0.1)
        session.filterEdit?.colorReference = try ColorReference(ImportedImage(image: reference, thumbnail: reference, name: "Warm"))
        var settings = session.filterEdit?.settings ?? FilterSettings()
        settings.colorTransfer.matchRegions = false
        settings.colorTransfer.asNewLayer = false
        session.updateFilter(settings, preview: true)
        await session.commitFilter()
        #expect(session.filterEdit == nil && session.history.undoCount == count + 1)
        let result = try #require(session.activeLayer?.asset?.image)
        #expect(distance(try mean(result), SIMD3(0.9, 0.3, 0.1)) < distance(try mean(image), SIMD3(0.9, 0.3, 0.1)))
    }

    @Test func otherLayersOfTheDocumentCanBeTheReference() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        let a = try gradient(40, 30), b = try solid(40, 30, 0.9, 0.3, 0.1)
        session.insert(ImportedImage(image: a, thumbnail: a, name: "Photo"))
        session.insert(ImportedImage(image: b, thumbnail: b, name: "Warm"))
        session.beginFilter(.colorTransfer)
        #expect(session.colorReferenceLayers.map(\.name).contains("Photo"))
        #expect(!session.colorReferenceLayers.contains { $0.id == session.activeLayer?.id })
    }

    // MARK: Result as new layer

    private func transferred(size: (Int, Int), newLayer: Bool, selection: DocumentSelection? = nil, mask: Bool = false,
                             transform: ((inout LayerTransform) -> Void)? = nil)
        async throws -> (session: EditorSession, source: CGImage, originalID: UUID, undoCount: Int) {
        let session = EditorSession()
        session.createDocument(width: size.0, height: size.1)
        let image = try gradient(size.0, size.1)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Photo"))
        let originalID = try #require(session.activeLayerID)
        if mask {
            session.addLayerMask()
            session.activeLayerID = originalID
            session.isMaskSelected = false
        }
        if let transform, let index = session.document?.layers.firstIndex(where: { $0.id == originalID }) {
            transform(&session.document!.layers[index].transform)
        }
        session.document?.selection = selection
        session.beginFilter(.colorTransfer)
        let reference = try solid(20, 20, 0.9, 0.3, 0.1)
        session.filterEdit?.colorReference = try ColorReference(ImportedImage(image: reference, thumbnail: reference, name: "Warm"))
        var settings = session.filterEdit?.settings ?? FilterSettings()
        settings.colorTransfer.matchRegions = false
        settings.colorTransfer.asNewLayer = newLayer
        session.updateFilter(settings, preview: true)
        let count = session.history.undoCount
        await session.commitFilter()
        return (session, image, originalID, count)
    }

    @Test(arguments: sizes) func resultAsNewLayerLeavesTheOriginalAndAddsOneAbove(size: (Int, Int)) async throws {
        let before = try await transferred(size: size, newLayer: false)
        let expected = try pixels(try #require(before.session.activeLayer?.asset?.image))
        let (session, source, originalID, count) = try await transferred(size: size, newLayer: true)
        let layers = try #require(session.document?.layers)
        #expect(layers.count == 2 && session.history.undoCount == count + 1)
        let original = try #require(layers.first { $0.id == originalID })
        #expect(layers.firstIndex { $0.id == originalID } == 0)
        #expect(original.asset?.image === source && original.isVisible)
        let made = layers[1]
        #expect(session.activeLayerID == made.id)
        #expect(made.name == "Photo – Color Transfer" && made.opacity == 1 && made.blendMode == .normal)
        #expect(made.transform == original.transform)
        let result = try pixels(try #require(made.asset?.image))
        #expect(result == expected)
        #expect(result != (try pixels(source)))
        session.undo()
        #expect(session.document?.layers.count == 1 && session.activeLayerID == originalID)
    }

    @Test func withTheCheckboxOffTheActiveLayerIsReplaced() async throws {
        let (session, source, originalID, count) = try await transferred(size: (30, 20), newLayer: false)
        #expect(session.document?.layers.count == 1 && session.activeLayerID == originalID)
        #expect(session.history.undoCount == count + 1)
        #expect(session.activeLayer?.asset?.image !== source)
    }

    @Test func newLayerKeepsScaleRotationAndFlips() async throws {
        let (session, _, originalID, _) = try await transferred(size: (37, 53), newLayer: true) {
            $0.rotation = 30; $0.flipX = true; $0.size = CGSize(width: $0.size.width * 0.5, height: $0.size.height * 0.5)
        }
        let layers = try #require(session.document?.layers)
        let original = try #require(layers.first { $0.id == originalID })
        #expect(layers.count == 2 && layers[1].transform == original.transform && original.transform.rotation == 30)
    }

    @Test func aSelectionColorsOnlyTheSelectedArea() async throws {
        let selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 15, height: 20), transform: nil), antialiased: false)
        let (session, _, _, _) = try await transferred(size: (30, 20), newLayer: true, selection: selection)
        let made = try pixels(try #require(session.activeLayer?.asset?.image))
        func alpha(_ x: Int, _ y: Int) -> UInt8 { made[(y * 30 + x) * 4 + 3] }
        #expect(alpha(5, 10) == 255)
        #expect(alpha(25, 10) == 0)
        #expect(session.document?.selection != nil)
    }

    @Test func theSourceLayersMaskIsCopiedOver() async throws {
        let (session, _, originalID, _) = try await transferred(size: (20, 30), newLayer: true, mask: true)
        let layers = try #require(session.document?.layers)
        let original = try #require(layers.first { $0.id == originalID })
        #expect(original.mask != nil && layers.count == 2 && layers[1].mask == original.mask)
    }
}
