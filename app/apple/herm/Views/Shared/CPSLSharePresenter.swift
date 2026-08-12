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
            .task { await CPSLShareInfrastructure.prewarmIfNeeded() }
#elseif canImport(UIKit)
        // Present from a host VC (same idea as macOS). Embedding UIActivityViewController
        // as a SwiftUI sheet root freezes on first presentation in Debug while frameworks load.
        background(CPSLActivitySharePresenter(file: file))
            .task { await CPSLShareInfrastructure.prewarmIfNeeded() }
#else
        self
#endif
    }
}

/// Cold-loads OS sharing once per process so the first user-facing Share isn't a ~0.5s hitch.
@MainActor
private enum CPSLShareInfrastructure {
    private static var didSchedule = false
    private static var didPrewarm = false

    static func prewarmIfNeeded() async {
        guard !didPrewarm, !didSchedule else {
            return
        }
        didSchedule = true
        // Let the hosting view finish its first layout / open animation.
        await Task.yield()
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !didPrewarm else {
            return
        }

        let url = prewarmFileURL()
#if os(macOS)
        _ = NSSharingService.sharingServices(forItems: [url])
#elseif canImport(UIKit)
        // Force dyld + first-time activity discovery off the Share tap path.
        _ = UIActivityViewController(activityItems: [url], applicationActivities: nil)
#endif
        didPrewarm = true
    }

    private static func prewarmFileURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("herm-share-prewarm.txt", isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            try? Data("herm-share-prewarm".utf8).write(to: url, options: .atomic)
        }
        return url
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
/// Host VC that presents `UIActivityViewController` modally (not as a SwiftUI sheet root).
private struct CPSLActivitySharePresenter: UIViewControllerRepresentable {
    @Binding var file: CPSLShareableFile?

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        guard let file else {
            return
        }
        guard context.coordinator.presentedID != file.id else {
            return
        }
        guard uiViewController.presentedViewController == nil else {
            return
        }

        context.coordinator.presentedID = file.id
        context.coordinator.lifetimeToken = file.lifetimeToken
        let items: [Any] = [file.url]
        let fileBinding = $file

        DispatchQueue.main.async {
            guard uiViewController.view.window != nil else {
                fileBinding.wrappedValue = nil
                context.coordinator.lifetimeToken = nil
                return
            }
            guard uiViewController.presentedViewController == nil else {
                return
            }

            let activity = UIActivityViewController(
                activityItems: items,
                applicationActivities: nil
            )
            activity.completionWithItemsHandler = { _, _, _, _ in
                fileBinding.wrappedValue = nil
                context.coordinator.lifetimeToken = nil
            }
            if let popover = activity.popoverPresentationController {
                popover.sourceView = uiViewController.view
                popover.sourceRect = CGRect(
                    x: uiViewController.view.bounds.midX,
                    y: uiViewController.view.bounds.midY,
                    width: 0,
                    height: 0
                )
                popover.permittedArrowDirections = []
            }
            uiViewController.present(activity, animated: true)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var presentedID: UUID?
        var lifetimeToken: AnyObject?
    }
}
#endif
