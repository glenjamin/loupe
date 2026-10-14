import AppKit
import LoupeCore

/// Headless timings for the riskiest steps: parsing a large diff, building one file's attributed
/// string, and laying it out / drawing it in the real DiffTextView.
@MainActor
enum Bench {
    static func run(diffPath: String, fileFilter: String?) {
        let text: String
        do {
            text = try String(contentsOfFile: diffPath, encoding: .utf8)
        } catch {
            print("can't read \(diffPath): \(error.localizedDescription)")
            return
        }
        let lineCount = text.utf8.reduce(0) { $1 == UInt8(ascii: "\n") ? $0 + 1 : $0 }
        let (files, parseTime) = measure { DiffParser.parse(text) }
        let parts = PathFilter.default.partition(files)
        print("parse: \(lineCount) diff lines, \(files.count) files (\(parts.excluded.count) excluded) in \(ms(parseTime))")

        let candidates = fileFilter.map { filter in files.filter { $0.path.contains(filter) } } ?? files
        guard let file = candidates.max(by: { $0.rowCount < $1.rowCount }) else {
            print("no matching file")
            return
        }
        print("file: \(file.path) — \(file.rowCount) rows")

        _ = RenderedDiff(file: FileDiff(path: "warmup", change: .modified, isBinary: false, hunks: []))
        let (rendered, renderTime) = measure { RenderedDiff(file: file) }
        print("render attributed string: \(ms(renderTime)) (\(rendered.text.length) UTF-16 units)")

        let viewport = NSRect(x: 0, y: 0, width: 1200, height: 900)
        let textView = DiffTextView.make()
        textView.frame = viewport
        let (_, showTime) = measure { textView.show(rendered) }
        print("set text storage: \(ms(showTime)), view now \(Int(textView.frame.height))pt tall")

        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let (_, firstScreen) = measure { layoutManager.ensureLayout(forBoundingRect: viewport, in: container) }
        print("lay out first screen: \(ms(firstScreen))")

        for (label, y) in [("first", 0.0), ("middle", textView.frame.height / 2), ("first again", 0.0)] {
            let rect = NSRect(x: 0, y: y, width: 1200, height: 900)
            let bitmap = textView.bitmapImageRepForCachingDisplay(in: rect)
            let (_, drawTime) = measure {
                if let bitmap { textView.cacheDisplay(in: rect, to: bitmap) }
            }
            print("draw \(label) screen: \(ms(drawTime))")
        }

        let (_, fullLayout) = measure { layoutManager.ensureLayout(for: container) }
        let height = layoutManager.usedRect(for: container).height
        print("lay out whole file: \(ms(fullLayout)), \(Int(height))pt tall")

        let (anchor, lookupTime) = measure { rendered.anchor(at: rendered.text.length / 2) }
        print("anchor at midpoint: \(anchor.map(String.init(describing:)) ?? "none") in \(ms(lookupTime))")
    }
}

private extension FileDiff {
    var rowCount: Int { hunks.reduce(0) { $0 + $1.lines.count + 1 } }
}

private func measure<T>(_ work: () -> T) -> (T, Duration) {
    let clock = ContinuousClock()
    var result: T?
    let elapsed = clock.measure { result = work() }
    return (result!, elapsed)
}

private func ms(_ duration: Duration) -> String {
    let (seconds, attos) = duration.components
    return String(format: "%.1fms", Double(seconds) * 1000 + Double(attos) / 1e15)
}
