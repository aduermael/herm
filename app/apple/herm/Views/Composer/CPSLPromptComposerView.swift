import Dispatch
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

#if canImport(AppKit)
import AppKit
#endif

#if canImport(UIKit)
private struct CPSLPromptTextView: UIViewRepresentable {
    @Binding var text: String
    let isCommandInput: Bool
    let isDisabled: Bool
    let verticalInset: CGFloat
    let maxHeight: CGFloat
    let focusPromptRequest: Int
    let dismissKeyboardRequest: Int
    let onHeightChange: (CGFloat) -> Void

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = UIColor(CPSLTheme.text)
        textView.tintColor = UIColor(CPSLTheme.text)
        textView.font = CPSLTheme.bodyUIFont
        textView.textContainerInset = textContainerInset
        textView.textContainer.lineFragmentPadding = 0
        textView.returnKeyType = .default
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        context.coordinator.focusPromptRequest = focusPromptRequest
        context.coordinator.dismissKeyboardRequest = dismissKeyboardRequest
        applyInputTraits(to: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.parent = self

        if textView.text != text {
            textView.text = text
        }

        let didChangeTraits = applyInputTraits(to: textView)
        if textView.textContainerInset != textContainerInset {
            textView.textContainerInset = textContainerInset
        }
        textView.isEditable = !isDisabled
        textView.isSelectable = !isDisabled
        textView.isScrollEnabled = textView.contentSize.height > maxHeight

        if isDisabled && textView.isFirstResponder {
            textView.resignFirstResponder()
        } else if context.coordinator.dismissKeyboardRequest != dismissKeyboardRequest {
            context.coordinator.dismissKeyboardRequest = dismissKeyboardRequest
            textView.resignFirstResponder()
        } else if context.coordinator.focusPromptRequest != focusPromptRequest {
            context.coordinator.focusPromptRequest = focusPromptRequest
            if !textView.isFirstResponder {
                DispatchQueue.main.async {
                    textView.becomeFirstResponder()
                }
            }
        }

        if didChangeTraits && textView.isFirstResponder {
            textView.reloadInputViews()
        }

        context.coordinator.reportHeight(for: textView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    private var textContainerInset: UIEdgeInsets {
        UIEdgeInsets(
            top: verticalInset,
            left: CPSLTheme.medium,
            bottom: verticalInset,
            right: CPSLTheme.medium
        )
    }

    @discardableResult
    private func applyInputTraits(to textView: UITextView) -> Bool {
        let keyboardType: UIKeyboardType = isCommandInput ? .asciiCapable : .default
        let autocapitalizationType: UITextAutocapitalizationType = isCommandInput ? .none : .sentences
        let autocorrectionType: UITextAutocorrectionType = isCommandInput ? .no : .yes
        let spellCheckingType: UITextSpellCheckingType = isCommandInput ? .no : .default
        let smartQuotesType: UITextSmartQuotesType = isCommandInput ? .no : .default
        let smartDashesType: UITextSmartDashesType = isCommandInput ? .no : .default
        let smartInsertDeleteType: UITextSmartInsertDeleteType = isCommandInput ? .no : .default

        let didChange = textView.keyboardType != keyboardType ||
            textView.autocapitalizationType != autocapitalizationType ||
            textView.autocorrectionType != autocorrectionType ||
            textView.spellCheckingType != spellCheckingType ||
            textView.smartQuotesType != smartQuotesType ||
            textView.smartDashesType != smartDashesType ||
            textView.smartInsertDeleteType != smartInsertDeleteType

        textView.keyboardType = keyboardType
        textView.autocapitalizationType = autocapitalizationType
        textView.autocorrectionType = autocorrectionType
        textView.spellCheckingType = spellCheckingType
        textView.smartQuotesType = smartQuotesType
        textView.smartDashesType = smartDashesType
        textView.smartInsertDeleteType = smartInsertDeleteType
        return didChange
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CPSLPromptTextView
        var focusPromptRequest = 0
        var dismissKeyboardRequest = 0

        init(parent: CPSLPromptTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            reportHeight(for: textView)
        }

        func reportHeight(for textView: UITextView) {
            let fittingSize = CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)
            let height = textView.sizeThatFits(fittingSize).height
            DispatchQueue.main.async {
                self.parent.onHeightChange(height)
            }
        }
    }
}
#endif

struct CPSLPromptComposerView: View {
    @ObservedObject var model: CPSLChatModel
    let dismissKeyboardRequest: Int
    let isCompact: Bool
    let dismissKeyboard: () -> Void
    @State private var focusAfterDictation = false
#if os(macOS)
    @State private var collapseSelectionOnFocus = false
#endif
    @State private var promptContentHeight: CGFloat = 0
    @State private var focusPromptRequest = 0
    @State private var isFileImporterPresented = false
    @State private var isPhotoPickerPresented = false
    @State private var isCameraPresented = false
    @State private var selectedPhotos: [PhotosPickerItem] = []
    @State private var pendingPhotoImportCount = 0
    @FocusState private var isPromptFocused: Bool

    private var dictation: CPSLDictationService {
        model.dictation
    }

    private var hasPromptInput: Bool {
        !model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSubmit: Bool {
        hasPromptInput || !model.composerAttachments.isEmpty
    }

    private var isAddingAttachment: Bool {
        model.isImportingAttachment || pendingPhotoImportCount > 0
    }

    private var isCommandInput: Bool {
        model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("!")
    }

    private var promptLineHeight: CGFloat {
#if canImport(UIKit)
        ceil(CPSLTheme.bodyUIFont.lineHeight)
#else
        ceil(CPSLTheme.FontSize.body * 1.25)
#endif
    }

    private var promptVerticalPadding: CGFloat {
        promptVerticalInset * 2
    }

    private var promptVerticalInset: CGFloat {
        if isCompact {
            return max(CPSLTheme.promptVerticalInset / 2, (CPSLTheme.controlSize - promptLineHeight) / 2)
        }
        return CPSLTheme.promptVerticalInset
    }

    private var promptMaxLineCount: Int {
        isCompact ? 3 : 6
    }

    private var promptMinTextHeight: CGFloat {
        isCompact ? CPSLTheme.controlSize : promptLineHeight + promptVerticalPadding
    }

    private var promptMeasuredHeight: CGFloat {
        hasPromptInput ? promptContentHeight : promptMinTextHeight
    }

    private var promptMaxTextHeight: CGFloat {
        promptLineHeight * CGFloat(promptMaxLineCount) + promptVerticalPadding
    }

    private var promptTextHeight: CGFloat {
        min(max(promptMeasuredHeight, promptMinTextHeight), promptMaxTextHeight)
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: isCompact ? 0 : CPSLTheme.composerSpacing) {
            if !model.composerAttachments.isEmpty {
                CPSLComposerAttachmentStrip(
                    attachments: model.composerAttachments,
                    onRemove: model.removeComposerAttachment
                )
                .padding(.bottom, CPSLTheme.small)
            }
            if isAddingAttachment {
                CPSLAttachmentImportStatus()
                    .padding(.bottom, CPSLTheme.small)
            }
            if isCompact {
                HStack(alignment: .bottom, spacing: CPSLTheme.small) {
                    promptInputBox
                    compactActionRow
                }
            } else {
                promptInputBox
                fullActionRow
            }
        }
        .padding(isCompact ? CPSLTheme.small : CPSLTheme.composerPadding)
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.composerRadius, style: .continuous))
        .contextMenu {
            Button {
                pastePromptText()
            } label: {
                Label("Paste", systemImage: "doc.on.clipboard")
            }
        }
        .background {
            RoundedRectangle(cornerRadius: CPSLTheme.composerRadius, style: .continuous)
                .fill(Color.clear)
                .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.composerRadius, style: .continuous))
                .onTapGesture {
                    focusPrompt()
                }
        }
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.composerRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.background, opacity: 0.54),
            strokeOpacity: 0.055
        )
    }

    private var promptInputBox: some View {
        ZStack(alignment: .topLeading) {
            if model.promptText.isEmpty {
                Text("Ask Anything")
                    .font(CPSLTheme.bodyFont)
                    .foregroundStyle(CPSLTheme.mutedText)
                    .padding(.horizontal, CPSLTheme.medium)
                    .padding(.vertical, promptVerticalInset)
            }

#if canImport(UIKit)
            CPSLPromptTextView(
                text: $model.promptText,
                isCommandInput: isCommandInput,
                isDisabled: model.isBusy,
                verticalInset: promptVerticalInset,
                maxHeight: promptMaxTextHeight,
                focusPromptRequest: focusPromptRequest,
                dismissKeyboardRequest: dismissKeyboardRequest
            ) { height in
                promptContentHeight = height
            }
            .frame(height: promptTextHeight)
#else
            TextField("", text: $model.promptText, axis: .vertical)
                .textFieldStyle(.plain)
                .submitLabel(.return)
                .lineLimit(1...promptMaxLineCount)
                .font(CPSLTheme.bodyFont)
                .foregroundStyle(CPSLTheme.text)
                .tint(CPSLTheme.text)
                .focused($isPromptFocused)
                .disabled(model.isBusy)
                .padding(.horizontal, CPSLTheme.medium)
                .padding(.vertical, promptVerticalInset)
#endif
        }
        .contentShape(Rectangle())
        .onTapGesture {
            focusPrompt()
        }
        .background {
            RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous)
                .fill(isCommandInput ? CPSLTheme.command.opacity(0.82) : Color.clear)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: 0.16), value: isCommandInput)
    }

    private var fullActionRow: some View {
        HStack(spacing: CPSLTheme.medium) {
            addButton

            Spacer()

            dictationButton
            sendButton
        }
    }

    private var compactActionRow: some View {
        HStack(spacing: CPSLTheme.small) {
            addButton
            dictationButton
            sendButton
        }
    }

    private var addButton: some View {
        Menu {
            Button {
                dismissKeyboard()
                isFileImporterPresented = true
            } label: {
                Label("Choose File", systemImage: "folder")
            }

            Button {
                dismissKeyboard()
                isPhotoPickerPresented = true
            } label: {
                Label("Photo Library", systemImage: "photo.on.rectangle")
            }

#if os(iOS)
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button {
                    dismissKeyboard()
                    isCameraPresented = true
                } label: {
                    Label("Take Photo", systemImage: "camera")
                }
            }
#endif
        } label: {
            Image(systemName: "plus")
                .font(CPSLTheme.iconLargeFont)
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(CPSLTheme.text)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(CPSLTheme.card, opacity: 0.38),
            strokeOpacity: 0.045
        )
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
        .disabled(model.isBusy || isAddingAttachment)
        .accessibilityLabel("Add Attachment")
    }

    private var dictationButton: some View {
        Button {
            toggleDictation()
        } label: {
            Image(systemName: dictation.isActive ? "mic.fill" : "mic")
                .font(CPSLTheme.iconMediumFont)
                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(dictation.isActive ? CPSLTheme.mauve : CPSLTheme.text)
        .cpslGlassBackground(
            in: RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous),
            tint: CPSLGlassTuning.tint(
                dictation.isActive ? CPSLTheme.mauve : CPSLTheme.card,
                opacity: dictation.isActive ? 0.22 : 0.38
            ),
            strokeOpacity: 0.045
        )
        .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private var sendButton: some View {
        if model.isRunning {
            Button {
                model.stopAgent()
            } label: {
                Image(systemName: "stop.fill")
                    .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconLarge, weight: .semibold))
                    .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                    .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(CPSLTheme.background)
            .background(CPSLTheme.error)
            .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
            .accessibilityLabel("Stop")
        } else if canSubmit {
            Button {
                dismissKeyboard()
                model.submitPrompt()
            } label: {
                Image(systemName: "arrow.up")
                    .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconLarge, weight: .semibold))
                    .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                    .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .foregroundStyle(CPSLTheme.background)
            .background(CPSLTheme.text)
            .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
            .disabled(isAddingAttachment)
        }
    }

    var body: some View {
        Group {
            if dictation.isActive {
                CPSLDictationBarView(
                    dictation: dictation,
                    onCancel: cancelDictation,
                    onConfirm: confirmDictation
                )
            } else {
                composerContent
            }
        }
        .padding(.horizontal, CPSLTheme.chromeHorizontalInset)
        .padding(.bottom, CPSLTheme.medium)
        .animation(.easeOut(duration: 0.2), value: dictation.isActive)
        .onChange(of: dismissKeyboardRequest) { _, _ in
            isPromptFocused = false
        }
        .onChange(of: model.isBusy) { _, isBusy in
            if isBusy {
                isPromptFocused = false
            }
        }
        .onChange(of: dictation.isActive) { wasActive, isActive in
            guard wasActive, !isActive else {
                return
            }
            commitTranscript()
            if focusAfterDictation {
                focusAfterDictation = false
#if os(macOS)
                collapseSelectionOnFocus = true
#endif
                focusPrompt()
            }
        }
#if os(macOS)
        .onChange(of: isPromptFocused) { _, focused in
            guard focused, collapseSelectionOnFocus else {
                return
            }
            collapseSelectionOnFocus = false
            DispatchQueue.main.async {
                guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
                    return
                }
                let end = (editor.string as NSString).length
                editor.setSelectedRange(NSRange(location: end, length: 0))
            }
        }
#endif
        .cpslDictationErrorAlert(dictation)
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: importFiles
        )
#if os(iOS)
        .sheet(isPresented: $isCameraPresented) {
            CPSLCameraPicker { data in
                isCameraPresented = false
                if let data {
                    model.addAttachment(
                        data: data,
                        preferredName: Self.photoFileName(fileExtension: "jpg")
                    )
                }
            }
            .ignoresSafeArea()
        }
#endif
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $selectedPhotos,
            maxSelectionCount: 10,
            matching: .images
        )
        .onChange(of: selectedPhotos) { _, items in
            guard !items.isEmpty else {
                return
            }
            selectedPhotos = []
            importPhotos(items)
        }
    }

    private func toggleDictation() {
        dismissKeyboard()
        if dictation.isActive {
            dictation.finish()
        } else {
            dictation.start()
        }
    }

    private func cancelDictation() {
        focusAfterDictation = false
        dictation.cancel()
    }

    private func confirmDictation() {
        focusAfterDictation = true
        dictation.finish()
    }

    private func commitTranscript() {
        let transcript = dictation.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            return
        }
        let base = model.promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        model.promptText = base.isEmpty ? transcript : base + " " + transcript
    }

    private func focusPrompt() {
        guard !model.isBusy else {
            return
        }

        focusPromptRequest += 1
        isPromptFocused = true
    }

    private func pastePromptText() {
        guard !model.isBusy else {
            return
        }
        guard let text = Self.pasteboardString(), !text.isEmpty else {
            focusPrompt()
            return
        }

        model.promptText += text
        focusPrompt()
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            urls.forEach { model.addAttachment(from: $0) }
        case .failure(let error):
            model.showComingSoon("Could not choose files: \(error.localizedDescription)")
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        pendingPhotoImportCount += items.count
        for item in items {
            Task {
                defer {
                    pendingPhotoImportCount = max(0, pendingPhotoImportCount - 1)
                }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        model.showComingSoon("Could not read the selected photo.")
                        return
                    }
                    let fileExtension = item.supportedContentTypes
                        .compactMap(\.preferredFilenameExtension)
                        .first ?? "jpg"
                    model.addAttachment(
                        data: data,
                        preferredName: Self.photoFileName(fileExtension: fileExtension)
                    )
                } catch {
                    model.showComingSoon("Could not read the selected photo: \(error.localizedDescription)")
                }
            }
        }
    }

    private static func pasteboardString() -> String? {
#if os(macOS)
        NSPasteboard.general.string(forType: .string)
#elseif canImport(UIKit)
        UIPasteboard.general.string
#else
        nil
#endif
    }

    private static func photoFileName(fileExtension: String) -> String {
        "photo-\(UUID().uuidString.prefix(8)).\(fileExtension)"
    }
}

private struct CPSLComposerAttachmentStrip: View {
    let attachments: [CPSLAttachment]
    let onRemove: (CPSLAttachment) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: CPSLTheme.small) {
                ForEach(attachments) { attachment in
                    CPSLAttachmentBadge(
                        name: attachment.name,
                        onRemove: { onRemove(attachment) }
                    )
                }
            }
        }
    }
}

private struct CPSLAttachmentImportStatus: View {
    var body: some View {
        HStack(spacing: CPSLTheme.small) {
            ProgressView()
                .controlSize(.small)
            Text("Adding attachment…")
                .font(CPSLTheme.controlFont)
                .foregroundStyle(CPSLTheme.secondaryText)
        }
        .padding(.horizontal, CPSLTheme.medium)
    }
}

#if os(iOS)
private struct CPSLCameraPicker: UIViewControllerRepresentable {
    let onCompletion: (Data?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        controller.sourceType = .camera
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCompletion: onCompletion)
    }

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let onCompletion: (Data?) -> Void

        init(onCompletion: @escaping (Data?) -> Void) {
            self.onCompletion = onCompletion
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            onCompletion((info[.originalImage] as? UIImage)?.jpegData(compressionQuality: 0.92))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCompletion(nil)
        }
    }
}
#endif
