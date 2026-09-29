import AppKit
import CoreImage

/// Unsharp Mask and High Pass. Both work from a Gaussian blur of the layer, made in Core Image with the edge pixels
/// extended so the layer's border is not treated as a step to sharpen. Colors are compared unpremultiplied and alpha is
/// never touched, so a soft edge gains no halo of its own.
nonisolated enum Sharpen {
    static let amountRange: ClosedRange<Double> = 0...500
    static let radiusRange: ClosedRange<Double> = 0.1...250
    static let thresholdRange: ClosedRange<Double> = 0...255

    /// Adds `amount` percent of the difference from the blur back to every channel that differs by at least `threshold`
    /// levels. Core Image's own `CIUnsharpMask` has no threshold, so the difference is applied here.
    static func unsharpMask(_ image: CGImage, amount: Double, radius: Double, threshold: Double) throws -> CGImage {
        guard amount > 0 else { return image }
        return try combine(image, radius: radius) { original, base in
            let gain = Float(amount / 100), limit = Float(threshold)
            var changed = false
            var result = original
            for channel in 0..<3 {
                let difference = original[channel] - base[channel]
                guard abs(difference) >= limit, difference != 0 else { continue }
                result[channel] = min(255, max(0, original[channel] + gain * difference))
                changed = true
            }
            return changed ? result : nil
        }
    }

    /// The layer's detail as mid-gray plus the difference from the blur: flat areas become 50% gray. Alpha is kept.
    static func highPass(_ image: CGImage, radius: Double) throws -> CGImage {
        try combine(image, radius: radius) { original, base in
            var result = original
            for channel in 0..<3 { result[channel] = min(255, max(0, 127.5 + original[channel] - base[channel])) }
            return result
        }
    }

    private static func blurred(_ image: CGImage, sigma: Double) throws -> CGImage {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let blurred = CIImage(cgImage: image).clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
        return try PixelAdjust.render(blurred, width: image.width, height: image.height, isMask: false)
    }

    /// Runs `transform(original, blurred)` on every visible pixel's unpremultiplied color (0–255); a nil result leaves
    /// the pixel's bytes as they were. Clear pixels stay clear.
    private static func combine(_ image: CGImage, radius: Double,
                                _ transform: (SIMD3<Float>, SIMD3<Float>) -> SIMD3<Float>?) throws -> CGImage {
        let width = image.width, height = image.height
        let target = try BrushRaster.copy(image)
        let source = try BrushRaster.copy(try blurred(image, sigma: radius))
        guard let pixels = target.data?.assumingMemoryBound(to: UInt8.self),
              let blur = source.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        let stride = target.bytesPerRow, blurStride = source.bytesPerRow
        func straight(_ p: UnsafePointer<UInt8>) -> (SIMD3<Float>, Float) {
            let alpha = Float(p[3])
            guard alpha > 0 else { return (.zero, 0) }
            let scale = 255 / alpha
            return (SIMD3(min(255, Float(p[0]) * scale), min(255, Float(p[1]) * scale), min(255, Float(p[2]) * scale)), alpha)
        }
        BrushRaster.inBands(count: width * height) { start, length in
            for index in start..<start + length {
                let y = index / width, x = index % width
                let p = pixels + y * stride + x * 4
                let (color, alpha) = straight(p)
                guard alpha > 0 else { continue }
                let (base, baseAlpha) = straight(blur + y * blurStride + x * 4)
                guard let result = transform(color, baseAlpha > 0 ? base : color) else { continue }
                let scale = alpha / 255
                for channel in 0..<3 { p[channel] = UInt8(min(alpha, (result[channel] * scale).rounded())) }
            }
        }
        guard let made = target.makeImage() else { throw ExportError.render }
        return made
    }
}
