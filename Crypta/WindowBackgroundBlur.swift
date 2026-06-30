import AppKit
import SwiftUI

/// Bridge NSVisualEffectView into SwiftUI as a window-level frosted background.
struct WindowBackgroundBlur: NSViewRepresentable {
    var materialAlpha: Double
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        view.alphaValue = CGFloat(materialAlpha)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.alphaValue = CGFloat(max(0, min(1, materialAlpha)))
    }
}

struct WindowTransparencyConfigurator: NSViewRepresentable {
    var enabled: Bool

    func makeNSView(context: Context) -> NSView {
        Probe()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            guard let window = nsView?.window else { return }
            apply(to: window)
        }
    }

    private func apply(to window: NSWindow) {
        if enabled {
            window.isOpaque = false
            window.backgroundColor = .clear
            window.titlebarAppearsTransparent = true
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
            window.titlebarAppearsTransparent = false
        }
        window.invalidateShadow()
        window.contentView?.needsDisplay = true
    }

    private final class Probe: NSView {
        override var isOpaque: Bool { false }
        override func draw(_ dirtyRect: NSRect) {}
    }
}
