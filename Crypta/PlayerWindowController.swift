import AppKit
import AVKit

private final class PlayerContentView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        if isInTitlebarDragRegion(point) {
            return self
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard isInTitlebarDragRegion(point), let window else {
            super.mouseDown(with: event)
            return
        }
        window.performDrag(with: event)
    }

    private func isInTitlebarDragRegion(_ point: NSPoint) -> Bool {
        guard let window else { return false }
        let contentLayoutRect = convert(window.contentLayoutRect, from: nil)
        return point.y >= contentLayoutRect.maxY
    }
}

private final class UnlockOverlayView: NSView {
    var onUnlock: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard super.hitTest(point) != nil else { return nil }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        onUnlock?()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 49, 76:
            onUnlock?()
        default:
            super.keyDown(with: event)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func accessibilityPerformPress() -> Bool {
        onUnlock?()
        return true
    }
}

@MainActor
final class PlayerWindowController: NSObject, NSGestureRecognizerDelegate, NSWindowDelegate {
    private var player: AVPlayer?
    private let title: String
    private var inMemoryPlaybackSource: InMemoryMediaPlaybackSource?
    private let startTimeSeconds: Double
    private let onProgress: @MainActor (Double) -> Void
    private let unlock: @MainActor () -> Void
    private let onFailure: @MainActor () -> Void
    private let onClose: @MainActor () -> Void
    private weak var playerView: AVPlayerView?
    private weak var privacyOverlay: NSView?
    private weak var windowDragRecognizer: NSPanGestureRecognizer?
    private var window: NSWindow?
    private var windowDragMouseDownEvent: NSEvent?
    private var keyMonitor: Any?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var shouldResumeAfterProtection = false
    private var isProtected = false
    private var didClose = false

    init(
        title: String,
        playerItem: AVPlayerItem,
        inMemoryPlaybackSource: InMemoryMediaPlaybackSource?,
        startTimeSeconds: Double,
        onProgress: @escaping @MainActor (Double) -> Void,
        unlock: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor () -> Void,
        onClose: @escaping @MainActor () -> Void
    ) {
        self.title = title
        self.inMemoryPlaybackSource = inMemoryPlaybackSource
        self.startTimeSeconds = startTimeSeconds
        self.onProgress = onProgress
        self.unlock = unlock
        self.onFailure = onFailure
        self.onClose = onClose
        super.init()

        let player = AVPlayer()
        player.volume = 0
        self.player = player
        let initialContentSize = Self.defaultContentSize

        let playerView = AVPlayerView(
            frame: NSRect(origin: .zero, size: initialContentSize)
        )
        playerView.player = player
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = true
        self.playerView = playerView

        let doubleClickGesture = NSClickGestureRecognizer(
            target: self,
            action: #selector(handleDoubleClick(_:))
        )
        doubleClickGesture.numberOfClicksRequired = 2
        playerView.addGestureRecognizer(doubleClickGesture)

        let windowDragRecognizer = NSPanGestureRecognizer(
            target: self,
            action: #selector(handleWindowDrag(_:))
        )
        windowDragRecognizer.delegate = self
        playerView.addGestureRecognizer(windowDragRecognizer)
        self.windowDragRecognizer = windowDragRecognizer

        player.replaceCurrentItem(with: playerItem)
        statusObservation = playerItem.observe(\.status, options: [.initial, .new]) {
            [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self, !didClose else { return }
                close()
                onFailure()
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                self?.reportProgress(time)
            }
        }

        let contentView = PlayerContentView(frame: playerView.frame)
        contentView.addSubview(playerView)
        playerView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])

        let privacyOverlay = makePrivacyOverlay()
        contentView.addSubview(privacyOverlay)
        privacyOverlay.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            privacyOverlay.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            privacyOverlay.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            privacyOverlay.topAnchor.constraint(equalTo: contentView.topAnchor),
            privacyOverlay.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        self.privacyOverlay = privacyOverlay

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.backgroundColor = .black
        window.contentView = contentView
        window.contentAspectRatio = initialContentSize
        window.center()
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        startMonitoringSeekKeys()
        scheduleContentAspectRatioUpdate()
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        guard startTimeSeconds > 1 else {
            player?.play()
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !didClose else { return }
            player?.seek(
                to: CMTime(seconds: startTimeSeconds, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.player?.play()
                }
            }
        }
    }

    func close() {
        window?.close()
    }

    func setProtected(_ isProtected: Bool) {
        self.isProtected = isProtected
        window?.title = isProtected ? "已锁定" : title
        privacyOverlay?.isHidden = !isProtected
        playerView?.controlsStyle = isProtected ? .none : .floating
        windowDragRecognizer?.isEnabled = !isProtected
        windowDragMouseDownEvent = nil
        if isProtected {
            window?.makeFirstResponder(privacyOverlay)
            shouldResumeAfterProtection = (player?.rate ?? 0) > 0
            player?.pause()
        } else {
            if window?.firstResponder === privacyOverlay {
                window?.makeFirstResponder(playerView)
            }
            if shouldResumeAfterProtection {
                shouldResumeAfterProtection = false
                player?.play()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        saveCurrentProgress()
        releasePlaybackResources()
        window?.delegate = nil
        window?.contentView = nil
        window = nil

        inMemoryPlaybackSource?.invalidate()
        inMemoryPlaybackSource = nil

        onClose()
    }

    private func releasePlaybackResources() {
        stopMonitoringSeekKeys()
        statusObservation?.invalidate()
        statusObservation = nil
        guard let player else { return }
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        let item = player.currentItem
        item?.cancelPendingSeeks()
        item?.asset.cancelLoading()
        player.pause()
        playerView?.player = nil
        player.replaceCurrentItem(with: nil)
        self.player = nil
    }

    private func makePrivacyOverlay() -> NSView {
        let overlay = UnlockOverlayView()
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        overlay.isHidden = true
        overlay.onUnlock = { [weak self] in
            self?.unlock()
        }
        overlay.setAccessibilityElement(true)
        overlay.setAccessibilityRole(.button)
        overlay.setAccessibilityLabel("解锁视频")
        overlay.setAccessibilityHelp("点击任意位置解锁")

        let lockedLabel = NSTextField(labelWithString: "已锁定")
        lockedLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        lockedLabel.textColor = .labelColor
        lockedLabel.translatesAutoresizingMaskIntoConstraints = false

        let unlockHint = NSTextField(labelWithString: "点击任意位置解锁")
        unlockHint.font = .systemFont(ofSize: 13)
        unlockHint.textColor = .secondaryLabelColor
        unlockHint.translatesAutoresizingMaskIntoConstraints = false

        let stackView = NSStackView(views: [lockedLabel, unlockHint])
        stackView.orientation = .vertical
        stackView.alignment = .centerX
        stackView.spacing = 10
        stackView.translatesAutoresizingMaskIntoConstraints = false

        overlay.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stackView.centerYAnchor.constraint(equalTo: overlay.centerYAnchor)
        ])
        return overlay
    }

    @objc private func handleDoubleClick(_ sender: NSClickGestureRecognizer) {
        window?.toggleFullScreen(nil)
    }

    func gestureRecognizer(
        _ gestureRecognizer: NSGestureRecognizer,
        shouldAttemptToRecognizeWith event: NSEvent
    ) -> Bool {
        guard gestureRecognizer === windowDragRecognizer,
              !isProtected,
              event.type == .leftMouseDown,
              canStartWindowDrag(at: event) else {
            windowDragMouseDownEvent = nil
            return false
        }
        windowDragMouseDownEvent = event
        return true
    }

    @objc private func handleWindowDrag(_ sender: NSPanGestureRecognizer) {
        guard sender.state == .began,
              let event = windowDragMouseDownEvent,
              let window else {
            return
        }
        windowDragMouseDownEvent = nil
        window.performDrag(with: event)

        sender.isEnabled = false
        sender.isEnabled = !isProtected
    }

    private func canStartWindowDrag(at event: NSEvent) -> Bool {
        guard let playerView else { return false }
        let point = playerView.convert(event.locationInWindow, from: nil)
        guard let hitView = playerView.hitTest(point) else { return false }
        guard hitView !== playerView else { return true }

        var candidate: NSView? = hitView
        while let view = candidate, view !== playerView {
            if view is NSControl || isCompactPlaybackControlContainer(view, in: playerView) {
                return false
            }
            candidate = view.superview
        }
        return true
    }

    private func isCompactPlaybackControlContainer(_ view: NSView, in playerView: AVPlayerView) -> Bool {
        let frame = view.convert(view.bounds, to: playerView)
        let playerArea = playerView.bounds.width * playerView.bounds.height
        let viewArea = frame.width * frame.height
        guard playerArea > 0, viewArea < playerArea * 0.75 else {
            return false
        }
        return containsInteractiveControl(view)
    }

    private func containsInteractiveControl(_ view: NSView) -> Bool {
        if view is NSControl {
            return true
        }
        return view.subviews.contains(where: containsInteractiveControl)
    }

    private func startMonitoringSeekKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let direction = MainActor.assumeIsolated {
                self?.seekDirection(for: event)
            }
            guard let direction else {
                return event
            }
            MainActor.assumeIsolated {
                self?.seek(by: direction * Self.seekIntervalSeconds)
            }
            return nil
        }
    }

    private func stopMonitoringSeekKeys() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func seekDirection(for event: NSEvent) -> Double? {
        guard event.window === window, !isProtected else { return nil }
        let blockedModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard event.modifierFlags.intersection(blockedModifiers).isEmpty else { return nil }
        switch event.keyCode {
        case Self.leftArrowKeyCode:
            return -1
        case Self.rightArrowKeyCode:
            return 1
        default:
            return nil
        }
    }

    private func seek(by offsetSeconds: Double) {
        guard let player else { return }
        let currentSeconds = player.currentTime().seconds
        guard currentSeconds.isFinite else { return }

        let durationSeconds = player.currentItem?.duration.seconds
        let upperBound = durationSeconds?.isFinite == true ? max(durationSeconds ?? 0, 0) : .infinity
        let targetSeconds = min(max(currentSeconds + offsetSeconds, 0), upperBound)
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(
            to: targetTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reportProgress(targetTime)
            }
        }
    }

    private func reportProgress(_ time: CMTime) {
        guard time.seconds.isFinite, time.seconds >= 0 else { return }
        onProgress(time.seconds)
    }

    private func saveCurrentProgress() {
        guard let player else { return }
        reportProgress(player.currentTime())
    }

    private func scheduleContentAspectRatioUpdate() {
        Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !didClose else { return }
                if applyContentAspectRatioIfAvailable() {
                    return
                }
            }
        }
    }

    private func applyContentAspectRatioIfAvailable() -> Bool {
        guard let presentationSize = player?.currentItem?.presentationSize,
              presentationSize.width > 0,
              presentationSize.height > 0 else {
            return false
        }
        let contentSize = Self.contentSize(for: presentationSize)
        window?.contentAspectRatio = contentSize
        window?.setContentSize(contentSize)
        window?.center()
        return true
    }

    private static var defaultContentSize: NSSize {
        NSSize(width: 960, height: 540)
    }

    private static let seekIntervalSeconds: Double = 10
    private static let leftArrowKeyCode: UInt16 = 123
    private static let rightArrowKeyCode: UInt16 = 124

    private static func contentSize(for videoSize: NSSize) -> NSSize {
        let fallbackSize = defaultContentSize

        let ratio = videoSize.width / videoSize.height
        guard ratio.isFinite, ratio > 0 else { return fallbackSize }

        let maximumSize = fallbackSize
        if ratio >= maximumSize.width / maximumSize.height {
            return NSSize(width: maximumSize.width, height: maximumSize.width / ratio)
        }
        return NSSize(width: maximumSize.height * ratio, height: maximumSize.height)
    }
}
