import Testing
import AppKit
@testable import Compositor

@MainActor
struct SmartObjectTabTests {
    static func image(_ width: Int, _ height: Int, gray: CGFloat = 0.5) throws -> ImportedImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(gray: gray, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image), name: "Pixels")
    }

    /// A layer wrapping `layers` as its smart object, shown as `asset` (the flattened render).
    static func smartLayer(_ asset: ImportedImage, at origin: CGPoint = .zero, holding layers: [ImageLayer]? = nil) -> ImageLayer {
        var shell = ImageLayer(asset: asset, origin: origin)
        let content = SmartObjectContent(width: asset.image.width, height: asset.image.height, resolution: 72,
                                         layers: layers ?? [ImageLayer(asset: asset, origin: .zero)])
        shell.smartObject = LayerSmartObject(content: content, image: asset.image)
        return shell
    }

    /// A workspace whose first tab holds one smart object layer, with that layer's tab opened and in front.
    private func workspaceWithOpenSmartObject() throws -> (workspace: ProjectWorkspace, parent: ProjectTab, nested: ProjectTab, layerID: UUID) {
        let workspace = ProjectWorkspace()
        let parent = workspace.current
        parent.session.createDocument(width: 40, height: 30)
        let shell = Self.smartLayer(try Self.image(8, 6), at: CGPoint(x: 2, y: 2))
        parent.session.document?.layers.append(shell)
        parent.session.activeLayerID = shell.id
        workspace.openSmartObject(layerID: shell.id)
        return (workspace, parent, workspace.current, shell.id)
    }

    private func layer(_ id: UUID, in tab: ProjectTab) -> ImageLayer? { tab.session.document?.layers.first { $0.id == id } }

    /// Paints the nested tab's top layer, so its contents differ from what the parent layer shows.
    private func edit(_ nested: ProjectTab) throws {
        nested.session.addBlankLayer()
        let top = try #require(nested.session.document?.layers.count) - 1
        nested.session.document?.layers[top].asset = try Self.image(8, 6, gray: 1)
    }

    /// Runs `operation` while answering any Save alert it raises with Don't Save; returns its result and the alerts seen.
    private func answeringAlerts(on window: NSWindow, _ operation: @escaping @MainActor () async -> Bool) async throws -> (result: Bool, alerts: Int) {
        func discard(in view: NSView) -> NSButton? {
            if let button = view as? NSButton, button.title == "Don’t Save" { return button }
            return view.subviews.lazy.compactMap { discard(in: $0) }.first
        }
        var finished = false
        let task = Task { @MainActor in
            let result = await operation()
            finished = true
            return result
        }
        var alerts = 0
        for _ in 0..<300 where !finished {
            if let sheet = window.attachedSheet, let content = sheet.contentView, let button = discard(in: content) {
                button.performClick(nil)
                alerts += 1
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return (await task.value, alerts)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    @Test func openingASmartObjectMakesATabOnceAndReusesIt() throws {
        let (workspace, parent, nested, layerID) = try workspaceWithOpenSmartObject()
        #expect(workspace.tabs.count == 2)
        #expect(nested.id != parent.id)
        #expect(nested.session.document?.width == 8 && nested.session.document?.height == 6)
        #expect(nested.smartObjectSource?.layerID == layerID)
        #expect(nested.smartObjectSource?.tabID == parent.id)
        #expect(nested.title == "◆ Pixels")
        #expect(workspace.smartObjectTab(for: layerID, in: parent.id) === nested)
        workspace.select(parent.id)
        workspace.openSmartObject(layerID: layerID)
        #expect(workspace.tabs.count == 2)
        #expect(workspace.current.id == nested.id)
    }

    @Test func aLayerThatIsNotASmartObjectOpensNothing() throws {
        let workspace = ProjectWorkspace()
        let session = workspace.current.session
        session.createDocument(width: 40, height: 30)
        let plain = ImageLayer(asset: try Self.image(8, 6), origin: .zero)
        session.document?.layers.append(plain)
        workspace.openSmartObject(layerID: plain.id)
        #expect(workspace.tabs.count == 1)
    }

    @Test func aSessionOpensItsSmartObjectThroughItsWorkspace() throws {
        let workspace = ProjectWorkspace()
        let parent = workspace.current
        parent.session.createDocument(width: 40, height: 30)
        let shell = Self.smartLayer(try Self.image(8, 6))
        parent.session.document?.layers.append(shell)
        parent.session.openSmartObject?(shell.id)
        #expect(workspace.tabs.count == 2)
    }

    @Test func closingAnEditedSmartObjectTabUpdatesTheLayerInOneUndoStep() async throws {
        let (workspace, parent, nested, id) = try workspaceWithOpenSmartObject()
        let before = try #require(layer(id, in: parent)?.asset?.image)
        try edit(nested)
        let undoCount = parent.session.history.undoCount
        await workspace.close(nested.id)
        #expect(workspace.tabs.count == 1)
        #expect(workspace.current.id == parent.id)
        let updated = try #require(layer(id, in: parent))
        #expect(updated.asset?.image !== before)
        #expect(updated.liveSmartObject?.content.layers.count == 2)
        #expect(parent.session.history.undoCount == undoCount + 1)
        #expect(parent.session.history.undoName == "Update Smart Object")
        parent.session.undo()
        #expect(layer(id, in: parent)?.asset?.image === before)
        #expect(layer(id, in: parent)?.liveSmartObject?.content.layers.count == 1)
    }

    @Test func closingAnUntouchedSmartObjectTabRecordsNothing() async throws {
        let (workspace, parent, nested, id) = try workspaceWithOpenSmartObject()
        let before = try #require(layer(id, in: parent)?.asset?.image)
        let undoCount = parent.session.history.undoCount
        await workspace.close(nested.id)
        #expect(workspace.tabs.count == 1)
        #expect(parent.session.history.undoCount == undoCount)
        #expect(layer(id, in: parent)?.asset?.image === before)
    }

    @Test func closingASmartObjectTabWhoseLayerWasDeletedDiscardsQuietly() async throws {
        let (workspace, parent, nested, id) = try workspaceWithOpenSmartObject()
        try edit(nested)
        parent.session.document?.layers.removeAll { $0.id == id }
        let undoCount = parent.session.history.undoCount
        await workspace.close(nested.id)
        #expect(workspace.tabs.count == 1)
        #expect(layer(id, in: parent) == nil)
        #expect(parent.session.history.undoCount == undoCount)
    }

    @Test func aLayerWhosePixelsWereEditedNoLongerTakesTheTabsEdits() async throws {
        let (workspace, parent, nested, id) = try workspaceWithOpenSmartObject()
        try edit(nested)
        let painted = try Self.image(8, 6, gray: 0.1)
        parent.session.document?.layers[0].asset = painted
        let undoCount = parent.session.history.undoCount
        await workspace.close(nested.id)
        #expect(layer(id, in: parent)?.asset?.image === painted.image)
        #expect(layer(id, in: parent)?.liveSmartObject == nil)
        #expect(parent.session.history.undoCount == undoCount)
    }

    @Test func returningToTheParentAppliesTheEditsOnce() throws {
        let (workspace, parent, nested, id) = try workspaceWithOpenSmartObject()
        try edit(nested)
        workspace.select(parent.id)
        #expect(layer(id, in: parent)?.liveSmartObject?.content.layers.count == 2)
        #expect(workspace.tabs.count == 2)
        let undoCount = parent.session.history.undoCount
        workspace.select(nested.id)
        workspace.select(parent.id)
        #expect(parent.session.history.undoCount == undoCount)
    }

    @Test func aTabKeepsItsOwnUndoAfterItsEditsAreApplied() throws {
        let (workspace, parent, nested, _) = try workspaceWithOpenSmartObject()
        try edit(nested)
        workspace.select(parent.id)
        #expect(nested.session.canUndo)
        nested.session.undo()
        workspace.select(nested.id)
        workspace.select(parent.id)
        #expect(layer(nested.smartObjectSource!.layerID, in: parent)?.liveSmartObject?.content.layers.count == 1)
    }

    @Test func changingTheNestedCanvasSizeRescalesTheShellAroundItsCenter() async throws {
        let (workspace, parent, nested, id) = try workspaceWithOpenSmartObject()
        parent.session.document?.layers[0].transform.rotation = 30
        let before = try #require(layer(id, in: parent)?.transform)
        let document = try #require(nested.session.document)
        nested.session.document = CanvasDocument(id: document.id, width: 16, height: 12, layers: document.layers, resolution: document.resolution)
        await workspace.close(nested.id)
        let updated = try #require(layer(id, in: parent))
        #expect(updated.asset?.image.width == 16 && updated.asset?.image.height == 12)
        #expect(updated.liveSmartObject?.content.width == 16)
        #expect(updated.transform.size == CGSize(width: before.size.width * 2, height: before.size.height * 2))
        #expect(abs(updated.transform.center.x - before.center.x) < 0.001 && abs(updated.transform.center.y - before.center.y) < 0.001)
        #expect(updated.transform.rotation == 30)
    }

    @Test func quittingAppliesAnEditedTabBeforeTheParentPromptsAndNeverPromptsForTheTab() async throws {
        let (workspace, parent, nested, id) = try workspaceWithOpenSmartObject()
        let window = makeWindow()
        defer { window.orderOut(nil) }
        workspace.window = window
        parent.session.history.markSaved()
        try edit(nested)
        #expect(!parent.session.isModified)
        let (quit, alerts) = try await answeringAlerts(on: window) { await workspace.confirmQuit() }
        #expect(quit)
        #expect(alerts == 1)
        #expect(layer(id, in: parent)?.liveSmartObject?.content.layers.count == 2)
    }

    @Test func closingTheParentAppliesAnEditedTabBeforeItsPromptAndClosesTheTab() async throws {
        let (workspace, parent, nested, id) = try workspaceWithOpenSmartObject()
        let window = makeWindow()
        defer { window.orderOut(nil) }
        workspace.window = window
        parent.session.history.markSaved()
        try edit(nested)
        #expect(!parent.session.isModified)
        workspace.select(parent.id)
        parent.session.history.markSaved()
        workspace.select(nested.id)
        nested.session.addBlankLayer()
        let (_, alerts) = try await answeringAlerts(on: window) { await workspace.close(parent.id); return true }
        #expect(alerts == 1)
        #expect(workspace.tabs.count == 1)
        #expect(workspace.tabs.allSatisfy { $0.smartObjectSource == nil })
        #expect(layer(id, in: parent)?.liveSmartObject?.content.layers.count == 3)
    }

    @Test func closingTheParentOfAnEditedTabAppliesNestedLevelsInnermostFirst() async throws {
        let workspace = ProjectWorkspace()
        let parent = workspace.current
        parent.session.createDocument(width: 40, height: 30)
        let innermost = Self.smartLayer(try Self.image(8, 6))
        let middle = Self.smartLayer(try Self.image(8, 6), holding: [innermost])
        parent.session.document?.layers.append(middle)
        let window = makeWindow()
        defer { window.orderOut(nil) }
        workspace.window = window
        workspace.openSmartObject(layerID: middle.id)
        let middleTab = workspace.current
        workspace.openSmartObject(layerID: innermost.id)
        let innermostTab = workspace.current
        #expect(innermostTab.smartObjectSource?.tabID == middleTab.id)
        try edit(innermostTab)
        parent.session.history.markSaved()
        let (_, alerts) = try await answeringAlerts(on: window) { await workspace.close(parent.id); return true }
        #expect(alerts == 1)
        #expect(workspace.tabs.count == 1)
        let applied = try #require(layer(middle.id, in: parent)?.liveSmartObject)
        #expect(applied.content.layers.first { $0.id == innermost.id }?.liveSmartObject?.content.layers.count == 2)
    }
}
