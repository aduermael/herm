import SwiftUI

struct CPSLAttachmentDropModifier: ViewModifier {
    @Binding var isTargeted: Bool
    let isEnabled: Bool
    let onDropFiles: ([URL]) -> Void

    func body(content: Content) -> some View {
        content
            .dropDestination(for: URL.self, isEnabled: isEnabled) { urls, _ in
                onDropFiles(urls)
            }
#if os(macOS)
            .onDropSessionUpdated { session in
                updateTarget(for: session.phase)
            }
#endif
            .overlay {
                RoundedRectangle(cornerRadius: CPSLTheme.composerRadius, style: .continuous)
                    .stroke(
                        CPSLTheme.text.opacity(0.72),
                        style: StrokeStyle(
                            lineWidth: 2,
                            lineCap: .round,
                            dash: [3, 6]
                        )
                    )
                    .opacity(isTargeted ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .animation(.easeOut(duration: 0.14), value: isTargeted)
    }

#if os(macOS)
    private func updateTarget(for phase: DropSession.Phase) {
        switch phase {
        case .entering, .active:
            isTargeted = true
        case .exiting, .ended, .dataTransferCompleted:
            isTargeted = false
        @unknown default:
            isTargeted = false
        }
    }
#endif
}

extension View {
    func cpslAttachmentDropDestination(
        isTargeted: Binding<Bool>,
        isEnabled: Bool,
        onDropFiles: @escaping ([URL]) -> Void
    ) -> some View {
        modifier(
            CPSLAttachmentDropModifier(
                isTargeted: isTargeted,
                isEnabled: isEnabled,
                onDropFiles: onDropFiles
            )
        )
    }
}
