import Foundation
import LoupeCore

/// `Loupe` opens the PR list; `Loupe <diff>` opens a diff file; `Loupe --bench <diff>
/// [path-substring]` times parse, render and layout headlessly and exits.
@main
enum Entry {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.first == "--bench", args.count >= 2 {
            Bench.run(diffPath: args[1], fileFilter: args.count > 2 ? args[2] : nil)
            return
        }
        if args.first == "--fixture-checkouts", args.count == 2 {
            let directory = URL(filePath: args[1], directoryHint: .isDirectory)
            Task { exit(await FixtureRun.buildCheckouts(in: directory)) }
            RunLoop.main.run()
        }
        if args.first?.hasPrefix("-") == true || args.count > 1 {
            FileHandle.standardError.write(Data("usage: Loupe [diff-file] | --bench <diff-file> [path-substring] | --fixture-checkouts <dir>\n".utf8))
            exit(2)
        }
        // Native tooltips, SwiftUI's `.help` included, show sooner than macOS's default; registered
        // rather than set, so it isn't saved and a value the user sets still wins.
        UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 400])
        if SnapshotRun.directory != nil {
            // A snapshot run's bundle has its own id and so its own defaults; it reads the real
            // app's settings beneath them, to look the same, without ever writing to them. A run
            // against the fixtures doesn't, so it starts the same whatever they are.
            if FixtureRun.directory == nil { UserDefaults.standard.addSuite(named: "com.glenmailer.Loupe") }
            // Shown in TODO mode for this run only, as the argument domain is never saved.
            if ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_TODO"] == "1" {
                UserDefaults.standard.setVolatileDomain([ListMode.key: ListMode.todo.rawValue], forName: UserDefaults.argumentDomain)
            }
        }
        if let path = args.first {
            LaunchOptions.diffPath = path
            DiffApp.main()
        } else {
            LoupeApp.main()
        }
    }
}

/// SwiftUI's App initialiser takes no arguments, so the diff path is handed over here.
@MainActor
enum LaunchOptions {
    static var diffPath = ""
}
