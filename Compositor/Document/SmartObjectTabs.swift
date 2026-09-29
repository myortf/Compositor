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
}
