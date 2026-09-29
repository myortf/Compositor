import CoreGraphics
import Foundation

/// The document a smart object holds: what its tab edits, and what is flattened onto the layer.
struct SmartObjectContent: Equatable {
    var id = UUID()
    var width: Int
    var height: Int
    var resolution: Double
    var layers: [ImageLayer]
}

/// A layer that wraps a nested document. Its pixels are an ordinary raster, the flattened render, so it clips, masks,
/// blends and exports like any layer; `image` is that render. Once anything else changes the layer's pixels the image
/// is no longer this one and the layer is plain pixels from then on.
struct LayerSmartObject: Equatable {
    var content: SmartObjectContent
    let image: CGImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.content == rhs.content && lhs.image === rhs.image }
}

extension ImageLayer {
    /// The smart object this layer still is: nil once its pixels were edited some other way.
    var liveSmartObject: LayerSmartObject? {
        guard let smartObject, let image = asset?.image, image === smartObject.image else { return nil }
        return smartObject
    }
}
