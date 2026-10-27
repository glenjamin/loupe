import AppKit

/// The diff palette, close to GitHub's: muted row tints that keep code legible, and
/// text colours dark enough to read in light mode without dazzling in dark mode.
public enum DiffColors {
    public static let additionBackground = dynamic(light: (0xDA, 0xFB, 0xE1, 1), dark: (0x2E, 0xA0, 0x43, 0.15))
    public static let deletionBackground = dynamic(light: (0xFF, 0xEB, 0xE9, 1), dark: (0xF8, 0x51, 0x49, 0.15))
    public static let hunkHeaderBackground = dynamic(light: (0xDD, 0xF4, 0xFF, 1), dark: (0x38, 0x8B, 0xFD, 0.15))
    public static let successText = dynamic(light: (0x1A, 0x7F, 0x37, 1), dark: (0x3F, 0xB9, 0x50, 1))
    public static let dangerText = dynamic(light: (0xCF, 0x22, 0x2E, 1), dark: (0xF8, 0x51, 0x49, 1))
    public static let attentionText = dynamic(light: (0x9A, 0x67, 0x00, 1), dark: (0xD2, 0x99, 0x22, 1))

    // Primer's syntax palette, as GitHub colours code.
    public static let syntaxKeyword = dynamic(light: (0xCF, 0x22, 0x2E, 1), dark: (0xFF, 0x7B, 0x72, 1))
    public static let syntaxString = dynamic(light: (0x0A, 0x30, 0x69, 1), dark: (0xA5, 0xD6, 0xFF, 1))
    public static let syntaxComment = dynamic(light: (0x6E, 0x77, 0x81, 1), dark: (0x8B, 0x94, 0x9E, 1))
    public static let syntaxEntity = dynamic(light: (0x82, 0x50, 0xDF, 1), dark: (0xD2, 0xA8, 0xFF, 1))
    public static let syntaxConstant = dynamic(light: (0x05, 0x50, 0xAE, 1), dark: (0x79, 0xC0, 0xFF, 1))
    public static let syntaxVariable = dynamic(light: (0x95, 0x38, 0x00, 1), dark: (0xFF, 0xA6, 0x57, 1))
    public static let syntaxTag = dynamic(light: (0x11, 0x63, 0x29, 1), dark: (0x7E, 0xE7, 0x87, 1))

    // The gutter beside a changed row or hunk header, a shade darker than the row; dark mode's
    // are translucent and drawn over the row's tint.
    public static let additionGutterBackground = dynamic(light: (0xC7, 0xF0, 0xD0, 1), dark: (0x3F, 0xB9, 0x50, 0.12))
    public static let deletionGutterBackground = dynamic(light: (0xFF, 0xD7, 0xD5, 1), dark: (0xF8, 0x51, 0x49, 0.12))
    public static let hunkHeaderGutterBackground = dynamic(light: (0xC2, 0xE6, 0xFF, 1), dark: (0x38, 0x8B, 0xFD, 0.15))

    // Words that changed within a modified line, drawn over the row's tint.
    public static let additionWordBackground = dynamic(light: (0xAB, 0xF2, 0xBC, 1), dark: (0x2E, 0xA0, 0x43, 0.4))
    public static let deletionWordBackground = dynamic(light: (0xFF, 0x81, 0x82, 0.4), dark: (0xF8, 0x51, 0x49, 0.4))
}

typealias RGBA = (r: Int, g: Int, b: Int, a: CGFloat)

func dynamic(light: RGBA, dark: RGBA) -> NSColor {
    NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return color(isDark ? dark : light)
    }
}

private func color(_ c: RGBA) -> NSColor {
    NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: c.a)
}
