import Foundation

/// A file shown as its image, as github.com shows image files in a PR, told by its extension.
public enum ImageKind: Sendable, Equatable {
    /// A binary image, shown in place of its diff, which has no lines.
    case raster
    /// An SVG, which is text with a diff of its own, so it's shown rendered only when asked.
    case svg

    /// The kind of image at `path`, or nil for any other file.
    public init?(path: String) {
        let ext = (path as NSString).pathExtension.lowercased()
        if ext == "svg" {
            self = .svg
        } else if Self.rasterExtensions.contains(ext) {
            self = .raster
        } else {
            return nil
        }
    }

    /// Formats macOS reads as images.
    private static let rasterExtensions: Set<String> = [
        "png", "apng", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "ico", "icns", "tif", "tiff", "bmp", "pdf",
    ]
}
