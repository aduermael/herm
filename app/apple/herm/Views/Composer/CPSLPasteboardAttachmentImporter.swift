import Foundation
import UniformTypeIdentifiers

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

enum CPSLPasteboardAttachmentImporter {
    static func canImportCurrent() -> Bool {
#if os(macOS)
        let pasteboard = NSPasteboard.general
        if pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) {
            return true
        }
        if NSImage(pasteboard: pasteboard) != nil {
            return true
        }
        guard let html = pasteboard.string(forType: .html) else {
            return false
        }
        return imageSource(from: html) != nil
#elseif canImport(UIKit)
        let pasteboard = UIPasteboard.general
        return pasteboard.urls?.contains(where: \.isFileURL) == true ||
            pasteboard.hasImages
#else
        return false
#endif
    }

    @discardableResult
    static func importCurrent(into model: CPSLChatModel) -> Bool {
#if os(macOS)
        let pasteboard = NSPasteboard.general
        let fileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        if !fileURLs.isEmpty {
            fileURLs.forEach(model.addAttachment)
            return true
        }
        if let image = NSImage(pasteboard: pasteboard),
           let data = pngData(from: image) {
            model.addAttachment(data: data, preferredName: pastedImageFileName())
            return true
        }
        guard let html = pasteboard.string(forType: .html),
              let source = imageSource(from: html)
        else {
            return false
        }
        importImage(from: source, into: model)
        return true
#elseif canImport(UIKit)
        let pasteboard = UIPasteboard.general
        let fileURLs = pasteboard.urls?.filter(\.isFileURL) ?? []
        if !fileURLs.isEmpty {
            fileURLs.forEach(model.addAttachment)
            return true
        }
        guard let images = pasteboard.images, !images.isEmpty else {
            return false
        }
        for image in images {
            if let data = image.pngData() {
                model.addAttachment(data: data, preferredName: pastedImageFileName())
            }
        }
        return true
#else
        return false
#endif
    }

    static func pasteboardString() -> String? {
#if os(macOS)
        NSPasteboard.general.string(forType: .string)
#elseif canImport(UIKit)
        UIPasteboard.general.string
#else
        nil
#endif
    }

#if os(macOS)
    private enum ImageSource {
        case data(Data, fileExtension: String)
        case url(URL)
    }

    private static func importImage(from source: ImageSource, into model: CPSLChatModel) {
        switch source {
        case .data(let data, let fileExtension):
            model.addAttachment(
                data: data,
                preferredName: pastedImageFileName(fileExtension: fileExtension)
            )
        case .url(let url) where url.isFileURL:
            model.addAttachment(from: url)
        case .url(let url):
            Task {
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    if let httpResponse = response as? HTTPURLResponse,
                       !(200...299).contains(httpResponse.statusCode) {
                        throw URLError(.badServerResponse)
                    }
                    guard NSImage(data: data) != nil else {
                        throw URLError(.cannotDecodeContentData)
                    }
                    model.addAttachment(
                        data: data,
                        preferredName: pastedImageFileName(
                            fileExtension: imageFileExtension(for: response, sourceURL: url)
                        )
                    )
                } catch {
                    model.showComingSoon("Could not paste the copied image: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func imageSource(from html: String) -> ImageSource? {
        let pattern = #"<img\b[^>]*\bsrc\s*=\s*(?:\"([^\"]+)\"|'([^']+)'|([^\s>]+))"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else {
            return nil
        }
        let searchRange = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = expression.firstMatch(in: html, range: searchRange) else {
            return nil
        }

        let htmlString = html as NSString
        let rawSource = (1..<match.numberOfRanges)
            .map { match.range(at: $0) }
            .first { $0.location != NSNotFound }
            .map { htmlString.substring(with: $0) }
        guard let rawSource,
              let decodedSource = decodeHTMLEntities(rawSource)
        else {
            return nil
        }

        if decodedSource.lowercased().hasPrefix("data:image/") {
            return dataImageSource(from: decodedSource)
        }
        guard let url = URL(string: decodedSource),
              url.isFileURL || url.scheme == "https" || url.scheme == "http"
        else {
            return nil
        }
        return .url(url)
    }

    private static func dataImageSource(from source: String) -> ImageSource? {
        let components = source.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard components.count == 2,
              components[0].lowercased().hasSuffix(";base64"),
              let data = Data(base64Encoded: String(components[1]), options: .ignoreUnknownCharacters)
        else {
            return nil
        }
        let mimeType = components[0]
            .dropFirst("data:".count)
            .split(separator: ";", maxSplits: 1)
            .first
            .map(String.init)
        let fileExtension = mimeType
            .flatMap { UTType(mimeType: $0) }?
            .preferredFilenameExtension ?? "png"
        return .data(data, fileExtension: fileExtension)
    }

    private static func decodeHTMLEntities(_ string: String) -> String? {
        guard let data = string.data(using: .utf8),
              let decoded = try? NSAttributedString(
                  data: data,
                  options: [
                      .documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue,
                  ],
                  documentAttributes: nil
              )
        else {
            return nil
        }
        return decoded.string
    }

    private static func imageFileExtension(for response: URLResponse, sourceURL: URL) -> String {
        if let mimeType = response.mimeType,
           let fileExtension = UTType(mimeType: mimeType)?.preferredFilenameExtension {
            return fileExtension
        }
        if let imageType = UTType(filenameExtension: sourceURL.pathExtension),
           imageType.conforms(to: .image),
           let fileExtension = imageType.preferredFilenameExtension {
            return fileExtension
        }
        return "png"
    }

    private static func pngData(from image: NSImage) -> Data? {
        guard let tiffData = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return representation.representation(using: .png, properties: [:])
    }
#endif

    private static func pastedImageFileName(fileExtension: String = "png") -> String {
        "pasted-image-\(UUID().uuidString.prefix(8)).\(fileExtension)"
    }
}
