import SwiftUI

struct CPSLChatScreen: View {
    @StateObject private var model = CPSLChatModel()
    @State private var promptDismissRequest = 0

    private var contentBottomInset: CGFloat {
        CPSLTheme.medium
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
            .ignoresSafeArea(.container, edges: .top)
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
    }
}

private struct CPSLHeaderView: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            CPSLHeaderIconButton(systemName: "line.3.horizontal", accessibilityLabel: "Menu") {
                model.showComingSoon("coming soon")
            }

            Spacer()

            CPSLHeaderIconButton(systemName: "square.and.pencil", accessibilityLabel: "New conversation") {
                model.startNewConversation()
            }
            .disabled(model.isRunning)
            .opacity(model.isRunning ? 0.45 : 1)
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.top, CPSLTheme.medium)
        .padding(.bottom, CPSLTheme.medium)
    }
}

private struct CPSLHeaderIconButton: View {
    let systemName: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconMedium, weight: .semibold))
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                .cpslGlassBackground(
                    in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
                    tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.34),
                    strokeOpacity: 0.045
                )
                .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.text)
        .accessibilityLabel(accessibilityLabel)
        .help(accessibilityLabel)
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
