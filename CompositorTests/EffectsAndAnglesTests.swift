import AppKit
import Testing
@testable import Compositor

@MainActor
struct EffectsAndAnglesTests {
    private func motionBlurSession(angle: Double) -> (EditorSession, UUID) {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        var settings = LayerAdjustment(kind: .motionBlur)
        settings.motionAngle = angle
        let layer = ImageLayer(id: UUID(), asset: nil, name: "Blur", isVisible: true,
                               transform: LayerTransform(origin: .zero, size: CGSize(width: 40, height: 20)), adjustment: settings)
        session.document?.layers.append(layer)
        return (session, layer.id)
    }

    private func angle(_ session: EditorSession, _ id: UUID) -> Double? {
        session.document?.layers.first { $0.id == id }?.adjustment?.resolvedMotionAngle
    }

    @Test func rotatingTheCanvasTurnsAMotionBlurWithIt() throws {
        let (session, id) = motionBlurSession(angle: 30)
        session.rotateCanvas(.clockwise)
        #expect(angle(session, id) == -60)
        session.rotateCanvas(.clockwise)
        #expect(angle(session, id) == 30)
        session.rotateCanvas(.counterclockwise)
        #expect(angle(session, id) == -60)
        session.rotateCanvas(.counterclockwise)
        #expect(angle(session, id) == 30)
        session.rotateCanvas(.half)
        #expect(angle(session, id) == 30)
    }

    @Test func undoingATurnRestoresTheBlurAngle() throws {
        let (session, id) = motionBlurSession(angle: 30)
        session.rotateCanvas(.clockwise)
        session.undo()
        #expect(angle(session, id) == 30)
        session.redo()
        #expect(angle(session, id) == -60)
    }

    @Test func aHorizontalBlurBecomesVerticalOnAQuarterTurn() throws {
        let (session, id) = motionBlurSession(angle: 0)
        session.rotateCanvas(.clockwise)
        #expect(abs(try #require(angle(session, id))) == 90)
    }

    @Test func flippingTheCanvasMirrorsTheBlurSlope() throws {
        let (session, id) = motionBlurSession(angle: 30)
        session.flipCanvas(horizontally: true)
        #expect(angle(session, id) == -30)
        session.flipCanvas(horizontally: false)
        #expect(angle(session, id) == 30)
    }

    @Test func imageSizeScalesEveryEffectAndKeepsThem() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 20)
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let cg = try #require(context.makeImage())
        var layer = ImageLayer(asset: ImportedImage(image: cg, thumbnail: cg, name: "L"), origin: .zero)
        layer.effects = LayerEffects(stroke: StrokeEffect(size: 4), shadow: ShadowEffect(angle: 45, distance: 10, blur: 6),
                                     innerShadow: InnerShadowEffect(distance: 2, blur: 4),
                                     outerGlow: OuterGlowEffect(size: 8), innerGlow: InnerGlowEffect(size: 6))
        session.document?.layers = [layer]
        let result = try await ImageResizer.shared.resize(try #require(session.projectSnapshot()),
            to: ImageSizeOptions(width: 80, height: 40, resolution: 72))
        session.applyImageSize(result)
        let effects = try #require(session.document?.layers.first?.effects)
        #expect(effects.stroke?.size == 8)
        #expect(effects.shadow?.distance == 20 && effects.shadow?.blur == 12 && effects.shadow?.angle == 45)
        #expect(effects.innerShadow?.distance == 4 && effects.innerShadow?.blur == 8)
        #expect(effects.outerGlow?.size == 16 && effects.innerGlow?.size == 12)
        #expect(effects.isValid)
    }

    @Test func scalingEffectsStaysWithinTheirLimits() {
        let big = LayerEffects(stroke: StrokeEffect(size: 400), shadow: ShadowEffect(distance: 4000, blur: 400)).scaled(by: 10)
        #expect(big.isValid)
    }
}
