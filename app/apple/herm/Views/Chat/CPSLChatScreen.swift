import SwiftUI

private enum CPSLDrawerMotion {
    static let duration = 0.2
    static let animation = Animation.easeOut(duration: duration)
}

struct CPSLChatScreen: View {
    @StateObject private var model = CPSLChatModel()
    @State private var promptDismissRequest = 0
    @State private var drawerProgress: CGFloat = 0

    private var contentBottomInset: CGFloat {
        CPSLTheme.medium
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CPSLTheme.background.ignoresSafeArea()

                CPSLConversationDrawerView(
                    model: model,
                    topInset: drawerTopInset(topSafeAreaInset: proxy.safeAreaInsets.top),
                    bottomInset: CPSLTheme.medium
                )
                .ignoresSafeArea(.container, edges: .vertical)
                .allowsHitTesting(model.isDrawerOpen)
                .offset(x: drawerOffset(width: proxy.size.width))

                CPSLMainContentStage(
                    model: model,
                    promptDismissRequest: $promptDismissRequest,
                    contentTopInset: contentTopInset(topSafeAreaInset: proxy.safeAreaInsets.top),
                    contentBottomInset: contentBottomInset
                )
                .offset(x: mainContentOffset(width: proxy.size.width))
                .allowsHitTesting(!model.isDrawerOpen)
                .zIndex(1)

                CPSLDrawerToggleButton(isOpen: model.isDrawerOpen) {
                    model.toggleDrawer()
                }
                .padding(.leading, CPSLTheme.medium)
                .padding(.top, CPSLTheme.medium)
                .offset(x: drawerToggleOffset(width: proxy.size.width))
                .zIndex(2)
            }
            .onAppear {
                drawerProgress = drawerTargetProgress
            }
            .onChange(of: model.isDrawerOpen) { _, _ in
                withAnimation(CPSLDrawerMotion.animation) {
                    drawerProgress = drawerTargetProgress
                }
            }
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

    private func drawerOffset(width: CGFloat) -> CGFloat {
        -CPSLConversationDrawerLayout.width(in: width) * (1 - drawerProgress)
    }

    private func mainContentOffset(width: CGFloat) -> CGFloat {
        width * drawerProgress
    }

    private func drawerToggleOffset(width: CGFloat) -> CGFloat {
        max(0, width - CPSLTheme.controlSize - CPSLTheme.medium * 2) * drawerProgress
    }

    private var drawerTargetProgress: CGFloat {
        model.isDrawerOpen ? 1 : 0
    }

    private func drawerTopInset(topSafeAreaInset: CGFloat) -> CGFloat {
        topSafeAreaInset + CPSLTheme.medium
    }

    private func contentTopInset(topSafeAreaInset: CGFloat) -> CGFloat {
        topSafeAreaInset + CPSLTheme.topChromeInset
    }
}

private struct CPSLMainContentStage: View {
    @ObservedObject var model: CPSLChatModel
    @Binding var promptDismissRequest: Int
    let contentTopInset: CGFloat
    let contentBottomInset: CGFloat

    var body: some View {
        ZStack {
            CPSLPrimaryContentView(
                model: model,
                promptDismissRequest: $promptDismissRequest,
                contentTopInset: contentTopInset,
                contentBottomInset: contentBottomInset
            )

            // TOP & BOTTOM GRADIENTS FOR NICE CONTENT FADE OUT
            CPSLScrollEdgeGlass(edge: .top, height: CPSLTheme.topBlendHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .ignoresSafeArea(.container, edges: .top)
                .allowsHitTesting(false)

            CPSLScrollEdgeGlass(edge: .bottom, height: CPSLTheme.bottomBlendHeight)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .ignoresSafeArea(.container, edges: .bottom)
                .allowsHitTesting(false)

            // TOP RIGHT ACTION BUTTONS
            CPSLHeaderActionsView(model: model)
                .contentShape(Rectangle())
                .onTapGesture {
                    promptDismissRequest += 1
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CPSLTheme.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // PROMPTING AREA + BUTTONS ON TOP
            CPSLBottomChromeView(
                model: model,
                promptDismissRequest: $promptDismissRequest
            )
        }
    }
}

private struct CPSLPrimaryContentView: View {
    @ObservedObject var model: CPSLChatModel
    @Binding var promptDismissRequest: Int
    let contentTopInset: CGFloat
    let contentBottomInset: CGFloat

    var body: some View {
        Group {
            if model.isFileBrowserOpen {
                CPSLFileBrowserView(
                    model: model,
                    topInset: contentTopInset,
                    bottomInset: contentBottomInset
                )
            } else {
                CPSLChatTimelineView(
                    model: model,
                    topInset: contentTopInset,
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
    }
}

private struct CPSLBottomChromeView: View {
    @ObservedObject var model: CPSLChatModel
    @Binding var promptDismissRequest: Int

    var body: some View {
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
        .frame(maxWidth: .infinity)
    }
}

private struct CPSLHeaderActionsView: View {
    @ObservedObject var model: CPSLChatModel

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            Spacer()

#if DEBUG
            CPSLChromeIconButton(systemName: "doc.on.doc", accessibilityLabel: "Copy conversation JSON") {
                model.copyConversationJSONToPasteboard()
            }
#endif

            CPSLChromeIconButton(systemName: "square.and.pencil", accessibilityLabel: "New conversation") {
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

private struct CPSLDrawerToggleButton: View {
    let isOpen: Bool
    let action: () -> Void
    @State private var displayedSystemName = "line.3.horizontal"
    @State private var iconOpacity = 1.0

    private var targetSystemName: String {
        isOpen ? "chevron.left" : "line.3.horizontal"
    }

    private var accessibilityLabel: String {
        isOpen ? "Back to chat" : "Menu"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: displayedSystemName)
                .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconMedium, weight: .semibold))
                .opacity(iconOpacity)
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
        .onAppear {
            displayedSystemName = targetSystemName
            iconOpacity = 1
        }
        .task(id: targetSystemName) {
            await transitionIconIfNeeded(to: targetSystemName)
        }
    }

    @MainActor
    private func transitionIconIfNeeded(to systemName: String) async {
        guard displayedSystemName != systemName else {
            return
        }

        withAnimation(.easeOut(duration: CPSLDrawerMotion.duration * 0.32)) {
            iconOpacity = 0
        }
        try? await Task.sleep(nanoseconds: UInt64(CPSLDrawerMotion.duration * 500_000_000))
        guard !Task.isCancelled else {
            return
        }
        displayedSystemName = systemName
        withAnimation(.easeIn(duration: CPSLDrawerMotion.duration * 0.32)) {
            iconOpacity = 1
        }
    }
}

private struct CPSLChromeIconButton: View {
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
