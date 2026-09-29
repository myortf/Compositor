import AppKit
import Testing
@testable import Compositor

/// Select > Modify: Smooth and Border, on square and non-square canvases.
@MainActor struct SelectionModifyTests {
    private func makeSession(width: Int, height: Int) -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: width, height: height, emptyLayer: true)
        session.selectTool(.lasso)
        return session
    }
    private func select(_ session: EditorSession, _ path: CGPath) {
        session.setSelection(DocumentSelection(path: path, antialiased: false), name: "Test Selection")
    }
    private func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGPath {
        CGPath(rect: CGRect(x: x, y: y, width: width, height: height), transform: nil)
    }
    /// Selection coverage at document resolution, row by row.
    private func mask(_ session: EditorSession) throws -> (bytes: [UInt8], width: Int, height: Int) {
        let document = try #require(session.document)
        let image = try #require(session.selection).coverage(width: document.width, height: document.height)
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (Array(UnsafeBufferPointer(start: data, count: image.width * image.height)), image.width, image.height)
    }
    private func isSelected(_ mask: (bytes: [UInt8], width: Int, height: Int), _ x: Int, _ y: Int) -> Bool {
        mask.bytes[y * mask.width + x] >= 128
    }

    @Test func smoothRemovesSpecksAndKeepsStraightEdges() throws {
        let session = makeSession(width: 300, height: 200)
        let outline = CGMutablePath()
        outline.addRect(CGRect(x: 60, y: 40, width: 100, height: 80))
        outline.addRect(CGRect(x: 250, y: 150, width: 2, height: 2))
        select(session, outline)
        session.smoothSelection(by: 4)
        #expect(session.history.undoName == "Smooth Selection")
        let smooth = try mask(session)
        #expect(!isSelected(smooth, 250, 150), "the speck survived")
        #expect(isSelected(smooth, 110, 80), "the body of the selection was lost")
        #expect(isSelected(smooth, 62, 80) && !isSelected(smooth, 57, 80), "a straight edge moved")
        #expect(isSelected(smooth, 110, 42) && !isSelected(smooth, 110, 37), "a straight edge moved")
    }

    @Test func smoothFillsAPinholeAndRoundsCorners() throws {
        let session = makeSession(width: 200, height: 300)
        let outline = CGMutablePath()
        outline.addRect(CGRect(x: 40, y: 60, width: 100, height: 100))
        // Opposite winding cuts a one-pixel hole.
        outline.move(to: CGPoint(x: 90, y: 100))
        outline.addLine(to: CGPoint(x: 90, y: 101))
        outline.addLine(to: CGPoint(x: 91, y: 101))
        outline.addLine(to: CGPoint(x: 91, y: 100))
        outline.closeSubpath()
        select(session, outline)
        #expect(try !isSelected(mask(session), 90, 100), "the test outline has no hole")
        session.smoothSelection(by: 6)
        let smooth = try mask(session)
        #expect(isSelected(smooth, 90, 100), "the pinhole stayed")
        #expect(!isSelected(smooth, 40, 60), "the corner was not rounded")
        #expect(isSelected(smooth, 90, 60) && isSelected(smooth, 40, 110))
    }

    @Test func smoothKeepsSelectionsThatTouchTheCanvasEdge() throws {
        for (width, height) in [(300, 200), (200, 300)] {
            let session = makeSession(width: width, height: height)
            session.selectAll()
            session.smoothSelection(by: 20)
            #expect(try mask(session).bytes.allSatisfy { $0 >= 128 }, "Select All lost pixels at \(width)x\(height)")

            select(session, rect(0, 50, 100, 80))
            session.smoothSelection(by: 8)
            let smooth = try mask(session)
            #expect(isSelected(smooth, 0, 90) && isSelected(smooth, 0, 51) && isSelected(smooth, 0, 128),
                    "the canvas edge was eroded at \(width)x\(height)")
            #expect(isSelected(smooth, 50, 90) && !isSelected(smooth, 105, 90) && !isSelected(smooth, 50, 45))

            select(session, rect(CGFloat(width - 60), CGFloat(height - 40), 60, 40))
            session.smoothSelection(by: 8)
            #expect(try isSelected(mask(session), width - 1, height - 1), "the canvas corner was eroded at \(width)x\(height)")
        }
    }

    @Test func smoothingEverythingAwayLeavesAnEmptySelection() throws {
        let session = makeSession(width: 300, height: 200)
        select(session, rect(100, 100, 3, 3))
        session.smoothSelection(by: 10)
        #expect(try #require(session.selection).isEmpty)
        #expect(!session.canModifySelection)
        session.undo()
        #expect(session.selection?.isEmpty == false)
    }

    @Test func borderMakesABandCenteredOnTheEdge() throws {
        let session = makeSession(width: 300, height: 200)
        select(session, rect(100, 60, 100, 80))
        session.borderSelection(by: 10)
        #expect(session.history.undoName == "Border Selection")
        let band = try mask(session)
        #expect(isSelected(band, 96, 100) && isSelected(band, 104, 100), "the band misses the edge")
        #expect(!isSelected(band, 94, 100) && !isSelected(band, 106, 100), "the band is too wide")
        #expect(!isSelected(band, 150, 100), "the middle is still selected")
        #expect(isSelected(band, 150, 57) && isSelected(band, 150, 143) && !isSelected(band, 150, 54))
    }

    @Test func borderOfOddWidthAndThinSelectionsHasNoHole() throws {
        let session = makeSession(width: 200, height: 300)
        select(session, rect(50, 50, 6, 100))
        session.borderSelection(by: 1)
        let one = try mask(session)
        #expect(isSelected(one, 50, 100) && !isSelected(one, 52, 100) && !isSelected(one, 49, 100))
        session.undo()
        session.borderSelection(by: 40)
        let thin = try mask(session)
        #expect(isSelected(thin, 53, 100) && isSelected(thin, 33, 100) && isSelected(thin, 73, 100), "a thin selection lost its center")
    }

    @Test func borderAlongTheCanvasEdgeKeepsItsWidth() throws {
        for (width, height) in [(300, 200), (200, 300)] {
            let session = makeSession(width: width, height: height)
            session.selectAll()
            session.borderSelection(by: 10)
            let frame = try mask(session)
            #expect(isSelected(frame, 0, height / 2) && isSelected(frame, 4, height / 2) && !isSelected(frame, 6, height / 2))
            #expect(isSelected(frame, width / 2, 0) && isSelected(frame, width - 1, height / 2) && isSelected(frame, width / 2, height - 1))
            #expect(!isSelected(frame, width / 2, height / 2))
            #expect(try #require(session.selection).path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: width, height: height))
        }
    }

    @Test func amountsAreRememberedAndBoundedPerOperation() throws {
        let session = makeSession(width: 300, height: 200)
        select(session, rect(100, 60, 100, 80))
        session.promptSelectionAmount(.smooth)
        #expect(session.selectionAmountOperation == .smooth)
        session.confirmSelectionAmount(101)
        #expect(session.selectionAmountOperation == .smooth, "an out-of-range amount was accepted")
        session.confirmSelectionAmount(7)
        #expect(session.selectionSmoothAmount == 7 && session.selectionAmountOperation == nil)
        session.promptSelectionAmount(.border)
        session.confirmSelectionAmount(201)
        #expect(session.selectionAmountOperation == .border)
        session.confirmSelectionAmount(12)
        #expect(session.selectionBorderAmount == 12)
        #expect(session.history.undoName == "Border Selection")
        session.promptSelectionAmount(.feather)
        session.confirmSelectionAmount(250)
        #expect(session.selectionFeatherAmount == 250)
    }
}
