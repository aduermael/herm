import SwiftUI

struct CPSLAttachmentBadge: View {
    private static let maximumDisplayNameLength = 24
    private static let trailingDisplayNameLength = 8

    let name: String
    let onRemove: (() -> Void)?

    init(name: String, onRemove: (() -> Void)? = nil) {
        self.name = name
        self.onRemove = onRemove
    }

    private var displayName: String {
        guard name.count > Self.maximumDisplayNameLength else {
            return name
        }
        let leadingCount = Self.maximumDisplayNameLength - Self.trailingDisplayNameLength - 1
        return "\(name.prefix(leadingCount))…\(name.suffix(Self.trailingDisplayNameLength))"
    }

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            Image(systemName: "paperclip")
                .foregroundStyle(CPSLTheme.mauve)

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
                .accessibilityLabel("Remove \(name)")
            }
        }
        .padding(.horizontal, CPSLTheme.small)
        .frame(height: CPSLTheme.controlSize)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.card, opacity: 0.38),
            strokeOpacity: 0.045
        )
    }
}
