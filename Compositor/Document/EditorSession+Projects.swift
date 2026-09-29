import Foundation

extension EditorSession {
    func projectSnapshot() -> ProjectSnapshot? {
        guard let document else { return nil }
        return Self.snapshot(of: document, activeLayerID: activeLayerID)
    }

    /// A smart object's nested project: its layers as a document of their own.
    static func snapshot(of content: SmartObjectContent) -> ProjectSnapshot {
        snapshot(of: CanvasDocument(id: content.id, width: content.width, height: content.height, layers: content.layers,
                                    resolution: content.resolution), activeLayerID: content.layers.last?.id)
    }

    private static func snapshot(of document: CanvasDocument, activeLayerID: UUID?) -> ProjectSnapshot {
        var images: [UUID: ImportedImage] = [:]
        var masks: [UUID: ImportedImage] = [:]
        var smartObjects: [UUID: ProjectSnapshot] = [:]
        let layers = document.layers.map { layer in
            if let smart = layer.liveSmartObject { smartObjects[layer.id] = snapshot(of: smart.content) }
            if let asset = layer.asset { images[layer.id] = asset }
            if let mask = layer.mask { masks[layer.id] = mask.asset }
            return ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: layer.isVisible,
                transform: layer.transform, imageFile: layer.asset == nil ? nil : "\(layer.id.uuidString).png", parentID: layer.parentID, isGroup: layer.isGroup, opacity: layer.opacity, blendMode: layer.blendMode, maskFile: layer.mask == nil ? nil : "\(layer.id.uuidString).mask.png", maskEnabled: layer.mask?.isEnabled, maskSourceID: layer.maskSourceID, adjustment: layer.adjustment, maskPlacement: layer.mask?.placement, maskLinked: layer.mask?.isLinked, shape: layer.liveShape?.style, effects: layer.effects, text: layer.liveText?.style, smartObject: layer.liveSmartObject == nil ? nil : true)
        }
        return ProjectSnapshot(manifest: ProjectManifest(resolution: document.resolution, documentID: document.id, width: document.width,
            height: document.height, activeLayerID: activeLayerID, layers: layers,
            guides: document.guides.isEmpty ? nil : document.guides), images: images, masks: masks, smartObjects: smartObjects)
    }

    /// The layers a loaded snapshot holds, smart objects included.
    static func layers(from snapshot: ProjectSnapshot) -> [ImageLayer] {
        snapshot.manifest.layers.map {
            ImageLayer(id: $0.id, asset: snapshot.images[$0.id], name: $0.name,
                       isVisible: $0.isVisible, transform: $0.transform, parentID: $0.parentID, isGroup: $0.isGroup == true, opacity: $0.opacity ?? 1, blendMode: $0.blendMode ?? .normal, mask: snapshot.mask(for: $0), maskSourceID: $0.maskSourceID, adjustment: $0.adjustment,
                       shape: LayerShape.loaded($0.shape, image: snapshot.images[$0.id]?.image),
                       effects: $0.effects,
                       text: LayerText.loaded($0.text, image: snapshot.images[$0.id]?.image),
                       smartObject: smartObject(for: $0, in: snapshot))
        }
    }

    private static func smartObject(for record: ProjectLayerRecord, in snapshot: ProjectSnapshot) -> LayerSmartObject? {
        guard record.smartObject == true, let image = snapshot.images[record.id]?.image,
              let nested = snapshot.smartObjects[record.id] else { return nil }
        let manifest = nested.manifest
        return LayerSmartObject(content: SmartObjectContent(id: manifest.documentID, width: manifest.width, height: manifest.height,
                                                            resolution: manifest.resolution ?? 72, layers: layers(from: nested)), image: image)
    }

    /// Called only after the entire package has successfully validated and loaded.
    func installProject(_ snapshot: ProjectSnapshot, from url: URL) {
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        guideDrag = nil
        let manifest = snapshot.manifest
        transformEdit = nil
        document = CanvasDocument(id: manifest.documentID, width: manifest.width, height: manifest.height,
            layers: Self.layers(from: snapshot), resolution: manifest.resolution ?? 72, guides: manifest.guides ?? [])
        activeLayerID = manifest.activeLayerID
        projectURL = url
        renamingLayerID = nil
        history.reset()
        viewport.fit(documentSize: document!.size)
    }

    /// Replaces the document with what its package holds now, after something else wrote it. Unlike `installProject`
    /// it keeps the viewport, the collapsed folders and the selection where those layers still exist, so the
    /// reload is invisible beyond the change itself. Undo history is session-only and starts over, as after an open.
    func reloadProject(_ snapshot: ProjectSnapshot) {
        guard let url = projectURL else { return }
        let viewport = self.viewport
        let collapsed = collapsedGroupIDs
        let active = activeLayerID
        let selected = selectedLayerIDs
        installProject(snapshot, from: url)
        self.viewport = viewport
        let ids = Set(snapshot.manifest.layers.map(\.id))
        collapsedGroupIDs = collapsed.intersection(ids)
        if let active, ids.contains(active) {
            activeLayerID = active
            selectedLayerIDs = selected.intersection(ids).union([active])
        }
    }

    func clearProject() {
        collapsedGroupIDs = []
        isMaskSelected = false
        cancelCrop()
        transformEdit = nil
        guideDrag = nil
        document = nil
        activeLayerID = nil
        renamingLayerID = nil
        projectURL = nil
        history.reset()
    }

    func createNewProject(width: Int, height: Int) {
        guard !isProjectBusy, !isImporting, (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else { return }
        clearProject()
        createDocument(width: width, height: height, emptyLayer: true)
    }
}
