import CoreGraphics
import Foundation

extension SmartObjectContent {
    var document: CanvasDocument { CanvasDocument(id: id, width: width, height: height, layers: layers, resolution: resolution) }
}

extension EditorSession {
    /// Shows a smart object's contents as this session's document, as a project that was just opened.
    func installSmartObject(_ content: SmartObjectContent) {
        collapsedGroupIDs = []
        isMaskSelected = false
        transformEdit = nil
        document = content.document
        activeLayerID = content.layers.last?.id
        projectURL = nil
        renamingLayerID = nil
        history.reset()
        viewport.fit(documentSize: content.document.size)
    }

    /// The smart object's contents as they stand in this tab, flattened at their own pixel size; nil when nothing
    /// changed from `source` or the render failed.
    func flattenedSmartObjectContent(from source: SmartObjectContent) -> (content: SmartObjectContent, image: ImportedImage)? {
        commitTransform()
        guard let document else { return nil }
        let changed = document.width != source.width || document.height != source.height
            || document.resolution != source.resolution || document.layers != source.layers
        guard changed, let context = try? BrushRaster.context(width: document.width, height: document.height, mask: false) else { return nil }
        drawLiveComposite(document, in: context)
        guard let image = context.makeImage(), let thumbnail = try? PixelAdjust.thumbnail(of: image) else { return nil }
        let content = SmartObjectContent(id: source.id, width: document.width, height: document.height,
                                         resolution: document.resolution, layers: document.layers)
        return (content, ImportedImage(image: image, thumbnail: thumbnail, name: source.layers.first?.name ?? "Smart Object"))
    }
}
