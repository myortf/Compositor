import SwiftUI

/// Right-click with a brush tool: size, hardness and opacity in a small popover at the pointer, as Photoshop's.
struct BrushQuickPanel: View {
    @Bindable var session: EditorSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            row("Size", value: "\(Int(session.brushSettings.diameter)) px") {
                Slider(value: Binding(get: { Double(session.brushSettings.diameter) },
                                      set: { session.brushSettings.diameter = CGFloat(min(2000, max(1, $0.rounded()))) }), in: 1...500)
            }
            row("Hardness", value: "\(Int((session.brushSettings.hardness * 100).rounded()))%") {
                Slider(value: Binding(get: { Double(session.brushSettings.hardness) },
                                      set: { session.brushSettings.hardness = CGFloat(min(1, max(0, $0))) }), in: 0...1)
            }
            row(session.tool == .blur ? "Strength" : session.tool == .dodgeBurn ? "Exposure" : "Opacity", value: "\(Int((session.brushSettings.opacity * 100).rounded()))%") {
                Slider(value: Binding(get: { Double(session.brushSettings.opacity) },
                                      set: { session.brushSettings.opacity = CGFloat(min(1, max(0.01, $0))) }), in: 0.01...1)
            }
        }
        .padding(14).frame(width: 260)
    }

    private func row<Control: View>(_ title: String, value: String, @ViewBuilder control: () -> Control) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(title); Spacer(); Text(value).monospacedDigit().foregroundStyle(.secondary) }.font(.callout)
            control()
        }
    }

    @MainActor static func show(for session: EditorSession, at point: NSPoint, in view: NSView) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: BrushQuickPanel(session: session))
        popover.show(relativeTo: NSRect(x: point.x, y: point.y, width: 1, height: 1), of: view, preferredEdge: .maxY)
    }
}
