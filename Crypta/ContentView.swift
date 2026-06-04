import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Bindable var library: CryptaLibrary
    @State private var importerPresented = false
    @State private var dropIsTargeted = false
    private let deleteTint = Color(red: 0.72, green: 0.20, blue: 0.24)

    var body: some View {
        NavigationSplitView {
            SidebarView(library: library)
        } detail: {
            VideoListPage(library: library)
        }
        .toolbar {
            ToolbarSpacer(.flexible)

            ToolbarItem {
                Button {
                    Task { await transformSelectedVideo() }
                } label: {
                    Label(transformTitle, systemImage: transformSystemImage)
                }
                .disabled(!library.canActOnSelection)
                .help(transformTitle)
            }

            ToolbarSpacer(.fixed)

            ToolbarItemGroup {
                Button {
                    importerPresented = true
                } label: {
                    Label("导入视频", systemImage: "plus")
                }
                .disabled(library.isImporting || library.isWorking)

                Button {
                    Task { await library.playSelectedVideo() }
                } label: {
                    Label("播放", systemImage: "play.fill")
                }
                .disabled(!library.canActOnSelection)
            }

            ToolbarSpacer(.fixed)

            ToolbarItem {
                Button {
                    library.confirmDeleteSelectedVideo()
                } label: {
                    Label("删除", systemImage: "trash")
                        .foregroundStyle(deleteTint)
                }
                .tint(deleteTint)
                .disabled(!library.canActOnSelection)
                .help("删除选中的视频")
            }
        }
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .fileImporter(
            isPresented: $importerPresented,
            allowedContentTypes: [.movie, .video, .mpeg4Movie, .quickTimeMovie],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                Task { await library.importVideos(from: urls) }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await library.importVideos(from: urls) }
            return true
        } isTargeted: {
            dropIsTargeted = $0
        }
        .overlay {
            if dropIsTargeted {
                RoundedRectangle(cornerRadius: 18)
                    .stroke(.tint, lineWidth: 3)
                    .padding(18)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .top) {
            toastView
        }
        .background {
            WindowTransparencyConfigurator(enabled: true)
                .frame(width: 0, height: 0)
            WindowBackgroundBlur(materialAlpha: 1.0)
                .ignoresSafeArea()
            MainWindowCloseObserver {
                library.resetEncryptedSectionAccess()
            }
            .frame(width: 0, height: 0)
            AppFocusObserver {
                library.lockEncryptedSectionAccess()
            }
            .frame(width: 0, height: 0)
        }
        .task(id: library.toast) {
            guard let currentToast = library.toast else { return }
            try? await Task.sleep(for: .seconds(2))
            await MainActor.run {
                guard library.toast == currentToast else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    library.toast = nil
                }
            }
        }
        .sheet(item: $library.renameRequest) { request in
            RenameVideoSheet(request: request) { newName in
                Task { await library.rename(request, to: newName) }
            }
        }
        .alert("删除视频？", isPresented: deleteAlertBinding, presenting: library.deleteRequest) { video in
            Button("取消", role: .cancel) {
                library.deleteRequest = nil
            }
            Button("删除", role: .destructive) {
                Task { await library.delete(video) }
            }
        } message: { video in
            let message = "将从 Crypta 中删除“\(video.displayName)”。"
            Text(message)
        }
        .alert("出错了", isPresented: errorAlertBinding, presenting: library.errorMessage) { _ in
            Button("好") {
                library.errorMessage = nil
            }
        } message: { message in
            Text(message)
        }
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { library.deleteRequest != nil },
            set: { if !$0 { library.deleteRequest = nil } }
        )
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = library.toast {
            Label(toast.message, systemImage: toast.systemImage)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(toast.foregroundStyle)
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .glassEffect(.regular, in: Capsule())
                .shadow(color: .black.opacity(0.16), radius: 18, y: 8)
                .padding(.top, 12)
                .transition(.blurReplace)
                .allowsHitTesting(false)
                .accessibilityAddTraits(.isStaticText)
        }
    }

    private var transformTitle: String {
        "解密"
    }

    private var transformSystemImage: String {
        "lock.open.fill"
    }

    private func transformSelectedVideo() async {
        guard let video = library.selectedVideo else { return }
        await library.decrypt(video)
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )
    }
}

private extension CryptaToast {
    var foregroundStyle: Color {
        switch kind {
        case .success: return .primary
        case .error: return Color(red: 0.82, green: 0.18, blue: 0.18)
        }
    }
}

private struct AppFocusObserver: NSViewRepresentable {
    let onResignActive: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onResignActive: onResignActive)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.startObserving()
        return NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onResignActive = onResignActive
        context.coordinator.startObserving()
    }

    @MainActor
    final class Coordinator: NSObject {
        var onResignActive: () -> Void
        private var isObserving = false

        init(onResignActive: @escaping () -> Void) {
            self.onResignActive = onResignActive
            super.init()
        }

        func startObserving() {
            guard !isObserving else { return }
            isObserving = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(appDidResignActive(_:)),
                name: NSApplication.didResignActiveNotification,
                object: NSApp
            )
        }

        @objc private func appDidResignActive(_ notification: Notification) {
            onResignActive()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

private struct MainWindowCloseObserver: NSViewRepresentable {
    let onClose: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onClose: onClose)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onClose = onClose
        DispatchQueue.main.async {
            context.coordinator.attach(to: view.window)
        }
    }

    @MainActor
    final class Coordinator: NSObject {
        var onClose: () -> Void
        private weak var observedWindow: NSWindow?

        init(onClose: @escaping () -> Void) {
            self.onClose = onClose
            super.init()
        }

        func attach(to window: NSWindow?) {
            guard let window, observedWindow !== window else { return }
            if let observedWindow {
                NotificationCenter.default.removeObserver(
                    self,
                    name: NSWindow.willCloseNotification,
                    object: observedWindow
                )
            }
            observedWindow = window
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(windowWillClose(_:)),
                name: NSWindow.willCloseNotification,
                object: window
            )
        }

        @objc private func windowWillClose(_ notification: Notification) {
            onClose()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}
