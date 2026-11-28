import SwiftUI

/// Design tokens from docs/plan.md §Visual Identity — sand neutrals, lavender
/// accent, coral for destructive. Dynamic NSColor providers so every token
/// follows the system light/dark appearance.
enum Theme {
    static let bg         = dyn(0xFCFCFB, 0x1A1A1A) // content background (sand-50 / vast-950)
    static let sidebar    = dyn(0xF5F4F0, 0x212120) // sand-500
    static let card       = dyn(0xFFFFFF, 0x262625)
    static let field      = dyn(0xFAF9F7, 0x1E1E1D) // sand-100
    static let border     = dyn(0xEEEBE3, 0x3A3A38) // sand-600
    static let control    = dyn(0xE3DFD5, 0x4A4A47) // button/field outline, a step stronger than border
    static let text       = dyn(0x30302F, 0xF5F4F0) // vast-900
    // Secondary text people must read (≥ 4.5:1 on card, bg and sidebar).
    static let muted      = dyn(0x6F6B62, 0xA19E96)
    static let accent     = dyn(0x6C358C, 0xD9B8F0) // brand-800 / bright lavender
    static let accentFill = dyn(0xF0D7FF, 0x3C2947) // brand-500 / brand-950
    static let onAccent   = dyn(0xFFFFFF, 0x30302F) // text on accent-filled surfaces
    static let success    = dyn(0x3FA866, 0x4FBF78)
    static let warning    = dyn(0xC27A12, 0xF0A64A)
    static let danger     = dyn(0xC93A3A, 0xEE6A6A) // also used as text: ≥ 4.5:1 in light

    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: 1)
        })
    }
}
