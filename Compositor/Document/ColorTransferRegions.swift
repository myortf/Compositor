import CoreGraphics
import CoreVideo
import Foundation
import Vision

/// The kinds of area Color Transfer matches with their counterpart in the other image, most specific first.
nonisolated enum RegionLabel: Int, CaseIterable, Sendable {
    case person, subject, sky, foliage, rest
}

/// Finds where the regions are in a raster. Each mask is 0...1 over the raster's pixels; masks may overlap, and a label
/// with nothing to show is left out. This is the seam a learned correspondence map would plug into.
nonisolated protocol RegionSegmenter: Sendable {
    func candidates(for raster: Raster) -> [RegionLabel: [Float]]
}

/// Apple's person and foreground-subject masks, then sky and foliage worked out from the pixels themselves.
nonisolated struct DefaultRegionSegmenter: RegionSegmenter {
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var entries: [(image: CGImage, size: Int, masks: [RegionLabel: [Float]])] = []
    }
    private static let cache = Cache()

    func candidates(for raster: Raster) -> [RegionLabel: [Float]] {
        let cache = Self.cache
        if let origin = raster.origin {
            cache.lock.lock()
            let hit = cache.entries.first { $0.image === origin && $0.size == raster.width * raster.height }
            cache.lock.unlock()
            if let hit { return hit.masks }
        }
        var masks = VisionRegionSegmenter().candidates(for: raster)
        for (label, mask) in HeuristicRegionSegmenter().candidates(for: raster) where masks[label] == nil { masks[label] = mask }
        if let origin = raster.origin {
            cache.lock.lock()
            cache.entries.append((origin, raster.width * raster.height, masks))
            if cache.entries.count > 3 { cache.entries.removeFirst() }
            cache.lock.unlock()
        }
        return masks
    }
}

/// Vision's masks. Anything Vision cannot find, or fails on, is a region that is not there.
nonisolated struct VisionRegionSegmenter: RegionSegmenter {
    func candidates(for raster: Raster) -> [RegionLabel: [Float]] {
        guard let image = raster.cgImage() else { return [:] }
        var result: [RegionLabel: [Float]] = [:]
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        let person = VNGeneratePersonSegmentationRequest()
        person.qualityLevel = .balanced
        person.outputPixelFormat = kCVPixelFormatType_OneComponent8
        if (try? handler.perform([person])) != nil, let buffer = person.results?.first?.pixelBuffer,
           let mask = Self.mask(buffer, width: raster.width, height: raster.height) {
            result[.person] = mask
        }
        let subject = VNGenerateForegroundInstanceMaskRequest()
        if (try? handler.perform([subject])) != nil, let observation = subject.results?.first, !observation.allInstances.isEmpty,
           let buffer = try? observation.generateScaledMaskForImage(forInstances: observation.allInstances, from: handler),
           let mask = Self.mask(buffer, width: raster.width, height: raster.height) {
            result[.subject] = mask
        }
        return result
    }

    /// A one-channel pixel buffer resampled (nearest) to `width` by `height` as 0...1.
    static func mask(_ buffer: CVPixelBuffer, width: Int, height: Int) -> [Float]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        guard format == kCVPixelFormatType_OneComponent8 || format == kCVPixelFormatType_OneComponent32Float else { return nil }
        var result = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let row = base + min(h - 1, y * h / height) * stride
            for x in 0..<width {
                let column = min(w - 1, x * w / width)
                result[y * width + x] = format == kCVPixelFormatType_OneComponent8
                    ? Float(row.load(fromByteOffset: column, as: UInt8.self)) / 255
                    : row.load(fromByteOffset: column * 4, as: Float.self)
            }
        }
        return result
    }
}

/// Sky and foliage from color and texture alone.
/// - Sky: blue, or bright and nearly colorless (cloud), smooth, in the upper part of the frame, and joined to the top
///   edge from above.
/// - Foliage: green hue of medium saturation.
nonisolated struct HeuristicRegionSegmenter: RegionSegmenter {
    /// How far down the frame sky is looked for, as a share of its height.
    static let skyDepth = 0.65
    static let smoothness: Float = 0.05

    func candidates(for raster: Raster) -> [RegionLabel: [Float]] {
        let width = raster.width, height = raster.height, count = width * height
        var luma = [Float](repeating: 0, count: count)
        var blue = [Bool](repeating: false, count: count)
        var foliage = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let a = raster.bytes[i * 4 + 3]
            guard a >= 128 else { continue }
            let scale = 255 / Float(a)
            let r = min(1, Float(raster.bytes[i * 4]) * scale / 255), g = min(1, Float(raster.bytes[i * 4 + 1]) * scale / 255)
            let b = min(1, Float(raster.bytes[i * 4 + 2]) * scale / 255)
            luma[i] = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let (hue, saturation, value) = Self.hsv(r, g, b)
            blue[i] = (hue >= 185 && hue <= 265 && saturation > 0.12 && value > 0.3) || (value > 0.8 && saturation < 0.15)
            if hue >= 65 && hue <= 170 && saturation >= 0.18 && saturation <= 0.9 && value >= 0.1 { foliage[i] = 1 }
        }
        let radius = 2
        let mean = RegionTransfer.boxBlur(luma, width, height, radius: radius, passes: 1)
        let meanSquare = RegionTransfer.boxBlur(luma.map { $0 * $0 }, width, height, radius: radius, passes: 1)
        var sky = [Float](repeating: 0, count: count)
        let limit = max(1, Int(Double(height) * Self.skyDepth))
        for x in 0..<width {
            for y in 0..<limit {
                let i = y * width + x
                let deviation = max(0, meanSquare[i] - mean[i] * mean[i]).squareRoot()
                guard blue[i], deviation < Self.smoothness else { break }
                sky[i] = 1
            }
        }
        var result: [RegionLabel: [Float]] = [:]
        if sky.contains(where: { $0 > 0 }) { result[.sky] = sky }
        if foliage.contains(where: { $0 > 0 }) { result[.foliage] = foliage }
        return result
    }

    /// Hue in degrees, saturation and value.
    static func hsv(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
        let high = max(r, g, b), low = min(r, g, b), delta = high - low
        guard delta > 0 else { return (0, 0, high) }
        var hue: Float
        if high == r { hue = (g - b) / delta } else if high == g { hue = 2 + (b - r) / delta } else { hue = 4 + (r - g) / delta }
        hue *= 60
        if hue < 0 { hue += 360 }
        return (hue, delta / high, high)
    }
}

/// The per-region mappings of one transfer and the soft masks that mix them.
nonisolated struct RegionTransfer: Sendable {
    /// Smaller than this share of the image's opaque pixels, in either image, a region is left to the global mapping.
    static let minimumShare: Float = 0.02

    let width: Int
    let height: Int
    var transforms: [RegionLabel: LabTransform] = [:]
    /// Normalized soft masks (mixing weights) on the small grid, for the labels in `transforms`.
    var weights: [RegionLabel: [Float]] = [:]

    /// Masks made disjoint by priority, with every pixel no other region claims going to `rest`.
    static func resolve(_ candidates: [RegionLabel: [Float]], count: Int) -> [RegionLabel: [Float]] {
        var taken = [Bool](repeating: false, count: count)
        var result: [RegionLabel: [Float]] = [:]
        for label in RegionLabel.allCases where label != .rest {
            guard let mask = candidates[label], mask.count == count else { continue }
            var own = [Float](repeating: 0, count: count)
            var any = false
            for i in 0..<count where !taken[i] && mask[i] > 0.5 { own[i] = 1; taken[i] = true; any = true }
            if any { result[label] = own }
        }
        result[.rest] = (0..<count).map { taken[$0] ? 0 : 1 }
        return result
    }

    /// Pairs the regions found in both images, or nil when none pairs.
    static func make(sourceRaster: Raster, source: LabField, referenceRaster: Raster, reference: LabField,
                     settings: ColorTransferSettings, segmenter: RegionSegmenter) -> RegionTransfer? {
        let sourceRegions = resolve(segmenter.candidates(for: sourceRaster), count: source.alpha.count)
        let referenceRegions = resolve(segmenter.candidates(for: referenceRaster), count: reference.alpha.count)
        return pair(source: source, sourceRegions: sourceRegions, reference: reference, referenceRegions: referenceRegions,
                    settings: settings)
    }

    /// The pairing and blending step, on masks that are already made (the part that does not depend on Vision).
    static func pair(source: LabField, sourceRegions: [RegionLabel: [Float]], reference: LabField,
                     referenceRegions: [RegionLabel: [Float]], settings: ColorTransferSettings) -> RegionTransfer? {
        let sourceOpaque = source.alpha.reduce(0, +), referenceOpaque = reference.alpha.reduce(0, +)
        guard sourceOpaque > 0, referenceOpaque > 0 else { return nil }
        var result = RegionTransfer(width: source.width, height: source.height)
        for label in RegionLabel.allCases {
            guard let mine = sourceRegions[label], let theirs = referenceRegions[label] else { continue }
            let mineWeights = zip(mine, source.alpha).map { $0 * $1 }, theirWeights = zip(theirs, reference.alpha).map { $0 * $1 }
            guard mineWeights.reduce(0, +) / sourceOpaque >= minimumShare,
                  theirWeights.reduce(0, +) / referenceOpaque >= minimumShare,
                  let map = ColorTransfer.transform(source, weights: mineWeights, reference: reference,
                                                    referenceWeights: theirWeights, settings: settings) else { continue }
            result.transforms[label] = map
        }
        guard !result.transforms.isEmpty else { return nil }
        // Feathered masks of every region, normalized together, so a label left to the global mapping still takes its
        // share of the mix and nothing shows a seam.
        let radius = max(2, Int((0.03 * Double(max(source.width, source.height))).rounded()))
        var blurred: [RegionLabel: [Float]] = [:]
        var total = [Float](repeating: 0, count: source.alpha.count)
        for label in RegionLabel.allCases {
            guard let mask = sourceRegions[label] else { continue }
            let soft = boxBlur(mask, source.width, source.height, radius: radius, passes: 3)
            blurred[label] = soft
            for i in 0..<total.count { total[i] += soft[i] }
        }
        for label in result.transforms.keys {
            guard let soft = blurred[label] else { continue }
            result.weights[label] = (0..<soft.count).map { total[$0] > 0 ? soft[$0] / total[$0] : 0 }
        }
        return result
    }

    /// `lab` mapped by the mix of its region's transforms, the global one for whatever the paired regions leave.
    /// `weights` is scratch, one slot per label.
    func blended(_ lab: SIMD3<Float>, x: Int, y: Int, width fullWidth: Int, height fullHeight: Int, global: LabTransform,
                 weights scratch: inout [Float]) -> SIMD3<Float> {
        let u = min(Float(width - 1), max(0, (Float(x) + 0.5) / Float(fullWidth) * Float(width) - 0.5))
        let v = min(Float(height - 1), max(0, (Float(y) + 0.5) / Float(fullHeight) * Float(height) - 0.5))
        let x0 = Int(u), y0 = Int(v), x1 = min(width - 1, x0 + 1), y1 = min(height - 1, y0 + 1)
        let fx = u - Float(x0), fy = v - Float(y0)
        var result = SIMD3<Float>.zero
        var used: Float = 0
        for (label, map) in transforms {
            guard let mask = weights[label] else { continue }
            let top = mask[y0 * width + x0] * (1 - fx) + mask[y0 * width + x1] * fx
            let bottom = mask[y1 * width + x0] * (1 - fx) + mask[y1 * width + x1] * fx
            let weight = top * (1 - fy) + bottom * fy
            guard weight > 0.0005 else { continue }
            result += map.apply(lab) * weight
            used += weight
        }
        if used < 1 { result += global.apply(lab) * (1 - used) }
        return result
    }

    /// A blur of `passes` box blurs (close to a Gaussian), clamped at the edges.
    static func boxBlur(_ values: [Float], _ width: Int, _ height: Int, radius: Int, passes: Int) -> [Float] {
        var current = values, scratch = values
        let size = Float(2 * radius + 1)
        for _ in 0..<passes {
            for y in 0..<height {
                let row = y * width
                var sum: Float = 0
                for k in -radius...radius { sum += current[row + min(width - 1, max(0, k))] }
                for x in 0..<width {
                    scratch[row + x] = sum / size
                    sum += current[row + min(width - 1, x + radius + 1)] - current[row + max(0, x - radius)]
                }
            }
            for x in 0..<width {
                var sum: Float = 0
                for k in -radius...radius { sum += scratch[min(height - 1, max(0, k)) * width + x] }
                for y in 0..<height {
                    current[y * width + x] = sum / size
                    sum += scratch[min(height - 1, y + radius + 1) * width + x] - scratch[max(0, y - radius) * width + x]
                }
            }
        }
        return current
    }
}
