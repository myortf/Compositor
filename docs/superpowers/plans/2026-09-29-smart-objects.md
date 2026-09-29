# Smart Objects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert one raster layer into a Smart Object whose contents open in their own project tab, and apply the edits back to the layer when that tab closes or the user returns to the parent.

**Architecture:** `ImageLayer` gains an optional `smartObject` (nested `CanvasDocument` contents plus the identity of the flattened render, the same "live only while the pixels are untouched" trick `LayerShape`/`LayerText` use). The shell layer's `asset` stays the flattened render, so no renderer or exporter changes. The nested document is edited in an ordinary `ProjectTab` tagged with its parent; closing it flattens via `drawLiveComposite` and writes one undo step in the parent. On disk each smart object is a nested package (`smartobjects/<layer UUID>/manifest.json` + `images/`) written and read by the same `ProjectStore` code, recursively.

**Tech Stack:** Swift, SwiftUI + AppKit, Swift Testing (`import Testing`), `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-09-29-smart-objects-design.md` (two deviations, decided while planning and recorded in Task 6: no format-version bump, and a canvas resize inside the smart object rescales the shell footprint).

## Global Constraints

- macOS app, Swift; match surrounding code style, naming and comment density; American spelling.
- Build: `xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' build`.
- Tests: `xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' test -only-testing:CompositorTests/<Suite>` (Swift Testing, `@MainActor struct ...Tests`, `@Test`, `#expect`).
- New layer-record field is optional and NOT gated on the format version (same as `shape`/`effects`); `ProjectManifest.current` stays 11. Older builds ignore the field and the `smartobjects/` folder and show the layer's own PNG.
- Limits reuse `DocumentLimits` (per-side, pixel budget, layer count); the pixel budget is shared across the whole package including nested levels.
- Nested depth at most 8 levels.
- No live per-edit update: apply happens only on tab close or return to parent.
- v1 converts exactly one selected non-group, non-adjustment, non-shape, non-text layer that has an image asset.

## Review Focus

- Deleting the smart-object layer (or undoing its creation) while its nested tab is open: closing the nested tab must discard silently, not crash or resurrect the layer.
- Closing the parent tab or quitting while a nested tab has edits: nested applies first, then the parent's normal save prompt runs.
- Painting, filtering or inverting the shell layer's pixels: it stops being a smart object (plain pixels) instead of later overwriting the paint when the nested tab is reopened.
- Opening the same smart object twice: reuses the existing tab.
- A `.comp` whose nested package is missing, damaged, oversized or nested too deep: the whole open is rejected with an error, never a half-loaded document.

---

### Task 1: Data model and copy propagation

**Files:**
- Create: `Compositor/Document/SmartObject.swift`
- Modify: `Compositor/Document/EditorSession.swift` (`ImageLayer`: `==`, field, init)
- Modify: `Compositor/Document/SelectionClipboard.swift` (`insertCopy`, ~line 226 and the paste site ~line 255)
- Modify: `Compositor/Document/ProjectWorkspace.swift` (`copyLayers`, ~line 241)
- Modify: `Compositor/IO/CanvasResizer.swift` (~line 31)
- Test: `CompositorTests/SmartObjectTests.swift`

**Interfaces:**
- Produces:
  - `struct SmartObjectContent: Equatable { var id: UUID; var width: Int; var height: Int; var resolution: Double; var layers: [ImageLayer] }`
  - `struct LayerSmartObject: Equatable, @unchecked Sendable { var content: SmartObjectContent; let image: CGImage }` (equality compares `content` and `image ===`)
  - `ImageLayer.smartObject: LayerSmartObject?`, `ImageLayer.liveSmartObject: LayerSmartObject?` (nil once `asset.image !== smartObject.image`)
  - `ImageLayer.init(... , smartObject: LayerSmartObject? = nil)` as the last parameter of the full initializer.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import AppKit
@testable import Compositor

@MainActor
struct SmartObjectTests {
    static func image(_ width: Int, _ height: Int, gray: CGFloat = 0.5) throws -> ImportedImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Pixels")
    }

    @Test func smartObjectIsLiveOnlyWhileItsPixelsAreUntouched() throws {
        let asset = try Self.image(8, 6)
        var layer = ImageLayer(asset: asset, origin: .zero)
        let inner = ImageLayer(asset: asset, origin: .zero)
        layer.smartObject = LayerSmartObject(content: SmartObjectContent(id: UUID(), width: 8, height: 6, resolution: 72, layers: [inner]), image: asset.image)
        #expect(layer.liveSmartObject != nil)
        layer.asset = try Self.image(8, 6, gray: 0.2)
        #expect(layer.liveSmartObject == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' test -only-testing:CompositorTests/SmartObjectTests`
Expected: build FAIL, `cannot find 'LayerSmartObject' in scope`.

- [ ] **Step 3: Implement**

`Compositor/Document/SmartObject.swift`:

```swift
import CoreGraphics
import Foundation

/// The document a smart object holds: what its tab edits, and what is flattened onto the layer.
struct SmartObjectContent: Equatable {
    var id = UUID()
    var width: Int
    var height: Int
    var resolution: Double
    var layers: [ImageLayer]
    var document: CanvasDocument { CanvasDocument(id: id, width: width, height: height, layers: layers, resolution: resolution) }
}

/// A layer that wraps a nested document. Its pixels are an ordinary raster, the flattened render, so it clips, masks,
/// blends and exports like any layer; `image` is that render. Once anything else changes the layer's pixels the image
/// is no longer this one and the layer is plain pixels from then on.
struct LayerSmartObject: Equatable, @unchecked Sendable {
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
```

`EditorSession.swift`: add `var smartObject: LayerSmartObject?` after `var text: LayerText?`; append `&& lhs.smartObject == rhs.smartObject` to `==`; add `smartObject: LayerSmartObject? = nil` as the last init parameter and `self.smartObject = smartObject`.

`SelectionClipboard.swift` `insertCopy`: add `smartObject: original.smartObject` (the copy shares the same immutable content; ids of nested layers are reused, which is fine because they live in a separate document). Check the paste site near line 255 (`layer.shape = shape; layer.text = text`) and leave it alone unless it clones an existing layer.

`ProjectWorkspace.copyLayers`: add `smartObject: layer.smartObject` to the `ImageLayer(...)` call.

`CanvasResizer.swift`: read the map at line ~31; where `shape: layer.shape, text: layer.text` is preserved for operations that keep the pixels (Canvas Size, Crop), add `smartObject: layer.smartObject`. Where pixels are resampled the new asset has a new image identity, so `liveSmartObject` goes nil by itself.

- [ ] **Step 4: Run to verify it passes**

Run the same command. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Compositor/Document/SmartObject.swift Compositor/Document/EditorSession.swift Compositor/Document/SelectionClipboard.swift Compositor/Document/ProjectWorkspace.swift Compositor/IO/CanvasResizer.swift CompositorTests/SmartObjectTests.swift
git commit -m "feat: smart object layer model"
```

---

### Task 2: Persist smart objects in the `.comp` package

**Files:**
- Modify: `Compositor/IO/ProjectStore.swift` (`ProjectLayerRecord`, `ProjectSnapshot`, `save`, `readPackage`, `validate`)
- Modify: `Compositor/Document/EditorSession+Projects.swift` (`projectSnapshot`, `installProject`)
- Modify: `docs/project-format.md`
- Test: `CompositorTests/SmartObjectTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces:
  - `ProjectLayerRecord.smartObject: Bool? = nil` (true means a nested package exists at `smartobjects/<layer UUID>/`).
  - `ProjectSnapshot.smartObjects: [UUID: ProjectSnapshot] = [:]` keyed by layer id.
  - `ProjectSnapshot.smartObjectContent(for record: ProjectLayerRecord, image: CGImage?) -> LayerSmartObject?`
  - `EditorSession.snapshot(of content: SmartObjectContent) -> ProjectSnapshot` (nested snapshot builder shared by `projectSnapshot()`).
  - `ProjectStore.maxSmartObjectDepth = 8`.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func smartObjectSurvivesSaveAndReopen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SmartObjectTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        let asset = try Self.image(8, 6)
        var shell = ImageLayer(asset: asset, origin: CGPoint(x: 3, y: 4))
        let inner = ImageLayer(asset: asset, origin: .zero)
        shell.smartObject = LayerSmartObject(content: SmartObjectContent(width: 8, height: 6, resolution: 72, layers: [inner]), image: asset.image)
        session.document?.layers.append(shell)
        let url = root.appendingPathComponent("a.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        let layer = try #require(reopened.document?.layers.first { $0.id == shell.id })
        let smart = try #require(layer.liveSmartObject)
        #expect(smart.content.layers.count == 1)
        #expect(smart.content.layers[0].id == inner.id)
        #expect(smart.content.width == 8 && smart.content.height == 6)
    }

    @Test func smartObjectWithMissingNestedPackageIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SmartObjectTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        let asset = try Self.image(8, 6)
        var shell = ImageLayer(asset: asset, origin: .zero)
        shell.smartObject = LayerSmartObject(content: SmartObjectContent(width: 8, height: 6, resolution: 72, layers: [ImageLayer(asset: asset, origin: .zero)]), image: asset.image)
        session.document?.layers.append(shell)
        let url = root.appendingPathComponent("a.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        try FileManager.default.removeItem(at: url.appendingPathComponent("smartobjects"))
        await #expect(throws: ProjectError.self) { _ = try await ProjectStore.shared.load(from: url) }
    }

    @Test func smartObjectNestedTooDeepIsRejectedOnSave() async throws {
        let asset = try Self.image(4, 4)
        var content = SmartObjectContent(width: 4, height: 4, resolution: 72, layers: [ImageLayer(asset: asset, origin: .zero)])
        for _ in 0..<(ProjectStore.maxSmartObjectDepth + 1) {
            var shell = ImageLayer(asset: asset, origin: .zero)
            shell.smartObject = LayerSmartObject(content: content, image: asset.image)
            content = SmartObjectContent(width: 4, height: 4, resolution: 72, layers: [shell])
        }
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        var top = ImageLayer(asset: asset, origin: .zero)
        top.smartObject = LayerSmartObject(content: content, image: asset.image)
        session.document?.layers.append(top)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deep-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url) }
    }
```

- [ ] **Step 2: Run to verify they fail**

Expected: build FAIL (`smartObjects`, `maxSmartObjectDepth` missing).

- [ ] **Step 3: Implement**

`ProjectStore.swift`:
- `ProjectLayerRecord`: add `var smartObject: Bool? = nil` with a doc comment "A nested package at smartobjects/<id>/; older builds ignore it and keep the pixels."
- `ProjectSnapshot`: add `var smartObjects: [UUID: ProjectSnapshot] = [:]` and
```swift
    /// A smart object layer's nested contents, or nil when the record has none or the layer's image is missing.
    func smartObject(for record: ProjectLayerRecord, image: CGImage?) -> LayerSmartObject? {
        guard record.smartObject == true, let image, let nested = smartObjects[record.id] else { return nil }
        return LayerSmartObject(content: nested.content(), image: image)
    }
    /// The layers of this snapshot as a smart object's contents.
    func content() -> SmartObjectContent {
        SmartObjectContent(id: manifest.documentID, width: manifest.width, height: manifest.height,
                           resolution: manifest.resolution ?? 72, layers: EditorSession.layers(from: self))
    }
```
  (`EditorSession.layers(from:)` is extracted from `installProject`, Step below.)
- Refactor `save` into `func save(...)` calling a private `packageContents(_ snapshot: ProjectSnapshot, depth: Int, pixels: inout Int, maskPixels: inout Int) throws -> [String: FileWrapper]` (everything currently between `try validate(snapshot.manifest)` and building `contents`, plus for each layer with `smartObject == true`: `guard depth < Self.maxSmartObjectDepth, let nested = snapshot.smartObjects[layer.id] else { throw ProjectError.invalid }`, recurse with `depth + 1`, and put the resulting `FileWrapper(directoryWithFileWrappers:)` under `smartobjects/<uuid>`). The top-level `contents` keeps `manifest.json`, `images`, optional `QuickLook`, and gains `"smartobjects"` only when non-empty. The nested package holds just `manifest.json`, `images` and its own `smartobjects`.
- Refactor `readPackage(_ url:)` into `readPackage(_ url: URL, depth: Int, pixels: inout Int, maskPixels: inout Int)` with the same body; after images/masks, for each layer with `smartObject == true`: `guard depth < Self.maxSmartObjectDepth else { throw ProjectError.invalid }`, `let folder = url.appendingPathComponent("smartobjects").appendingPathComponent(layer.id.uuidString)`, `try checkFile(folder.appendingPathComponent("manifest.json"), inside: url, maximumBytes: 4 * 1024 * 1024)` (missing file throws), then `nested[layer.id] = try readPackage(folder, depth: depth + 1, pixels: &pixels, maskPixels: &maskPixels)`. `load(from:)` calls it with depth 0 and zero counters. Note `checkFile(_, inside: package)` is passed the top-level package for the containment check; keep passing the outermost URL (add a `root: URL` parameter threaded through).
- `validate`: `layer.smartObject == true` requires `layer.imageFile != nil`, `layer.isGroup != true`, `layer.adjustment == nil`, `layer.text == nil`, `layer.shape == nil`; otherwise `ProjectError.invalid`.
- `static let maxSmartObjectDepth = 8` on `ProjectStore`.

`EditorSession+Projects.swift`:
- Extract `static func layers(from snapshot: ProjectSnapshot) -> [ImageLayer]` from the `manifest.layers.map { ImageLayer(...) }` in `installProject`, adding `smartObject: snapshot.smartObject(for: $0, image: snapshot.images[$0.id]?.image)` to each layer; `installProject` calls it.
- `projectSnapshot()`: build the nested snapshot for every layer whose `liveSmartObject` is non-nil: `smartObjects[layer.id] = Self.snapshot(of: smart.content)`, set the record's `smartObject: layer.liveSmartObject == nil ? nil : true`. `static func snapshot(of content: SmartObjectContent) -> ProjectSnapshot` is the current body of `projectSnapshot()` generalized to take a `CanvasDocument` and `activeLayerID` (nil for nested), and `projectSnapshot()` calls it with `document` and `activeLayerID`. The recursion follows the nested layers' own smart objects.

`docs/project-format.md`: add a bullet under "Additive layer fields": `smartObject`: true on a layer whose flattened PNG has nested contents in `smartobjects/<layer UUID>/`, itself a full package (`manifest.json`, `images/`, and `smartobjects/` again, at most 8 levels deep); pixel budgets and limits count the whole package. Older builds ignore it and render the layer's PNG.

- [ ] **Step 4: Run to verify they pass**

Run: `xcodebuild ... test -only-testing:CompositorTests/SmartObjectTests -only-testing:CompositorTests/ProjectTests`
Expected: PASS (existing project tests still pass).

- [ ] **Step 5: Commit**

```bash
git add Compositor/IO/ProjectStore.swift Compositor/Document/EditorSession+Projects.swift docs/project-format.md CompositorTests/SmartObjectTests.swift
git commit -m "feat: save and load smart object contents as nested packages"
```

---

### Task 3: Convert to Smart Object

**Files:**
- Modify: `Compositor/Document/SmartObject.swift` (`EditorSession` extension)
- Modify: `Compositor/UI/NativeLayerList.swift` (context menu, ~line 111-230, action selectors ~line 244-300)
- Modify: `Compositor/CompositorApp.swift` (Layer menu near line 329)
- Test: `CompositorTests/SmartObjectTests.swift`

**Interfaces:**
- Consumes: Task 1 types.
- Produces: `EditorSession.canConvertToSmartObject: Bool`, `EditorSession.convertToSmartObject()` (one undo step "Convert to Smart Object").

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func convertingAPlainLayerKeepsItsPixelsAndUndoes() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        let asset = try Self.image(8, 6)
        session.document?.layers.append(ImageLayer(asset: asset, origin: CGPoint(x: 5, y: 5)))
        session.activeLayerID = session.document?.layers.last?.id
        session.selectedLayerIDs = [try #require(session.activeLayerID)]
        #expect(session.canConvertToSmartObject)
        session.convertToSmartObject()
        let layer = try #require(session.activeLayer)
        #expect(layer.asset?.image === asset.image)
        let smart = try #require(layer.liveSmartObject)
        #expect(smart.content.width == 8 && smart.content.height == 6)
        #expect(smart.content.layers.count == 1)
        #expect(smart.content.layers[0].transform.origin == .zero)
        #expect(!session.canConvertToSmartObject)
        session.undo()
        #expect(session.activeLayer?.smartObject == nil)
    }

    @Test func convertIsUnavailableForGroupsEmptyLayersAndSeveralLayers() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        session.addBlankLayer()
        #expect(!session.canConvertToSmartObject)
        let a = ImageLayer(asset: try Self.image(4, 4), origin: .zero)
        let b = ImageLayer(asset: try Self.image(4, 4), origin: .zero)
        session.document?.layers.append(contentsOf: [a, b])
        session.selectLayers([a.id, b.id], primary: b.id)
        #expect(!session.canConvertToSmartObject)
    }
```

- [ ] **Step 2: Run to verify they fail** — build FAIL, `canConvertToSmartObject` missing.

- [ ] **Step 3: Implement**

```swift
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
        let width = asset.image.width, height = asset.image.height
        var inner = ImageLayer(asset: asset, origin: .zero)
        inner.name = layer.name
        let content = SmartObjectContent(width: width, height: height, resolution: document.resolution, layers: [inner])
        finishOpacityEdit()
        beginEdit("Convert to Smart Object")
        self.document?.layers[index].smartObject = LayerSmartObject(content: content, image: asset.image)
        endEdit()
    }
}
```

UI: in `NativeLayerList.contextMenu(for:)` add, next to the Merge item, `NSMenuItem(title: "Convert to Smart Object", action: #selector(convertToSmartObjectAction), keyEquivalent: "")` (hidden when the layer is already a smart object; validate with `session.canConvertToSmartObject` in the existing `validateMenuItem` switch) plus `@objc func convertToSmartObjectAction(_ sender: Any?) { session.convertToSmartObject() }`. Add `Button("Convert to Smart Object") { session.convertToSmartObject() }.disabled(!session.canConvertToSmartObject)` beside the merge button in `CompositorApp.swift`.

- [ ] **Step 4: Run tests** — `-only-testing:CompositorTests/SmartObjectTests`. Expected: PASS. Then run the full `build`.

- [ ] **Step 5: Commit**

```bash
git add Compositor/Document/SmartObject.swift Compositor/UI/NativeLayerList.swift Compositor/CompositorApp.swift CompositorTests/SmartObjectTests.swift
git commit -m "feat: convert a layer to a smart object"
```

---

### Task 4: Open smart object contents in a tab

**Files:**
- Modify: `Compositor/Document/ProjectWorkspace.swift` (`ProjectTab`, `ProjectWorkspace`)
- Modify: `Compositor/Document/SmartObject.swift` (`EditorSession.installSmartObject`)
- Modify: `Compositor/UI/NativeLayerList.swift` (double-click on thumbnail, context menu item)
- Modify: tab strip title (find with `grep -rn "\.title" Compositor/UI | grep -i tab`)
- Test: `CompositorTests/SmartObjectTests.swift`

**Interfaces:**
- Consumes: Tasks 1, 3.
- Produces:
  - `ProjectTab.smartObjectSource: (tabID: UUID, layerID: UUID)?`
  - `EditorSession.installSmartObject(_ content: SmartObjectContent)`
  - `ProjectWorkspace.openSmartObject(layerID: UUID)` (uses the current tab as parent; selects and returns the existing tab if one already edits that layer)
  - `ProjectWorkspace.smartObjectTab(for layerID: UUID, in parent: UUID) -> ProjectTab?`
  - `ProjectTab.title` returns `"◆ \(name)"` for smart object tabs, where name is the layer name at open time.

- [ ] **Step 1: Write the failing tests**

```swift
    @Test func openingASmartObjectMakesATabOnceAndReusesIt() throws {
        let workspace = ProjectWorkspace()
        let parent = workspace.current
        parent.session.createDocument(width: 40, height: 30)
        parent.session.document?.layers.append(ImageLayer(asset: try Self.image(8, 6), origin: .zero))
        parent.session.activeLayerID = parent.session.document?.layers.last?.id
        parent.session.selectedLayerIDs = [try #require(parent.session.activeLayerID)]
        parent.session.convertToSmartObject()
        let layerID = try #require(parent.session.activeLayerID)
        workspace.openSmartObject(layerID: layerID)
        #expect(workspace.tabs.count == 2)
        let nested = workspace.current
        #expect(nested.id != parent.id)
        #expect(nested.session.document?.width == 8)
        #expect(nested.smartObjectSource?.layerID == layerID)
        workspace.select(parent.id)
        workspace.openSmartObject(layerID: layerID)
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current.id == nested.id)
    }
```
(Task 5 changes `select` to apply on return; the test stays valid because nothing changed inside.)

- [ ] **Step 2: Run to verify it fails** — build FAIL, `openSmartObject` missing.

- [ ] **Step 3: Implement**

`ProjectTab`: add `var smartObjectSource: (tabID: UUID, layerID: UUID)?` and `var smartObjectName: String?`; `title` returns `smartObjectName.map { "◆ \($0)" } ?? existing`.

`EditorSession.installSmartObject`:
```swift
    /// Shows a smart object's contents as this session's document, as a project that was just opened.
    func installSmartObject(_ content: SmartObjectContent) {
        collapsedGroupIDs = []
        isMaskSelected = false
        transformEdit = nil
        document = content.document
        activeLayerID = content.layers.last?.id
        selectedLayerIDs = activeLayerID.map { [$0] } ?? []
        projectURL = nil
        renamingLayerID = nil
        history.reset()
        viewport.fit(documentSize: document!.size)
    }
```
`ProjectWorkspace`:
```swift
    func smartObjectTab(for layerID: UUID, in parent: UUID) -> ProjectTab? {
        tabs.first { $0.smartObjectSource?.tabID == parent && $0.smartObjectSource?.layerID == layerID }
    }
    /// Opens the current tab's smart object layer in a tab of its own, or brings its tab forward.
    func openSmartObject(layerID: UUID) {
        guard canSwitch, let layer = current.session.document?.layers.first(where: { $0.id == layerID }),
              let smart = layer.liveSmartObject else { return }
        let parent = current
        if let existing = smartObjectTab(for: layerID, in: parent.id) { select(existing.id); return }
        parent.session.commitTransform()
        let tab = addTab(reuseEmpty: false)
        tab.smartObjectSource = (parent.id, layerID)
        tab.smartObjectName = layer.name
        tab.session.installSmartObject(smart.content)
    }
```
UI: in `renameClickedLayer`, inside the `cell?.isOnControl(point)` branch add `if rows[table.clickedRow].liveSmartObject != nil { workspace?.openSmartObject(layerID: id); return }` (the table coordinator needs the workspace; find how other rows reach it, `grep -n "workspace" Compositor/UI/NativeLayerList.swift Compositor/UI/LayersPanel.swift`, and thread it the same way). Add context menu item "Edit Smart Object Contents" shown only for live smart objects, action calls `openSmartObject`. Add a small badge to the layer thumbnail cell for live smart objects (an SF Symbol `square.stack.3d.up.fill` corner overlay in `LayerCell`, mirroring how text layers show their marker; follow that code).

- [ ] **Step 4: Run tests** — `-only-testing:CompositorTests/SmartObjectTests -only-testing:CompositorTests/ProjectWorkspaceTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A Compositor CompositorTests
git commit -m "feat: open a smart object's contents in a project tab"
```

---

### Task 5: Apply edits back on close or return

**Files:**
- Modify: `Compositor/Document/SmartObject.swift` (`flattenedSmartObject`, `applySmartObject`)
- Modify: `Compositor/Document/ProjectWorkspace.swift` (`select`, `close`, `confirmQuit`, `removeTab`)
- Test: `CompositorTests/SmartObjectTests.swift`

**Interfaces:**
- Consumes: Task 4.
- Produces:
  - `EditorSession.flattenedSmartObjectContent(from source: SmartObjectContent) -> (content: SmartObjectContent, image: ImportedImage)?` (on the nested session; nil when nothing changed or rendering fails).
  - `ProjectWorkspace.applySmartObject(from tab: ProjectTab)` (writes into the parent; silent no-op when the parent or layer is gone).

- [ ] **Step 1: Write the failing tests**

```swift
    private func workspaceWithOpenSmartObject() throws -> (ProjectWorkspace, ProjectTab, ProjectTab, UUID) {
        let workspace = ProjectWorkspace()
        let parent = workspace.current
        parent.session.createDocument(width: 40, height: 30)
        parent.session.document?.layers.append(ImageLayer(asset: try Self.image(8, 6), origin: CGPoint(x: 2, y: 2)))
        let id = try #require(parent.session.document?.layers.last?.id)
        parent.session.activeLayerID = id
        parent.session.selectedLayerIDs = [id]
        parent.session.convertToSmartObject()
        workspace.openSmartObject(layerID: id)
        return (workspace, parent, workspace.current, id)
    }

    @Test func closingAnEditedSmartObjectTabUpdatesTheLayerInOneUndoStep() async throws {
        let (workspace, parent, nested, id) = try workspaceWithOpenSmartObject()
        let before = try #require(parent.session.document?.layers.first { $0.id == id }?.asset?.image)
        nested.session.addBlankLayer()
        nested.session.document?.layers[nested.session.document!.layers.count - 1].asset = try Self.image(8, 6, gray: 1)
        let undoCount = parent.session.history.undoCount
        await workspace.close(nested.id)
        #expect(workspace.tabs.count == 1)
        let layer = try #require(parent.session.document?.layers.first { $0.id == id })
        #expect(layer.asset?.image !== before)
        #expect(layer.liveSmartObject?.content.layers.count == 2)
        #expect(parent.session.history.undoCount == undoCount + 1)
        #expect(parent.session.history.undoName == "Update Smart Object")
    }

    @Test func closingAnUntouchedSmartObjectTabRecordsNothing() async throws {
        let (workspace, parent, nested, _) = try workspaceWithOpenSmartObject()
        let undoCount = parent.session.history.undoCount
        await workspace.close(nested.id)
        #expect(parent.session.history.undoCount == undoCount)
    }

    @Test func closingASmartObjectTabWhoseLayerWasDeletedDiscardsQuietly() async throws {
        let (workspace, parent, nested, id) = try workspaceWithOpenSmartObject()
        nested.session.addBlankLayer()
        parent.session.document?.layers.removeAll { $0.id == id }
        await workspace.close(nested.id)
        #expect(workspace.tabs.count == 1)
        #expect(parent.session.document?.layers.contains { $0.id == id } == false)
    }

    @Test func returningToTheParentAppliesTheEdits() throws {
        let (workspace, parent, nested, id) = try workspaceWithOpenSmartObject()
        nested.session.addBlankLayer()
        workspace.select(parent.id)
        #expect(parent.session.document?.layers.first { $0.id == id }?.liveSmartObject?.content.layers.count == 2)
    }
```

- [ ] **Step 2: Run to verify they fail** — the first fails on `layer.asset?.image !== before`.

- [ ] **Step 3: Implement**

`SmartObject.swift` (session):
```swift
extension EditorSession {
    /// The smart object's contents as they stand in this tab, flattened at their own pixel size; nil when nothing
    /// changed from `source` or the render failed.
    func flattenedSmartObjectContent(from source: SmartObjectContent) -> (content: SmartObjectContent, image: ImportedImage)? {
        commitTransform()
        guard let document else { return nil }
        let changed = document.width != source.width || document.height != source.height
            || document.resolution != source.resolution || document.layers != source.layers
        guard changed,
              let context = try? BrushRaster.context(width: document.width, height: document.height, mask: false) else { return nil }
        drawLiveComposite(document, in: context)
        guard let image = context.makeImage(), let thumbnail = try? PixelAdjust.thumbnail(of: image) else { return nil }
        let content = SmartObjectContent(id: source.id, width: document.width, height: document.height,
                                         resolution: document.resolution, layers: document.layers)
        return (content, ImportedImage(image: image, thumbnail: thumbnail, name: source.layers.first?.name ?? "Smart Object"))
    }
}
```
`ProjectWorkspace`:
```swift
    /// Writes a smart object tab's edits into its layer in the parent tab, as one undo step there. Nothing happens
    /// when nothing changed, or when the parent or the layer is gone (deleted, undone, rasterized).
    func applySmartObject(from tab: ProjectTab) {
        guard let source = tab.smartObjectSource,
              let parent = tabs.first(where: { $0.id == source.tabID }),
              let index = parent.session.document?.layers.firstIndex(where: { $0.id == source.layerID }),
              let layer = parent.session.document?.layers[index], let smart = layer.liveSmartObject,
              let result = tab.session.flattenedSmartObjectContent(from: smart.content) else { return }
        let scaleX = CGFloat(result.content.width) / CGFloat(smart.content.width)
        let scaleY = CGFloat(result.content.height) / CGFloat(smart.content.height)
        var transform = layer.transform
        let center = transform.center
        transform.size = CGSize(width: transform.size.width * scaleX, height: transform.size.height * scaleY)
        transform.origin = CGPoint(x: center.x - transform.size.width / 2, y: center.y - transform.size.height / 2)
        parent.session.finishOpacityEdit()
        parent.session.beginEdit("Update Smart Object")
        parent.session.document?.layers[index].asset = result.image
        parent.session.document?.layers[index].transform = transform
        parent.session.document?.layers[index].smartObject = LayerSmartObject(content: result.content, image: result.image.image)
        parent.session.endEdit()
    }
```
(If `transform.center`/`origin` are defined differently for rotated layers, read `LayerTransform.swift` and keep the rotation center fixed the same way; with equal scale factors `transform` is untouched.)

Hooks:
- `select(_:)`: before switching away, `if let tab = tabs.first(where: { $0.id == selectedID }), tab.smartObjectSource != nil { applySmartObject(from: tab) }`. The nested tab's own edited content must stay reopenable: after applying, update the nested tab's baseline. Simplest: keep the tab alive and re-`installSmartObject` is wrong (loses undo); instead store `tab.smartObjectBaseline` and refresh it inside `applySmartObject`. Add `var smartObjectBaseline: SmartObjectContent?` to `ProjectTab`, set in `openSmartObject`, compared/updated in `applySmartObject` (use it in place of `smart.content` for the "changed" check and set it to `result.content` after applying).
- `close(_:)`: for a smart object tab skip `confirmQuit` (no save prompt), call `applySmartObject(from:)`, select the parent if it exists, then `removeTab`.
- `confirmQuit()` (app quit / window close): before the loop, apply every smart object tab (`for tab in tabs where tab.smartObjectSource != nil { applySmartObject(from: tab) }`), then drop them from the prompt list (`quitOrder.filter { $0.smartObjectSource == nil }`), so only real documents prompt. After quit, smart object tabs are removed by `closeWindow`'s `tabs.removeAll()`.
- `removeTab(_:)`: when a parent tab is removed, also remove tabs whose `smartObjectSource?.tabID` equals it after applying them (apply first).

- [ ] **Step 4: Run tests** — `-only-testing:CompositorTests/SmartObjectTests -only-testing:CompositorTests/ProjectWorkspaceTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add -A Compositor CompositorTests
git commit -m "feat: apply smart object edits to the layer on close or return"
```

---

### Task 6: Docs, spec sync, full verification

**Files:**
- Modify: `docs/superpowers/specs/2026-09-29-smart-objects-design.md`
- Modify: `README.md` (feature list, if it lists layer features)

- [ ] **Step 1: Sync the spec with what was built.** In the File format section replace the version-12 paragraph with: additive, ungated field `smartObject: true`, nested packages under `smartobjects/<layer UUID>/`, depth 8, no version bump, older builds show the flattened PNG. In Edge cases, replace the canvas-resize bullet with: the shell footprint scales by the ratio of new to old nested pixel size around its center. Drop the "pre-bump version rejected" test line; add the missing-nested-package and too-deep tests.
- [ ] **Step 2: Add a line to `README.md`** where layer features are listed (skip if it has no such list).
- [ ] **Step 3: Run the full suite:** `xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' test -only-testing:CompositorTests`. Expected: PASS, no regressions.
- [ ] **Step 4: Launch the app and exercise the flow by hand:** import an image, right-click the layer, Convert to Smart Object; double-click its thumbnail; paint in the new tab; close it; confirm the parent shows the paint and Undo removes it; save, reopen, open the smart object again.
- [ ] **Step 5: Commit**

```bash
git add docs README.md
git commit -m "docs: smart objects spec and format notes"
```
