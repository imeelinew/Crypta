import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var library: CryptaLibrary

    var body: some View {
        List(selection: sectionSelection) {
            ForEach(LibrarySection.allCases) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
                .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Crypta")
        .navigationSplitViewColumnWidth(min: 150, ideal: 180)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .background(TransparentListBackgroundInstaller())
    }

    private var sectionSelection: Binding<LibrarySection?> {
        Binding(
            get: { library.selectedSection },
            set: { nextSection in
                guard let nextSection else { return }
                Task { await library.selectSection(nextSection) }
            }
        )
    }
}

struct VideoListPage: View {
    @Bindable var library: CryptaLibrary

    var body: some View {
        Group {
            if !library.canAccessSelectedSection {
                LockedEncryptedSectionView(
                    section: library.selectedSection,
                    isAuthenticating: library.isAuthenticatingEncryptedSection
                ) {
                    Task { await library.unlockEncryptedSection() }
                }
            } else {
                VStack(spacing: 0) {
                    VideoListHeader(
                        sortMode: $library.sortMode,
                        summary: library.visibleVideoSummary
                    )

                    if library.visibleVideos.isEmpty {
                        ContentUnavailableView {
                            Label(emptyTitle, systemImage: library.selectedSection.systemImage)
                        } description: {
                            Text(emptyDescription)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.clear)
                    } else {
                        List(selection: $library.selectedVideoIDs) {
                            ForEach(library.visibleVideos) { video in
                                VideoRow(video: video)
                                    .tag(video.id)
                                    .listRowBackground(Color.clear)
                                    .contextMenu {
                                        Button("重命名") {
                                            library.requestRename(video)
                                        }
                                    }
                            }
                        }
                        .listStyle(.inset)
                        .scrollContentBackground(.hidden)
                        .background {
                            Color.clear
                            VideoListInteractionInstaller(
                                videos: library.visibleVideos,
                                onDoubleClick: { video in
                                    library.selectOnly(video)
                                    Task { await library.play(video) }
                                },
                                onSpacePreview: {
                                    Task { await library.previewSelectedVideo() }
                                },
                                onSelectAll: {
                                    library.selectAllVisibleVideos()
                                }
                            )
                        }
                    }
                }
            }
        }
        .navigationTitle(library.selectedSection.title)
        .searchable(text: $library.searchText, placement: .toolbar, prompt: "搜索\(library.selectedSection.itemNoun)")
    }

    private var emptyTitle: String {
        switch library.selectedSection {
        case .video: return "无视频"
        case .encrypted: return "无加密视频"
        case .encryptedImage: return "无加密图片"
        }
    }

    private var emptyDescription: String {
        switch library.selectedSection {
        case .video: return "拖拽以导入视频"
        case .encrypted: return "拖拽以导入加密视频"
        case .encryptedImage: return "拖拽以导入加密图片"
        }
    }
}

private struct VideoListHeader: View {
    @Binding var sortMode: VideoSortMode
    let summary: String

    var body: some View {
        HStack(spacing: 10) {
            VideoSortPopup(sortMode: $sortMode)
                .frame(width: 118, height: 24)

            Text(summary)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 8)
    }
}

private struct VideoSortPopup: NSViewRepresentable {
    @Binding var sortMode: VideoSortMode

    func makeCoordinator() -> Coordinator {
        Coordinator(sortMode: $sortMode)
    }

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changeSortMode(_:))
        if let cell = button.cell as? NSPopUpButtonCell {
            cell.alignment = .left
        }
        for mode in VideoSortMode.allCases {
            button.addItem(withTitle: mode.title)
            button.lastItem?.representedObject = mode.rawValue
        }
        button.selectItem(withTitle: sortMode.title)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.sortMode = $sortMode
        if button.selectedItem?.representedObject as? String != sortMode.rawValue {
            button.selectItem(withTitle: sortMode.title)
        }
    }

    final class Coordinator: NSObject {
        var sortMode: Binding<VideoSortMode>

        init(sortMode: Binding<VideoSortMode>) {
            self.sortMode = sortMode
        }

        @objc func changeSortMode(_ sender: NSPopUpButton) {
            guard let rawValue = sender.selectedItem?.representedObject as? String,
                  let nextMode = VideoSortMode(rawValue: rawValue) else {
                return
            }
            sortMode.wrappedValue = nextMode
        }
    }
}

private struct LockedEncryptedSectionView: View {
    let section: LibrarySection
    let isAuthenticating: Bool
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: section.systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("已加密")
                .font(.title3.weight(.semibold))

            Button(isAuthenticating ? "正在验证" : "解锁\(section.itemNoun)") {
                unlock()
            }
            .disabled(isAuthenticating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }
}

private struct VideoListInteractionInstaller: NSViewRepresentable {
    let videos: [CryptaVideo]
    let onDoubleClick: (CryptaVideo) -> Void
    let onSpacePreview: () -> Void
    let onSelectAll: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            videos: videos,
            onDoubleClick: onDoubleClick,
            onSpacePreview: onSpacePreview,
            onSelectAll: onSelectAll
        )
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            context.coordinator.attach(from: view)
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.videos = videos
        context.coordinator.onDoubleClick = onDoubleClick
        context.coordinator.onSpacePreview = onSpacePreview
        context.coordinator.onSelectAll = onSelectAll
        DispatchQueue.main.async {
            context.coordinator.attach(from: view)
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.stopMonitoringSpaceKey()
    }

    @MainActor
    final class Coordinator: NSObject {
        var videos: [CryptaVideo]
        var onDoubleClick: (CryptaVideo) -> Void
        var onSpacePreview: () -> Void
        var onSelectAll: () -> Void
        private weak var tableView: NSTableView?
        private var keyMonitor: Any?

        init(
            videos: [CryptaVideo],
            onDoubleClick: @escaping (CryptaVideo) -> Void,
            onSpacePreview: @escaping () -> Void,
            onSelectAll: @escaping () -> Void
        ) {
            self.videos = videos
            self.onDoubleClick = onDoubleClick
            self.onSpacePreview = onSpacePreview
            self.onSelectAll = onSelectAll
            super.init()
        }

        func attach(from view: NSView) {
            guard let tableView = view.nearestTableView() else { return }
            guard self.tableView !== tableView else {
                startMonitoringSpaceKey()
                return
            }
            self.tableView = tableView
            tableView.applyTransparentListBackground()
            tableView.allowsMultipleSelection = true
            tableView.target = self
            tableView.doubleAction = #selector(handleDoubleClick(_:))
            startMonitoringSpaceKey()
        }

        @objc private func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard videos.indices.contains(row) else { return }
            onDoubleClick(videos[row])
        }

        private func startMonitoringSpaceKey() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let shouldHandle = MainActor.assumeIsolated {
                    guard let self else { return false }
                    return self.shouldHandleSpaceKey(event)
                }
                guard shouldHandle else {
                    return event
                }
                MainActor.assumeIsolated {
                    self?.handleKeyEvent(event)
                }
                return nil
            }
        }

        private func shouldHandleSpaceKey(_ event: NSEvent) -> Bool {
            guard isSpaceKeyEvent(event) || isSelectAllEvent(event), let tableView, event.window === tableView.window else {
                return false
            }
            guard tableView.window?.firstResponder is NSTextView == false else {
                return false
            }
            return isSelectAllEvent(event) || tableView.selectedRow >= 0
        }

        private func handleKeyEvent(_ event: NSEvent) {
            if isSelectAllEvent(event) {
                onSelectAll()
            } else {
                onSpacePreview()
            }
        }

        private func isSpaceKeyEvent(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            guard flags.isEmpty else { return false }
            return event.keyCode == 49 || event.charactersIgnoringModifiers == " "
        }

        private func isSelectAllEvent(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting(.capsLock)
            return flags == .command && event.charactersIgnoringModifiers?.lowercased() == "a"
        }

        func stopMonitoringSpaceKey() {
            if let keyMonitor {
                NSEvent.removeMonitor(keyMonitor)
                self.keyMonitor = nil
            }
        }
    }
}

private struct TransparentListBackgroundInstaller: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            view?.nearestTableView()?.applyTransparentListBackground()
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
}

struct VideoRow: View {
    let video: CryptaVideo
    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 12) {
            ThumbnailView(video: video, thumbnail: thumbnail)

            VStack(alignment: .leading, spacing: 3) {
                Text(video.displayName)
                    .lineLimit(1)
                Text(video.detailLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.vertical, 5)
        .onAppear {
            thumbnail = VideoThumbnailLoader.cachedThumbnail(for: video)
        }
        .task(id: video.id) {
            if let cachedThumbnail = VideoThumbnailLoader.cachedThumbnail(for: video) {
                thumbnail = cachedThumbnail
                return
            }
            thumbnail = await VideoThumbnailLoader.thumbnail(for: video)
        }
    }
}

struct ThumbnailView: View {
    let video: CryptaVideo
    let thumbnail: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.12))

            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 64, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: placeholderSystemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(video.libraryKind == .video ? Color.secondary : Color.accentColor)
            }
        }
        .frame(width: 64, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var placeholderSystemImage: String {
        if video.isImage {
            return "photo.fill"
        }
        return video.libraryKind == .video ? "video.fill" : "lock.fill"
    }
}

struct RenameVideoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    let request: RenameRequest
    let onSave: (String) -> Void

    init(request: RenameRequest, onSave: @escaping (String) -> Void) {
        self.request = request
        self.onSave = onSave
        self._name = State(initialValue: request.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("重命名")
                .font(.title3.weight(.semibold))

            TextField("名称", text: $name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 360)

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button("保存") {
                    onSave(name)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
    }
}
