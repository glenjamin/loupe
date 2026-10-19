import AppKit
import LoupeCore
import LoupeInbox
import SwiftUI

/// An image file's versions, how a changed one is compared, and for an SVG whether it shows
/// rendered rather than its diff.
struct ImagePreview {
    let change: ImageChange
    /// Nil until asked for, and for an added file.
    let old: ImageState?
    /// Nil until asked for, and for a deleted file.
    let new: ImageState?
    let mode: ImageComparisonMode
    let setMode: (ImageComparisonMode) -> Void
    let isRendered: Bool
    let setRendered: (Bool) -> Void
    /// Reads the versions, unless that's done or underway.
    let load: () async -> Void

    var isSVG: Bool { change.kind == .svg }

    /// The block a binary image is shown in, laid before anything else after the diff's rows
    /// (it has none), so the file's threads and the review footer still follow it.
    @MainActor var block: DiffBlockContent? {
        guard !isSVG else { return nil }
        return DiffBlockContent(id: "image", placement: .end, view: AnyView(ImageComparisonView(preview: self)))
    }
}

/// The image as github.com shows a PR's image file: an added one's new version, a deleted one's
/// old, and a changed one's two compared 2-up, by swipe or as an onion skin. Each is scaled down
/// to the width there is, never up past one image pixel to a screen pixel, on a checkerboard
/// that shows its transparency; Actual Size, or a click on it, shows it unscaled.
struct ImageComparisonView: View {
    let preview: ImagePreview
    @State private var actualSize = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let old = preview.change.old.map { decoded(preview.old, of: $0) }
        let new = preview.change.new.map { decoded(preview.new, of: $0) }
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                if old != nil && new != nil {
                    Picker("Compare", selection: Binding(get: { preview.mode }, set: { preview.setMode($0) })) {
                        Text("2-up").tag(ImageComparisonMode.twoUp)
                        Text("Swipe").tag(ImageComparisonMode.swipe)
                        Text("Onion skin").tag(ImageComparisonMode.onionSkin)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .disabled(old?.image == nil || new?.image == nil)
                    .help("Compare the versions side by side, by dragging a divider across them, or one over the other")
                }
                Toggle(isOn: $actualSize) {
                    Label("Actual Size", systemImage: "1.magnifyingglass")
                }
                .toggleStyle(.button)
                .help("Show the image unscaled, one image pixel to a screen pixel, rather than fitted to the width")
            }
            .controlSize(.small)
            Group {
                if actualSize {
                    ScrollView(.horizontal) { comparison(old: old, new: new) }
                } else {
                    comparison(old: old, new: new)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .task(id: preview.change) { await preview.load() }
    }

    @ViewBuilder
    private func comparison(old: Decoded?, new: Decoded?) -> some View {
        switch (old, new) {
        case let (old?, new?):
            if let before = old.image, let after = new.image, preview.mode != .twoUp {
                VStack(spacing: 8) {
                    if preview.mode == .swipe {
                        SwipeComparison(old: before, new: after, displayScale: displayScale, actualSize: actualSize)
                    } else {
                        OnionSkinComparison(old: before, new: after, displayScale: displayScale, actualSize: $actualSize)
                    }
                    HStack(spacing: 16) {
                        Text(verbatim: "Old: \(before.caption)").foregroundStyle(.diffDanger)
                        Text(verbatim: "New: \(after.caption)").foregroundStyle(.diffSuccess)
                    }
                    .font(.caption)
                }
            } else {
                HStack(alignment: .top, spacing: 16) {
                    pane(old, border: .diffDanger).frame(maxWidth: .infinity)
                    pane(new, border: .diffSuccess).frame(maxWidth: .infinity)
                }
            }
        case let (old?, nil):
            pane(old, border: .diffDanger)
        case let (nil, new?):
            pane(new, border: .diffSuccess)
        case (nil, nil):
            EmptyView()
        }
    }

    /// One version in a border of the colour github.com gives its side, with its size below.
    @ViewBuilder
    private func pane(_ version: Decoded, border: Color) -> some View {
        if let image = version.image {
            VStack(spacing: 6) {
                FitBox(natural: image.naturalSize(at: displayScale), actualSize: actualSize) {
                    ImageLayer(image: image.image)
                }
                .background { Checkerboard() }
                .padding(1)
                .border(border, width: 1)
                .onTapGesture { actualSize.toggle() }
                .help(actualSize ? "Click to fit the width" : "Click for actual size")
                Text(verbatim: image.caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else {
            VersionMessage(version: version)
        }
    }

    /// The version as an image, or why it isn't one. Decoded images are kept by commit and path,
    /// so redrawing doesn't decode them again.
    private func decoded(_ state: ImageState?, of source: ImageSource) -> Decoded {
        switch state {
        case .loading, nil:
            return .loading
        case let .tooLarge(bytes):
            return .message("At \(fileSize(bytes)), this image is more than Loupe reads (\(fileSize(ImagePreviews.byteLimit))).", symbol: "photo")
        case let .failed(message):
            return .message("Couldn't read this image: \(message)", symbol: "exclamationmark.triangle")
        case let .ready(data):
            let key = "\(source.oid):\(source.path)" as NSString
            if let image = decodedImages.object(forKey: key) {
                return .image(LoadedImage(image: image, bytes: data.count))
            }
            guard let image = NSImage(data: data), image.isValid else {
                let isLFSPointer = data.starts(with: Data("version https://git-lfs.github.com/spec/".utf8))
                return .message(isLFSPointer ? "This image is stored with Git LFS, and the checkout has only its pointer." : "macOS can't read this image.", symbol: "photo")
            }
            decodedImages.setObject(image, forKey: key)
            return .image(LoadedImage(image: image, bytes: data.count))
        }
    }
}

/// The old version on the left of a divider and the new on the right, both in the same place,
/// the divider following a drag or click across them.
private struct SwipeComparison: View {
    let old: LoadedImage
    let new: LoadedImage
    let displayScale: CGFloat
    let actualSize: Bool
    /// Where the divider is, as a fraction of the width.
    @State private var position = 0.5

    var body: some View {
        let canvas = canvasSize(old, new, displayScale: displayScale)
        FitBox(natural: canvas, actualSize: actualSize) {
            GeometryReader { geometry in
                let scale = geometry.size.width / canvas.width
                let divider = geometry.size.width * position
                ZStack {
                    Checkerboard()
                    ImageLayer(image: old.image).frame(width: old.naturalSize(at: displayScale).width * scale, height: old.naturalSize(at: displayScale).height * scale)
                    ImageLayer(image: new.image).frame(width: new.naturalSize(at: displayScale).width * scale, height: new.naturalSize(at: displayScale).height * scale)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .mask(alignment: .trailing) { Rectangle().frame(width: geometry.size.width - divider) }
                    SwipeHandle()
                        .frame(height: geometry.size.height)
                        .position(x: divider, y: geometry.size.height / 2)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    position = min(max(drag.location.x / geometry.size.width, 0), 1)
                })
            }
        }
        .padding(1)
        .border(Color(nsColor: .separatorColor), width: 1)
        .help("Drag across the image to move the divider between the old version, left, and the new, right")
    }
}

/// The new version over the old, as opaque as the slider below says.
private struct OnionSkinComparison: View {
    let old: LoadedImage
    let new: LoadedImage
    let displayScale: CGFloat
    @Binding var actualSize: Bool
    @State private var opacity = 0.5

    var body: some View {
        let canvas = canvasSize(old, new, displayScale: displayScale)
        VStack(spacing: 8) {
            FitBox(natural: canvas, actualSize: actualSize) {
                GeometryReader { geometry in
                    let scale = geometry.size.width / canvas.width
                    ZStack {
                        Checkerboard()
                        ImageLayer(image: old.image).frame(width: old.naturalSize(at: displayScale).width * scale, height: old.naturalSize(at: displayScale).height * scale)
                        ImageLayer(image: new.image).frame(width: new.naturalSize(at: displayScale).width * scale, height: new.naturalSize(at: displayScale).height * scale)
                            .opacity(opacity)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .padding(1)
            .border(Color(nsColor: .separatorColor), width: 1)
            .onTapGesture { actualSize.toggle() }
            .help(actualSize ? "Click to fit the width" : "Click for actual size")
            Slider(value: $opacity, in: 0...1) {
                Text("Opacity")
            } minimumValueLabel: {
                Text("Old").font(.caption)
            } maximumValueLabel: {
                Text("New").font(.caption)
            }
            .labelsHidden()
            .controlSize(.small)
            .frame(maxWidth: 260)
            .help("How much of the new version shows over the old")
        }
    }
}

/// The divider between the two versions in a swipe, with a knob to grab.
private struct SwipeHandle: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.accentColor)
                .frame(width: 2)
            Circle()
                .fill(Color.accentColor)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
        }
        .shadow(color: .black.opacity(0.3), radius: 1)
    }
}

/// Why a version can't be shown, or a spinner while it's read.
private struct VersionMessage: View {
    let version: Decoded

    var body: some View {
        Group {
            if case let .message(text, symbol) = version {
                Label(text, systemImage: symbol)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .font(.system(size: 12))
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}

/// An image decoded, with the size it's shown at and described by.
private struct LoadedImage {
    let image: NSImage
    /// The size of the file.
    let bytes: Int

    /// A drawing, such as an SVG or PDF, has no pixels of its own, only a size in points.
    private var pixels: CGSize? {
        let widest = image.representations.max { $0.pixelsWide < $1.pixelsWide }
        guard let widest, widest.pixelsWide > 0, widest.pixelsHigh > 0 else { return nil }
        return CGSize(width: widest.pixelsWide, height: widest.pixelsHigh)
    }

    /// Its size unscaled, in points: one image pixel to a screen pixel, or a drawing's own size.
    func naturalSize(at displayScale: CGFloat) -> CGSize {
        guard let pixels else { return image.size }
        return CGSize(width: pixels.width / displayScale, height: pixels.height / displayScale)
    }

    /// Its dimensions and file size, as github.com gives them under each version.
    var caption: String {
        let size = pixels ?? image.size
        let dimensions = "\(Int(size.width.rounded())) \u{00D7} \(Int(size.height.rounded()))\(pixels == nil ? "" : " px")"
        return "\(dimensions) \u{00B7} \(fileSize(bytes))"
    }
}

private enum Decoded {
    case loading
    case image(LoadedImage)
    case message(String, symbol: String)

    var image: LoadedImage? {
        if case let .image(image) = self { return image }
        return nil
    }
}

/// Sizes its content to `natural`, scaled down to the width offered unless `actualSize`, so its
/// height follows the width it's given, and gives the content that size.
private struct FitBox: Layout {
    let natural: CGSize
    let actualSize: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard natural.width > 0, natural.height > 0 else { return .zero }
        let width = actualSize ? natural.width : min(natural.width, proposal.width ?? natural.width)
        return CGSize(width: width, height: natural.height * width / natural.width)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// An image filling the frame it's given, animated if it's an animated GIF or PNG. It takes no
/// clicks, so they reach the gestures around it.
private struct ImageLayer: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> PassThroughImageView {
        let view = PassThroughImageView()
        view.imageScaling = .scaleAxesIndependently
        view.animates = true
        view.isEditable = false
        return view
    }

    func updateNSView(_ view: PassThroughImageView, context: Context) {
        if view.image !== image { view.image = image }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PassThroughImageView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }

    final class PassThroughImageView: NSImageView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// The grey and white squares github.com shows behind an image's transparent parts.
private struct Checkerboard: View {
    var body: some View {
        Image(nsImage: checkerTile)
            .resizable(resizingMode: .tile)
    }
}

/// Decoded images by commit and path, which never change.
@MainActor private let decodedImages = NSCache<NSString, NSImage>()

@MainActor private let checkerTile = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
    NSColor.white.setFill()
    rect.fill()
    NSColor(white: 0.9, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    NSRect(x: 8, y: 8, width: 8, height: 8).fill()
    return true
}

/// The size two versions share in a swipe or onion skin: wide and tall enough for either.
private func canvasSize(_ old: LoadedImage, _ new: LoadedImage, displayScale: CGFloat) -> CGSize {
    let before = old.naturalSize(at: displayScale)
    let after = new.naturalSize(at: displayScale)
    return CGSize(width: max(before.width, after.width), height: max(before.height, after.height))
}

private func fileSize(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

extension PullRequestTab {
    /// The versions and their comparison for an image file; nil for any other.
    func imagePreview(of file: FileDiff) -> ImagePreview? {
        guard let change = imageChange(of: file) else { return nil }
        let images = images
        return ImagePreview(
            change: change,
            old: change.old.flatMap { images.image($0) },
            new: change.new.flatMap { images.image($0) },
            mode: images.mode(of: file.path),
            setMode: { images.setMode($0, path: file.path) },
            isRendered: images.isRendered(file.path),
            setRendered: { images.setRendered($0, path: file.path) },
            load: { await self.loadImages(change) }
        )
    }
}
