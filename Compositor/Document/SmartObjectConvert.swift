import CoreGraphics

extension EditorSession {
    var canConvertToSmartObject: Bool {
        guard canEditLayers, selectedLayerIDs.count <= 1, let layer = activeLayer else { return false }
        return !layer.isGroup && layer.asset != nil && layer.adjustment == nil
            && layer.liveShape == nil && layer.liveText == nil && layer.liveSmartObject == nil
    }

    /// Wraps the active layer's pixels in a smart object: its own document, at the pixels' native size, that opens in a tab.
    func convertToSmartObject() {
        commitTransform()
        guard canConvertToSmartObject, let document, let layer = activeLayer, let asset = layer.asset,
              let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        var inner = ImageLayer(asset: asset, origin: .zero)
        inner.name = layer.name
        let content = SmartObjectContent(width: asset.image.width, height: asset.image.height, resolution: document.resolution, layers: [inner])
        finishOpacityEdit()
        beginEdit("Convert to Smart Object")
        self.document?.layers[index].smartObject = LayerSmartObject(content: content, image: asset.image)
        endEdit()
    }
}
