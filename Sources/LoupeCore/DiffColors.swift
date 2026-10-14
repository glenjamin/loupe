import AppKit

/// The diff palette, close to GitHub's: muted row tints that keep code legible, and
/// text colours dark enough to read in light mode without dazzling in dark mode.
public enum DiffColors {
    public static let additionBackground = dynamic(light: (0xDA, 0xFB, 0xE1, 1), dark: (0x2E, 0xA0, 0x43, 0.15))
    public static let deletionBackground = dynamic(light: (0xFF, 0xEB, 0xE9, 1), dark: (0xF8, 0x51, 0x49, 0.15))
    public static let hunkHeaderBackground = dynamic(light: (0xDD, 0xF4, 0xFF, 1), dark: (0x38, 0x8B, 0xFD, 0.15))
    public static let successText = dynamic(light: (0x1A, 0x7F, 0x37, 1), dark: (0x3F, 0xB9, 0x50, 1))
    public static let dangerText = dynamic(light: (0xCF, 0x22, 0x2E, 1), dark: (0xF8, 0x51, 0x49, 1))
}

private typealias RGBA = (r: Int, g: Int, b: Int, a: CGFloat)

private func dynamic(light: RGBA, dark: RGBA) -> NSColor {
    NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return color(isDark ? dark : light)
    }
}

private func color(_ c: RGBA) -> NSColor {
    NSColor(srgbRed: CGFloat(c.r) / 255, green: CGFloat(c.g) / 255, blue: CGFloat(c.b) / 255, alpha: c.a)
}
