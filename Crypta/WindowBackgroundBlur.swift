import AppKit
import SwiftUI

/// Bridge NSVisualEffectView into SwiftUI as a window-level frosted background.
///
/// The important bit is `blendingMode = .behindWindow`: the material blurs the
/// desktop and windows behind Crypta, instead of blurring Crypta's own content.
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

/// Clears NSTableView / scroll view backgrounds so sidebar lists sit on window blur.
struct TransparentListBackgroundInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            view?.nearestTableView()?.applyTransparentListBackground()
        }
    }
}

/// Applies AppKit's native source-list style to SwiftUI sidebar lists.
struct SidebarSourceListStyleInstaller: NSViewRepresentable {
    var enabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view, enabled, coordinator = context.coordinator] in
            guard let tableView = view?.nearestTableView() else { return }
            coordinator.configure(tableView, enabled: enabled)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        private weak var tableView: NSTableView?
        private var enabled = false

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func configure(_ tableView: NSTableView, enabled: Bool) {
            if self.tableView !== tableView {
                removeObservers()
                self.tableView = tableView
                installObservers(for: tableView)
            }

            self.enabled = enabled
            refresh()
        }

        private func installObservers(for tableView: NSTableView) {
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(handleRefreshNotification),
                name: NSTableView.selectionDidChangeNotification,
                object: tableView
            )
            center.addObserver(
                self,
                selector: #selector(handleRefreshNotification),
                name: NSWindow.didBecomeKeyNotification,
                object: tableView.window
            )
            center.addObserver(
                self,
                selector: #selector(handleRefreshNotification),
                name: NSWindow.didResignKeyNotification,
                object: tableView.window
            )
            center.addObserver(
                self,
                selector: #selector(handleRefreshNotification),
                name: NSApplication.didBecomeActiveNotification,
                object: NSApp
            )
        }

        private func removeObservers() {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func handleRefreshNotification() {
            scheduleRefresh()
        }

        private func scheduleRefresh() {
            DispatchQueue.main.async { [weak self] in
                self?.refresh()
            }
        }

        private func refresh() {
            guard let tableView else { return }
            tableView.applySidebarSourceListStyle(enabled: enabled)
            tableView.applyVisibleRowEmphasis(isEmphasized: !enabled)
            DispatchQueue.main.async { [weak self] in
                guard let self, let tableView = self.tableView else { return }
                tableView.applyVisibleRowEmphasis(isEmphasized: !self.enabled)
            }
        }
    }
}

private extension NSView {
    func nearestTableView() -> NSTableView? {
        var candidate: NSView? = self
        while let view = candidate {
            if let tableView = view.firstDescendant(ofType: NSTableView.self) {
                return tableView
            }
            candidate = view.superview
        }
        return nil
    }

    func firstDescendant<T: NSView>(ofType type: T.Type) -> T? {
        if let typed = self as? T {
            return typed
        }

        for subview in subviews {
            if let typed = subview.firstDescendant(ofType: type) {
                return typed
            }
        }

        return nil
    }
}

private extension NSTableView {
    func applyTransparentListBackground() {
        backgroundColor = .clear
        enclosingScrollView?.drawsBackground = false
    }

    func applySidebarSourceListStyle(enabled: Bool) {
        if enabled {
            style = .sourceList
        } else {
            style = .automatic
            selectionHighlightStyle = .regular
        }
    }

    func applyVisibleRowEmphasis(isEmphasized: Bool) {
        let visibleRows = rows(in: visibleRect)
        guard visibleRows.location != NSNotFound else { return }

        for row in visibleRows.location..<(visibleRows.location + visibleRows.length) {
            guard let rowView = rowView(atRow: row, makeIfNecessary: false) else {
                continue
            }
            rowView.isEmphasized = isEmphasized
            rowView.needsDisplay = true
        }
    }
}
