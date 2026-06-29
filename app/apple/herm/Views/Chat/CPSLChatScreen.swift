import SwiftUI

struct CPSLChatScreen: View {
    @StateObject private var model = CPSLChatModel()
    @State private var promptDismissRequest = 0
    @State private var bottomChromeHeight = CPSLTheme.bottomChromeInset

    private var contentBottomInset: CGFloat {
        bottomChromeHeight + CPSLTheme.medium
    }

    var body: some View {
        ZStack {
            CPSLTheme.background.ignoresSafeArea()

            Group {
                if model.isFileBrowserOpen {
                    CPSLFileBrowserView(
                        model: model,
                        topInset: CPSLTheme.topChromeInset,
                        bottomInset: contentBottomInset
                    )
                } else {
                    CPSLChatTimelineView(
                        model: model,
                        topInset: CPSLTheme.topChromeInset,
                        bottomInset: contentBottomInset
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: [.top, .bottom])
            .contentShape(Rectangle())
            .onTapGesture {
                promptDismissRequest += 1
            }

            CPSLScrollEdgeGlass(edge: .top, height: CPSLTheme.topBlendHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)

            CPSLScrollEdgeGlass(edge: .bottom, height: CPSLTheme.bottomBlendHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                CPSLHeaderView(model: model)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        promptDismissRequest += 1
                    }

                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            bottomChrome
        }
        .onPreferenceChange(CPSLBottomChromeHeightKey.self) { height in
            guard height > 0, abs(height - bottomChromeHeight) > 0.5 else {
                return
            }
            bottomChromeHeight = height
        }
        .alert(
            "Coming soon",
            isPresented: Binding(
                get: { model.comingSoonMessage != nil },
                set: { isPresented in
                    if !isPresented {
                        model.comingSoonMessage = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.comingSoonMessage ?? "Coming soon")
        }
    }

    private var bottomChrome: some View {
        VStack(spacing: 0) {
            CPSLToolStripView(model: model)
                .contentShape(Rectangle())
                .onTapGesture {
                    promptDismissRequest += 1
                }

            CPSLPromptComposerView(
                model: model,
                dismissKeyboardRequest: promptDismissRequest
            ) {
                promptDismissRequest += 1
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear.preference(
                    key: CPSLBottomChromeHeightKey.self,
                    value: proxy.size.height
                )
            }
        }
    }
}

private struct CPSLBottomChromeHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct CPSLHeaderView: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            HStack(spacing: CPSLTheme.small) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(CPSLTheme.mauve)
                Text("Herm")
                    .font(CPSLTheme.headerFont)
            }
            .foregroundStyle(CPSLTheme.text)

            Spacer()

            Button {
                model.startNewConversation()
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                    .cpslGlassBackground(
                        in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
                        tint: CPSLTheme.background.opacity(0.34),
                        strokeOpacity: 0.045
                    )
                    .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(CPSLTheme.text)
            .disabled(model.isRunning)
            .opacity(model.isRunning ? 0.45 : 1)
            .accessibilityLabel("New conversation")
            .help("New conversation")
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.top, CPSLTheme.medium)
        .padding(.bottom, CPSLTheme.medium)
    }
}

private struct CPSLScrollEdgeGlass: View {
    let edge: VerticalEdge
    let height: CGFloat

    var body: some View {
        ZStack {
            backgroundFade
        }
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .ignoresSafeArea(.container, edges: safeAreaEdge)
    }

    private var backgroundFade: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: CPSLTheme.background, location: 0),
                .init(color: CPSLTheme.background, location: 0.05),
                .init(color: CPSLTheme.background.opacity(0), location: 1)
            ],
            startPoint: edge == .top ? .top : .bottom,
            endPoint: edge == .top ? .bottom : .top
        )
    }

    private var safeAreaEdge: Edge.Set {
        switch edge {
        case .top:
            return .top
        case .bottom:
            return .bottom
        }
    }
}
