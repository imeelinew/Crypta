import AppKit

@MainActor
final class ProtectedImageWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var imageView: NSImageView?
    private var representedObjectID: UUID?
    private var onClose: (() -> Void)?

    func isShowing(objectID: UUID) -> Bool {
        window?.isVisible == true && representedObjectID == objectID
    }

    func toggle(
        image: NSImage,
        title: String,
        objectID: UUID,
        onClose: @escaping () -> Void
    ) {
        if isShowing(objectID: objectID) {
            close()
            return
        }
        show(
            image: image,
            title: title,
            objectID: objectID,
            onClose: onClose
        )
    }

    func show(
        image: NSImage,
        title: String,
        objectID: UUID,
        onClose: @escaping () -> Void
    ) {
        close()

        let imageView = NSImageView()
        imageView.image = image
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(origin: .zero, size: image.size)
        imageView.autoresizingMask = []
        self.imageView = imageView

        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .black
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 8
        scrollView.documentView = imageView

        let initialSize = Self.initialWindowSize(for: image.size)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [
                .titled,
                .closable,
                .miniaturizable,
                .resizable,
                .fullSizeContentView
            ],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .black
        window.contentView = scrollView
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        representedObjectID = objectID
        self.onClose = onClose
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        DispatchQueue.main.async {
            let contentSize = scrollView.contentSize
            let scale = min(
                1,
                contentSize.width / max(1, image.size.width),
                contentSize.height / max(1, image.size.height)
            )
            scrollView.setMagnification(
                max(scrollView.minMagnification, scale),
                centeredAt: NSPoint(
                    x: image.size.width / 2,
                    y: image.size.height / 2
                )
            )
        }
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        imageView?.image = nil
        window?.delegate = nil
        window?.contentView = nil
        window = nil
        imageView = nil
        representedObjectID = nil
        let callback = onClose
        onClose = nil
        callback?()
    }

    private static func initialWindowSize(for imageSize: NSSize) -> NSSize {
        let fallback = NSSize(width: 960, height: 640)
        guard imageSize.width > 0, imageSize.height > 0 else {
            return fallback
        }
        let maximum = NSSize(width: 1_200, height: 820)
        let minimum = NSSize(width: 520, height: 360)
        let scale = min(
            1,
            maximum.width / imageSize.width,
            maximum.height / imageSize.height
        )
        return NSSize(
            width: max(minimum.width, imageSize.width * scale),
            height: max(minimum.height, imageSize.height * scale)
        )
    }
}
