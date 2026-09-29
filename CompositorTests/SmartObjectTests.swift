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
        layer.smartObject = LayerSmartObject(content: SmartObjectContent(width: 8, height: 6, resolution: 72, layers: [inner]), image: asset.image)
        #expect(layer.liveSmartObject != nil)
        layer.asset = try Self.image(8, 6, gray: 0.2)
        #expect(layer.liveSmartObject == nil)
    }

    private static func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SmartObjectTests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return root
    }

    private static func sessionWithSmartObject(_ asset: ImportedImage) -> (EditorSession, ImageLayer, ImageLayer) {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        var shell = ImageLayer(asset: asset, origin: CGPoint(x: 3, y: 4))
        let inner = ImageLayer(asset: asset, origin: .zero)
        shell.smartObject = LayerSmartObject(content: SmartObjectContent(width: 8, height: 6, resolution: 72, layers: [inner]), image: asset.image)
        session.document?.layers.append(shell)
        return (session, shell, inner)
    }

    @Test func smartObjectSurvivesSaveAndReopen() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, shell, inner) = Self.sessionWithSmartObject(try Self.image(8, 6))
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

    @Test func smartObjectNestedInsideASmartObjectSurvives() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let asset = try Self.image(4, 4)
        var middle = ImageLayer(asset: asset, origin: .zero)
        middle.smartObject = LayerSmartObject(content: SmartObjectContent(width: 4, height: 4, resolution: 72, layers: [ImageLayer(asset: asset, origin: .zero)]), image: asset.image)
        var top = ImageLayer(asset: asset, origin: .zero)
        top.smartObject = LayerSmartObject(content: SmartObjectContent(width: 4, height: 4, resolution: 72, layers: [middle]), image: asset.image)
        let session = EditorSession()
        session.createDocument(width: 10, height: 10)
        session.document?.layers.append(top)
        let url = root.appendingPathComponent("a.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: url)
        let reopened = EditorSession()
        reopened.installProject(try await ProjectStore.shared.load(from: url), from: url)
        let outer = try #require(reopened.document?.layers.first { $0.id == top.id }?.liveSmartObject)
        #expect(outer.content.layers.first?.liveSmartObject?.content.layers.count == 1)
    }

    @Test func smartObjectWithMissingNestedPackageIsRejected() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, _, _) = Self.sessionWithSmartObject(try Self.image(8, 6))
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
        var top = ImageLayer(asset: asset, origin: .zero)
        top.smartObject = LayerSmartObject(content: content, image: asset.image)
        let session = EditorSession()
        session.createDocument(width: 4, height: 4)
        session.document?.layers.append(top)
        let snapshot = try #require(session.projectSnapshot())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("deep-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        await #expect(throws: ProjectError.self) { try await ProjectStore.shared.save(snapshot, to: url) }
    }

    @Test func editedPixelsDropTheSmartObjectOnSave() async throws {
        let root = try Self.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (session, shell, _) = Self.sessionWithSmartObject(try Self.image(8, 6))
        let index = try #require(session.document?.layers.firstIndex { $0.id == shell.id })
        session.document?.layers[index].asset = try Self.image(8, 6, gray: 0.9)
        let snapshot = try #require(session.projectSnapshot())
        #expect(snapshot.smartObjects.isEmpty)
        let url = root.appendingPathComponent("a.comp")
        try await ProjectStore.shared.save(snapshot, to: url)
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("smartobjects").path))
    }
}
