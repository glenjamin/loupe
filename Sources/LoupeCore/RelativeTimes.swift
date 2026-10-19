import Foundation

/// The conversation page's "N ago" times, kept current in place by a script in the app's own
/// content world, which the page's policy against script doesn't reach, as its `<time>`s carry
/// when they were. Its words are Swift's, as `ConversationHTML` first writes them.
public enum RelativeTimes {
    /// Rewords the page's times once it's loaded, each minute while it can be seen, and as soon
    /// as it's seen again. Nil if the app is missing the script.
    public static func pageScript(firstWeekday: Int = Calendar.autoupdatingCurrent.firstWeekday) -> String? {
        functions(firstWeekday: firstWeekday).map { $0 + "\n" + start }
    }

    /// The script's functions alone: `relativeTime(date, now)`, the words for a time; `updateTimes()`,
    /// which rewords the page's; and `moveClock(milliseconds)`, which moves the clock on and
    /// rewords them. A week starts on `firstWeekday`, 1 being Sunday, as `Calendar`'s does.
    public static func functions(firstWeekday: Int = Calendar.autoupdatingCurrent.firstWeekday) -> String? {
        source.map { "const firstWeekday = \(firstWeekday);\n" + $0 }
    }

    private static let source = bundledResource("relative-times.js", in: "Loupe_LoupeCore").flatMap { try? String(contentsOf: $0, encoding: .utf8) }

    private static let start = """
        updateTimes();
        setInterval(() => { if (document.visibilityState === 'visible') updateTimes(); }, 60000);
        document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') updateTimes(); });
        """
}
