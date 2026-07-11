import SwiftUI
import OsmoCore

// Reusable orchid components. Every hairline/shadow is ink-alpha; light mode is
// enforced at the scene level.

/// A soft card surface (card fill + soft hairline).
public struct Card<Content: View>: View {
    var padding: CGFloat
    var content: Content
    public init(padding: CGFloat = DS.Space.l, @ViewBuilder content: () -> Content) {
        self.padding = padding; self.content = content()
    }
    public var body: some View {
        content
            .padding(padding)
            .background(DS.Colors.card, in: RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DS.Radius.xl, style: .continuous)
                .stroke(DS.Colors.hairlineSoft, lineWidth: 1))
    }
}

public struct HairlineDivider: View {
    public init() {}
    public var body: some View {
        Rectangle().fill(DS.Colors.hairline).frame(height: 1)
    }
}

/// A left-to-right, top-to-bottom wrapping row — for chip groups whose labels
/// vary in width, where a fixed-column grid would truncate or waste space.
public struct FlowLayout: Layout {
    var spacing: CGFloat
    public init(spacing: CGFloat = 6) { self.spacing = spacing }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let width = bounds.width
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Primary (accent-filled) or quiet (chip) capsule button.
public struct PillButton: View {
    public enum Kind { case primary, quiet, destructive }
    let title: String
    var icon: String?
    var kind: Kind
    var action: () -> Void
    // So a `.disabled()` PillButton reads as inactive instead of a fully-lit,
    // clickable-looking capsule that silently does nothing.
    @Environment(\.isEnabled) private var isEnabled

    public init(_ title: String, icon: String? = nil, kind: Kind = .primary, action: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.kind = kind; self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: DS.Space.xs) {
                if let icon { Image(systemName: icon).font(.system(size: 12, weight: .medium)) }
                Text(title).font(DS.Typography.captionEm)
            }
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .foregroundStyle(fg)
            .background(bg, in: Capsule())
            .overlay(kind == .quiet ? Capsule().stroke(DS.Colors.hairline, lineWidth: 1) : nil)
            .opacity(isEnabled ? 1 : 0.4)
        }
        .buttonStyle(.plain)
    }

    private var fg: Color {
        switch kind {
        case .primary: return .white
        case .quiet: return DS.Colors.ink
        case .destructive: return .white
        }
    }
    private var bg: Color {
        switch kind {
        case .primary: return DS.Colors.accent
        case .quiet: return DS.Colors.chip
        case .destructive: return DS.Colors.red
        }
    }
}

/// A small labeled chip (platform tags, tone chips).
public struct Chip: View {
    let text: String
    var systemImage: String?
    public init(_ text: String, systemImage: String? = nil) {
        self.text = text; self.systemImage = systemImage
    }
    public var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 9)) }
            Text(text).font(DS.Typography.eyebrow)
        }
        .padding(.horizontal, DS.Space.s)
        .padding(.vertical, 3)
        .foregroundStyle(DS.Colors.muted)
        .background(DS.Colors.chip, in: Capsule())
    }
}

public struct Eyebrow: View {
    let text: String
    /// Accent-tinted eyebrows are reserved for Osmo's INTERPRETATION (the read,
    /// its judgments); factual/reference labels stay muted. One tracking value
    /// (0.8) everywhere so micro-caps read as one system.
    var accent: Bool
    public init(_ text: String, accent: Bool = false) { self.text = text; self.accent = accent }
    public var body: some View {
        Text(text.uppercased())
            .font(DS.Typography.eyebrow)
            .tracking(0.8)
            .foregroundStyle(accent ? DS.Colors.accent : DS.Colors.muted)
    }
}

/// A small "PRO" badge for gating copy in Settings — never implies the
/// feature is broken for free users, just that it needs the upgrade.
public struct ProTag: View {
    public init() {}
    public var body: some View {
        Text("PRO")
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.5)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .foregroundStyle(.white)
            .background(DS.Colors.accent, in: Capsule())
    }
}

/// Status dot — accent = active, red = attention, muted = idle. Orchid's palette
/// is blue/red/ink only; green is reserved for a hard "connected" confirm.
public struct StatusDot: View {
    public enum State { case idle, active, attention, connected }
    let state: State
    public init(_ state: State) { self.state = state }
    public var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
    }
    private var color: Color {
        switch state {
        case .idle: return DS.Colors.muted.opacity(0.5)
        case .active: return DS.Colors.accent
        case .attention: return DS.Colors.red
        case .connected: return DS.Colors.green
        }
    }
}

/// A full-section empty state that points somewhere.
public struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String
    var cta: (title: String, action: () -> Void)?

    public init(icon: String, title: String, message: String,
                cta: (title: String, action: () -> Void)? = nil) {
        self.icon = icon; self.title = title; self.message = message; self.cta = cta
    }

    public var body: some View {
        VStack(spacing: DS.Space.m) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DS.Colors.muted)
            Text(title).font(DS.Typography.title).foregroundStyle(DS.Colors.ink)
            Text(message)
                .font(DS.Typography.body).foregroundStyle(DS.Colors.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if let cta {
                PillButton(cta.title, action: cta.action).padding(.top, DS.Space.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Space.xxl)
    }
}

/// A circular avatar (photo or monogram) with a hairline ring.
public struct AvatarView: View {
    let name: String
    let data: Data?
    var size: CGFloat
    public init(name: String, data: Data? = nil, size: CGFloat = 40) {
        self.name = name; self.data = data; self.size = size
    }
    public var body: some View {
        Group {
            if let data, let image = NSImage(data: data) {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Text(monogram)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(DS.Colors.ink)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(DS.Colors.chip)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().stroke(DS.Colors.hairline, lineWidth: 1))
    }

    /// First letter, or "?" when the name is empty/non-alphabetic — never a
    /// blank chip circle.
    private var monogram: String {
        let letter = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .first { $0.isLetter || $0.isNumber }
        return letter.map { String($0).uppercased() } ?? "?"
    }
}

/// Platform glyph + label helpers (SF Symbols; NEVER Apple emoji per house rule).
public extension Platform {
    var symbolName: String {
        switch self {
        case .imessage: return "message.fill"
        case .gmail: return "envelope.fill"
        case .slack: return "number"
        case .whatsapp: return "phone.bubble.fill"
        case .linkedin: return "briefcase.fill"
        case .x: return "at"
        case .instagram: return "camera.fill"
        }
    }
    var tint: Color {
        switch self {
        case .imessage: return Color(hex: 0x34C759)
        case .gmail: return Color(hex: 0xEA4335)
        case .slack: return Color(hex: 0x611F69)
        case .whatsapp: return Color(hex: 0x25D366)
        case .linkedin: return Color(hex: 0x0A66C2)
        case .x: return DS.Colors.ink
        case .instagram: return Color(hex: 0xC13584)
        }
    }
}
