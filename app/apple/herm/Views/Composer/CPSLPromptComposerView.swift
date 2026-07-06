import Dispatch
import SwiftUI

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
        textView.textContainerInset = .zero
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
    let dismissKeyboard: () -> Void
    @State private var focusAfterDictation = false
#if os(macOS)
    @State private var collapseSelectionOnFocus = false
#endif
    @State private var promptContentHeight: CGFloat = 0
    @State private var focusPromptRequest = 0
    @FocusState private var isPromptFocused: Bool

    private var dictation: CPSLDictationService {
        model.dictation
    }

    private var hasPromptInput: Bool {
        !model.promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    private var promptTextHeight: CGFloat {
        min(max(promptContentHeight, promptLineHeight), promptLineHeight * 6)
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: CPSLTheme.composerSpacing) {
            ZStack(alignment: .topLeading) {
                if model.promptText.isEmpty {
                    Text("Ask Anything")
                        .font(CPSLTheme.bodyFont)
                        .foregroundStyle(CPSLTheme.mutedText)
                        .padding(.horizontal, CPSLTheme.medium)
                        .padding(.vertical, CPSLTheme.promptVerticalInset)
                }

#if canImport(UIKit)
                CPSLPromptTextView(
                    text: $model.promptText,
                    isCommandInput: isCommandInput,
                    isDisabled: model.isRunning,
                    maxHeight: promptLineHeight * 6,
                    focusPromptRequest: focusPromptRequest,
                    dismissKeyboardRequest: dismissKeyboardRequest
                ) { height in
                    promptContentHeight = height
                }
                .frame(height: promptTextHeight)
                .padding(.horizontal, CPSLTheme.medium)
                .padding(.vertical, CPSLTheme.promptVerticalInset)
#else
                TextField("", text: $model.promptText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .submitLabel(.return)
                    .lineLimit(1...6)
                    .font(CPSLTheme.bodyFont)
                    .foregroundStyle(CPSLTheme.text)
                    .tint(CPSLTheme.text)
                    .focused($isPromptFocused)
                    .disabled(model.isRunning)
                    .padding(.horizontal, CPSLTheme.medium)
                    .padding(.vertical, CPSLTheme.promptVerticalInset)
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
            .animation(.easeOut(duration: 0.16), value: isCommandInput)

            HStack(spacing: CPSLTheme.medium) {
                Button {
                    dismissKeyboard()
                    model.showComingSoon("coming soon")
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

                Spacer()

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
                .disabled(model.isRunning)

                Button {
                    dismissKeyboard()
                    if hasPromptInput {
                        model.submitPrompt()
                    } else {
                        model.showComingSoon("coming soon")
                    }
                } label: {
                    Group {
                        if hasPromptInput {
                            Image(systemName: "arrow.up")
                                .font(CPSLTheme.iconFont(size: CPSLTheme.FontSize.iconLarge, weight: .semibold))
                                .frame(width: CPSLTheme.controlSize, height: CPSLTheme.controlSize)
                        } else {
                            HStack(spacing: CPSLTheme.small) {
                                Image(systemName: "waveform")
                                    .font(CPSLTheme.iconMediumFont)
                                Text("Speak")
                                    .font(CPSLTheme.controlFont)
                            }
                            .padding(.horizontal, CPSLTheme.medium)
                            .frame(height: CPSLTheme.controlSize)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(CPSLTheme.background)
                .background(CPSLTheme.text)
                .clipShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: CPSLTheme.controlRadius, style: .continuous))
            }
        }
        .padding(CPSLTheme.composerPadding)
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
        .onChange(of: model.isRunning) { _, isRunning in
            if isRunning {
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
        guard !model.isRunning else {
            return
        }

        focusPromptRequest += 1
        isPromptFocused = true
    }
}
