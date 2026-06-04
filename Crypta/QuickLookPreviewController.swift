import AppKit
import QuickLookUI

@MainActor
final class QuickLookPreviewController: NSObject {
    private var item: QuickLookPreviewItem?
    private var cleanupURL: URL?
    private var previewedVideoID: CryptaVideo.ID?
    private weak var panel: QLPreviewPanel?
    private var keyMonitor: Any?

    var isPresented: Bool {
        panel?.isVisible == true && item != nil
    }

    func isPreviewing(_ video: CryptaVideo) -> Bool {
        isPresented && previewedVideoID == video.id
    }

    func togglePreview(for video: CryptaVideo, thumbnail: NSImage) throws {
        if isPresented, previewedVideoID == video.id {
            close()
            return
        }

        try showPreview(for: video, thumbnail: thumbnail)
    }

    func close() {
        guard item != nil || cleanupURL != nil else { return }
        panel?.close()
        cleanupCurrentPreview()
        stopMonitoringSpaceKey()
        panel = nil
    }

    private func showPreview(for video: CryptaVideo, thumbnail: NSImage) throws {
        let previousCleanupURL = cleanupURL
        let previewURL = try writePreviewImage(thumbnail)
        item = QuickLookPreviewItem(url: previewURL, title: video.displayName)
        cleanupURL = previewURL
        previewedVideoID = video.id

        let previewPanel = QLPreviewPanel.shared()
        previewPanel?.dataSource = self
        previewPanel?.delegate = self
        previewPanel?.reloadData()
        previewPanel?.currentPreviewItemIndex = 0
        previewPanel?.makeKeyAndOrderFront(nil)
        panel = previewPanel
        startMonitoringSpaceKey()

        if let previousCleanupURL, previousCleanupURL != cleanupURL {
            cleanup(previousCleanupURL)
        }
    }

    private func writePreviewImage(_ image: NSImage) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CryptaQuickLook", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.92]) else {
            throw CryptaError.thumbnailFailed
        }

        let url = directory.appendingPathComponent("\(UUID().uuidString).jpg", isDirectory: false)
        try data.write(to: url, options: [.atomic])
        return url
    }

    private func cleanupCurrentPreview() {
        let url = cleanupURL
        item = nil
        cleanupURL = nil
        previewedVideoID = nil

        if let url {
            cleanup(url)
        }
    }

    private func cleanup(_ url: URL) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            try? FileManager.default.removeItem(at: url)
            let directory = url.deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    private func startMonitoringSpaceKey() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let shouldClose = MainActor.assumeIsolated {
                guard let self else { return false }
                return self.isSpaceKeyEvent(event) && self.isPresented
            }
            guard shouldClose else {
                return event
            }
            MainActor.assumeIsolated {
                self?.close()
            }
            return nil
        }
    }

    private func stopMonitoringSpaceKey() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func isSpaceKeyEvent(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        guard flags.isEmpty else { return false }
        return event.keyCode == 49 || event.charactersIgnoringModifiers == " "
    }
}

extension QuickLookPreviewController: @preconcurrency QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        item == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        item
    }

    func previewPanelWillClose(_ panel: QLPreviewPanel!) {
        cleanupCurrentPreview()
        stopMonitoringSpaceKey()
        self.panel = nil
    }
}

private final class QuickLookPreviewItem: NSObject, QLPreviewItem {
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(url: URL, title: String) {
        self.previewItemURL = url
        self.previewItemTitle = title
        super.init()
    }
}
