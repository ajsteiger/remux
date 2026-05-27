import QuickLook
import SwiftUI

struct GhosttyAttachmentQuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        if context.coordinator.update(url: url) {
            controller.reloadData()
        }
    }

    static func dismantleUIViewController(
        _ controller: QLPreviewController,
        coordinator: Coordinator
    ) {
        coordinator.stopAccessing()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        private var url: URL
        private var accessedURL: URL?

        init(url: URL) {
            self.url = url
            super.init()
            startAccessing(url)
        }

        func update(url: URL) -> Bool {
            guard self.url != url else { return false }
            stopAccessing()
            self.url = url
            startAccessing(url)
            return true
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            1
        }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> QLPreviewItem {
            url as NSURL
        }

        private func startAccessing(_ url: URL) {
            if url.startAccessingSecurityScopedResource() {
                accessedURL = url
            }
        }

        func stopAccessing() {
            accessedURL?.stopAccessingSecurityScopedResource()
            accessedURL = nil
        }
    }
}
