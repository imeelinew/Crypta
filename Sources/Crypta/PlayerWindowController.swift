import AppKit
import AVKit

@MainActor
final class PlayerWindowController: NSObject, NSWindowDelegate {
    private let player = AVPlayer()
    private let temporaryURL: URL?
    private var window: NSWindow?

    init(title: String, url: URL, temporaryURL: URL?) {
        self.temporaryURL = temporaryURL
        super.init()

        let playerView = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
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
        window.delegate = self
        self.window = window
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        player.play()
    }

    func windowWillClose(_ notification: Notification) {
        player.pause()
        player.replaceCurrentItem(with: nil)
        if let temporaryURL {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
    }
}
