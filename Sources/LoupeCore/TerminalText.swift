import AppKit

/// Text a program printed to a terminal, as the terminal would show it: coloured and styled by
/// its SGR escapes, each line ended by `\n` or `\r\n`, and a line rewritten after a lone `\r`, as
/// progress bars are, showing only what was written last. Other escapes are dropped.
public enum TerminalText {
    public static func attributed(_ text: String, fontSize: CGFloat = 12) -> NSAttributedString {
        var renderer = Renderer(fontSize: fontSize)
        renderer.render(text)
        return renderer.output
    }
}

private struct Renderer {
    let fontSize: CGFloat
    let output = NSMutableAttributedString()
    private var line = NSMutableAttributedString()
    private var style = Style()
    /// A lone `\r` came last, so the next character starts the line again.
    private var isReturned = false

    init(fontSize: CGFloat) {
        self.fontSize = fontSize
    }

    mutating func render(_ text: String) {
        let scalars = Array(text.unicodeScalars)
        var index = 0
        var run = ""
        func flush(_ renderer: inout Renderer) {
            guard !run.isEmpty else { return }
            renderer.append(run)
            run = ""
        }
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar {
            case "\u{1B}":
                flush(&self)
                index = escape(in: scalars, at: index)
                continue
            case "\r":
                flush(&self)
                if index + 1 < scalars.count, scalars[index + 1] == "\n" {
                    endLine()
                    index += 2
                    continue
                }
                isReturned = true
            case "\n":
                flush(&self)
                endLine()
            case "\u{08}":
                flush(&self)
                if line.length > 0 { line.deleteCharacters(in: NSRange(location: line.length - 1, length: 1)) }
            default:
                if isReturned {
                    flush(&self)
                    line = NSMutableAttributedString()
                    isReturned = false
                }
                // Other control characters, such as BEL, print nothing.
                if scalar.value >= 0x20 || scalar == "\t" { run.unicodeScalars.append(scalar) }
            }
            index += 1
        }
        flush(&self)
        if line.length > 0 { output.append(line) }
    }

    private mutating func append(_ text: String) {
        line.append(NSAttributedString(string: text, attributes: style.attributes(fontSize: fontSize)))
    }

    private mutating func endLine() {
        isReturned = false
        line.append(NSAttributedString(string: "\n", attributes: Style().attributes(fontSize: fontSize)))
        output.append(line)
        line = NSMutableAttributedString()
    }

    /// Reads the escape starting at `start`, applying it if it's SGR, and gives where the text
    /// after it starts.
    private mutating func escape(in scalars: [Unicode.Scalar], at start: Int) -> Int {
        var index = start + 1
        guard index < scalars.count else { return index }
        switch scalars[index] {
        case "[":
            index += 1
            var parameters = ""
            while index < scalars.count, !(0x40...0x7E).contains(scalars[index].value) {
                parameters.unicodeScalars.append(scalars[index])
                index += 1
            }
            if index < scalars.count, scalars[index] == "m" { style.apply(parameters) }
            return index + 1
        case "]":
            // An operating system command, such as a window title or a hyperlink, ended by BEL
            // or ST.
            index += 1
            while index < scalars.count {
                if scalars[index] == "\u{07}" { return index + 1 }
                if scalars[index] == "\u{1B}", index + 1 < scalars.count, scalars[index + 1] == "\\" { return index + 2 }
                index += 1
            }
            return index
        default:
            return index + 1
        }
    }
}

private struct Style {
    var foreground: NSColor?
    var background: NSColor?
    var isBold = false
    var isDim = false
    var isItalic = false
    var isUnderlined = false

    mutating func apply(_ parameters: String) {
        var codes = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        if codes.isEmpty { codes = [0] }
        var index = 0
        while index < codes.count {
            let code = codes[index]
            switch code {
            case 0: self = Style()
            case 1: isBold = true
            case 2: isDim = true
            case 3: isItalic = true
            case 4: isUnderlined = true
            case 22: isBold = false; isDim = false
            case 23: isItalic = false
            case 24: isUnderlined = false
            case 30...37: foreground = ansiColor(code - 30)
            case 90...97: foreground = ansiColor(code - 90 + 8)
            case 39: foreground = nil
            case 40...47: background = ansiColor(code - 40).withAlphaComponent(0.25)
            case 100...107: background = ansiColor(code - 100 + 8).withAlphaComponent(0.25)
            case 49: background = nil
            case 38, 48:
                let (color, used) = extendedColor(codes, after: index)
                if code == 38 { foreground = color } else { background = color?.withAlphaComponent(0.25) }
                index += used
            default: break
            }
            index += 1
        }
    }

    func attributes(fontSize: CGFloat) -> [NSAttributedString.Key: Any] {
        var font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: isBold ? .bold : .regular)
        if isItalic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        var color = foreground ?? .textColor
        if isDim { color = color.withAlphaComponent(0.6) }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let background { attributes[.backgroundColor] = background }
        if isUnderlined { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }
}

/// `5;n` for one of 256 colours or `2;r;g;b`, after the 38 or 48 at `index`, and how many codes
/// it took.
private func extendedColor(_ codes: [Int], after index: Int) -> (NSColor?, Int) {
    guard index + 1 < codes.count else { return (nil, 0) }
    switch codes[index + 1] {
    case 5:
        guard index + 2 < codes.count else { return (nil, 1) }
        return (indexedColor(codes[index + 2]), 2)
    case 2:
        guard index + 4 < codes.count else { return (nil, codes.count - index - 1) }
        return (rgb(codes[index + 2], codes[index + 3], codes[index + 4]), 4)
    default:
        return (nil, 1)
    }
}

private func indexedColor(_ index: Int) -> NSColor? {
    switch index {
    case 0..<16: return ansiColor(index)
    case 16..<232:
        let cube = index - 16
        let level = { (value: Int) in value == 0 ? 0 : 55 + value * 40 }
        return rgb(level(cube / 36), level(cube / 6 % 6), level(cube % 6))
    case 232..<256:
        let gray = 8 + (index - 232) * 10
        return rgb(gray, gray, gray)
    default: return nil
    }
}

private func rgb(_ red: Int, _ green: Int, _ blue: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(red) / 255, green: CGFloat(green) / 255, blue: CGFloat(blue) / 255, alpha: 1)
}

/// The 16 colours as GitHub's logs show them, legible in light and dark mode alike.
private func ansiColor(_ index: Int) -> NSColor {
    ansiPalette[max(0, min(index, ansiPalette.count - 1))]
}

private let ansiPalette: [NSColor] = [
    dynamic(light: (0x24, 0x29, 0x2F, 1), dark: (0x48, 0x4F, 0x58, 1)),
    dynamic(light: (0xCF, 0x22, 0x2E, 1), dark: (0xFF, 0x7B, 0x72, 1)),
    dynamic(light: (0x11, 0x63, 0x29, 1), dark: (0x3F, 0xB9, 0x50, 1)),
    dynamic(light: (0x4D, 0x2D, 0x00, 1), dark: (0xD2, 0x99, 0x22, 1)),
    dynamic(light: (0x09, 0x69, 0xDA, 1), dark: (0x58, 0xA6, 0xFF, 1)),
    dynamic(light: (0x82, 0x50, 0xDF, 1), dark: (0xBC, 0x8C, 0xFF, 1)),
    dynamic(light: (0x1B, 0x7C, 0x83, 1), dark: (0x39, 0xC5, 0xCF, 1)),
    dynamic(light: (0x6E, 0x77, 0x81, 1), dark: (0xB1, 0xBA, 0xC4, 1)),
    dynamic(light: (0x57, 0x60, 0x6A, 1), dark: (0x6E, 0x76, 0x81, 1)),
    dynamic(light: (0xA4, 0x0E, 0x26, 1), dark: (0xFF, 0xA1, 0x98, 1)),
    dynamic(light: (0x1A, 0x7F, 0x37, 1), dark: (0x56, 0xD3, 0x64, 1)),
    dynamic(light: (0x63, 0x3C, 0x01, 1), dark: (0xE3, 0xB3, 0x41, 1)),
    dynamic(light: (0x21, 0x8B, 0xFF, 1), dark: (0x79, 0xC0, 0xFF, 1)),
    dynamic(light: (0xA4, 0x75, 0xF9, 1), dark: (0xD2, 0xA8, 0xFF, 1)),
    dynamic(light: (0x31, 0x92, 0xAA, 1), dark: (0x56, 0xD4, 0xDD, 1)),
    dynamic(light: (0x8C, 0x95, 0x9F, 1), dark: (0xFF, 0xFF, 0xFF, 1)),
]
