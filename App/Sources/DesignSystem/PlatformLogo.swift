import SwiftUI
import OsmoCore

/// The real, full-color brand mark for a platform (from Assets.xcassets:
/// `logo-<rawValue>`, rasterized from the official-geometry SVGs). Falls back to
/// the tinted SF Symbol if an asset is ever missing. Use this instead of
/// `Image(systemName: platform.symbolName)` wherever we present the platform as a
/// "connect to X" identity — it's what makes the Connections screen read as a
/// real product rather than generic library glyphs.
struct PlatformLogo: View {
    let platform: Platform
    var size: CGFloat

    init(_ platform: Platform, size: CGFloat = 24) {
        self.platform = platform
        self.size = size
    }

    var body: some View {
        if let image = NSImage(named: "logo-\(platform.rawValue)") {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: size, height: size)
                .accessibilityLabel(platform.displayName)
        } else {
            Image(systemName: platform.symbolName)
                .font(.system(size: size * 0.72))
                .foregroundStyle(platform.tint)
                .frame(width: size, height: size)
                .accessibilityLabel(platform.displayName)
        }
    }
}
