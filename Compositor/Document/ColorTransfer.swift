import AppKit
import CoreGraphics
import simd
import UniformTypeIdentifiers

/// Color Transfer: gives a layer the colors of a reference image with classical statistics matching, all in CIE Lab
/// (D65) computed from linearized sRGB. Alpha is never touched, and pixels with no alpha count for nothing in either
/// image's statistics.
nonisolated enum ColorTransferMethod: String, CaseIterable, Sendable {
    /// Per-channel mean and standard deviation (Reinhard, Ashikhmin, Gooch and Shirley, 2001).
    case reinhard = "Reinhard"
    /// Per-channel cumulative distributions matched channel by channel.
    case histogram = "Histogram Matching"
    /// The linear Monge-Kantorovich transport of the two color covariances (Pitié and Kokaram, 2007).
    case monge = "Monge-Kantorovich"
}

nonisolated struct ColorTransferSettings: Equatable, Sendable {
    static let strengthRange: ClosedRange<Double> = 0...100
    var method: ColorTransferMethod = .reinhard
    /// 0–100: how much of the transferred color replaces the original.
    var strength: Double = 100
    /// Keeps each pixel's lightness and moves only its color (a and b).
    var preserveLuminance = false
    /// Matches like with like (sky to sky, people to people) instead of the images as wholes.
    var matchRegions = true
    /// Puts the result on a new layer above the active one instead of replacing its pixels.
    var asNewLayer = true
    var normalized: Self {
        var result = self
        result.strength = strength.isFinite ? min(100, max(0, strength)) : 100
        return result
    }
}

/// A raster copy of an image: straight top-down RGBA bytes, premultiplied, in sRGB.
nonisolated struct Raster: @unchecked Sendable {
    let width: Int
    let height: Int
    var bytes: [UInt8]
    /// The image this was made from, which is what caches key on.
    let origin: CGImage?

    /// `image` scaled down so its longest side is at most `maxSide` (never up).
    static func make(_ image: CGImage, maxSide: Int) throws -> Raster {
        let factor = min(1, Double(maxSide) / Double(max(image.width, image.height)))
        let width = max(1, Int((Double(image.width) * factor).rounded())), height = max(1, Int((Double(image.height) * factor).rounded()))
        let context = try ColorTransfer.context(width: width, height: height)
        context.interpolationQuality = factor < 1 ? .high : .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw ExportError.render }
        let bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        return Raster(width: width, height: height, bytes: bytes, origin: image)
    }

    func cgImage() -> CGImage? {
        var copy = bytes
        return copy.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
            return context?.makeImage()
        }
    }
}

/// Lab values of a raster's pixels and their alpha, for gathering statistics.
nonisolated struct LabField: Sendable {
    let width: Int
    let height: Int
    var lab: [SIMD3<Float>]
    var alpha: [Float]

    init(_ raster: Raster) {
        width = raster.width; height = raster.height
        let count = raster.width * raster.height
        var lab = [SIMD3<Float>](repeating: .zero, count: count)
        var alpha = [Float](repeating: 0, count: count)
        raster.bytes.withUnsafeBufferPointer { bytes in
            for i in 0..<count {
                let a = bytes[i * 4 + 3]
                guard a > 0 else { continue }
                alpha[i] = Float(a) / 255
                lab[i] = LabSpace.lab(fromPremultiplied: bytes[i * 4], bytes[i * 4 + 1], bytes[i * 4 + 2], a)
            }
        }
        self.lab = lab; self.alpha = alpha
    }
}

nonisolated enum LabSpace {
    private static let d65 = SIMD3<Float>(0.95047, 1, 1.08883)
    private static let epsilon: Float = 216.0 / 24389, kappa: Float = 24389.0 / 27
    /// sRGB's transfer curve undone, for every 8-bit level.
    static let linear: [Float] = (0..<256).map { level in
        let v = Double(level) / 255
        return Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4))
    }

    static func lab(fromPremultiplied r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8) -> SIMD3<Float> {
        // Straight color, rounded to a level, before the curve is undone.
        let scale = 255 / Float(a)
        func level(_ value: UInt8) -> Int { min(255, Int((Float(value) * scale).rounded())) }
        return lab(red: linear[level(r)], green: linear[level(g)], blue: linear[level(b)])
    }

    static func lab(red r: Float, green g: Float, blue b: Float) -> SIMD3<Float> {
        let x = (0.4124564 * r + 0.3575761 * g + 0.1804375 * b) / d65.x
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = (0.0193339 * r + 0.1191920 * g + 0.9503041 * b) / d65.z
        func f(_ t: Float) -> Float { t > epsilon ? cbrtf(t) : (kappa * t + 16) / 116 }
        let fx = f(x), fy = f(y), fz = f(z)
        return SIMD3(116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    /// Linear RGB for `lab`, not yet limited to the gamut.
    static func linearRGB(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let fy = (lab.x + 16) / 116, fx = fy + lab.y / 500, fz = fy - lab.z / 200
        func inverse(_ f: Float) -> Float { let cube = f * f * f; return cube > epsilon ? cube : (116 * f - 16) / kappa }
        let x = inverse(fx) * d65.x, y = lab.x > kappa * epsilon ? fy * fy * fy : lab.x / kappa, z = inverse(fz) * d65.z
        return SIMD3(3.2404542 * x - 1.5371385 * y - 0.4985314 * z,
                     -0.9692660 * x + 1.8760108 * y + 0.0415560 * z,
                     0.0556434 * x - 0.2040259 * y + 1.0572252 * z)
    }

    /// sRGB in 0...1 (clamped to the gamut), gamma-encoded.
    static func srgb(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        let linear = linearRGB(lab)
        func encode(_ v: Float) -> Float {
            let c = min(1, max(0, v))
            return c <= 0.0031308 ? 12.92 * c : 1.055 * powf(c, 1 / 2.4) - 0.055
        }
        return SIMD3(encode(linear.x), encode(linear.y), encode(linear.z))
    }

    /// `lab` with its chroma drawn in just far enough to fit the gamut, so its lightness survives.
    static func fitted(_ lab: SIMD3<Float>) -> SIMD3<Float> {
        func inside(_ p: SIMD3<Float>) -> Bool {
            let c = linearRGB(p)
            return c.x >= -0.0005 && c.y >= -0.0005 && c.z >= -0.0005 && c.x <= 1.0005 && c.y <= 1.0005 && c.z <= 1.0005
        }
        guard !inside(lab) else { return lab }
        var low: Float = 0, high: Float = 1
        for _ in 0..<10 {
            let middle = (low + high) / 2
            if inside(SIMD3(lab.x, lab.y * middle, lab.z * middle)) { low = middle } else { high = middle }
        }
        return SIMD3(lab.x, lab.y * low, lab.z * low)
    }
}

/// One mapping of Lab colors: a matrix and offset, or a lookup table for each channel.
nonisolated struct LabTransform: Sendable {
    static let lutSize = 1024
    static let ranges: [ClosedRange<Float>] = [0...100, -128...128, -128...128]
    var rows: [SIMD3<Float>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
    var offset = SIMD3<Float>.zero
    /// Per channel; an empty table leaves the channel to `rows`.
    var luts: [[Float]] = []

    static let identity = LabTransform()

    func apply(_ p: SIMD3<Float>) -> SIMD3<Float> {
        guard !luts.isEmpty else {
            return SIMD3(simd_dot(rows[0], p), simd_dot(rows[1], p), simd_dot(rows[2], p)) + offset
        }
        var result = p
        for channel in 0..<3 where !luts[channel].isEmpty {
            let range = Self.ranges[channel]
            let position = (min(range.upperBound, max(range.lowerBound, p[channel])) - range.lowerBound)
                / (range.upperBound - range.lowerBound) * Float(Self.lutSize - 1)
            let low = min(Self.lutSize - 2, Int(position)), fraction = position - Float(low)
            result[channel] = luts[channel][low] * (1 - fraction) + luts[channel][low + 1] * fraction
        }
        return result
    }
}

nonisolated enum ColorTransfer {
    static let referenceSide = 512
    /// Added to every variance so a flat image neither divides by zero nor turns its noise into texture.
    static let varianceFloor = 1.0

    static func context(width: Int, height: Int) throws -> CGContext {
        guard let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { throw ExportError.render }
        return result
    }

    /// `reference` shrunk to the size its statistics are gathered at.
    static func downsampled(_ image: CGImage) throws -> CGImage {
        guard max(image.width, image.height) > referenceSide else { return image }
        return try Raster.make(image, maxSide: referenceSide).cgImage() ?? { throw ExportError.render }()
    }

    /// `image` with the reference's colors put on it. `segmenter` is used only when `settings.matchRegions` is on.
    static func apply(_ image: CGImage, reference: CGImage, settings: ColorTransferSettings,
                      segmenter: RegionSegmenter = DefaultRegionSegmenter()) throws -> CGImage {
        let settings = settings.normalized
        guard settings.strength > 0 else { return image }
        let sourceSmall = try Raster.make(image, maxSide: referenceSide)
        let referenceSmall = try Raster.make(reference, maxSide: referenceSide)
        let source = LabField(sourceSmall), target = LabField(referenceSmall)
        guard let global = transform(source, weights: source.alpha, reference: target, referenceWeights: target.alpha, settings: settings)
        else { return image }
        var regions: RegionTransfer?
        if settings.matchRegions {
            regions = RegionTransfer.make(sourceRaster: sourceSmall, source: source, referenceRaster: referenceSmall, reference: target,
                                          settings: settings, segmenter: segmenter)
        }
        return try render(image, global: global, regions: regions, settings: settings)
    }

    /// The Lab mapping from the image behind `source` (over its `weights`) to the one behind `reference`, nil when
    /// either has nothing to measure.
    static func transform(_ source: LabField, weights: [Float], reference: LabField, referenceWeights: [Float],
                          settings: ColorTransferSettings) -> LabTransform? {
        let s = Moments(source, weights), t = Moments(reference, referenceWeights)
        guard s.weight > 0, t.weight > 0 else { return nil }
        let channels = settings.preserveLuminance ? [1, 2] : [0, 1, 2]
        switch settings.method {
        case .reinhard:
            var result = LabTransform.identity
            var diagonal = SIMD3<Float>(1, 1, 1)
            for c in channels { diagonal[c] = Float(((t.covariance[c * 3 + c] + varianceFloor) / (s.covariance[c * 3 + c] + varianceFloor)).squareRoot()) }
            result.rows = [SIMD3(diagonal.x, 0, 0), SIMD3(0, diagonal.y, 0), SIMD3(0, 0, diagonal.z)]
            for c in channels { result.offset[c] = Float(t.mean[c]) - diagonal[c] * Float(s.mean[c]) }
            return result
        case .monge:
            let d = channels.count
            func sub(_ m: [Double]) -> [Double] {
                var out = [Double](repeating: 0, count: d * d)
                for i in 0..<d { for j in 0..<d { out[i * d + j] = m[channels[i] * 3 + channels[j]] + (i == j ? varianceFloor : 0) } }
                return out
            }
            let cs = sub(s.covariance), ct = sub(t.covariance)
            let root = SymmetricMatrix.function(cs, d) { $0.squareRoot() }
            let inverseRoot = SymmetricMatrix.function(cs, d) { 1 / $0.squareRoot() }
            let middle = SymmetricMatrix.function(SymmetricMatrix.multiply(SymmetricMatrix.multiply(root, ct, d), root, d), d) { max(0, $0).squareRoot() }
            let map = SymmetricMatrix.multiply(SymmetricMatrix.multiply(inverseRoot, middle, d), inverseRoot, d)
            var result = LabTransform.identity
            var rows = [SIMD3<Float>](repeating: .zero, count: 3)
            for c in 0..<3 where !channels.contains(c) { rows[c][c] = 1 }
            for (i, ci) in channels.enumerated() { for (j, cj) in channels.enumerated() { rows[ci][cj] = Float(map[i * d + j]) } }
            result.rows = rows
            for (i, ci) in channels.enumerated() {
                var moved = 0.0
                for (j, cj) in channels.enumerated() { moved += map[i * d + j] * s.mean[cj] }
                result.offset[ci] = Float(t.mean[ci] - moved)
            }
            return result
        case .histogram:
            var result = LabTransform.identity
            result.luts = [[Float]](repeating: [], count: 3)
            for c in channels {
                result.luts[c] = histogramTable(source, weights, reference, referenceWeights, channel: c)
            }
            return result
        }
    }

    /// The table sending each level of `channel` to the level of the same cumulative share in the reference. Each
    /// pixel sits at the middle of its own share, so equal distributions map to themselves.
    private static func histogramTable(_ source: LabField, _ weights: [Float], _ reference: LabField, _ referenceWeights: [Float],
                                       channel: Int) -> [Float] {
        let n = LabTransform.lutSize, range = LabTransform.ranges[channel]
        func histogram(_ field: LabField, _ w: [Float]) -> [Double] {
            var bins = [Double](repeating: 0, count: n)
            for i in 0..<field.lab.count where w[i] > 0 {
                let position = (min(range.upperBound, max(range.lowerBound, field.lab[i][channel])) - range.lowerBound)
                    / (range.upperBound - range.lowerBound) * Float(n - 1)
                bins[Int(position.rounded())] += Double(w[i])
            }
            return bins
        }
        let s = histogram(source, weights), t = histogram(reference, referenceWeights)
        let sTotal = s.reduce(0, +), tTotal = t.reduce(0, +)
        var before = [Double](repeating: 0, count: n)
        var running = 0.0
        for i in 0..<n { before[i] = running; running += t[i] / tTotal }
        let step = (range.upperBound - range.lowerBound) / Float(n - 1)
        var table = [Float](repeating: 0, count: n)
        var sBefore = 0.0, j = 0
        for i in 0..<n {
            let share = min(1, sBefore + s[i] / sTotal / 2)
            sBefore += s[i] / sTotal
            // The reference bin holding this share; empty bins are passed over.
            while j < n - 1 && (t[j] == 0 || before[j] + t[j] / tTotal < share) { j += 1 }
            let inside = t[j] > 0 ? min(1, max(0, (share - before[j]) / (t[j] / tTotal))) : 0.5
            table[i] = range.lowerBound + step * (Float(j) - 0.5 + Float(inside))
        }
        return table
    }

    /// The layer with its colors moved: to `global`, or, where `regions` has a mapping for the area a pixel is in,
    /// to that mix. Alpha stays as it was.
    private static func render(_ image: CGImage, global: LabTransform, regions: RegionTransfer?, settings: ColorTransferSettings) throws -> CGImage {
        let width = image.width, height = image.height
        let input = try context(width: width, height: height)
        input.interpolationQuality = .none
        input.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let output = try context(width: width, height: height)
        guard let inData = input.data, let outData = output.data else { throw ExportError.render }
        let strength = Float(settings.strength / 100), keepsLightness = settings.preserveLuminance
        let inRow = input.bytesPerRow, outRow = output.bytesPerRow
        let source = UnsafeSendable(inData.assumingMemoryBound(to: UInt8.self)), target = UnsafeSendable(outData.assumingMemoryBound(to: UInt8.self))
        let bands = max(1, min(height, 64))
        DispatchQueue.concurrentPerform(iterations: bands) { band in
            let rows = (band * height / bands)..<((band + 1) * height / bands)
            var weights = [Float](repeating: 0, count: RegionLabel.allCases.count)
            for y in rows {
                let from = source.pointer + y * inRow, to = target.pointer + y * outRow
                for x in 0..<width {
                    let r = from[x * 4], g = from[x * 4 + 1], b = from[x * 4 + 2], a = from[x * 4 + 3]
                    guard a > 0 else {
                        to[x * 4] = r; to[x * 4 + 1] = g; to[x * 4 + 2] = b; to[x * 4 + 3] = a
                        continue
                    }
                    let lab = LabSpace.lab(fromPremultiplied: r, g, b, a)
                    var moved: SIMD3<Float>
                    if let regions {
                        moved = regions.blended(lab, x: x, y: y, width: width, height: height, global: global, weights: &weights)
                    } else {
                        moved = global.apply(lab)
                    }
                    if keepsLightness { moved.x = lab.x }
                    var result = lab + (moved - lab) * strength
                    result.x = min(100, max(0, result.x))
                    let color = LabSpace.srgb(keepsLightness ? LabSpace.fitted(result) : result)
                    let alpha = Float(a) / 255
                    to[x * 4] = UInt8(min(255, (color.x * 255 * alpha).rounded()))
                    to[x * 4 + 1] = UInt8(min(255, (color.y * 255 * alpha).rounded()))
                    to[x * 4 + 2] = UInt8(min(255, (color.z * 255 * alpha).rounded()))
                    to[x * 4 + 3] = a
                }
            }
        }
        guard let result = output.makeImage() else { throw ExportError.render }
        return result
    }
}

/// A raw pointer the bands of a parallel loop write through, each to its own rows.
nonisolated struct UnsafeSendable: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<UInt8>
    init(_ pointer: UnsafeMutablePointer<UInt8>) { self.pointer = pointer }
}

/// Weighted mean and covariance of a field's Lab values.
nonisolated struct Moments {
    var weight = 0.0
    var mean = [Double](repeating: 0, count: 3)
    var covariance = [Double](repeating: 0, count: 9)

    init(_ field: LabField, _ weights: [Float]) {
        var sum = [Double](repeating: 0, count: 3), products = [Double](repeating: 0, count: 9)
        var total = 0.0
        for i in 0..<field.lab.count where weights[i] > 0 {
            let w = Double(weights[i]), p = field.lab[i]
            let v = [Double(p.x), Double(p.y), Double(p.z)]
            total += w
            for a in 0..<3 {
                sum[a] += w * v[a]
                for b in a..<3 { products[a * 3 + b] += w * v[a] * v[b] }
            }
        }
        weight = total
        guard total > 0 else { return }
        for a in 0..<3 { mean[a] = sum[a] / total }
        for a in 0..<3 {
            for b in a..<3 {
                let value = products[a * 3 + b] / total - mean[a] * mean[b]
                covariance[a * 3 + b] = a == b ? max(0, value) : value
                covariance[b * 3 + a] = covariance[a * 3 + b]
            }
        }
    }
}

/// Small dense symmetric matrices (2 x 2 or 3 x 3, row-major) and functions of them.
nonisolated enum SymmetricMatrix {
    static func multiply(_ a: [Double], _ b: [Double], _ n: Int) -> [Double] {
        var result = [Double](repeating: 0, count: n * n)
        for i in 0..<n { for j in 0..<n { for k in 0..<n { result[i * n + j] += a[i * n + k] * b[k * n + j] } } }
        return result
    }

    /// V f(D) Vᵀ from the eigen-decomposition of `matrix` (cyclic Jacobi rotations).
    static func function(_ matrix: [Double], _ n: Int, _ f: (Double) -> Double) -> [Double] {
        var a = matrix
        var v = [Double](repeating: 0, count: n * n)
        for i in 0..<n { v[i * n + i] = 1 }
        for _ in 0..<30 {
            var off = 0.0
            for i in 0..<n { for j in (i + 1)..<max(i + 1, n) { off += a[i * n + j] * a[i * n + j] } }
            if off < 1e-24 { break }
            for p in 0..<n {
                for q in (p + 1)..<max(p + 1, n) where abs(a[p * n + q]) > 1e-30 {
                    let theta = (a[q * n + q] - a[p * n + p]) / (2 * a[p * n + q])
                    let t = (theta >= 0 ? 1.0 : -1.0) / (abs(theta) + (theta * theta + 1).squareRoot())
                    let c = 1 / (t * t + 1).squareRoot(), s = t * c
                    for k in 0..<n {
                        let akp = a[k * n + p], akq = a[k * n + q]
                        a[k * n + p] = c * akp - s * akq
                        a[k * n + q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p * n + k], aqk = a[q * n + k]
                        a[p * n + k] = c * apk - s * aqk
                        a[q * n + k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k * n + p], vkq = v[k * n + q]
                        v[k * n + p] = c * vkp - s * vkq
                        v[k * n + q] = s * vkp + c * vkq
                    }
                }
            }
        }
        var result = [Double](repeating: 0, count: n * n)
        for k in 0..<n {
            let value = f(max(0, a[k * n + k]))
            for i in 0..<n { for j in 0..<n { result[i * n + j] += v[i * n + k] * value * v[j * n + k] } }
        }
        return result
    }
}

/// A reference for Color Transfer: the image gathered statistics come from, at most 512 pixels on a side.
nonisolated struct ColorReference: @unchecked Sendable {
    let image: CGImage
    let thumbnail: CGImage
    let name: String

    init(_ imported: ImportedImage) throws {
        image = try ColorTransfer.downsampled(imported.image)
        thumbnail = imported.thumbnail
        name = imported.name
    }
}

extension EditorSession {
    /// The document's other image layers, which can stand in as a reference.
    var colorReferenceLayers: [ImageLayer] {
        guard let edit = filterEdit else { return [] }
        return document?.layers.filter { $0.id != edit.layerID && !$0.isGroup && $0.asset != nil } ?? []
    }

    func useColorReferenceLayer(_ id: UUID) {
        guard let edit = filterEdit, edit.kind == .colorTransfer, let asset = document?.layers.first(where: { $0.id == id })?.asset else { return }
        Task { await setColorReference(asset, on: edit) }
    }

    func chooseColorReferenceFile() {
        guard let edit = filterEdit, edit.kind == .colorTransfer else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .heic, .tiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.title = "Choose Reference Image"
        Task {
            guard await panel.begin() == .OK, let url = panel.url else { return }
            do { await setColorReference(try await ImageImporter.shared.decode(url), on: edit) }
            catch { brushError = error.localizedDescription }
        }
    }

    private func setColorReference(_ imported: ImportedImage, on edit: FilterEdit) async {
        do {
            let reference = try await Task.detached(priority: .userInitiated) { try ColorReference(imported) }.value
            guard filterEdit === edit, !edit.committing else { return }
            edit.colorReference = reference
            updateFilter(edit.settings, preview: edit.preview)
        } catch { brushError = error.localizedDescription }
    }
}
