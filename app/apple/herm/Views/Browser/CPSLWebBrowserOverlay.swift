import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct CPSLWebBrowserOverlay: View {
    @ObservedObject private var model: CPSLChatModel
    @ObservedObject private var webBrowser: CPSLWebBrowserService
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(
        model: CPSLChatModel,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) {
        _model = ObservedObject(wrappedValue: model)
        _webBrowser = ObservedObject(wrappedValue: model.webBrowser)
        self.topInset = topInset
        self.bottomInset = bottomInset
    }

    var body: some View {
        CPSLFileOverlayStage(
            metrics: CPSLFileOverlayStageMetrics(
                topInset: topInset,
                bottomInset: bottomInset,
                dimOpacity: 0.001
            )
        ) {
            CPSLWebBrowserPanel(model: model, webBrowser: webBrowser)
        }
    }
}

private struct CPSLWebBrowserPanel: View {
    @ObservedObject var model: CPSLChatModel
    @ObservedObject var webBrowser: CPSLWebBrowserService

    var body: some View {
        CPSLFileOverlayPanel {
            CPSLWebBrowserHeader(model: model, webBrowser: webBrowser)
        } content: {
            CPSLWebBrowserContent(webBrowser: webBrowser)
        }
    }
}

private struct CPSLWebBrowserHeader: View {
    @ObservedObject var model: CPSLChatModel
    @ObservedObject var webBrowser: CPSLWebBrowserService

    private var summary: CPSLWebBrowserSummary? {
        webBrowser.visibleSummary
    }

    private var subtitle: String {
        guard let summary else {
            return "No active page"
        }
        if let url = summary.url, !url.isEmpty {
            return url
        }
        return summary.id
    }

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            Image(systemName: "globe")
                .symbolRenderingMode(.hierarchical)
                .font(CPSLTheme.iconMediumFont)
                .foregroundStyle(CPSLTheme.success)
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)

            VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
                Text(summary?.title?.nilIfEmpty ?? "Browser")
                    .font(CPSLTheme.supportingMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(1)
                Text(subtitle)
                    .font(CPSLTheme.captionFont)
                    .foregroundStyle(CPSLTheme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: CPSLTheme.medium)

            if let summary {
                CPSLWebBrowserModeBadge(mode: summary.resourceMode)
            }

            CPSLFileOverlayIconButton(systemName: "xmark", accessibilityLabel: "Close browser") {
                model.closeWebBrowser()
            }
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.vertical, CPSLTheme.small)
        .frame(minHeight: CPSLTheme.controlSize + CPSLTheme.medium)
    }
}

private struct CPSLWebBrowserModeBadge: View {
    let mode: CPSLWebBrowserResourceMode

    var body: some View {
        Text(mode.rawValue.uppercased())
            .font(CPSLTheme.captionMediumFont)
            .foregroundStyle(mode == .lean ? CPSLTheme.secondaryText : CPSLTheme.success)
            .padding(.horizontal, CPSLTheme.small)
            .frame(height: CPSLTheme.controlSize)
            .cpslGlassBackground(
                in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
                tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.32),
                strokeOpacity: 0.05
            )
    }
}

private struct CPSLWebBrowserContent: View {
    @ObservedObject var webBrowser: CPSLWebBrowserService

    var body: some View {
        VStack(spacing: 0) {
            if !webBrowser.summaries.isEmpty {
                CPSLWebBrowserTabStrip(
                    summaries: webBrowser.summaries,
                    visibleBrowserID: webBrowser.visibleBrowserID,
                    webBrowser: webBrowser
                )

                Rectangle()
                    .fill(CPSLTheme.text.opacity(0.07))
                    .frame(height: 1)
            }

            if let webView = webBrowser.visibleWebView {
                GeometryReader { proxy in
                    CPSLPlatformWebView(webView: webView)
                        .id(ObjectIdentifier(webView))
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .onAppear {
                            webBrowser.updateVisibleBrowserViewport(proxy.size)
                        }
                        .onChange(of: proxy.size) { _, newSize in
                            webBrowser.updateVisibleBrowserViewport(newSize)
                        }
                }
                .background(CPSLTheme.command)
            } else if webBrowser.summaries.isEmpty {
                CPSLWebBrowserEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CPSLTheme.command)
            } else {
                CPSLWebBrowserPicker(summaries: webBrowser.summaries, webBrowser: webBrowser)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(CPSLTheme.command)
            }
        }
    }
}

private struct CPSLWebBrowserTabStrip: View {
    let summaries: [CPSLWebBrowserSummary]
    let visibleBrowserID: String?
    @ObservedObject var webBrowser: CPSLWebBrowserService

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CPSLTheme.small) {
                ForEach(summaries) { summary in
                    CPSLWebBrowserTab(summary: summary, isSelected: summary.id == visibleBrowserID) {
                        Task {
                            await webBrowser.showBrowserFromUI(id: summary.id)
                        }
                    }
                }
            }
            .padding(.horizontal, CPSLTheme.medium)
            .padding(.vertical, CPSLTheme.small)
        }
        .frame(height: CPSLTheme.controlSize + CPSLTheme.medium)
        .background(CPSLTheme.command.opacity(0.72))
    }
}

private struct CPSLWebBrowserTab: View {
    let summary: CPSLWebBrowserSummary
    let isSelected: Bool
    let action: () -> Void

    private var title: String {
        summary.title?.nilIfEmpty ?? summary.url?.nilIfEmpty ?? summary.id
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: CPSLTheme.small) {
                Image(systemName: "globe")
                    .symbolRenderingMode(.hierarchical)
                    .font(CPSLTheme.iconSmallFont)
                    .foregroundStyle(isSelected ? CPSLTheme.success : CPSLTheme.secondaryText)
                Text(title)
                    .font(CPSLTheme.captionMediumFont)
                    .lineLimit(1)
            }
            .foregroundStyle(CPSLTheme.text)
            .padding(.horizontal, CPSLTheme.medium)
            .frame(height: CPSLTheme.controlSize)
            .frame(maxWidth: 220, alignment: .leading)
            .cpslGlassBackground(
                in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
                tint: CPSLGlassTuning.tint(
                    isSelected ? CPSLTheme.card : CPSLTheme.background,
                    opacity: isSelected ? 0.52 : 0.30
                ),
                strokeOpacity: isSelected ? 0.10 : 0.045
            )
            .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct CPSLWebBrowserPicker: View {
    let summaries: [CPSLWebBrowserSummary]
    @ObservedObject var webBrowser: CPSLWebBrowserService

    var body: some View {
        ScrollView {
            LazyVStack(spacing: CPSLTheme.small) {
                ForEach(summaries) { summary in
                    CPSLWebBrowserPickerRow(summary: summary) {
                        Task {
                            await webBrowser.showBrowserFromUI(id: summary.id)
                        }
                    }
                }
            }
            .padding(CPSLTheme.medium)
        }
    }
}

private struct CPSLWebBrowserPickerRow: View {
    let summary: CPSLWebBrowserSummary
    let action: () -> Void

    private var title: String {
        summary.title?.nilIfEmpty ?? summary.url?.nilIfEmpty ?? summary.id
    }

    private var subtitle: String {
        summary.url?.nilIfEmpty ?? summary.id
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: CPSLTheme.medium) {
                Image(systemName: "globe")
                    .symbolRenderingMode(.hierarchical)
                    .font(CPSLTheme.iconMediumFont)
                    .foregroundStyle(CPSLTheme.success)
                    .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)

                VStack(alignment: .leading, spacing: CPSLTheme.small / 2) {
                    Text(title)
                        .font(CPSLTheme.supportingMediumFont)
                        .foregroundStyle(CPSLTheme.text)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(CPSLTheme.captionFont)
                        .foregroundStyle(CPSLTheme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: CPSLTheme.medium)

                Image(systemName: "chevron.right")
                    .font(CPSLTheme.iconSmallFont)
                    .foregroundStyle(CPSLTheme.mutedText)
            }
            .padding(.horizontal, CPSLTheme.medium)
            .padding(.vertical, CPSLTheme.small)
            .frame(minHeight: CPSLTheme.controlSize + CPSLTheme.medium)
            .cpslGlassBackground(
                in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
                tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.28),
                strokeOpacity: 0.045
            )
            .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct CPSLWebBrowserEmptyState: View {
    var body: some View {
        VStack(spacing: CPSLTheme.medium) {
            Image(systemName: "globe")
                .font(CPSLTheme.emptyStateIconFont)
                .foregroundStyle(CPSLTheme.success.opacity(0.30))
            Text("No active page")
                .font(CPSLTheme.controlFont)
                .foregroundStyle(CPSLTheme.mutedText)
        }
        .padding(CPSLTheme.large)
    }
}

#if os(macOS)
private struct CPSLPlatformWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView {
        webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
#elseif canImport(UIKit)
private struct CPSLPlatformWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
#endif

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
