import Foundation
import LoupeCore
import Testing
import WebKit

@MainActor
struct RelativeTimesTests {
    @Test func thePagesScriptWordsATimeAsSwiftWroteItWhateverHowLongAgo() async throws {
        let now = Date.now
        let dates = Self.offsets.map { now.addingTimeInterval(-$0) }
        let swift = dates.map { $0.formatted(.relative(presentation: .named).locale(Locale(identifier: "en_US"))) }
        let script = try #require(RelativeTimes.functions())
        let arguments: [String: Any] = ["dates": dates.map { $0.timeIntervalSince1970 * 1000 }, "now": now.timeIntervalSince1970 * 1000]
        let found = try await WKWebView().callAsyncJavaScript(script + "\nreturn dates.map(date => relativeTime(new Date(date), new Date(now)))", arguments: arguments, in: nil, contentWorld: .defaultClient)
        let words = try #require(found as? [String])

        let differing = zip(Self.offsets, zip(swift, words)).filter { $1.0 != $1.1 }.map { "\(Int($0)) seconds ago: Swift \($1.0), script \($1.1)" }
        #expect(differing.isEmpty, "\(differing.prefix(20).joined(separator: "\n"))")
        #expect(words.first == "now" && words.contains("yesterday") && words.contains("last week") && words.contains("last month") && words.contains("last year"))
    }

    @Test func aTimeStillToComeIsJustNowAsThePageWritesIt() async throws {
        let script = try #require(RelativeTimes.functions())
        let found = try await WKWebView().callAsyncJavaScript(script + "\nreturn relativeTime(new Date(Date.now() + 5000), new Date())", arguments: [:], in: nil, contentWorld: .defaultClient)
        #expect(found as? String == "just now")
    }

    /// Seconds ago, densest where the words change most: every second to two minutes, every
    /// half minute to three hours, every quarter hour to three days, every three hours to two
    /// months, then every day to over two years.
    private static let offsets: [TimeInterval] =
        Array(stride(from: 0, through: 125, by: 1)) + Array(stride(from: 150, through: 10_800, by: 30))
            + Array(stride(from: 11_700, through: 259_200, by: 900)) + Array(stride(from: 270_000, through: 5_184_000, by: 10_800))
            + Array(stride(from: 5_270_400, through: 70_000_000, by: 86_400))
}
