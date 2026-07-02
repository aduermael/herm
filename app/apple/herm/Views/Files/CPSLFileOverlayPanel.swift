import SwiftUI

struct CPSLFileOverlayStageMetrics {
    let topInset: CGFloat
    let bottomInset: CGFloat
    let dimOpacity: Double

    var horizontalInset: CGFloat {
        CPSLTheme.medium
    }

    var topPadding: CGFloat {
        topInset
    }

    var bottomPadding: CGFloat {
        bottomInset
    }

    func panelWidth(in size: CGSize) -> CGFloat {
        min(960, max(1, size.width - horizontalInset * 2))
    }

    func panelHeight(in size: CGSize) -> CGFloat {
        max(1, size.height - topPadding - bottomPadding)
    }
}

struct CPSLFileOverlayStage<Content: View>: View {
    let metrics: CPSLFileOverlayStageMetrics
    let content: Content

    init(
        metrics: CPSLFileOverlayStageMetrics,
        @ViewBuilder content: () -> Content
    ) {
        self.metrics = metrics
        self.content = content()
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(metrics.dimOpacity)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)

                content
                    .frame(
                        width: metrics.panelWidth(in: proxy.size),
                        height: metrics.panelHeight(in: proxy.size)
                    )
                    .padding(.horizontal, metrics.horizontalInset)
                    .padding(.top, metrics.topPadding)
                    .padding(.bottom, metrics.bottomPadding)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
    }
}

struct CPSLFileOverlayPanel<Header: View, Content: View>: View {
    let header: Header
    let content: Content

    init(
        @ViewBuilder header: () -> Header,
        @ViewBuilder content: () -> Content
    ) {
        self.header = header()
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.paneRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.command, opacity: 0.82),
            strokeOpacity: 0.07
        )
    }
}

struct CPSLFileOverlayIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(CPSLTheme.iconSmallFont)
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.text)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.rowRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.36),
            strokeOpacity: 0.06
        )
    }
}
