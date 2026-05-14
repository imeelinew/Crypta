import AppKit
import AVKit

@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    private let player = AVPlayer()
    private let cleanupURL: URL?
    private let onClose: @MainActor () -> Void
    private weak var playerView: AVPlayerView?
    private var window: NSWindow?
    private var didClose = false

    init(title: String, url: URL, cleanupURL: URL?, onClose: @escaping @MainActor () -> Void) {
        self.cleanupURL = cleanupURL
        self.onClose = onClose
        super.init()

        let playerView = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        self.playerView = playerView
        player.replaceCurrentItem(with: AVPlayerItem(url: url))

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.contentView = playerView
        window.center()
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        player.play()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        player.pause()
        playerView?.player = nil
        player.replaceCurrentItem(with: nil)
        window?.delegate = nil
        window = nil

        if let cleanupURL {
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }

        onClose()
    }
}
