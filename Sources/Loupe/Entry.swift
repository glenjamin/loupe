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
        if args.first?.hasPrefix("-") == true || args.count > 1 {
            FileHandle.standardError.write(Data("usage: Loupe [diff-file] | --bench <diff-file> [path-substring]\n".utf8))
            exit(2)
        }
        if SnapshotRun.directory != nil {
            // A snapshot run's bundle has its own id and so its own defaults; it reads the real
            // app's settings beneath them, to look the same, without ever writing to them.
            UserDefaults.standard.addSuite(named: "com.glenmailer.Loupe")
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
