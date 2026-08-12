import Foundation
import SwiftUI
#if os(macOS)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

extension View {
    /// Presents the OS share sheet / sharing-service picker for a file URL.
    func cpslShareFile(file: Binding<CPSLShareableFile?>) -> some View {
#if os(macOS)
        background(CPSLSharingServicePicker(file: file))
#elseif canImport(UIKit)
        sheet(item: file) { shareFile in
            CPSLActivityShareView(activityItems: [shareFile.url])
                .onDisappear {
                    // Drop retained iCloud scopes after the sheet closes.
                    _ = shareFile.lifetimeToken
                }
        }
#else
        self
#endif
    }
}

#if os(macOS)
private struct CPSLSharingServicePicker: NSViewRepresentable {
    @Binding var file: CPSLShareableFile?

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
        context.coordinator.lifetimeToken = file.lifetimeToken
        let fileBinding = $file
        DispatchQueue.main.async {
            guard nsView.window != nil else {
                fileBinding.wrappedValue = nil
                context.coordinator.lifetimeToken = nil
                return
            }

            let picker = NSSharingServicePicker(items: [file.url])
            context.coordinator.picker = picker
            picker.show(relativeTo: nsView.bounds, of: nsView, preferredEdge: .minY)
            fileBinding.wrappedValue = nil
            // Keep scopes until the next share or view teardown.
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var presentedID: UUID?
        var picker: NSSharingServicePicker?
        var lifetimeToken: AnyObject?
    }
}
#elseif canImport(UIKit)
private struct CPSLActivityShareView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif
