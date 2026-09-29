import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Dodge lightens and Burn darkens under the brush only, weighted by tone, leaving alpha, the selection edge and
/// undo as every other brush does.
@MainActor
struct DodgeBurnTests {
    /// A flat layer `width` by `height` of `gray` at `alpha`, on a document of the same size, with the tool chosen.
    private func makeSession(width: Int = 300, height: Int = 120, gray: CGFloat = 0.5, alpha: CGFloat = 1,
                             mode: DodgeBurnMode = .dodge, range: DodgeBurnRange = .midtones) throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: width, height: height)
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(gray: gray, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Flat"))
        session.selectTool(.dodgeBurn)
        session.dodgeBurnMode = mode
        session.dodgeBurnRange = range
        session.brushSettings.diameter = 40
        session.brushSettings.hardness = 1
        session.brushSettings.opacity = 1
        return session
    }
    private func stroke(_ session: EditorSession, from: CGPoint, to: CGPoint) {
        session.beginBrush(at: from)
        session.continueBrush(at: to)
        session.finishBrushImmediately()
    }
    /// The layer's premultiplied RGBA at (x, y).
    private func pixel(_ session: EditorSession, x: Int, y: Int) throws -> [Int] {
        let context = try BrushRaster.copy(try #require(session.activeLayer?.asset?.image))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { Int(data[y * context.bytesPerRow + x * 4 + $0]) }
    }

    @Test func dodgeLightensOnlyUnderTheBrush() throws {
        let session = try makeSession()
        let before = try pixel(session, x: 100, y: 60)
        stroke(session, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 140, y: 60))
        #expect(session.brushError == nil)
        let inside = try pixel(session, x: 100, y: 60)
        #expect(inside[0] > before[0] && inside[1] > before[1] && inside[2] > before[2], "\(before) became \(inside)")
        #expect(try pixel(session, x: 250, y: 60) == before)
        #expect(try pixel(session, x: 100, y: 110) == before)
    }

    @Test func burnDarkensOnlyUnderTheBrush() throws {
        let session = try makeSession(mode: .burn)
        let before = try pixel(session, x: 100, y: 60)
        stroke(session, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 140, y: 60))
        let inside = try pixel(session, x: 100, y: 60)
        #expect(inside[0] < before[0] && inside[1] < before[1] && inside[2] < before[2], "\(before) became \(inside)")
        #expect(try pixel(session, x: 250, y: 60) == before)
    }

    @Test func exposureSetsHowMuchItChanges() throws {
        var lifted: [Int] = []
        for exposure: CGFloat in [0.25, 1] {
            let session = try makeSession()
            session.brushSettings.opacity = exposure
            stroke(session, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 140, y: 60))
            lifted.append(try pixel(session, x: 100, y: 60)[0] - 128)
        }
        #expect(lifted[0] > 0 && lifted[1] > lifted[0] * 2, "\(lifted)")
    }

    @Test func rangePicksTheTonesItWorksOn() throws {
        // Dodging a dark tone moves it further under Shadows than under Highlights, and the reverse for a light one.
        func lift(gray: CGFloat, range: DodgeBurnRange) throws -> Int {
            let session = try makeSession(gray: gray, range: range)
            let before = try pixel(session, x: 100, y: 60)[0]
            stroke(session, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 140, y: 60))
            return try pixel(session, x: 100, y: 60)[0] - before
        }
        #expect(try lift(gray: 0.2, range: .shadows) > lift(gray: 0.2, range: .highlights))
        #expect(try lift(gray: 0.8, range: .highlights) > lift(gray: 0.8, range: .shadows))
        #expect(try lift(gray: 0.5, range: .midtones) > lift(gray: 0.1, range: .midtones))
    }

    @Test func alphaIsUnchanged() throws {
        for mode in DodgeBurnMode.allCases {
            let session = try makeSession(alpha: 0.5, mode: mode)
            session.brushSettings.opacity = 0.6
            let before = try pixel(session, x: 100, y: 60)
            stroke(session, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 140, y: 60))
            let after = try pixel(session, x: 100, y: 60)
            #expect(after[3] == before[3] && before[3] > 0, "\(mode): \(before) became \(after)")
            #expect(after[0] != before[0], "\(mode) changed nothing on a half-transparent pixel")
        }
    }

    @Test func aSelectionKeepsTheStrokeInside() throws {
        let session = try makeSession()
        session.document?.selection = DocumentSelection(path: CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 120), transform: nil),
                                                        antialiased: false, feather: 0)
        let before = try pixel(session, x: 50, y: 60)
        stroke(session, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 140, y: 60))
        #expect(try pixel(session, x: 80, y: 60)[0] > before[0])
        #expect(try pixel(session, x: 130, y: 60) == before)
    }

    @Test func aStrokeIsOneUndoStep() throws {
        let session = try makeSession()
        let before = try pixel(session, x: 100, y: 60)
        let count = session.history.undoCount
        stroke(session, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 140, y: 60))
        #expect(session.history.undoCount == count + 1)
        #expect(try pixel(session, x: 100, y: 60) != before)
        session.undo()
        #expect(try pixel(session, x: 100, y: 60) == before)
    }

    @Test func worksOnALayerSmallerThanTheDocument() throws {
        let session = EditorSession()
        session.createDocument(width: 400, height: 200)
        let context = try BrushRaster.context(width: 90, height: 50, mask: false)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 90, height: 50))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Small"))
        session.selectTool(.dodgeBurn)
        session.brushSettings.diameter = 20
        session.brushSettings.hardness = 1
        session.brushSettings.opacity = 1
        let layer = try #require(session.activeLayer)
        let before = try pixel(session, x: 45, y: 25)
        stroke(session, from: CGPoint(x: layer.transform.center.x - 20, y: layer.transform.center.y),
               to: CGPoint(x: layer.transform.center.x + 20, y: layer.transform.center.y))
        #expect(session.brushError == nil)
        #expect(try pixel(session, x: 45, y: 25)[0] > before[0])
        #expect(try pixel(session, x: 2, y: 2) == before)
        #expect(try #require(session.activeLayer?.asset?.image).width >= 90)
    }

    @Test(arguments: [(DodgeBurnMode.dodge, false, DodgeBurnRange.shadows), (.burn, true, .highlights)])
    func onAMaskItLightensAndDarkensTheMask(mode: DodgeBurnMode, revealing: Bool, range: DodgeBurnRange) throws {
        let session = try makeSession(mode: mode, range: range)
        session.addLayerMask(revealing: revealing)
        session.selectLayerTarget(try #require(session.activeLayerID), mask: true)
        #expect(session.isMaskSelected)
        func gray(x: Int) throws -> Int {
            let image = try #require(session.activeLayer?.mask?.asset.image)
            let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return Int(try #require(context.data).assumingMemoryBound(to: UInt8.self)[60 * context.bytesPerRow + x])
        }
        // A fresh mask is one solid pixel; the stroke gives it the layer's full size.
        let before = revealing ? 255 : 0
        stroke(session, from: CGPoint(x: 60, y: 60), to: CGPoint(x: 140, y: 60))
        #expect(session.brushError == nil)
        let inside = try gray(x: 100)
        #expect(mode == .dodge ? inside > before : inside < before, "\(mode): \(before) became \(inside)")
        #expect(try gray(x: 250) == before)
    }

    @Test func theToolIsWiredIntoTheEditor() throws {
        #expect(NavigationTool.dodgeBurn.isBrushTool)
        let session = try makeSession()
        session.selectTool(.brush)
        session.selectTool(.dodgeBurn)
        #expect(session.tool == .dodgeBurn)
        session.cycleToolMode()
        #expect(session.dodgeBurnMode == .burn)
        session.typeOpacityDigit(3)
        #expect(session.brushSettings.opacity == 0.3)
    }
}
