import Foundation
import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct CPSLAttachmentBadge: View {
    private static let maximumDisplayNameLength = 24
    private static let trailingDisplayNameLength = 8

    let attachment: CPSLAttachment
    let onRemove: (() -> Void)?
    let loadThumbnail: ((CPSLAttachment) async -> Data?)?
    @State private var thumbnailData: Data?

    init(
        attachment: CPSLAttachment,
        onRemove: (() -> Void)? = nil,
        loadThumbnail: ((CPSLAttachment) async -> Data?)? = nil
    ) {
        self.attachment = attachment
        self.onRemove = onRemove
        self.loadThumbnail = loadThumbnail
    }

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            CPSLAttachmentVisual(name: attachment.name, thumbnailData: thumbnailData)

            Text(displayName)
                .font(CPSLTheme.captionFont)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: CPSLTheme.controlSize * 4, alignment: .leading)

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(CPSLTheme.mutedText)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.name)")
            }
        }
        .padding(.horizontal, CPSLTheme.small)
        .frame(height: CPSLTheme.controlSize)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.card, opacity: 0.38),
            strokeOpacity: 0.045
        )
        .task(id: attachment.id) {
            guard previewCategory == .image, let loadThumbnail else {
                thumbnailData = nil
                return
            }
            thumbnailData = await loadThumbnail(attachment)
        }
    }

    private var displayName: String {
        let name = attachment.name
        guard name.count > Self.maximumDisplayNameLength else {
            return name
        }
        let leadingCount = Self.maximumDisplayNameLength - Self.trailingDisplayNameLength - 1
        return "\(name.prefix(leadingCount))…\(name.suffix(Self.trailingDisplayNameLength))"
    }

    private var previewCategory: CPSLFilePreviewCategory {
        let fileExtension = URL(fileURLWithPath: attachment.name).pathExtension.lowercased()
        return CPSLFilePreviewCategory(
            fileName: attachment.name,
            fileExtension: fileExtension
        )
    }
}

private struct CPSLAttachmentVisual: View {
    let name: String
    let thumbnailData: Data?

    var body: some View {
        ZStack {
            if let image = platformImage {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: fallbackSystemImageName)
                    .symbolRenderingMode(.hierarchical)
                    .font(CPSLTheme.iconMediumFont)
                    .foregroundStyle(CPSLTheme.mauve)
            }
        }
        .frame(width: 28, height: 28)
        .background(CPSLTheme.elevated)
        .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.small, style: .continuous))
        .accessibilityHidden(true)
    }

    private var platformImage: Image? {
        guard let thumbnailData else {
            return nil
        }
#if canImport(UIKit)
        guard let image = UIImage(data: thumbnailData) else {
            return nil
        }
        return Image(uiImage: image)
#elseif canImport(AppKit)
        guard let image = NSImage(data: thumbnailData) else {
            return nil
        }
        return Image(nsImage: image)
#else
        return nil
#endif
    }

    private var fallbackSystemImageName: String {
        switch fileExtension {
        case "doc", "docx", "odt", "pages", "rtf":
            return "doc.text.fill"
        case "key", "odp", "ppt", "pptx":
            return "rectangle.on.rectangle.angled"
        case "csv", "numbers", "ods", "xls", "xlsx":
            return "tablecells.fill"
        default:
            return previewCategory.systemImageName
        }
    }

    private var fileExtension: String {
        URL(fileURLWithPath: name).pathExtension.lowercased()
    }

    private var previewCategory: CPSLFilePreviewCategory {
        CPSLFilePreviewCategory(fileName: name, fileExtension: fileExtension)
    }
}
