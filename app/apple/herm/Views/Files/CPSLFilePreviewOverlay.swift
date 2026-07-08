import Foundation
import Combine
import SwiftUI

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
#if canImport(AVKit)
@preconcurrency import AVKit
#endif
#if os(macOS) && canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if canImport(PDFKit)
import PDFKit
#endif

struct CPSLFilePreviewContentView: View {
    let preview: CPSLFilePreview

    var body: some View {
        switch preview.kind {
        case .text(let text):
            CPSLTextFilePreview(text: text)
        case .code(let text, let language):
            CPSLCodeFilePreview(text: text, language: language)
        case .pdf(let url):
            CPSLPDFFilePreview(url: url)
        case .image(let url):
            CPSLImageFilePreview(url: url, preview: preview)
        case .audio(let url):
            CPSLAudioFilePreview(url: url, preview: preview)
        case .video(let url):
            CPSLVideoFilePreview(url: url, preview: preview)
        case .file(let reason):
            CPSLGenericFilePreview(preview: preview, reason: reason)
        }
    }
}

private struct CPSLTextFilePreview: View {
    let text: String

    var body: some View {
        ScrollView(.vertical) {
            Text(text)
                .font(CPSLTheme.monospacedBodyFont)
                .foregroundStyle(CPSLTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CPSLTheme.medium)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct CPSLCodeFilePreview: View {
    let text: String
    let language: CPSLCodeLanguage

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            CPSLHighlightedCodeText(text: text, language: language)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(CPSLTheme.medium)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CPSLHighlightedCodeText: View {
    let text: String
    let language: CPSLCodeLanguage

    var body: some View {
        Text(CPSLCodeHighlighter.highlight(text, language: language))
    }
}

private struct CPSLPDFFilePreview: View {
    let url: URL

    var body: some View {
        #if os(macOS) && canImport(PDFKit)
            CPSLPDFKitView(url: url)
        #elseif canImport(UIKit) && canImport(PDFKit)
            CPSLPDFKitView(url: url)
        #else
            CPSLUnsupportedPDFPreview()
        #endif
    }
}

private struct CPSLUnsupportedPDFPreview: View {
    var body: some View {
        VStack(spacing: CPSLTheme.small) {
            Image(systemName: "doc.richtext")
                .font(CPSLTheme.iconLargeFont)
                .foregroundStyle(CPSLTheme.secondaryText)
            Text("PDF preview is not available on this platform.")
                .font(CPSLTheme.supportingFont)
                .foregroundStyle(CPSLTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct CPSLImageFilePreview: View {
    let url: URL
    let preview: CPSLFilePreview

    var body: some View {
        #if os(macOS) && canImport(AppKit)
            CPSLPlatformImageFilePreview(url: url, preview: preview)
        #elseif canImport(UIKit)
            CPSLPlatformImageFilePreview(url: url, preview: preview)
        #else
            CPSLGenericFilePreview(
                preview: preview, reason: "Image preview is not available on this platform.")
        #endif
    }
}

private struct CPSLAudioFilePreview: View {
    let url: URL
    let preview: CPSLFilePreview

    var body: some View {
        #if canImport(AVFoundation) && canImport(AVKit)
            CPSLAudioPlayerPreview(url: url, preview: preview)
        #else
            CPSLGenericFilePreview(
                preview: preview, reason: "Audio playback is not available on this platform.")
        #endif
    }
}

private struct CPSLVideoFilePreview: View {
    let url: URL
    let preview: CPSLFilePreview

    var body: some View {
        #if canImport(AVFoundation) && canImport(AVKit)
            CPSLVideoPlayerPreview(url: url, preview: preview)
        #else
            CPSLGenericFilePreview(
                preview: preview, reason: "Video playback is not available on this platform.")
        #endif
    }
}

private struct CPSLGenericFilePreview: View {
    let preview: CPSLFilePreview
    let reason: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CPSLTheme.large) {
                CPSLFilePreviewHero(
                    name: preview.name,
                    category: preview.metadata.category,
                    reason: reason
                )
                CPSLFileMetadataList(metadata: preview.metadata)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CPSLTheme.large)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct CPSLFilePreviewHero: View {
    let name: String
    let category: CPSLFilePreviewCategory
    let reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.medium) {
            Image(systemName: category.systemImageName)
                .symbolRenderingMode(.hierarchical)
                .font(CPSLTheme.emptyStateIconFont)
                .foregroundStyle(category.iconColor)
                .frame(width: 72, height: 72, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(name)
                    .font(CPSLTheme.headerFont)
                    .foregroundStyle(CPSLTheme.text)
                    .textSelection(.enabled)

                Text(category.displayName)
                    .font(CPSLTheme.supportingFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
            }

            if let reason {
                Text(reason)
                    .font(CPSLTheme.supportingFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CPSLFileMetadataList: View {
    let metadata: CPSLFileMetadata

    var body: some View {
        VStack(spacing: 0) {
            CPSLFileMetadataRow(label: "Type", value: metadata.typeDescription)

            if let sizeBytes = metadata.sizeBytes {
                CPSLFileMetadataDivider()
                CPSLFileMetadataRow(
                    label: "Size",
                    value: CPSLFilePreviewFormatting.byteCount(sizeBytes)
                )
            }

            if let dimensions = metadata.dimensions {
                CPSLFileMetadataDivider()
                CPSLFileMetadataRow(
                    label: "Dimensions",
                    value: CPSLFilePreviewFormatting.dimensions(dimensions)
                )
            }

            if let durationSeconds = metadata.durationSeconds {
                CPSLFileMetadataDivider()
                CPSLFileMetadataRow(
                    label: "Duration",
                    value: CPSLFilePreviewFormatting.duration(durationSeconds)
                )
            }

            if let creationDate = metadata.creationDate {
                CPSLFileMetadataDivider()
                CPSLFileMetadataRow(
                    label: "Created",
                    value: CPSLFilePreviewFormatting.date(creationDate)
                )
            }

            if let modificationDate = metadata.modificationDate {
                CPSLFileMetadataDivider()
                CPSLFileMetadataRow(
                    label: "Modified",
                    value: CPSLFilePreviewFormatting.date(modificationDate)
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CPSLFileMetadataRow: View {
    let label: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: CPSLTheme.medium) {
            Text(label)
                .font(CPSLTheme.captionMediumFont)
                .foregroundStyle(CPSLTheme.secondaryText)
                .frame(width: 84, alignment: .leading)

            Text(value)
                .font(CPSLTheme.captionFont)
                .foregroundStyle(CPSLTheme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, CPSLTheme.small)
    }
}

private struct CPSLFileMetadataDivider: View {
    var body: some View {
        Divider()
            .overlay(CPSLTheme.text.opacity(0.05))
    }
}

private enum CPSLFilePreviewFormatting {
    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func date(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .shortened)
    }

    static func dimensions(_ dimensions: CPSLFileDimensions) -> String {
        "\(dimensions.width) x \(dimensions.height) px"
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite && seconds >= 0 else {
            return "0:00"
        }

        let totalSeconds = Int(seconds.rounded())
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let remainingSeconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

#if os(macOS) && canImport(AppKit)
private typealias CPSLPlatformPreviewImage = NSImage

private enum CPSLPlatformImageLoader {
    static func image(for url: URL) -> CPSLPlatformPreviewImage? {
        NSImage(contentsOf: url)
    }
}

private struct CPSLPlatformImageView: View {
    let image: CPSLPlatformPreviewImage

    var body: some View {
        Image(nsImage: image)
            .resizable()
    }
}
#elseif canImport(UIKit)
private typealias CPSLPlatformPreviewImage = UIImage

private enum CPSLPlatformImageLoader {
    static func image(for url: URL) -> CPSLPlatformPreviewImage? {
        UIImage(contentsOfFile: url.path)
    }
}

private struct CPSLPlatformImageView: View {
    let image: CPSLPlatformPreviewImage

    var body: some View {
        Image(uiImage: image)
            .resizable()
    }
}
#endif

#if (os(macOS) && canImport(AppKit)) || canImport(UIKit)
private struct CPSLPlatformImageFilePreview: View {
    let url: URL
    let preview: CPSLFilePreview
    @State private var image: CPSLPlatformPreviewImage?
    @State private var didAttemptLoad = false

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            VStack(alignment: .leading, spacing: CPSLTheme.large) {
                if let image {
                    CPSLPlatformImageView(image: image)
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                } else if didAttemptLoad {
                    CPSLFilePreviewHero(
                        name: preview.name,
                        category: preview.metadata.category,
                        reason: "This image could not be loaded."
                    )
                    CPSLFileMetadataList(metadata: preview.metadata)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, CPSLTheme.large)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CPSLTheme.large)
        }
        .scrollBounceBehavior(.basedOnSize)
        .task(id: url) {
            image = CPSLPlatformImageLoader.image(for: url)
            didAttemptLoad = true
        }
    }
}
#endif

#if canImport(AVFoundation) && canImport(AVKit)
private struct CPSLAudioPlayerPreview: View {
    let preview: CPSLFilePreview
    @StateObject private var playback: CPSLMediaPlaybackModel

    init(url: URL, preview: CPSLFilePreview) {
        self.preview = preview
        _playback = StateObject(
            wrappedValue: CPSLMediaPlaybackModel(
                url: url,
                duration: preview.metadata.durationSeconds
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CPSLTheme.large) {
                CPSLFilePreviewHero(name: preview.name, category: .audio, reason: nil)
                CPSLMediaControlsView(playback: playback)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CPSLTheme.large)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

private struct CPSLVideoPlayerPreview: View {
    let preview: CPSLFilePreview
    @StateObject private var playback: CPSLMediaPlaybackModel

    init(url: URL, preview: CPSLFilePreview) {
        self.preview = preview
        _playback = StateObject(
            wrappedValue: CPSLMediaPlaybackModel(
                url: url,
                duration: preview.metadata.durationSeconds
            )
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: CPSLTheme.large) {
                VideoPlayer(player: playback.player)
                    .aspectRatio(videoAspectRatio, contentMode: .fit)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.compactRadius, style: .continuous))

                CPSLMediaControlsView(playback: playback)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CPSLTheme.large)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private var videoAspectRatio: CGFloat {
        guard let dimensions = preview.metadata.dimensions, dimensions.height > 0 else {
            return 16.0 / 9.0
        }
        return CGFloat(dimensions.width) / CGFloat(dimensions.height)
    }
}

private struct CPSLMediaControlsView: View {
    @ObservedObject var playback: CPSLMediaPlaybackModel

    var body: some View {
        VStack(spacing: CPSLTheme.small) {
            HStack(spacing: CPSLTheme.medium) {
                Button(action: playback.togglePlayback) {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(CPSLTheme.iconMediumFont)
                        .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPSLTheme.text)
                .accessibilityLabel(playback.isPlaying ? "Pause" : "Play")

                Slider(
                    value: Binding(
                        get: { playback.currentTime },
                        set: { playback.seek(to: $0) }
                    ),
                    in: 0...sliderUpperBound
                )
                .tint(CPSLTheme.mauve)
            }

            HStack {
                Text(CPSLFilePreviewFormatting.duration(playback.currentTime))
                Spacer()
                Text(CPSLFilePreviewFormatting.duration(playback.duration))
            }
            .font(CPSLTheme.captionFont)
            .foregroundStyle(CPSLTheme.secondaryText)
            .monospacedDigit()
        }
    }

    private var sliderUpperBound: Double {
        max(playback.duration, playback.currentTime, 1)
    }
}

@MainActor
private final class CPSLMediaPlaybackModel: ObservableObject {
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double
    @Published private(set) var isPlaying = false

    let player: AVPlayer

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?

    init(url: URL, duration: Double?) {
        self.duration = duration ?? 0
        self.player = AVPlayer(url: url)

        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            guard let playback = self else {
                return
            }
            Task { @MainActor in
                playback.updateCurrentTime(seconds)
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: player.currentItem,
            queue: .main
        ) { [weak self] _ in
            guard let playback = self else {
                return
            }
            Task { @MainActor in
                playback.finishPlayback()
            }
        }
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        player.pause()
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }

        if duration > 0 && currentTime >= duration - 0.25 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    func seek(to seconds: Double) {
        let upperBound = max(duration, seconds)
        let clampedSeconds = min(max(seconds, 0), upperBound)
        currentTime = clampedSeconds
        player.seek(
            to: CMTime(seconds: clampedSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func updateCurrentTime(_ seconds: Double) {
        if seconds.isFinite {
            currentTime = max(0, seconds)
        }
        isPlaying = player.rate != 0

        if duration <= 0,
            let itemDuration = player.currentItem?.duration,
            itemDuration.seconds.isFinite,
            itemDuration.seconds > 0
        {
            duration = itemDuration.seconds
        }
    }

    private func finishPlayback() {
        isPlaying = false
        currentTime = duration
    }
}
#endif

#if os(macOS) && canImport(PDFKit)
private struct CPSLPDFKitView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        configure(pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        configure(pdfView)
    }

    private func configure(_ pdfView: PDFView) {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = PDFDocument(url: url)
    }
}
#elseif canImport(UIKit) && canImport(PDFKit)
private struct CPSLPDFKitView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        configure(pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        configure(pdfView)
    }

    private func configure(_ pdfView: PDFView) {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.document = PDFDocument(url: url)
    }
}
#endif

private enum CPSLCodeHighlighter {
    static func highlight(_ text: String, language: CPSLCodeLanguage) -> AttributedString {
        var attributed = AttributedString(text)
        attributed.font = CPSLTheme.monospacedBodyFont
        attributed.foregroundColor = CPSLTheme.text

        if language == .html || language == .xml {
            apply(pattern: "</?[A-Za-z][^>]*>", color: CPSLTheme.mauve, in: text, to: &attributed)
        }

        var protectedRanges: [NSRange] = []
        let stringRanges = matches(
            for: #""(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*'|`(?:\\.|[^`\\])*`"#,
            in: text
        )
        apply(ranges: stringRanges, color: CPSLTheme.success, in: text, to: &attributed)
        protectedRanges.append(contentsOf: stringRanges)

        let commentRanges = commentPatterns(for: language).flatMap { pattern in
            matches(for: pattern, in: text, options: [.anchorsMatchLines])
                .filter { !intersects($0, protectedRanges) }
        }
        apply(ranges: commentRanges, color: CPSLTheme.mutedText, in: text, to: &attributed)
        protectedRanges.append(contentsOf: commentRanges)

        let numberRanges = matches(
            for: #"(?<![\w.])(?:0x[0-9A-Fa-f]+|\d+(?:\.\d+)?)(?![\w.])"#, in: text
        )
        .filter { !intersects($0, protectedRanges) }
        apply(ranges: numberRanges, color: CPSLTheme.mauve, in: text, to: &attributed)

        let keywordRanges = keywordMatches(for: language, in: text)
            .filter { !intersects($0, protectedRanges) }
        apply(ranges: keywordRanges, color: CPSLTheme.IconPalette.folder, in: text, to: &attributed)

        return attributed
    }

    private static func commentPatterns(for language: CPSLCodeLanguage) -> [String] {
        switch language {
        case .html, .xml, .markdown:
            return ["<!--[\\s\\S]*?-->"]
        case .lua:
            return ["--\\[\\[[\\s\\S]*?\\]\\]", "--.*"]
        case .python, .ruby, .shell, .yaml:
            return ["#.*"]
        case .json, .toml:
            return []
        default:
            return ["/\\*[\\s\\S]*?\\*/", "//.*"]
        }
    }

    private static func keywordMatches(for language: CPSLCodeLanguage, in text: String) -> [NSRange] {
        let keywords = language.keywords
        guard !keywords.isEmpty else {
            return []
        }
        let pattern =
            "\\b("
            + keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            + ")\\b"
        return matches(for: pattern, in: text)
    }

    private static func matches(
        for pattern: String,
        in text: String,
        options: NSRegularExpression.Options = []
    ) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return []
        }
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return regex.matches(in: text, range: fullRange).map(\.range)
    }

    private static func apply(
        pattern: String,
        color: Color,
        in text: String,
        to attributed: inout AttributedString
    ) {
        apply(ranges: matches(for: pattern, in: text), color: color, in: text, to: &attributed)
    }

    private static func apply(
        ranges: [NSRange],
        color: Color,
        in text: String,
        to attributed: inout AttributedString
    ) {
        for nsRange in ranges {
            guard let range = Range(nsRange, in: text),
                let lowerBound = AttributedString.Index(range.lowerBound, within: attributed),
                let upperBound = AttributedString.Index(range.upperBound, within: attributed)
            else {
                continue
            }
            attributed[lowerBound..<upperBound].foregroundColor = color
        }
    }

    private static func intersects(_ range: NSRange, _ otherRanges: [NSRange]) -> Bool {
        otherRanges.contains { NSIntersectionRange(range, $0).length > 0 }
    }
}
