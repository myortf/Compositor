import AppKit
import Testing
@testable import Compositor

@MainActor
struct SharpenFilterTests {
    private static let sizes = [(300, 200), (200, 300), (37, 53)]

    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: image.width * image.height * 4))
    }

    /// Dark gray on the left half, light gray on the right, at the given alpha.
    private func edge(_ width: Int, _ height: Int, alpha: CGFloat = 1) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.35 * alpha, green: 0.35 * alpha, blue: 0.35 * alpha, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height))
        context.setFillColor(CGColor(srgbRed: 0.65 * alpha, green: 0.65 * alpha, blue: 0.65 * alpha, alpha: alpha))
        context.fill(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height))
        return try #require(context.makeImage())
    }

    private func flat(_ width: Int, _ height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.4, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try #require(context.makeImage())
    }

    private func run(_ kind: FilterKind, _ source: CGImage, _ change: (inout FilterSettings) -> Void) throws -> CGImage {
        var settings = FilterSettings()
        change(&settings)
        return try PixelFilter.run(FilterJob(kind: kind, image: source, settings: settings, scale: 1, selection: nil, mapping: .identity))
    }

    private func red(_ data: [UInt8], _ x: Int, _ y: Int, width: Int) -> Int { Int(data[(y * width + x) * 4]) }

    @Test(arguments: sizes) func unsharpMaskIncreasesEdgeContrast(width: Int, height: Int) throws {
        let source = try edge(width, height)
        let result = try run(.unsharpMask, source) { $0.sharpenAmount = 200; $0.sharpenRadius = 2 }
        #expect(result.width == width && result.height == height)
        let before = try pixels(source), after = try pixels(result)
        let y = height / 2, left = width / 2 - 1, right = width / 2
        let contrastBefore = red(before, right, y, width: width) - red(before, left, y, width: width)
        let contrastAfter = red(after, right, y, width: width) - red(after, left, y, width: width)
        #expect(contrastAfter > contrastBefore + 20)
        // Far from the edge nothing moves, and the layer's border is not treated as an edge.
        #expect(abs(red(after, 0, 0, width: width) - red(before, 0, 0, width: width)) <= 1)
        #expect(abs(red(after, width - 1, height - 1, width: width) - red(before, width - 1, height - 1, width: width)) <= 1)
    }

    @Test func amountZeroIsIdentity() throws {
        let source = try edge(64, 48)
        let result = try run(.unsharpMask, source) { $0.sharpenAmount = 0 }
        #expect(try pixels(result) == pixels(source))
    }

    @Test func thresholdKeepsSmallDifferencesUnchanged() throws {
        let source = try edge(64, 48)
        let result = try run(.unsharpMask, source) { $0.sharpenAmount = 200; $0.sharpenRadius = 2; $0.sharpenThreshold = 200 }
        #expect(try pixels(result) == pixels(source))
    }

    @Test func alphaIsPreserved() throws {
        let source = try edge(60, 40, alpha: 0.5)
        for kind in [FilterKind.unsharpMask, .highPass] {
            let result = try run(kind, source) { $0.sharpenAmount = 300; $0.sharpenRadius = 2; $0.highPassRadius = 2 }
            let before = try pixels(source), after = try pixels(result)
            #expect(stride(from: 3, to: after.count, by: 4).allSatisfy { after[$0] == before[$0] })
        }
    }

    @Test func clearPixelsStayClear() throws {
        let context = try BrushRaster.context(width: 40, height: 40, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 20, height: 20))
        let source = try #require(context.makeImage())
        for kind in [FilterKind.unsharpMask, .highPass] {
            let after = try pixels(try run(kind, source) { $0.sharpenAmount = 300; $0.highPassRadius = 3 })
            #expect(after[0...3].allSatisfy { $0 == 0 })
        }
    }

    @Test(arguments: sizes) func highPassOfFlatImageIsFlatGray(width: Int, height: Int) throws {
        let result = try run(.highPass, try flat(width, height)) { $0.highPassRadius = 5 }
        #expect(result.width == width && result.height == height)
        let data = try pixels(result)
        for index in stride(from: 0, to: data.count, by: 4) {
            #expect(abs(Int(data[index]) - 128) <= 1)
            #expect(abs(Int(data[index + 1]) - 128) <= 1)
            #expect(abs(Int(data[index + 2]) - 128) <= 1)
            #expect(data[index + 3] == 255)
        }
    }

    @Test func highPassPutsEdgesAroundMidGray() throws {
        let data = try pixels(try run(.highPass, try edge(80, 40)) { $0.highPassRadius = 3 })
        #expect(red(data, 39, 20, width: 80) < 118)
        #expect(red(data, 40, 20, width: 80) > 138)
        #expect(abs(red(data, 2, 20, width: 80) - 128) <= 2)
    }
}
