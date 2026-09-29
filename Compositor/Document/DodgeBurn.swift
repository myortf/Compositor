import AppKit

nonisolated enum DodgeBurnMode: String, CaseIterable, Sendable {
    case dodge = "Dodge"
    case burn = "Burn"
}

/// The tones a stroke works on: Shadows and Highlights fade out toward the other end of the scale.
nonisolated enum DodgeBurnRange: String, CaseIterable, Sendable {
    case shadows = "Shadows"
    case midtones = "Midtones"
    case highlights = "Highlights"
}

extension EditorSession {

    /// What a Dodge or Burn stroke paints: the layer's own pixels (or, painting the mask, its mask) lightened or
    /// darkened by tone, opaque so the stroke leaves alpha alone. Exposure is the brush opacity, which blends it in.
    /// `render` tones any part of the sample, so only what the brush reaches is ever worked on.
    func dodgeBurnSample(for stroke: BrushStroke) -> (sample: (image: CGImage, placed: CGRect, inGrid: Bool), render: (CGRect) -> CGImage?)? {
        let layer = stroke.layer
        guard let image = stroke.isMask ? layer.mask?.asset.image : layer.asset?.image else { return nil }
        let region = stroke.sourceRect
        let canvas = (document?.width ?? 0) * (document?.height ?? 0)
        let budget = Double(min(DocumentLimits.maxSurfacePixels, max(16_000_000, 4 * canvas)))
        let fit = min(1, (budget / Double(region.width * region.height)).squareRoot())
        let width = max(1, Int((region.width * fit).rounded(.up))), height = max(1, Int((region.height * fit).rounded(.up)))
        let isMask = stroke.isMask
        guard let source = try? BrushRaster.context(width: width, height: height, mask: isMask),
              let base = source.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: isMask, context: source)
        guard let sharp = source.makeImage() else { return nil }
        let burn: Int32 = dodgeBurnMode == .burn ? 1 : 0
        let range: Int32 = dodgeBurnRange == .shadows ? 0 : dodgeBurnRange == .midtones ? 1 : 2
        let pixelSize = isMask ? 1 : 4
        let render: (CGRect) -> CGImage? = { part in
            // The closure keeps `source` alive: `base` points into it.
            let bounds = part.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
            guard !bounds.isNull, !bounds.isEmpty,
                  let piece = try? BrushRaster.context(width: Int(bounds.width), height: Int(bounds.height), mask: isMask),
                  let target = piece.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
            let row = Int(bounds.width) * pixelSize
            for y in 0..<Int(bounds.height) {
                memcpy(target + y * piece.bytesPerRow, base + (Int(bounds.minY) + y) * source.bytesPerRow + Int(bounds.minX) * pixelSize, row)
            }
            if isMask {
                dodge_burn_gray(target, piece.bytesPerRow, Int(bounds.width), Int(bounds.height), burn, range)
            } else {
                layer_unpremultiply_opaque(target, piece.bytesPerRow, Int(bounds.width), Int(bounds.height))
                dodge_burn_rgba(target, piece.bytesPerRow, Int(bounds.width), Int(bounds.height), burn, range)
            }
            return piece.makeImage()
        }
        return ((sharp, region, true), render)
    }
}
