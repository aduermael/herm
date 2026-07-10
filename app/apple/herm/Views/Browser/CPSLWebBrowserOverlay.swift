import SwiftUI
import WebKit
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

private enum CPSLWebBrowserOverlayLayout {
    static let toolbarControlSize: CGFloat = 32
    static let toolbarHeight = toolbarControlSize + CPSLTheme.medium
    static let tabHeight: CGFloat = 26
    static let tabBottomMargin: CGFloat = 4
    static let tabStripHeight = tabHeight + tabBottomMargin
    static let tabMaxWidth: CGFloat = 172
}

struct CPSLWebBrowserOverlay: View {
    private let model: CPSLChatModel
    private let webBrowser: CPSLWebBrowserService
    let topInset: CGFloat
    let bottomInset: CGFloat

    init(
        model: CPSLChatModel,
        topInset: CGFloat,
        bottomInset: CGFloat
    ) {
        self.model = model
        webBrowser = model.webBrowser
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
        .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

private struct CPSLWebBrowserPanel: View {
    let model: CPSLChatModel
    let webBrowser: CPSLWebBrowserService

    var body: some View {
        CPSLFileOverlayPanel {
            CPSLWebBrowserToolbar(model: model, webBrowser: webBrowser)
        } content: {
            CPSLWebBrowserContent(webBrowser: webBrowser)
        }
    }
}

private struct CPSLWebBrowserToolbar: View {
    let model: CPSLChatModel
    @ObservedObject var webBrowser: CPSLWebBrowserService
    @State private var addressText = ""

    private var summary: CPSLWebBrowserSummary? {
        webBrowser.visibleSummary
    }

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            CPSLWebBrowserNavButton(
                systemName: "chevron.left",
                accessibilityLabel: "Back",
                isEnabled: summary?.canGoBack == true
            ) {
                webBrowser.goBackFromUI()
            }

            CPSLWebBrowserNavButton(
                systemName: "chevron.right",
                accessibilityLabel: "Forward",
                isEnabled: summary?.canGoForward == true
            ) {
                webBrowser.goForwardFromUI()
            }

            CPSLWebBrowserNavButton(
                systemName: "arrow.clockwise",
                accessibilityLabel: "Reload",
                isEnabled: summary != nil
            ) {
                webBrowser.reloadFromUI()
            }

            CPSLWebBrowserAddressField(
                text: $addressText,
                isLoading: summary?.isLoading == true
            ) {
                Task {
                    await webBrowser.navigateVisibleBrowserFromUI(to: addressText)
                }
            }
            .layoutPriority(1)

            CPSLWebBrowserNavButton(
                systemName: "xmark",
                accessibilityLabel: "Close browser",
                isEnabled: true
            ) {
                model.closeWebBrowser()
            }
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.vertical, CPSLTheme.small / 2)
        .frame(minHeight: CPSLWebBrowserOverlayLayout.toolbarHeight)
        .onAppear {
            addressText = summary?.url ?? ""
        }
        .onChange(of: summary?.id) { _, _ in
            addressText = summary?.url ?? ""
        }
        .onChange(of: summary?.url) { _, url in
            addressText = url ?? ""
        }
    }
}

private struct CPSLWebBrowserAddressField: View {
    @Binding var text: String
    let isLoading: Bool
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            Image(systemName: isLoading ? "globe.badge.chevron.backward" : "magnifyingglass")
                .symbolRenderingMode(.hierarchical)
                .font(CPSLTheme.iconSmallFont)
                .foregroundStyle(isLoading ? CPSLTheme.success : CPSLTheme.secondaryText)

            TextField("Search or enter website", text: $text)
                .textFieldStyle(.plain)
                .font(CPSLTheme.supportingFont)
                .foregroundStyle(CPSLTheme.text)
                .lineLimit(1)
                #if !os(macOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                #endif
                .submitLabel(.go)
                .onSubmit(onSubmit)
        }
        .padding(.horizontal, CPSLTheme.small)
        .frame(height: CPSLWebBrowserOverlayLayout.toolbarControlSize)
        .cpslSurfaceBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
            tint: CPSLTheme.background.opacity(0.34),
            strokeOpacity: 0.05
        )
    }
}

private struct CPSLWebBrowserNavButton: View {
    let systemName: String
    let accessibilityLabel: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(CPSLTheme.iconSmallFont)
                .frame(
                    width: CPSLWebBrowserOverlayLayout.toolbarControlSize,
                    height: CPSLWebBrowserOverlayLayout.toolbarControlSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .foregroundStyle(isEnabled ? CPSLTheme.text : CPSLTheme.mutedText)
        .opacity(isEnabled ? 1 : 0.45)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
        .cpslSurfaceBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
            tint: CPSLTheme.background.opacity(0.32),
            strokeOpacity: 0.045
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
                    CPSLScaledWebBrowserViewport(
                        webView: webView,
                        viewportSize: webBrowser.visibleBrowserWindowSize,
                        availableSize: proxy.size
                    )
                    .onAppear {
                        webBrowser.updateVisibleBrowserProjection(availableSize: proxy.size)
                    }
                    .onChange(of: proxy.size) { _, newSize in
                        webBrowser.updateVisibleBrowserProjection(availableSize: newSize)
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
    let webBrowser: CPSLWebBrowserService

    var body: some View {
        HStack(alignment: .top, spacing: CPSLTheme.small) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: CPSLTheme.small / 2) {
                    ForEach(summaries) { summary in
                        CPSLWebBrowserTab(
                            summary: summary,
                            isSelected: summary.id == visibleBrowserID
                        ) {
                            Task {
                                await webBrowser.showBrowserFromUI(id: summary.id)
                            }
                        } closeAction: {
                            webBrowser.closeBrowserFromUI(id: summary.id)
                        }
                    }
                }
                .padding(.leading, CPSLTheme.medium)
            }

            CPSLWebBrowserTabIconButton(
                systemName: "plus",
                accessibilityLabel: "New Tab"
            ) {
                Task {
                    await webBrowser.createBrowserFromUI()
                }
            }
        }
        .padding(.trailing, CPSLTheme.medium)
        .padding(.bottom, CPSLWebBrowserOverlayLayout.tabBottomMargin)
        .frame(height: CPSLWebBrowserOverlayLayout.tabStripHeight, alignment: .top)
        .background(CPSLTheme.command.opacity(0.72))
    }
}

private struct CPSLWebBrowserTab: View {
    let summary: CPSLWebBrowserSummary
    let isSelected: Bool
    let action: () -> Void
    let closeAction: () -> Void

    private var title: String {
        summary.title?.nilIfEmpty ?? summary.url?.nilIfEmpty ?? summary.id
    }

    private var shape: CPSLWebBrowserTabShape {
        CPSLWebBrowserTabShape(radius: CPSLTheme.rowRadius)
    }

    var body: some View {
        HStack(spacing: 2) {
            Button(action: action) {
                Text(title)
                    .font(CPSLTheme.captionMediumFont)
                    .foregroundStyle(CPSLTheme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .font(CPSLTheme.iconFont(size: 10, weight: .semibold))
                    .frame(width: CPSLWebBrowserOverlayLayout.tabHeight, height: CPSLWebBrowserOverlayLayout.tabHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(CPSLTheme.secondaryText)
            .accessibilityLabel("Close tab")
            .help("Close tab")
        }
        .padding(.leading, CPSLTheme.small)
        .frame(height: CPSLWebBrowserOverlayLayout.tabHeight)
        .frame(minWidth: 96, maxWidth: CPSLWebBrowserOverlayLayout.tabMaxWidth, alignment: .leading)
        .background {
            CPSLWebBrowserTabBackground(
                shape: shape,
                tint: (isSelected ? CPSLTheme.card : CPSLTheme.background)
                    .opacity(isSelected ? 0.52 : 0.30),
                strokeOpacity: isSelected ? 0.10 : 0.045
            )
        }
        .clipShape(shape)
        .contentShape(shape)
    }
}

private struct CPSLWebBrowserTabIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    private var shape: CPSLWebBrowserTabShape {
        CPSLWebBrowserTabShape(radius: CPSLTheme.rowRadius)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(CPSLTheme.iconSmallFont)
                .frame(
                    width: CPSLWebBrowserOverlayLayout.tabHeight,
                    height: CPSLWebBrowserOverlayLayout.tabHeight
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.text)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
        .background {
            CPSLWebBrowserTabBackground(
                shape: shape,
                tint: CPSLTheme.background.opacity(0.32),
                strokeOpacity: 0.045
            )
        }
        .clipShape(shape)
        .contentShape(shape)
    }
}

private struct CPSLWebBrowserTabBackground: View {
    let shape: CPSLWebBrowserTabShape
    let tint: Color
    let strokeOpacity: Double

    var body: some View {
        shape.fill(tint)
            .overlay {
                CPSLWebBrowserTabStrokeShape(radius: shape.radius)
                    .stroke(CPSLTheme.text.opacity(strokeOpacity), lineWidth: 1)
            }
    }
}

private struct CPSLWebBrowserTabStrokeShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.maxY),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.maxY - radius),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return path
    }
}

private struct CPSLWebBrowserTabShape: Shape {
    let radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.closeSubpath()
        return path
    }
}

private struct CPSLScaledWebBrowserViewport: View {
    let webView: WKWebView
    let viewportSize: CGSize
    let availableSize: CGSize

    private var scale: CGFloat {
        guard viewportSize.width > 0,
              viewportSize.height > 0,
              availableSize.width > 0,
              availableSize.height > 0
        else {
            return 1
        }
        return availableSize.width / viewportSize.width
    }

    var body: some View {
        CPSLPlatformWebView(webView: webView)
            .id(ObjectIdentifier(webView))
            .frame(width: viewportSize.width, height: viewportSize.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(
                width: viewportSize.width * scale,
                height: viewportSize.height * scale,
                alignment: .topLeading
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
    }
}

private struct CPSLWebBrowserPicker: View {
    let summaries: [CPSLWebBrowserSummary]
    let webBrowser: CPSLWebBrowserService

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
        .scrollBounceBehavior(.basedOnSize)
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
            .cpslSurfaceBackground(
                in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
                tint: CPSLTheme.background.opacity(0.28),
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
