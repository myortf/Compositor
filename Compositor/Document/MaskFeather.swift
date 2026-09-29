import CoreImage
import CoreGraphics

nonisolated private struct FeatherBox: @unchecked Sendable {
    let image: CGImage
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

nonisolated enum MaskFeather {
    /// `image` (8-bit gray mask) blurred with a Gaussian of standard deviation `sigma` mask pixels; edges repeat, so
    /// the border of the mask doesn't fade toward black.
    static func blurred(_ image: CGImage, sigma: Double) throws -> CGImage {
        let width = image.width, height = image.height
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let gray = CGColorSpaceCreateDeviceGray()
        let source = CIImage(cgImage: image).clampedToExtent()
        guard let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputImageKey: source, kCIInputRadiusKey: sigma]),
              let output = blur.outputImage?.cropped(to: extent),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                      space: gray, bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { throw ExportError.render }
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
            .render(output, toBitmap: data, rowBytes: context.bytesPerRow, bounds: extent, format: .L8, colorSpace: nil)
        guard let result = context.makeImage() else { throw ExportError.render }
        return result
    }
}

extension EditorSession {
    static let maxMaskFeather = 250

    /// A layer (or folder) mask that is enabled and holds real pixels; a uniform 1×1 mask has nothing to soften.
    var canFeatherMask: Bool {
        _ = showsBusy
        guard canEditMask, !isProjectBusy, !isImporting, brushStroke == nil, pixelMove == nil, transformEdit == nil,
              let mask = activeLayer?.mask, mask.isEnabled else { return false }
        return mask.asset.image.width > 1 || mask.asset.image.height > 1
    }

    func promptMaskFeather() {
        guard canFeatherMask else { return }
        if let id = activeLayerID { selectLayerTarget(id, mask: true) }
        selectionAmountOperation = .featherMask
    }

    /// Softens the active layer's mask by `radius` document pixels, as Photoshop's Properties → Feather does.
    /// One undo step; the blur runs off the main thread.
    func featherMask(by radius: Int) async {
        guard canFeatherMask, (1...Self.maxMaskFeather).contains(radius) else { return }
        commitTransform()
        if gradientEdit != nil { await commitGradient() }
        guard canFeatherMask, let document, let layer = activeLayer, let mask = layer.mask,
              let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        finishOpacityEdit()
        isProjectBusy = true
        defer { isProjectBusy = false }
        do {
            let image = mask.asset.image
            // The radius is in document pixels; the mask grid may be finer or coarser than the document.
            let perMaskPixel = layer.maskTransform.size.width / CGFloat(max(1, image.width))
            let sigma = max(0.5, Double(CGFloat(radius) / max(0.0001, perMaskPixel)) / 2)
            let result = try await Task.detached(priority: .userInitiated) { FeatherBox(image: try MaskFeather.blurred(image, sigma: sigma)) }.value.image
            let asset = try LayerMask.asset(from: result)
            guard let current = self.document?.layers[safe: index], current.id == layer.id,
                  current.mask?.asset.image === image else { return }
            beginEdit("Feather Mask")
            self.document?.layers[index].mask = mask.replacing(asset)
            endEdit()
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }
}
