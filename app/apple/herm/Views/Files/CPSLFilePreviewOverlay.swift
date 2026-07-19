import Foundation
import CoreGraphics
import ImageIO
import Observation
import SwiftUI

#if canImport(AVFoundation)
@preconcurrency import AVFoundation
#endif
#if canImport(AVKit)
@preconcurrency import AVKit
#endif
#if canImport(PDFKit)
@preconcurrency import PDFKit
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
        if text.utf8.count <= 32_768 {
            Text(CPSLCodeHighlighter.highlight(text, language: language))
        } else {
            Text(text)
                .font(CPSLTheme.monospacedBodyFont)
                .foregroundStyle(CPSLTheme.text)
        }
    }
}

private struct CPSLPDFFilePreview: View {
    let url: URL

    var body: some View {
        #if (os(macOS) || canImport(UIKit)) && canImport(PDFKit)
            CPSLPDFKitView(url: url)
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
            CPSLPDFPreviewUnavailable(message: "PDF preview is not available on this platform.")
        #endif
    }
}

private struct CPSLPDFPreviewUnavailable: View {
    let message: String

    var body: some View {
        VStack(spacing: CPSLTheme.small) {
            Image(systemName: "doc.richtext")
                .font(CPSLTheme.iconLargeFont)
                .foregroundStyle(CPSLTheme.secondaryText)
            Text(message)
                .font(CPSLTheme.supportingFont)
                .foregroundStyle(CPSLTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#if canImport(PDFKit)
private nonisolated struct CPSLSendablePDFDocument: @unchecked Sendable {
    let value: PDFDocument?
}

@MainActor
private final class CPSLPDFKitCoordinator {
    private var representedURL: URL?
    private var loadTask: Task<Void, Never>?

    func load(url: URL, into pdfView: PDFView) {
        guard representedURL != url else {
            return
        }
        representedURL = url
        loadTask?.cancel()
        pdfView.document = nil
        loadTask = Task { @MainActor [weak self, weak pdfView] in
            let document = await Task.detached(priority: .userInitiated) {
                CPSLSendablePDFDocument(value: PDFDocument(url: url))
            }.value
            guard !Task.isCancelled,
                  self?.representedURL == url,
                  let pdfView
            else {
                return
            }
            pdfView.document = document.value
            pdfView.autoScales = true
        }
    }

    func cancel() {
        loadTask?.cancel()
        loadTask = nil
        representedURL = nil
    }
}

@MainActor
private enum CPSLPDFKitConfiguration {
    static func makeView() -> PDFView {
        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayBox = .cropBox
        pdfView.displayDirection = .vertical
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        return pdfView
    }
}

#if os(macOS)
private struct CPSLPDFKitView: NSViewRepresentable, Equatable {
    let url: URL

    func makeCoordinator() -> CPSLPDFKitCoordinator {
        CPSLPDFKitCoordinator()
    }

    func makeNSView(context: Context) -> PDFView {
        let pdfView = CPSLPDFKitConfiguration.makeView()
        context.coordinator.load(url: url, into: pdfView)
        return pdfView
    }

    func updateNSView(_ pdfView: PDFView, context: Context) {
        context.coordinator.load(url: url, into: pdfView)
    }

    static func dismantleNSView(_ pdfView: PDFView, coordinator: CPSLPDFKitCoordinator) {
        coordinator.cancel()
        pdfView.document = nil
    }
}
#elseif canImport(UIKit)
private struct CPSLPDFKitView: UIViewRepresentable, Equatable {
    let url: URL

    func makeCoordinator() -> CPSLPDFKitCoordinator {
        CPSLPDFKitCoordinator()
    }

    func makeUIView(context: Context) -> PDFView {
        let pdfView = CPSLPDFKitConfiguration.makeView()
        context.coordinator.load(url: url, into: pdfView)
        return pdfView
    }

    func updateUIView(_ pdfView: PDFView, context: Context) {
        context.coordinator.load(url: url, into: pdfView)
    }

    static func dismantleUIView(_ pdfView: PDFView, coordinator: CPSLPDFKitCoordinator) {
        coordinator.cancel()
        pdfView.document = nil
    }
}
#endif
#endif

private nonisolated struct CPSLSendableCGImage: @unchecked Sendable {
    let value: CGImage
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

private enum CPSLPlatformImageLoader {
    static func image(for url: URL) async -> CPSLSendableCGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_400,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            ) else {
                return nil
            }
            return CPSLSendableCGImage(value: image)
        }.value
    }
}

private struct CPSLPlatformImageFilePreview: View {
    let url: URL
    let preview: CPSLFilePreview
    @Environment(\.displayScale) private var displayScale
    @State private var image: CGImage?
    @State private var didAttemptLoad = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: displayScale, orientation: .up)
                    .resizable()
                    .scaledToFit()
                    .padding(CPSLTheme.large)
            } else if didAttemptLoad {
                CPSLImageLoadFailurePreview(preview: preview)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            image = nil
            didAttemptLoad = false
            image = await CPSLPlatformImageLoader.image(for: url)?.value
            didAttemptLoad = true
        }
    }
}

private struct CPSLImageLoadFailurePreview: View {
    let preview: CPSLFilePreview

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: CPSLTheme.large) {
                CPSLFilePreviewHero(
                    name: preview.name,
                    category: preview.metadata.category,
                    reason: "This image could not be loaded."
                )
                CPSLFileMetadataList(metadata: preview.metadata)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(CPSLTheme.large)
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

#if canImport(AVFoundation) && canImport(AVKit)
private struct CPSLAudioPlayerPreview: View {
    let preview: CPSLFilePreview
    @State private var playback: CPSLMediaPlaybackModel

    init(url: URL, preview: CPSLFilePreview) {
        self.preview = preview
        _playback = State(
            initialValue: CPSLMediaPlaybackModel(
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
    @State private var playback: CPSLMediaPlaybackModel

    init(url: URL, preview: CPSLFilePreview) {
        self.preview = preview
        _playback = State(
            initialValue: CPSLMediaPlaybackModel(
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
    let playback: CPSLMediaPlaybackModel

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
@Observable
private final class CPSLMediaPlaybackModel {
    private(set) var currentTime: Double = 0
    private(set) var duration: Double
    private(set) var isPlaying = false

    let player: AVPlayer

    @ObservationIgnored
    private var timeObserver: Any?
    @ObservationIgnored
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
