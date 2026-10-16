import Foundation

/// The IDE a checkout is opened in: GoLand for a Go module, VS Code for anything else.
public enum Editor: Sendable, Equatable {
    case goLand
    case visualStudioCode

    /// GoLand when the checkout's root has a `go.mod`, else VS Code.
    public init(for checkout: URL) {
        let goMod = checkout.appending(path: "go.mod").path(percentEncoded: false)
        self = FileManager.default.fileExists(atPath: goMod) ? .goLand : .visualStudioCode
    }

    public var name: String {
        switch self {
        case .goLand: "GoLand"
        case .visualStudioCode: "VS Code"
        }
    }

    /// Launch Services' name for the app, so it's found wherever it's installed.
    public var bundleIdentifier: String {
        switch self {
        case .goLand: "com.jetbrains.goland"
        case .visualStudioCode: "com.microsoft.VSCode"
        }
    }
}
