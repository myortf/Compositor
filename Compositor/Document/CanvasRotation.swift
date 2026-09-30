import AppKit

/// A turn of the whole canvas, as in Image > Image Rotation.
enum CanvasRotation: CaseIterable {
    case clockwise, counterclockwise, half

    var undoName: String {
        switch self {
        case .clockwise: "Rotate Canvas 90° Clockwise"
        case .counterclockwise: "Rotate Canvas 90° Counterclockwise"
        case .half: "Rotate Canvas 180°"
        }
    }

    /// Clockwise degrees.
    var degrees: CGFloat {
        switch self {
        case .clockwise: 90
        case .counterclockwise: -90
        case .half: 180
        }
    }

    var swapsSides: Bool { self != .half }

    /// The canvas size after the turn.
    func size(of size: CGSize) -> CGSize { swapsSides ? CGSize(width: size.height, height: size.width) : size }

    /// Where a point on a canvas of `size` lands on the turned canvas (y down).
    func point(_ point: CGPoint, in size: CGSize) -> CGPoint {
        switch self {
        case .clockwise: CGPoint(x: size.height - point.y, y: point.x)
        case .counterclockwise: CGPoint(x: point.y, y: size.width - point.x)
        case .half: CGPoint(x: size.width - point.x, y: size.height - point.y)
        }
    }

    /// The same turn as a matrix on document coordinates.
    func matrix(for size: CGSize) -> CGAffineTransform {
        switch self {
        case .clockwise: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: size.height, ty: 0)
        case .counterclockwise: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: size.width)
        case .half: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: size.width, ty: size.height)
        }
    }
}

extension LayerTransform {
    /// This placement carried along as the canvas of `canvas` turns: its middle goes where that point goes and
    /// its angle turns with the canvas, kept between -180° and 180°. Size and flips are unchanged.
    func rotated(_ rotation: CanvasRotation, in canvas: CGSize) -> LayerTransform {
        var result = self
        let middle = rotation.point(center, in: canvas)
        result.origin = CGPoint(x: middle.x - size.width / 2, y: middle.y - size.height / 2)
        let turned = self.rotation + rotation.degrees
        result.rotation = turned - 360 * ((turned - 180) / 360).rounded(.up)
        return result
    }
}

extension CanvasGuide {
    /// This guide on the turned canvas: a guide across the turn becomes the other axis.
    func rotated(_ rotation: CanvasRotation, in canvas: CGSize) -> CanvasGuide {
        var guide = self
        let point = axis == .vertical ? CGPoint(x: position, y: 0) : CGPoint(x: 0, y: position)
        let turned = rotation.point(point, in: canvas)
        if rotation.swapsSides { guide.axis = axis == .vertical ? .horizontal : .vertical }
        guide.position = Double(guide.axis == .vertical ? turned.x : turned.y)
        return guide
    }
}

extension EditorSession {
    /// Turns the whole canvas: the size swaps sides for a quarter turn, and every layer, folder and placed mask,
    /// the guides and the selection turn with it, as one undo step.
    func rotateCanvas(_ rotation: CanvasRotation) {
        commitTransform()
        cancelCrop()
        guard canEditLayers, let document else { return }
        let canvas = document.size
        let size = rotation.size(of: canvas)
        var turned = CanvasDocument(id: document.id, width: Int(size.width), height: Int(size.height),
            layers: document.layers, resolution: document.resolution,
            guides: document.guides.map { $0.rotated(rotation, in: canvas) })
        for index in turned.layers.indices {
            turned.layers[index].transform = turned.layers[index].transform.rotated(rotation, in: canvas)
            turned.layers[index].adjustment?.turnMotionBlur(clockwiseDegrees: Double(rotation.degrees))
            if let placement = turned.layers[index].mask?.placement {
                turned.layers[index].mask?.placement = placement.rotated(rotation, in: canvas)
            }
        }
        if let selection = document.selection {
            var matrix = rotation.matrix(for: canvas)
            if let path = selection.path.copy(using: &matrix) {
                turned.selection = DocumentSelection(path: path, antialiased: selection.antialiased, feather: selection.feather)
            }
        }
        finishOpacityEdit()
        beginEdit(rotation.undoName)
        self.document = turned
        if rotation.swapsSides { viewport.fit(documentSize: turned.size) }
        endEdit()
    }
}
