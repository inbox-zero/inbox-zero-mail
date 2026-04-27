import AppKit
import SwiftUI

public enum MailDesignTokens {
    // Backgrounds
    public static let background = dynamicColor(
        light: NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1),
        dark: NSColor(srgbRed: 0.07, green: 0.08, blue: 0.10, alpha: 1)
    )
    public static let sidebar = dynamicColor(
        light: NSColor(srgbRed: 0.95, green: 0.96, blue: 0.98, alpha: 1),
        dark: NSColor(srgbRed: 0.09, green: 0.10, blue: 0.13, alpha: 1)
    )
    public static let sidebarSurface = dynamicColor(
        light: NSColor(srgbRed: 0.91, green: 0.93, blue: 0.96, alpha: 1),
        dark: NSColor(srgbRed: 0.13, green: 0.14, blue: 0.18, alpha: 1)
    )

    // Surfaces
    public static let surface = dynamicColor(
        light: .white,
        dark: NSColor(srgbRed: 0.11, green: 0.12, blue: 0.14, alpha: 1)
    )
    public static let surfaceMuted = dynamicColor(
        light: NSColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1),
        dark: NSColor(srgbRed: 0.14, green: 0.15, blue: 0.18, alpha: 1)
    )

    // Accent
    public static let accent = dynamicColor(
        light: NSColor(srgbRed: 0.25, green: 0.52, blue: 0.96, alpha: 1),
        dark: NSColor(srgbRed: 0.42, green: 0.64, blue: 1.00, alpha: 1)
    )
    public static let accentStrong = dynamicColor(
        light: NSColor(srgbRed: 0.18, green: 0.42, blue: 0.84, alpha: 1),
        dark: NSColor(srgbRed: 0.55, green: 0.74, blue: 1.00, alpha: 1)
    )

    // Status
    public static let unread = dynamicColor(
        light: NSColor(srgbRed: 0.25, green: 0.52, blue: 0.96, alpha: 1),
        dark: NSColor(srgbRed: 0.46, green: 0.68, blue: 1.00, alpha: 1)
    )
    public static let selected = dynamicColor(
        light: NSColor(srgbRed: 0.93, green: 0.95, blue: 1.00, alpha: 1),
        dark: NSColor(srgbRed: 0.18, green: 0.24, blue: 0.36, alpha: 1)
    )

    // Chips
    public static let chipBackground = dynamicColor(
        light: NSColor(srgbRed: 0.92, green: 0.95, blue: 1.00, alpha: 1),
        dark: NSColor(srgbRed: 0.18, green: 0.22, blue: 0.30, alpha: 1)
    )

    // Text
    public static let textPrimary = dynamicColor(
        light: NSColor(srgbRed: 0.10, green: 0.11, blue: 0.15, alpha: 1),
        dark: NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1)
    )
    public static let textSecondary = dynamicColor(
        light: NSColor(srgbRed: 0.45, green: 0.47, blue: 0.54, alpha: 1),
        dark: NSColor(srgbRed: 0.66, green: 0.68, blue: 0.74, alpha: 1)
    )
    public static let textTertiary = dynamicColor(
        light: NSColor(srgbRed: 0.62, green: 0.64, blue: 0.70, alpha: 1),
        dark: NSColor(srgbRed: 0.50, green: 0.52, blue: 0.58, alpha: 1)
    )

    // Sidebar text
    public static let sidebarText = dynamicColor(
        light: NSColor(srgbRed: 0.14, green: 0.17, blue: 0.22, alpha: 1),
        dark: NSColor(srgbRed: 0.92, green: 0.93, blue: 0.96, alpha: 1)
    )
    public static let sidebarMuted = dynamicColor(
        light: NSColor(srgbRed: 0.42, green: 0.47, blue: 0.55, alpha: 1),
        dark: NSColor(srgbRed: 0.62, green: 0.65, blue: 0.72, alpha: 1)
    )
    public static let sidebarHover = dynamicColor(
        light: NSColor(srgbRed: 0.25, green: 0.52, blue: 0.96, alpha: 0.10),
        dark: NSColor(srgbRed: 0.42, green: 0.64, blue: 1.00, alpha: 0.16)
    )
    public static let sidebarSelected = dynamicColor(
        light: NSColor(srgbRed: 0.25, green: 0.52, blue: 0.96, alpha: 0.18),
        dark: NSColor(srgbRed: 0.42, green: 0.64, blue: 1.00, alpha: 0.26)
    )

    // Borders & Shadows
    public static let border = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.06),
        dark: NSColor.white.withAlphaComponent(0.10)
    )
    public static let divider = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.06),
        dark: NSColor.white.withAlphaComponent(0.08)
    )
    public static let shadow = dynamicColor(
        light: NSColor.black.withAlphaComponent(0.06),
        dark: NSColor.black.withAlphaComponent(0.45)
    )

    private static func dynamicColor(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark, .aqua])
            switch match {
            case .darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastVibrantDark:
                return dark
            default:
                return light
            }
        })
    }
}
