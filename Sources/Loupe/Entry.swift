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
        LaunchOptions.diffPath = args.first
        LoupeApp.main()
    }
}

/// SwiftUI's App initialiser takes no arguments, so the diff path is handed over here.
@MainActor
enum LaunchOptions {
    static var diffPath: String?
}
