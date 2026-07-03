import SwiftUI

struct CPSLMarkdownCodeBlockView: View {
    let language: String?
    let text: String
    let foreground: Color
    let fillsAvailableWidth: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
            if let language {
                Text(language)
                    .font(CPSLTheme.captionMediumFont)
                    .foregroundStyle(foreground.opacity(0.62))
            }

            Text(text)
                .font(CPSLTheme.monospacedBodyFont)
                .foregroundStyle(foreground)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: fillsAvailableWidth ? .infinity : nil, alignment: .leading)
        }
        .padding(CPSLTheme.small)
        .background(CPSLTheme.command)
        .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
    }
}

struct CPSLCommandBlockBody: View {
    let text: String
    let foreground: Color

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical, showsIndicators: contentHeight > CPSLTheme.commandBlockMaxHeight) {
            Text(text)
                .font(CPSLTheme.monospacedBodyFont)
                .foregroundStyle(foreground)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: CPSLCommandBlockHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .frame(height: contentHeight > 0 ? min(contentHeight, CPSLTheme.commandBlockMaxHeight) : nil)
        .scrollBounceBehavior(.basedOnSize)
        .onPreferenceChange(CPSLCommandBlockHeightKey.self) { height in
            contentHeight = height
        }
    }
}

private struct CPSLCommandBlockHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
