import Foundation
import LoupeCore
import LoupeGit
import Observation

/// An open PR's image files, read from the checkout to show as github.com does: an added file's
/// new image, a deleted one's old, and both versions of a changed one. Each version is kept by
/// the commit it's of while the tab lives, so moving between files or modes doesn't read it
/// again; so is how each changed image is compared, and which SVGs show rendered.
@Observable
@MainActor
public final class ImagePreviews {
    /// The most of an image read from the checkout; a bigger one only says how big it is.
    public static let byteLimit = 20 * 1024 * 1024

    private let differ: PullRequestDiffer
    private var images: [ImageSource: ImageState] = [:]
    private var modes: [String: ImageComparisonMode] = [:]
    /// The SVGs shown rendered; any other shows its diff.
    private var renderedPaths: Set<String> = []

    init(differ: PullRequestDiffer) {
        self.differ = differ
    }

    /// The version's bytes once asked for.
    public func image(_ source: ImageSource) -> ImageState? {
        images[source]
    }

    /// How a changed image is compared, 2-up until another way is picked.
    public func mode(of path: String) -> ImageComparisonMode {
        modes[path] ?? .twoUp
    }

    public func setMode(_ mode: ImageComparisonMode, path: String) {
        modes[path] = mode
    }

    public func isRendered(_ path: String) -> Bool {
        renderedPaths.contains(path)
    }

    public func setRendered(_ rendered: Bool, path: String) {
        if rendered {
            renderedPaths.insert(path)
        } else {
            renderedPaths.remove(path)
        }
    }

    /// Reads both versions the change shows, each unless that's done or underway. A failed read
    /// is tried again.
    func load(_ change: ImageChange, checkout: URL) async {
        async let old: Void = load(change.old, checkout: checkout)
        async let new: Void = load(change.new, checkout: checkout)
        _ = await (old, new)
    }

    private func load(_ source: ImageSource?, checkout: URL) async {
        guard let source else { return }
        switch images[source] {
        case .loading, .ready, .tooLarge: return
        case .failed, nil: break
        }
        images[source] = .loading
        do {
            switch try await differ.blob(of: source.path, at: source.oid, in: checkout, limit: Self.byteLimit) {
            case let .contents(data): images[source] = .ready(data)
            case let .tooLarge(bytes): images[source] = .tooLarge(bytes: bytes)
            }
        } catch {
            images[source] = .failed(error.localizedDescription)
        }
    }
}

/// An image file as it is in one commit.
public struct ImageSource: Sendable, Hashable {
    public let path: String
    public let oid: String
}

public enum ImageState: Sendable, Equatable {
    case loading
    /// The file's bytes, as committed.
    case ready(Data)
    /// Its size, being over `ImagePreviews.byteLimit`.
    case tooLarge(bytes: Int)
    /// Why it couldn't be read.
    case failed(String)
}

/// What an image file's change shows: the version before, the version after, or both.
public struct ImageChange: Sendable, Hashable {
    public let kind: ImageKind
    /// Nil for an added file.
    public let old: ImageSource?
    /// Nil for a deleted file.
    public let new: ImageSource?
}

/// github.com's ways of comparing two versions of an image.
public enum ImageComparisonMode: String, Sendable, CaseIterable {
    /// Side by side.
    case twoUp
    /// One over the other, with a divider dragged across to reveal the new one.
    case swipe
    /// The new one over the old, as transparent as a slider says.
    case onionSkin
}

extension PullRequestTab {
    /// What an image file in the shown changes compares: its version at their base, by the name
    /// it had there, and at their head; only the one for an added or deleted file. Nil for any
    /// other file, or until the diff is ready.
    public func imageChange(of file: FileDiff) -> ImageChange? {
        guard let kind = ImageKind(path: file.path), let range = shownRange else { return nil }
        let oldPath: String? = switch file.change {
        case .added: nil
        case let .renamed(from, _), let .copied(from, _): from
        case .deleted, .modified: file.path
        }
        return ImageChange(
            kind: kind,
            old: oldPath.map { ImageSource(path: $0, oid: range.base) },
            new: file.change == .deleted ? nil : ImageSource(path: file.path, oid: range.head)
        )
    }

    /// Reads the change's versions from the checkout, unless that's done or underway.
    public func loadImages(_ change: ImageChange) async {
        guard let checkout else { return }
        await images.load(change, checkout: checkout)
    }
}
