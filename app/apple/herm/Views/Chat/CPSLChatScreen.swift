import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif
#if canImport(WebKit)
import WebKit
#endif

enum CPSLTransientInteractionReset {
#if canImport(UIKit)
    private final class WeakTextView {
        weak var value: UITextView?

        init(_ value: UITextView) {
            self.value = value
        }
    }

    private static var selectableTextViews: [WeakTextView] = []
#elseif os(macOS)
    private final class WeakTextView {
        weak var value: NSTextView?

        init(_ value: NSTextView) {
            self.value = value
        }
    }

    private static var selectableTextViews: [WeakTextView] = []
#endif

#if canImport(UIKit)
    static func registerSelectableTextView(_ textView: UITextView) {
        selectableTextViews.removeAll { $0.value == nil || $0.value === textView }
        selectableTextViews.append(WeakTextView(textView))
    }

    static func unregisterSelectableTextView(_ textView: UITextView) {
        selectableTextViews.removeAll { $0.value == nil || $0.value === textView }
    }

    static func isRegisteredSelectableTextView(_ textView: UITextView) -> Bool {
        selectableTextViews.contains { $0.value === textView }
    }
#elseif os(macOS)
    static func registerSelectableTextView(_ textView: NSTextView) {
        selectableTextViews.removeAll { $0.value == nil || $0.value === textView }
        selectableTextViews.append(WeakTextView(textView))
    }

    static func unregisterSelectableTextView(_ textView: NSTextView) {
        selectableTextViews.removeAll { $0.value == nil || $0.value === textView }
    }

    static func isRegisteredSelectableTextView(_ textView: NSTextView) -> Bool {
        selectableTextViews.contains { $0.value === textView }
    }
#endif

    static func reset() {
#if canImport(UIKit)
        selectableTextViews.removeAll { box in
            guard let textView = box.value else {
                return true
            }
            textView.selectedRange = NSRange(location: 0, length: 0)
            if textView.isFirstResponder {
                textView.resignFirstResponder()
            }
            return false
        }

        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { $0.endEditing(true) }
#elseif os(macOS)
        selectableTextViews.removeAll { box in
            guard let textView = box.value else {
                return true
            }
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            if textView.window?.firstResponder === textView {
                textView.window?.makeFirstResponder(nil)
            }
            return false
        }
        NSApp.keyWindow?.makeFirstResponder(nil)
#endif
    }
}

private struct CPSLTransientInteractionResetModifier: ViewModifier {
    let onReset: () -> Void

    func body(content: Content) -> some View {
        content
            .background {
                CPSLTransientInteractionResetObserver(onReset: onReset)
                    .frame(width: 0, height: 0)
            }
    }
}

extension View {
    func cpslResetTransientsOnBackgroundTap(
        onReset: @escaping () -> Void
    ) -> some View {
        modifier(CPSLTransientInteractionResetModifier(onReset: onReset))
    }
}

#if canImport(UIKit)
private struct CPSLTransientInteractionResetObserver: UIViewRepresentable {
    let onReset: () -> Void

    func makeUIView(context: Context) -> CPSLTransientInteractionResetUIView {
        let view = CPSLTransientInteractionResetUIView()
        view.isUserInteractionEnabled = false
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            if let window {
                coordinator?.install(in: window)
            } else {
                coordinator?.uninstall()
            }
        }
        return view
    }

    func updateUIView(_ view: CPSLTransientInteractionResetUIView, context: Context) {
        context.coordinator.onReset = onReset
        if let window = view.window {
            context.coordinator.install(in: window)
        }
    }

    static func dismantleUIView(
        _ view: CPSLTransientInteractionResetUIView,
        coordinator: Coordinator
    ) {
        coordinator.uninstall()
        view.onWindowChange = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReset: onReset)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onReset: () -> Void
        private weak var installedWindow: UIWindow?
        private var recognizer: UITapGestureRecognizer?

        init(onReset: @escaping () -> Void) {
            self.onReset = onReset
        }

        func install(in window: UIWindow) {
            guard installedWindow !== window else {
                return
            }
            uninstall()
            let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleTap))
            recognizer.cancelsTouchesInView = false
            recognizer.delegate = self
            window.addGestureRecognizer(recognizer)
            installedWindow = window
            self.recognizer = recognizer
        }

        func uninstall() {
            if let recognizer, let installedWindow {
                installedWindow.removeGestureRecognizer(recognizer)
            }
            recognizer = nil
            installedWindow = nil
        }

        @objc private func handleTap() {
            CPSLTransientInteractionReset.reset()
            onReset()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let view = touch.view else {
                return true
            }
            return shouldReset(for: view)
        }

        private func shouldReset(for view: UIView) -> Bool {
            var current: UIView? = view
            while let candidate = current {
                if candidate is UIControl {
                    return false
                }
                if candidate.accessibilityTraits.contains(.button) {
                    return false
                }
                if let textView = candidate as? UITextView,
                   !CPSLTransientInteractionReset.isRegisteredSelectableTextView(textView) {
                    return !textView.isEditable
                }
#if canImport(WebKit)
                if candidate is WKWebView {
                    return false
                }
#endif
                if candidate is UITextInput || candidate is UIKeyInput {
                    return false
                }
                if candidate is UITextField {
                    return false
                }
                current = candidate.superview
            }
            return true
        }
    }
}

private final class CPSLTransientInteractionResetUIView: UIView {
    var onWindowChange: ((UIWindow?) -> Void)?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onWindowChange?(window)
    }
}
#elseif os(macOS)
private struct CPSLTransientInteractionResetObserver: NSViewRepresentable {
    let onReset: () -> Void

    func makeNSView(context: Context) -> CPSLTransientInteractionResetNSView {
        let view = CPSLTransientInteractionResetNSView()
        view.onWindowChange = { [weak coordinator = context.coordinator] window in
            if let window {
                coordinator?.install(in: window)
            } else {
                coordinator?.uninstall()
            }
        }
        return view
    }

    func updateNSView(_ view: CPSLTransientInteractionResetNSView, context: Context) {
        context.coordinator.onReset = onReset
        if let window = view.window {
            context.coordinator.install(in: window)
        }
    }

    static func dismantleNSView(
        _ view: CPSLTransientInteractionResetNSView,
        coordinator: Coordinator
    ) {
        coordinator.uninstall()
        view.onWindowChange = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onReset: onReset)
    }

    final class Coordinator {
        var onReset: () -> Void
        private weak var installedWindow: NSWindow?
        private var monitor: Any?

        init(onReset: @escaping () -> Void) {
            self.onReset = onReset
        }

        func install(in window: NSWindow) {
            guard installedWindow !== window else {
                return
            }
            uninstall()
            installedWindow = window
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self, weak window] event in
                guard let self, event.window === window else {
                    return event
                }
                if self.shouldReset(for: event, in: window) {
                    CPSLTransientInteractionReset.reset()
                    self.onReset()
                }
                return event
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
            installedWindow = nil
        }

        private func shouldReset(for event: NSEvent, in window: NSWindow?) -> Bool {
            guard let targetView = window?.contentView?.hitTest(event.locationInWindow) else {
                return true
            }

            var current: NSView? = targetView
            while let candidate = current {
                if candidate is NSControl {
                    return false
                }
                if candidate.accessibilityRole() == .button {
                    return false
                }
                if let textView = candidate as? NSTextView,
                   !CPSLTransientInteractionReset.isRegisteredSelectableTextView(textView) {
                    return !textView.isEditable
                }
#if canImport(WebKit)
                if candidate is WKWebView {
                    return false
                }
#endif
                current = candidate.superview
            }
            return true
        }
    }
}

private final class CPSLTransientInteractionResetNSView: NSView {
    var onWindowChange: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindowChange?(window)
    }
}
#else
private struct CPSLTransientInteractionResetObserver: View {
    let onReset: () -> Void

    var body: some View {
        Color.clear
    }
}
#endif

private enum CPSLDrawerMotion {
    static let duration = 0.2
    static let animation = Animation.easeOut(duration: duration)
}

private enum CPSLOverlayMotion {
    static let duration = 0.2
    static let animation = Animation.easeOut(duration: duration)
    static let transition = AnyTransition.move(edge: .trailing).combined(with: .opacity)
}

struct CPSLChatScreen: View {
    @StateObject private var model = CPSLChatModel()
    @State private var promptDismissRequest = 0
    @State private var drawerProgress: CGFloat = 0
    @State private var drawerMotionGeneration = 0
    @State private var isDrawerMotionActive = false
    @State private var activeDrawerDragStartProgress: CGFloat?

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
                .allowsHitTesting(isDrawerVisible)
                .offset(x: drawerOffset(width: proxy.size.width))

                CPSLMainContentStage(
                    model: model,
                    promptDismissRequest: $promptDismissRequest,
                    contentTopInset: contentTopInset(topSafeAreaInset: proxy.safeAreaInsets.top),
                    contentBottomInset: contentBottomInset,
                    isTimelineScrollGeometryPaused: isTimelineScrollGeometryPaused
                )
                .offset(x: mainContentOffset(width: proxy.size.width))
                .allowsHitTesting(!isDrawerVisible)
                .zIndex(1)

                CPSLDrawerToggleButton(isOpen: model.isDrawerOpen) {
                    toggleDrawer()
                }
                .padding(.leading, CPSLTheme.medium)
                .padding(.top, CPSLTheme.topChromeSafeAreaGap)
                .offset(x: drawerToggleOffset(width: proxy.size.width))
                .zIndex(3)

            }
            .simultaneousGesture(drawerDragGesture(width: proxy.size.width))
            .onAppear {
                drawerProgress = drawerTargetProgress
                isDrawerMotionActive = false
            }
            .onChange(of: model.isDrawerOpen) { _, _ in
                animateDrawerProgress(to: drawerTargetProgress)
            }
        }
        .cpslResetTransientsOnBackgroundTap {
            promptDismissRequest += 1
        }
        .alert(
            "Herm",
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
        max(
            0,
            width
                - CPSLTheme.controlSize
                - CPSLTheme.medium
                - CPSLTheme.drawerToggleOpenTrailingInset
        ) * drawerProgress
    }

    private var drawerTargetProgress: CGFloat {
        model.isDrawerOpen ? 1 : 0
    }

    private var isDrawerVisible: Bool {
        model.isDrawerOpen
            || drawerProgress > 0
            || isDrawerMotionActive
            || activeDrawerDragStartProgress != nil
    }

    private var isTimelineScrollGeometryPaused: Bool {
        isDrawerVisible
    }

    private func drawerTopInset(topSafeAreaInset: CGFloat) -> CGFloat {
        topSafeAreaInset + CPSLTheme.topChromeSafeAreaGap
    }

    private func contentTopInset(topSafeAreaInset: CGFloat) -> CGFloat {
        topSafeAreaInset + CPSLTheme.topChromeInset
    }

    private func drawerDragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                updateDrawerDrag(value, width: width)
            }
            .onEnded { value in
                finishDrawerDrag(value, width: width)
            }
    }

    private func toggleDrawer() {
        isDrawerMotionActive = true
        model.toggleDrawer()
    }

    private func updateDrawerDrag(_ value: DragGesture.Value, width: CGFloat) {
        guard width > 0 else {
            return
        }
        guard let startProgress = activeDrawerDragStartProgress
            ?? drawerDragStartProgress(value, width: width) else {
            return
        }

        activeDrawerDragStartProgress = startProgress
        drawerProgress = clampedDrawerProgress(startProgress + value.translation.width / width)
    }

    private func finishDrawerDrag(_ value: DragGesture.Value, width: CGFloat) {
        guard width > 0 else {
            activeDrawerDragStartProgress = nil
            return
        }
        guard let startProgress = activeDrawerDragStartProgress
            ?? drawerDragStartProgress(value, width: width) else {
            return
        }

        let predictedProgress = clampedDrawerProgress(
            startProgress + value.predictedEndTranslation.width / width
        )
        let shouldOpen = predictedProgress >= 0.5
        let wasOpen = model.isDrawerOpen
        isDrawerMotionActive = true
        activeDrawerDragStartProgress = nil
        model.setDrawerOpen(shouldOpen)

        if wasOpen == shouldOpen {
            animateDrawerProgress(to: shouldOpen ? 1 : 0)
        }
    }

    private func drawerDragStartProgress(_ value: DragGesture.Value, width: CGFloat) -> CGFloat? {
        if model.isDrawerOpen {
            return value.startLocation.x >= width - CPSLTheme.drawerGestureEdgeWidth ? drawerProgress : nil
        }

        return value.startLocation.x <= CPSLTheme.drawerGestureEdgeWidth ? drawerProgress : nil
    }

    private func clampedDrawerProgress(_ progress: CGFloat) -> CGFloat {
        min(max(progress, 0), 1)
    }

    private func animateDrawerProgress(to targetProgress: CGFloat) {
        drawerMotionGeneration += 1
        let generation = drawerMotionGeneration
        isDrawerMotionActive = true

        withAnimation(CPSLDrawerMotion.animation) {
            drawerProgress = targetProgress
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(CPSLDrawerMotion.duration * 1_000_000_000))
            guard drawerMotionGeneration == generation else {
                return
            }
            isDrawerMotionActive = false
        }
    }
}

private struct CPSLMainContentStage: View {
    @ObservedObject var model: CPSLChatModel
    @Binding var promptDismissRequest: Int
    let contentTopInset: CGFloat
    let contentBottomInset: CGFloat
    let isTimelineScrollGeometryPaused: Bool

    var body: some View {
        ZStack {
            CPSLPrimaryContentView(
                model: model,
                contentTopInset: contentTopInset,
                contentBottomInset: contentBottomInset,
                isTimelineScrollGeometryPaused: isTimelineScrollGeometryPaused
            )
            .blur(radius: model.isToolOverlayOpen ? 3 : 0)
            .opacity(model.isToolOverlayOpen ? 0.55 : 1)
            .allowsHitTesting(!model.isToolOverlayOpen)
            .animation(CPSLOverlayMotion.animation, value: model.isToolOverlayOpen)

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
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .zIndex(3)

            if model.isFileBrowserOpen {
                CPSLFileBrowserOverlay(
                    model: model,
                    topInset: CPSLTheme.topChromeInset,
                    bottomInset: contentBottomInset
                )
                    .transition(CPSLOverlayMotion.transition)
                    .zIndex(4)
            }

            if model.isWebBrowserOpen {
                CPSLWebBrowserOverlay(
                    model: model,
                    topInset: CPSLTheme.topChromeInset,
                    bottomInset: contentBottomInset
                )
                    .transition(CPSLOverlayMotion.transition)
                    .zIndex(5)
            }

            if model.isCalendarOpen {
                CPSLCalendarOverlay(
                    model: model,
                    topInset: CPSLTheme.topChromeInset,
                    bottomInset: contentBottomInset
                )
                    .transition(CPSLOverlayMotion.transition)
                    .zIndex(6)
            }

            if model.isLocationOpen {
                CPSLLocationOverlay(
                    model: model,
                    topInset: CPSLTheme.topChromeInset,
                    bottomInset: contentBottomInset
                )
                    .transition(CPSLOverlayMotion.transition)
                    .zIndex(7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CPSLTheme.background.ignoresSafeArea())
        .animation(CPSLOverlayMotion.animation, value: model.isFileBrowserOpen)
        .animation(CPSLOverlayMotion.animation, value: model.isWebBrowserOpen)
        .animation(CPSLOverlayMotion.animation, value: model.isCalendarOpen)
        .animation(CPSLOverlayMotion.animation, value: model.isLocationOpen)
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
    let contentTopInset: CGFloat
    let contentBottomInset: CGFloat
    let isTimelineScrollGeometryPaused: Bool

    var body: some View {
        CPSLChatTimelineView(
            model: model,
            topInset: contentTopInset,
            bottomInset: contentBottomInset,
            isScrollGeometryPaused: isTimelineScrollGeometryPaused
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .top)
    }
}

private struct CPSLFileBrowserOverlay: View {
    let model: CPSLChatModel
    let topInset: CGFloat
    let bottomInset: CGFloat

    var body: some View {
        CPSLFileOverlayStage(
            metrics: CPSLFileOverlayStageMetrics(
                topInset: topInset,
                bottomInset: bottomInset,
                dimOpacity: 0.001
            )
        ) {
            CPSLFileBrowserView(model: model)
        }
    }
}

private struct CPSLBottomChromeView: View {
    @ObservedObject var model: CPSLChatModel
    @Binding var promptDismissRequest: Int

    private var isPromptCompact: Bool {
        model.isToolOverlayOpen
    }

    var body: some View {
        VStack(spacing: 0) {
            CPSLToolStripView(model: model)

            if let progress = model.iCloudImportProgress {
                CPSLICloudImportStatusView(progress: progress) {
                    model.cancelICloudImport()
                }
            } else {
                CPSLPromptComposerView(
                    model: model,
                    dismissKeyboardRequest: promptDismissRequest,
                    isCompact: isPromptCompact
                ) {
                    promptDismissRequest += 1
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

private struct CPSLICloudImportStatusView: View {
    let progress: CPSLICloudImportProgress
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.small) {
            HStack(spacing: CPSLTheme.medium) {
                if progress.phase == .preparing || progress.phase == .cancelling {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "icloud.and.arrow.down")
                        .font(CPSLTheme.iconMediumFont)
                        .foregroundStyle(CPSLTheme.IconPalette.cloud)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Connecting iCloud Folder")
                        .font(CPSLTheme.supportingMediumFont)
                        .foregroundStyle(CPSLTheme.text)
                    Text(detailText)
                        .font(CPSLTheme.captionFont)
                        .foregroundStyle(CPSLTheme.secondaryText)
                }

                Spacer()

                Button("Cancel", action: onCancel)
                    .font(CPSLTheme.controlFont)
                    .buttonStyle(.plain)
                    .foregroundStyle(CPSLTheme.text)
                    .padding(.horizontal, CPSLTheme.medium)
                    .frame(height: CPSLTheme.controlSize)
                    .cpslGlassBackground(
                        in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
                        tint: CPSLGlassTuning.tint(CPSLTheme.card, opacity: 0.38),
                        strokeOpacity: 0.045
                    )
                    .disabled(progress.phase == .cancelling)
                    .opacity(progress.phase == .cancelling ? 0.45 : 1)
            }

            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
                    .tint(CPSLTheme.IconPalette.cloud)
            }
        }
        .padding(CPSLTheme.composerPadding)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.composerRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.54),
            strokeOpacity: 0.055
        )
        .padding(.horizontal, CPSLTheme.chromeHorizontalInset)
        .padding(.bottom, CPSLTheme.medium)
    }

    private var detailText: String {
        switch progress.phase {
        case .cancelling:
            return "Stopping…"
        case .preparing:
            return "Preparing folder…"
        case .downloading:
            return "Downloading \(progress.completedItems) of \(progress.totalItems) iCloud files"
        }
    }
}

private struct CPSLHeaderActionsView: View {
    @ObservedObject var model: CPSLChatModel
#if DEBUG
    @State private var traceShareFile: CPSLJSONTraceShareFile?
    @State private var isPreparingTraceShareFile = false
#endif

    var body: some View {
        HStack(spacing: CPSLTheme.medium) {
            Spacer()

#if DEBUG
            CPSLChromeIconButton(systemName: "ladybug.fill", accessibilityLabel: "Share debug JSON") {
                shareConversationJSONTrace()
            }
            .disabled(isPreparingTraceShareFile)
            .opacity(isPreparingTraceShareFile ? 0.45 : 1)
#endif

            CPSLChromeIconButton(systemName: "square.and.pencil", accessibilityLabel: "New conversation") {
                model.startNewConversation()
            }
            .disabled(model.isBusy)
            .opacity(model.isBusy ? 0.45 : 1)
        }
        .padding(.horizontal, CPSLTheme.medium)
        .padding(.top, CPSLTheme.topChromeSafeAreaGap)
        .padding(.bottom, CPSLTheme.medium)
#if DEBUG
        .cpslJSONTraceShare(file: $traceShareFile)
#endif
    }

#if DEBUG
    private func shareConversationJSONTrace() {
        guard !isPreparingTraceShareFile else {
            return
        }

        isPreparingTraceShareFile = true
        Task { @MainActor in
            defer {
                isPreparingTraceShareFile = false
            }
            traceShareFile = await model.makeConversationJSONTraceShareFile().map { url in
                CPSLJSONTraceShareFile(url: url)
            }
        }
    }
#endif
}

#if DEBUG
private struct CPSLJSONTraceShareFile: Identifiable {
    let id = UUID()
    let url: URL

    init(url: URL) {
        self.url = url
    }
}

private extension View {
    func cpslJSONTraceShare(file: Binding<CPSLJSONTraceShareFile?>) -> some View {
#if os(macOS)
        background(CPSLJSONTraceSharingServicePicker(file: file))
#elseif canImport(UIKit)
        sheet(item: file) { shareFile in
            CPSLJSONTraceActivityView(activityItems: [shareFile.url])
        }
#else
        self
#endif
    }
}

#if os(macOS)
private struct CPSLJSONTraceSharingServicePicker: NSViewRepresentable {
    @Binding var file: CPSLJSONTraceShareFile?

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let file else {
            return
        }
        guard context.coordinator.presentedID != file.id else {
            return
        }

        context.coordinator.presentedID = file.id
        let fileBinding = $file
        DispatchQueue.main.async {
            guard nsView.window != nil else {
                fileBinding.wrappedValue = nil
                return
            }

            let picker = NSSharingServicePicker(items: [file.url])
            context.coordinator.picker = picker
            picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
            fileBinding.wrappedValue = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var presentedID: UUID?
        var picker: NSSharingServicePicker?
    }
}
#elseif canImport(UIKit)
private struct CPSLJSONTraceActivityView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
#endif

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
