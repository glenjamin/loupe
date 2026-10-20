import SwiftUI

/// Redraws `content` every minute, for an "N ago" label, with the time it's drawn. A
/// TimelineView's own date is the start of the minute, which a time just made is after.
struct EveryMinute<Content: View>: View {
    @ViewBuilder let content: (Date) -> Content

    var body: some View {
        TimelineView(.everyMinute) { context in
            content(max(context.date, .now))
        }
    }
}
