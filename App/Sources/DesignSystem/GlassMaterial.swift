import SwiftUI
import AppKit

/// Real macOS glass with an orchid finish. On macOS 26 (Tahoe) it uses the
/// native Liquid Glass material; earlier it falls back to an NSVisualEffectView
/// with the orchid token stack (white fill + ink hairline + top light edge).
/// The shadow is always applied by the CALLER on the outer wrapper — never on
/// the blur view — or native glass samples it and washes out.
public struct GlassSurface<S: InsettableShape>: View {
    let shape: S
    var tinted: Bool

    public init(shape: S, tinted: Bool = true) {
        self.shape = shape
        self.tinted = tinted
    }

    public var body: some View {
        if #available(macOS 26.0, *) {
            shape
                .fill(.clear)
                .glassEffect(in: shape)
                .overlay(shape.stroke(DS.Colors.glassBorder, lineWidth: 1))
        } else {
            VisualEffectView(material: .popover, blending: .behindWindow)
                .overlay(shape.fill(DS.Colors.glassFill))
                .overlay(  // top light edge — the "lit from above" cue
                    shape.stroke(
                        LinearGradient(colors: [DS.Colors.glassTopEdge, .clear],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1))
                .overlay(shape.stroke(DS.Colors.glassBorder, lineWidth: 1))
                .clipShape(shape)
        }
    }
}

/// AppKit NSVisualEffectView bridge for the fallback path.
public struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blending: NSVisualEffectView.BlendingMode

    public init(material: NSVisualEffectView.Material, blending: NSVisualEffectView.BlendingMode) {
        self.material = material
        self.blending = blending
    }

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .active
        view.appearance = NSAppearance(named: .aqua)   // lock light regardless of system
        return view
    }
    public func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// A glass capsule/rounded-rect ready to wrap pill + panel content, with the
/// orchid shadow on the outer wrapper.
public struct GlassCard<Content: View>: View {
    var cornerRadius: CGFloat
    var content: Content

    public init(cornerRadius: CGFloat = DS.Radius.xxl, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(GlassSurface(shape: shape))
            .clipShape(shape)
            .shadow(color: DS.Colors.shadow, radius: 24, x: 0, y: 8)
    }
}
