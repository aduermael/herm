#if os(macOS)
import AppKit
import Dispatch
import SwiftUI

private final class CPSLPasteAwareTextView: NSTextView {
    var canPasteAttachments: (() -> Bool)?
    var pasteAttachments: (() -> Bool)?

    override func paste(_ sender: Any?) {
        if pasteAttachments?() == true {
            return
        }
        guard let text = NSPasteboard.general.string(forType: .string) else {
            return
        }
        insertText(text, replacementRange: selectedRange())
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(NSText.paste(_:)),
           canPasteAttachments?() == true {
            return isEditable
        }
        return super.validateMenuItem(menuItem)
    }
}

final class CPSLDropAwareScrollView: NSScrollView {
    var isFileDropEnabled = true
    var onDropFiles: (([URL]) -> Void)?
    var onDropTargeted: ((Bool) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender, updateTarget: true)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropOperation(for: sender, updateTarget: true)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDropTargeted?(false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender)
        guard isFileDropEnabled, !urls.isEmpty else {
            onDropTargeted?(false)
            return false
        }
        onDropFiles?(urls)
        onDropTargeted?(false)
        return true
    }

    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) {
        onDropTargeted?(false)
    }

    private func dropOperation(
        for draggingInfo: any NSDraggingInfo,
        updateTarget: Bool
    ) -> NSDragOperation {
        let acceptsDrop = isFileDropEnabled && !fileURLs(from: draggingInfo).isEmpty
        if updateTarget {
            onDropTargeted?(acceptsDrop)
        }
        return acceptsDrop ? .copy : []
    }

    private func fileURLs(from draggingInfo: any NSDraggingInfo) -> [URL] {
        draggingInfo.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
    }
}

struct CPSLPromptTextView: NSViewRepresentable {
    @Binding var text: String
    let isCommandInput: Bool
    let isDisabled: Bool
    let verticalInset: CGFloat
    let maxHeight: CGFloat
    let focusPromptRequest: Int
    let dismissKeyboardRequest: Int
    let canPasteAttachments: () -> Bool
    let onPasteAttachments: () -> Bool
    let onDropFiles: ([URL]) -> Void
    let onDropTargeted: (Bool) -> Void
    let onHeightChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> CPSLDropAwareScrollView {
        let scrollView = CPSLDropAwareScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true

        let textView = CPSLPasteAwareTextView()
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.textColor = NSColor(CPSLTheme.text)
        textView.insertionPointColor = NSColor(CPSLTheme.text)
        textView.font = .systemFont(ofSize: CPSLTheme.FontSize.body)
        textView.menu = makeContextMenu(target: textView)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.unregisterDraggedTypes()
        textView.minSize = .zero
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView
        configure(textView, in: scrollView)
        context.coordinator.focusPromptRequest = focusPromptRequest
        context.coordinator.dismissKeyboardRequest = dismissKeyboardRequest
        return scrollView
    }

    func updateNSView(_ scrollView: CPSLDropAwareScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CPSLPasteAwareTextView else {
            return
        }
        context.coordinator.parent = self
        configure(textView, in: scrollView)

        let didChangeText = textView.string != text
        if didChangeText {
            textView.string = text
        }

        if isDisabled && textView.window?.firstResponder === textView {
            textView.window?.makeFirstResponder(nil)
        } else if context.coordinator.dismissKeyboardRequest != dismissKeyboardRequest {
            context.coordinator.dismissKeyboardRequest = dismissKeyboardRequest
            textView.window?.makeFirstResponder(nil)
        } else if context.coordinator.focusPromptRequest != focusPromptRequest {
            context.coordinator.focusPromptRequest = focusPromptRequest
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
            }
        }

        if didChangeText {
            context.coordinator.reportHeight(for: textView, in: scrollView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private func configure(
        _ textView: CPSLPasteAwareTextView,
        in scrollView: CPSLDropAwareScrollView
    ) {
        textView.canPasteAttachments = canPasteAttachments
        textView.pasteAttachments = onPasteAttachments
        textView.textContainerInset = NSSize(width: CPSLTheme.medium, height: verticalInset)
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        textView.unregisterDraggedTypes()
        textView.isAutomaticQuoteSubstitutionEnabled = !isCommandInput
        textView.isAutomaticDashSubstitutionEnabled = !isCommandInput
        textView.isAutomaticSpellingCorrectionEnabled = !isCommandInput
        textView.isContinuousSpellCheckingEnabled = !isCommandInput

        scrollView.isFileDropEnabled = !isDisabled
        scrollView.onDropFiles = onDropFiles
        scrollView.onDropTargeted = onDropTargeted
    }

    private func makeContextMenu(target: NSTextView) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: String(localized: "Cut", comment: "Context menu action for the prompt field."),
            action: #selector(NSText.cut(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: String(localized: "Copy", comment: "Context menu action for the prompt field."),
            action: #selector(NSText.copy(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: String(localized: "Paste", comment: "Context menu action for the prompt field."),
            action: #selector(NSText.paste(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: String(localized: "Select All", comment: "Context menu action for the prompt field."),
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: ""
        )
        for item in menu.items where !item.isSeparatorItem {
            item.target = target
        }
        return menu
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CPSLPromptTextView
        var focusPromptRequest = 0
        var dismissKeyboardRequest = 0

        init(parent: CPSLPromptTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let scrollView = textView.enclosingScrollView
            else {
                return
            }
            parent.text = textView.string
            reportHeight(for: textView, in: scrollView)
        }

        func reportHeight(for textView: NSTextView, in scrollView: NSScrollView) {
            guard let textContainer = textView.textContainer,
                  let layoutManager = textView.layoutManager
            else {
                return
            }
            layoutManager.ensureLayout(for: textContainer)
            let height = ceil(
                layoutManager.usedRect(for: textContainer).height + textView.textContainerInset.height * 2
            )
            scrollView.hasVerticalScroller = height > parent.maxHeight
            DispatchQueue.main.async {
                self.parent.onHeightChange(height)
            }
        }
    }
}
#endif
