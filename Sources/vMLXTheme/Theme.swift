import SwiftUI

/// MLX Studio native-noir theme. Single source of truth for the app's visual
/// design: calm graphite surfaces, semantic status colors, and mono only where
/// technical data benefits from it.
///
/// **Color scheme awareness**: every color token is now a `Color` built with
/// a SwiftUI dynamic provider, so the same token resolves to the dark or
/// light palette automatically when `.preferredColorScheme(.light/.dark)`
/// flips at the Scene level. Previously every token was a hardcoded dark
/// hex which silently overrode the system color scheme — this is what
/// broke the menu-bar Appearance picker live-test 2026-04-15.
///
/// Hex sources:
///   Dark  - native studio noir direction (Jun 2026)
///   Light - intentionally close to dark; this product direction is noir-first.
public enum Theme {

    // MARK: Colors
    public enum Colors {
        public static let background = dynamic(dark: 0x08090D, light: 0x08090D)
        public static let surface    = dynamic(dark: 0x111318, light: 0x111318)
        public static let surfaceHi  = dynamic(dark: 0x1A1D24, light: 0x1A1D24)
        public static let surfaceGlow = Color(hex: 0x17202B, alpha: 0.78)
        public static let border     = Color(hex: 0x5D6674, alpha: 0.26)
        public static let borderHi   = Color(hex: 0x8FA3BA, alpha: 0.42)

        public static let textHigh   = dynamic(dark: 0xF4F7FB, light: 0xF4F7FB)
        public static let textMid    = Color(hex: 0xBAC4D0)
        public static let textLow    = Color(hex: 0x768191)

        public static let accent     = Color(hex: 0x6EA8FF)
        public static let accentHi   = Color(hex: 0xAFCFFF)

        public static let success    = Color(hex: 0x5BD489)
        public static let warning    = Color(hex: 0xF0B35A)
        public static let danger     = Color(hex: 0xFF6B8A)
        public static let creative   = Color(hex: 0xD6A5FF)

        // MARK: Markdown accessibility palette

        /// Markdown is the one dense reading surface that intentionally opts
        /// into Dynamic Type and the system's increased-contrast appearance.
        /// Keep these separate from the fixed-density global tokens above so
        /// the rest of Studio remains visually stable.
        public static let markdownText = dynamic(
            dark: 0xF4F7FB,
            light: 0xF4F7FB,
            highContrastDark: 0xFFFFFF,
            highContrastLight: 0xFFFFFF
        )
        public static let markdownTextSecondary = dynamic(
            dark: 0xBAC4D0,
            light: 0xBAC4D0,
            highContrastDark: 0xE9F0F8,
            highContrastLight: 0xE9F0F8
        )
        public static let markdownTextTertiary = dynamic(
            dark: 0x8C99A8,
            light: 0x8C99A8,
            highContrastDark: 0xD5DFE9,
            highContrastLight: 0xD5DFE9
        )
        public static let markdownAccent = dynamic(
            dark: 0x6EA8FF,
            light: 0x6EA8FF,
            highContrastDark: 0xB8D4FF,
            highContrastLight: 0xB8D4FF
        )
        public static let markdownSuccess = dynamic(
            dark: 0x5BD489,
            light: 0x5BD489,
            highContrastDark: 0xA8F3C3,
            highContrastLight: 0xA8F3C3
        )
        public static let markdownWarning = dynamic(
            dark: 0xF0B35A,
            light: 0xF0B35A,
            highContrastDark: 0xFFE0A8,
            highContrastLight: 0xFFE0A8
        )
        public static let markdownSurface = dynamic(
            dark: 0x111318,
            light: 0x111318,
            highContrastDark: 0x000000,
            highContrastLight: 0x000000
        )
        public static let markdownSurfaceHi = dynamic(
            dark: 0x1A1D24,
            light: 0x1A1D24,
            highContrastDark: 0x0B0D12,
            highContrastLight: 0x0B0D12
        )
        public static let markdownBorder = dynamic(
            dark: 0x526071,
            light: 0x526071,
            highContrastDark: 0xDDE8F3,
            highContrastLight: 0xDDE8F3
        )
    }

    // MARK: Spacing
    public enum Spacing {
        public static let xs: CGFloat = 4
        public static let sm: CGFloat = 8
        public static let md: CGFloat = 12
        public static let lg: CGFloat = 16
        public static let xl: CGFloat = 24
        public static let xxl: CGFloat = 32
    }

    // MARK: Radius
    public enum Radius {
        public static let sm: CGFloat = 2
        public static let md: CGFloat = 4
        public static let lg: CGFloat = 6
        public static let xl: CGFloat = 8
    }

    // MARK: Typography
    /// Fixed-point chat density tokens for the rest of the app. Markdown uses
    /// the semantic `markdown*` tokens below so long-form response reading can
    /// honor Dynamic Type without changing Studio's global density.
    public enum Typography {
        public static let display  = Font.system(size: 30, weight: .semibold, design: .default)
        public static let title    = Font.system(size: 18, weight: .semibold, design: .default)
        public static let body     = Font.system(size: 13, weight: .regular, design: .default)
        public static let bodyHi   = Font.system(size: 13, weight: .medium,  design: .default)
        public static let caption  = Font.system(size: 11, weight: .regular, design: .default)
        public static let captionHi = Font.system(size: 11, weight: .medium, design: .default)
        public static let mono     = Font.system(size: 12, weight: .regular, design: .monospaced)
        public static let monoCaption = Font.system(size: 11, weight: .regular, design: .monospaced)

        // MARK: Markdown Dynamic Type

        public static let markdownBody = Font.system(.body, design: .default)
        public static let markdownBodyEmphasized = Font.system(.body, design: .default)
            .weight(.medium)
        public static let markdownCaption = Font.system(.caption, design: .default)
        public static let markdownMono = Font.system(.body, design: .monospaced)
        public static let markdownMonoCaption = Font.system(.caption, design: .monospaced)

        /// ATX Markdown heading hierarchy. Every level maps to a semantic
        /// text style so accessibility text-size settings scale all headings,
        /// including levels four through six.
        public static func markdownHeading(level: Int) -> Font {
            switch max(1, min(level, 6)) {
            case 1: return .system(.title2, design: .default).weight(.semibold)
            case 2: return .system(.title3, design: .default).weight(.semibold)
            case 3: return .system(.headline, design: .default)
            case 4: return .system(.subheadline, design: .default).weight(.semibold)
            case 5: return .system(.footnote, design: .default).weight(.medium)
            default: return .system(.caption, design: .default).weight(.medium)
            }
        }
    }

    public struct ProNoirBackground: View {
        public init() {}

        public var body: some View {
            ZStack {
                Colors.background
                Canvas { context, size in
                    var path = Path()
                    let step: CGFloat = 64
                    var x: CGFloat = 0
                    while x <= size.width {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        x += step
                    }
                    var y: CGFloat = 0
                    while y <= size.height {
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        y += step
                    }
                    context.stroke(path, with: .color(Colors.border.opacity(0.08)), lineWidth: 1)
                }
                LinearGradient(
                    colors: [
                        Colors.surfaceGlow.opacity(0.52),
                        Colors.accent.opacity(0.055),
                        Colors.background.opacity(0.0),
                    ],
                    startPoint: .topTrailing,
                    endPoint: .bottomLeading
                )
            }
        }
    }

    public struct ProNoirPanelBackground: View {
        public var active: Bool

        public init(active: Bool = false) {
            self.active = active
        }

        public var body: some View {
            RoundedRectangle(cornerRadius: Radius.lg)
                .fill(
                    LinearGradient(
                        colors: [
                            Colors.surfaceHi.opacity(active ? 0.98 : 0.90),
                            Colors.surface.opacity(active ? 0.92 : 0.78),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.lg)
                        .stroke(
                            active ? Colors.borderHi : Colors.border,
                            lineWidth: active ? 1.2 : 1
                        )
                )
        }
    }
}

extension Color {
    /// Initialize a Color from a 0xRRGGBB integer literal.
    public init(hex: UInt32, alpha: Double = 1.0) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >>  8) & 0xFF) / 255.0
        let b = Double( hex        & 0xFF) / 255.0
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

/// Build a `Color` that resolves to two different sRGB tuples based on
/// the active `userInterfaceStyle` (light or dark). The closure form lets
/// us avoid `Color(NSColor(...))` ceremony and works across macOS 14+
/// without needing an asset catalog. Used by `Theme.Colors` so the same
/// token name (`background`, `surface`, `textHigh`) automatically picks
/// the right shade when the user flips the Appearance menu in the tray. The
/// optional high-contrast overrides are used only by Markdown's dedicated
/// reading palette, leaving global Studio colors unchanged.
@inline(__always)
private func dynamic(
    dark: UInt32,
    light: UInt32,
    highContrastDark: UInt32? = nil,
    highContrastLight: UInt32? = nil
) -> Color {
    #if canImport(AppKit)
    return Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(
            from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]
        ) != nil
        let isHighContrast = appearance.bestMatch(
            from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]
        ) != nil
        let normal = isDark ? dark : light
        let highContrast = isDark
            ? (highContrastDark ?? dark)
            : (highContrastLight ?? light)
        let hex = isHighContrast ? highContrast : normal
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >>  8) & 0xFF) / 255.0
        let b = CGFloat( hex        & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
    })
    #else
    return Color(hex: dark)
    #endif
}
