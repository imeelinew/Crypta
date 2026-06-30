import AppKit
import SwiftUI

struct SidebarView: View {
    @Bindable var library: CryptaLibrary

    var body: some View {
        AppKitSidebarList(
            groups: library.groups,
            selectedGroupID: library.selectedGroupID,
            isGroupUnlocked: { library.isGroupUnlocked($0) },
            canManuallyLock: { library.canManuallyLock($0) },
            canDeleteGroup: { library.canDeleteGroup($0) },
            onSelectGroup: { group in
                Task { await library.selectGroup(group) }
            },
            onMove: { source, destination in
                library.moveGroups(from: source, to: destination)
            },
            onLock: { library.manuallyLock($0) },
            onRename: { library.requestEditGroup($0) },
            onDelete: { group in
                Task { await library.deleteGroup(group) }
            }
        )
        .navigationTitle("Crypta")
        .navigationSplitViewColumnWidth(min: 150, ideal: 180)
    }
}

struct VideoListPage: View {
    @Bindable var library: CryptaLibrary

    var body: some View {
        Group {
            if library.groups.isEmpty {
                ContentUnavailableView {
                    Label("无保险箱", systemImage: "folder.badge.plus")
                } description: {
                    Text("新建一个保险箱来开始")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
            } else if let group = library.selectedGroup {
                if !library.canAccessSelectedGroup {
                    LockedEncryptedSectionView(
                        group: group,
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
                                Label("无\(group.itemNoun)", systemImage: group.systemImage)
                            } description: {
                                Text("拖拽以导入\(group.itemNoun)")
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(Color.clear)
                        } else {
                            AppKitVideoList(
                                videos: library.visibleVideos,
                                selectedVideoIDs: library.selectedVideoIDs,
                                subtitleJob: library.subtitleJob,
                                canGenerateSubtitles: { library.canGenerateSubtitles(for: $0) },
                                subtitleActionTitle: { library.subtitleActionTitle(for: $0) },
                                onSelectionChange: { ids, primaryID in
                                    library.selectVideoIDs(ids, primaryID: primaryID)
                                },
                                onDoubleClick: { video in
                                    library.selectOnly(video)
                                    Task { await library.play(video) }
                                },
                                onSpacePreview: {
                                    Task { await library.previewSelectedVideo() }
                                },
                                onSelectAll: {
                                    library.selectAllVisibleVideos()
                                },
                                onGenerateSubtitles: { video in
                                    library.requestGenerateSubtitles(video)
                                },
                                onRename: { video in
                                    library.requestRename(video)
                                },
                                onDelete: { video in
                                    library.confirmDeleteVideo(video)
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
            } else {
                ContentUnavailableView {
                    Label("选择保险箱", systemImage: "folder")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.clear)
            }
        }
        .navigationTitle(library.selectedGroup?.name ?? "Crypta")
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
    let group: LibraryGroup
    let isAuthenticating: Bool
    let unlock: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: group.systemImage)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("已加密")
                .font(.title3.weight(.semibold))

            Button(buttonTitle) {
                unlock()
            }
            .disabled(isAuthenticating)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
    }

    private var buttonTitle: String {
        if isAuthenticating {
            return "正在验证"
        }
        return "解锁\(group.itemNoun)"
    }
}

private struct AppKitVideoList: NSViewRepresentable {
    let videos: [CryptaVideo]
    let selectedVideoIDs: Set<CryptaVideo.ID>
    let subtitleJob: SubtitleJobProgress?
    let canGenerateSubtitles: (CryptaVideo) -> Bool
    let subtitleActionTitle: (CryptaVideo) -> String
    let onSelectionChange: (Set<CryptaVideo.ID>, CryptaVideo.ID?) -> Void
    let onDoubleClick: (CryptaVideo) -> Void
    let onSpacePreview: () -> Void
    let onSelectAll: () -> Void
    let onGenerateSubtitles: (CryptaVideo) -> Void
    let onRename: (CryptaVideo) -> Void
    let onDelete: (CryptaVideo) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            videos: videos,
            selectedVideoIDs: selectedVideoIDs,
            subtitleJob: subtitleJob,
            canGenerateSubtitles: canGenerateSubtitles,
            subtitleActionTitle: subtitleActionTitle,
            onSelectionChange: onSelectionChange,
            onDoubleClick: onDoubleClick,
            onSpacePreview: onSpacePreview,
            onSelectAll: onSelectAll,
            onGenerateSubtitles: onGenerateSubtitles,
            onRename: onRename,
            onDelete: onDelete
        )
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(
            videos: videos,
            selectedVideoIDs: selectedVideoIDs,
            subtitleJob: subtitleJob,
            canGenerateSubtitles: canGenerateSubtitles,
            subtitleActionTitle: subtitleActionTitle,
            onSelectionChange: onSelectionChange,
            onDoubleClick: onDoubleClick,
            onSpacePreview: onSpacePreview,
            onSelectAll: onSelectAll,
            onGenerateSubtitles: onGenerateSubtitles,
            onRename: onRename,
            onDelete: onDelete
        )
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, VideoTableViewActionDelegate, HoverTableViewDelegate {
        var videos: [CryptaVideo]
        var selectedVideoIDs: Set<CryptaVideo.ID>
        var subtitleJob: SubtitleJobProgress?
        var canGenerateSubtitles: (CryptaVideo) -> Bool
        var subtitleActionTitle: (CryptaVideo) -> String
        var onSelectionChange: (Set<CryptaVideo.ID>, CryptaVideo.ID?) -> Void
        var onDoubleClick: (CryptaVideo) -> Void
        var onSpacePreview: () -> Void
        var onSelectAll: () -> Void
        var onGenerateSubtitles: (CryptaVideo) -> Void
        var onRename: (CryptaVideo) -> Void
        var onDelete: (CryptaVideo) -> Void
        private weak var scrollView: NSScrollView?
        private weak var tableView: VideoTableView?
        private var isSyncingSelection = false
        private var hoveredRow: Int = -1

        init(
            videos: [CryptaVideo],
            selectedVideoIDs: Set<CryptaVideo.ID>,
            subtitleJob: SubtitleJobProgress?,
            canGenerateSubtitles: @escaping (CryptaVideo) -> Bool,
            subtitleActionTitle: @escaping (CryptaVideo) -> String,
            onSelectionChange: @escaping (Set<CryptaVideo.ID>, CryptaVideo.ID?) -> Void,
            onDoubleClick: @escaping (CryptaVideo) -> Void,
            onSpacePreview: @escaping () -> Void,
            onSelectAll: @escaping () -> Void,
            onGenerateSubtitles: @escaping (CryptaVideo) -> Void,
            onRename: @escaping (CryptaVideo) -> Void,
            onDelete: @escaping (CryptaVideo) -> Void
        ) {
            self.videos = videos
            self.selectedVideoIDs = selectedVideoIDs
            self.subtitleJob = subtitleJob
            self.canGenerateSubtitles = canGenerateSubtitles
            self.subtitleActionTitle = subtitleActionTitle
            self.onSelectionChange = onSelectionChange
            self.onDoubleClick = onDoubleClick
            self.onSpacePreview = onSpacePreview
            self.onSelectAll = onSelectAll
            self.onGenerateSubtitles = onGenerateSubtitles
            self.onRename = onRename
            self.onDelete = onDelete
            super.init()
        }

        func makeScrollView() -> NSScrollView {
            let scrollView = NSScrollView()
            scrollView.drawsBackground = false
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = false
            scrollView.autohidesScrollers = true

            let tableView = VideoTableView()
            self.scrollView = scrollView
            self.tableView = tableView
            tableView.actionDelegate = self
            tableView.hoverDelegate = self
            tableView.delegate = self
            tableView.dataSource = self
            tableView.headerView = nil
            tableView.backgroundColor = .clear
            tableView.selectionHighlightStyle = .regular
            tableView.rowHeight = 58
            tableView.intercellSpacing = NSSize(width: 0, height: 0)
            tableView.allowsMultipleSelection = true
            tableView.allowsEmptySelection = true
            tableView.target = self
            tableView.doubleAction = #selector(handleDoubleClick(_:))

            let column = NSTableColumn(identifier: .videoListMainColumn)
            column.resizingMask = .autoresizingMask
            tableView.addTableColumn(column)

            scrollView.documentView = tableView
            installScrollObserver()
            syncSelection(in: tableView)
            return scrollView
        }

        func update(
            videos: [CryptaVideo],
            selectedVideoIDs: Set<CryptaVideo.ID>,
            subtitleJob: SubtitleJobProgress?,
            canGenerateSubtitles: @escaping (CryptaVideo) -> Bool,
            subtitleActionTitle: @escaping (CryptaVideo) -> String,
            onSelectionChange: @escaping (Set<CryptaVideo.ID>, CryptaVideo.ID?) -> Void,
            onDoubleClick: @escaping (CryptaVideo) -> Void,
            onSpacePreview: @escaping () -> Void,
            onSelectAll: @escaping () -> Void,
            onGenerateSubtitles: @escaping (CryptaVideo) -> Void,
            onRename: @escaping (CryptaVideo) -> Void,
            onDelete: @escaping (CryptaVideo) -> Void
        ) {
            let shouldReload = self.videos != videos || self.subtitleJob != subtitleJob
            self.videos = videos
            self.selectedVideoIDs = selectedVideoIDs
            self.subtitleJob = subtitleJob
            self.canGenerateSubtitles = canGenerateSubtitles
            self.subtitleActionTitle = subtitleActionTitle
            self.onSelectionChange = onSelectionChange
            self.onDoubleClick = onDoubleClick
            self.onSpacePreview = onSpacePreview
            self.onSelectAll = onSelectAll
            self.onGenerateSubtitles = onGenerateSubtitles
            self.onRename = onRename
            self.onDelete = onDelete
            guard let tableView else { return }
            if shouldReload {
                tableView.reloadData()
                applyHoveredRow(-1)
                tableView.updateHoverFromCurrentMouse()
            }
            syncSelection(in: tableView)
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            videos.count
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard videos.indices.contains(row) else { return nil }
            let video = videos[row]
            let cell = tableView.makeView(
                withIdentifier: VideoTableCellView.reuseIdentifier,
                owner: self
            ) as? VideoTableCellView ?? VideoTableCellView()
            cell.configure(video: video, progress: subtitleProgress(for: video))
            loadThumbnail(for: video, into: cell)
            return cell
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = HoverableRowView()
            view.isHovered = isRowHovered(row)
            return view
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !isSyncingSelection,
                  let tableView = notification.object as? NSTableView else { return }
            let selectedIDs = Set(tableView.selectedRowIndexes.compactMap { row in
                videos.indices.contains(row) ? videos[row].id : nil
            })
            let primaryID = videos.indices.contains(tableView.selectedRow) ? videos[tableView.selectedRow].id : nil
            onSelectionChange(selectedIDs, primaryID)
        }

        @objc private func handleDoubleClick(_ sender: NSTableView) {
            let row = sender.clickedRow
            guard videos.indices.contains(row) else { return }
            onDoubleClick(videos[row])
        }

        func videoTableViewDidPressSpace(_ tableView: VideoTableView) {
            guard tableView.selectedRow >= 0 else { return }
            onSpacePreview()
        }

        func videoTableViewDidPressSelectAll(_ tableView: VideoTableView) {
            tableView.selectAll(nil)
            onSelectAll()
        }

        func videoTableView(_ tableView: VideoTableView, menuFor event: NSEvent) -> NSMenu? {
            let point = tableView.convert(event.locationInWindow, from: nil)
            let row = tableView.row(at: point)
            guard videos.indices.contains(row) else { return nil }
            if !tableView.selectedRowIndexes.contains(row) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            let video = videos[row]
            let menu = NSMenu()
            if canGenerateSubtitles(video) {
                menu.addItem(menuItem(
                    title: subtitleActionTitle(video),
                    action: #selector(generateSubtitlesFromMenu(_:)),
                    video: video
                ))
                menu.addItem(.separator())
            }
            menu.addItem(menuItem(title: "重命名", action: #selector(renameFromMenu(_:)), video: video))
            menu.addItem(menuItem(title: "删除", action: #selector(deleteFromMenu(_:)), video: video))
            return menu
        }

        func hoverTableView(_ tableView: VideoTableView, didHoverRow row: Int) {
            let resolved: Int
            if videos.indices.contains(row) {
                resolved = row
            } else {
                resolved = -1
            }
            applyHoveredRow(resolved)
        }

        @objc private func generateSubtitlesFromMenu(_ sender: NSMenuItem) {
            guard let video = sender.representedObject as? CryptaVideo else { return }
            onGenerateSubtitles(video)
        }

        @objc private func renameFromMenu(_ sender: NSMenuItem) {
            guard let video = sender.representedObject as? CryptaVideo else { return }
            onRename(video)
        }

        @objc private func deleteFromMenu(_ sender: NSMenuItem) {
            guard let video = sender.representedObject as? CryptaVideo else { return }
            onDelete(video)
        }

        private func syncSelection(in tableView: NSTableView) {
            let selectedRows = IndexSet(videos.indices.filter { selectedVideoIDs.contains(videos[$0].id) })
            guard selectedRows != tableView.selectedRowIndexes else { return }
            isSyncingSelection = true
            tableView.selectRowIndexes(selectedRows, byExtendingSelection: false)
            isSyncingSelection = false
        }

        private func installScrollObserver() {
            guard let scrollView else { return }
            scrollView.contentView.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(contentBoundsDidChange),
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
        }

        @objc private func contentBoundsDidChange() {
            tableView?.updateHoverFromCurrentMouse()
        }

        private func applyHoveredRow(_ row: Int) {
            guard row != hoveredRow else { return }
            let previous = hoveredRow
            hoveredRow = row

            guard let tableView else { return }
            let rowCount = tableView.numberOfRows
            if previous >= 0,
               previous < rowCount,
               let view = tableView.rowView(atRow: previous, makeIfNecessary: false) as? HoverableRowView {
                view.isHovered = false
            }
            if row >= 0,
               row < rowCount,
               let view = tableView.rowView(atRow: row, makeIfNecessary: false) as? HoverableRowView {
                view.isHovered = true
            }
        }

        func isRowHovered(_ row: Int) -> Bool {
            row == hoveredRow
        }

        private func loadThumbnail(for video: CryptaVideo, into cell: VideoTableCellView) {
            if let cachedThumbnail = VideoThumbnailLoader.cachedThumbnail(for: video) {
                cell.setThumbnail(cachedThumbnail, for: video)
                return
            }
            cell.setPlaceholder(for: video)
            Task { @MainActor in
                let thumbnail = await VideoThumbnailLoader.thumbnail(for: video)
                guard cell.videoID == video.id else { return }
                cell.setThumbnail(thumbnail, for: video)
            }
        }

        private func subtitleProgress(for video: CryptaVideo) -> SubtitleJobProgress? {
            subtitleJob?.videoID == video.id ? subtitleJob : nil
        }

        private func menuItem(title: String, action: Selector, video: CryptaVideo) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.representedObject = video
            return item
        }
    }
}

private protocol HoverTableViewDelegate: AnyObject {
    func hoverTableView(_ tableView: VideoTableView, didHoverRow row: Int)
}

private protocol VideoTableViewActionDelegate: AnyObject {
    func videoTableViewDidPressSpace(_ tableView: VideoTableView)
    func videoTableViewDidPressSelectAll(_ tableView: VideoTableView)
    func videoTableView(_ tableView: VideoTableView, menuFor event: NSEvent) -> NSMenu?
}

private final class VideoTableView: NSTableView {
    weak var actionDelegate: VideoTableViewActionDelegate?
    weak var hoverDelegate: HoverTableViewDelegate?
    private var hoverTrackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        hoverDelegate?.hoverTableView(self, didHoverRow: row(at: point))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverDelegate?.hoverTableView(self, didHoverRow: -1)
    }

    func updateHoverFromCurrentMouse() {
        guard let window else { return }
        let mouse = window.mouseLocationOutsideOfEventStream
        let point = convert(mouse, from: nil)
        let inside = bounds.contains(point) && visibleRect.contains(point)
        hoverDelegate?.hoverTableView(self, didHoverRow: inside ? row(at: point) : -1)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        if flags.isEmpty, event.keyCode == 49 || event.charactersIgnoringModifiers == " " {
            actionDelegate?.videoTableViewDidPressSpace(self)
            return
        }
        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "a" {
            actionDelegate?.videoTableViewDidPressSelectAll(self)
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        actionDelegate?.videoTableView(self, menuFor: event)
    }
}

private final class HoverableRowView: NSTableRowView {
    var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
        }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard isHovered, !isSelected else { return }
        drawRoundedBackground(color: NSColor.labelColor.withAlphaComponent(0.08))
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        drawRoundedBackground(color: .selectedContentBackgroundColor)
    }

    private func drawRoundedBackground(color: NSColor) {
        let inset = bounds.insetBy(dx: 10, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: 8, yRadius: 8)
        color.setFill()
        path.fill()
    }
}

private final class AspectFillThumbnailImageView: NSImageView {
    var shouldAspectFill = false {
        didSet {
            guard shouldAspectFill != oldValue else { return }
            needsDisplay = true
        }
    }

    override var image: NSImage? {
        didSet {
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard shouldAspectFill, let image else {
            super.draw(dirtyRect)
            return
        }

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).addClip()
        NSColor.secondaryLabelColor.withAlphaComponent(0.12).setFill()
        bounds.fill()

        let imageSize = image.size
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else {
            NSGraphicsContext.restoreGraphicsState()
            return
        }

        let scale = max(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let drawSize = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let drawRect = NSRect(
            x: bounds.midX - drawSize.width / 2,
            y: bounds.midY - drawSize.height / 2,
            width: drawSize.width,
            height: drawSize.height
        )
        image.draw(
            in: drawRect,
            from: NSRect(origin: .zero, size: imageSize),
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: nil
        )
        NSGraphicsContext.restoreGraphicsState()
    }
}

private final class VideoTableCellView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("VideoTableCell")

    private let thumbnailImageView = AspectFillThumbnailImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let statusImageView = NSImageView()
    private let progressIndicator = NSProgressIndicator()
    private let progressField = NSTextField(labelWithString: "")
    private let separator = NSBox()
    var videoID: CryptaVideo.ID?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseIdentifier
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        identifier = Self.reuseIdentifier
        setup()
    }

    func configure(video: CryptaVideo, progress: SubtitleJobProgress?) {
        videoID = video.id
        titleField.stringValue = video.displayName
        detailField.stringValue = video.detailLine
        if let progress {
            statusImageView.isHidden = true
            progressIndicator.isHidden = false
            progressField.isHidden = false
            progressIndicator.doubleValue = Double(progress.percent)
            progressField.stringValue = "\(progress.percent)% \(progress.desc)"
        } else {
            progressIndicator.isHidden = true
            progressField.isHidden = true
            statusImageView.isHidden = !video.hasEmbeddedSubtitles
            statusImageView.image = NSImage(
                systemSymbolName: "captions.bubble",
                accessibilityDescription: "已有字幕"
            )
        }
    }

    func setThumbnail(_ thumbnail: NSImage?, for video: CryptaVideo) {
        if let thumbnail {
            thumbnailImageView.shouldAspectFill = true
            thumbnailImageView.image = thumbnail
            thumbnailImageView.contentTintColor = nil
        } else {
            setPlaceholder(for: video)
        }
    }

    func setPlaceholder(for video: CryptaVideo) {
        let symbolName = video.isImage ? "photo.fill" : "video.fill"
        thumbnailImageView.shouldAspectFill = false
        thumbnailImageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        thumbnailImageView.contentTintColor = .secondaryLabelColor
    }

    private func setup() {
        wantsLayer = true
        thumbnailImageView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailImageView.wantsLayer = true
        thumbnailImageView.layer?.cornerRadius = 6
        thumbnailImageView.layer?.backgroundColor = NSColor.secondaryLabelColor.withAlphaComponent(0.12).cgColor
        thumbnailImageView.layer?.masksToBounds = true

        titleField.font = .systemFont(ofSize: 13, weight: .medium)
        titleField.lineBreakMode = .byTruncatingTail
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail

        statusImageView.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        statusImageView.contentTintColor = .secondaryLabelColor
        statusImageView.imageScaling = .scaleProportionallyUpOrDown

        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 100
        progressIndicator.controlSize = .small
        progressField.font = .systemFont(ofSize: 10)
        progressField.textColor = .secondaryLabelColor
        progressField.alignment = .right
        progressField.lineBreakMode = .byTruncatingTail

        separator.boxType = .separator

        [thumbnailImageView, titleField, detailField, statusImageView, progressIndicator, progressField, separator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        NSLayoutConstraint.activate([
            thumbnailImageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            thumbnailImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumbnailImageView.widthAnchor.constraint(equalToConstant: 64),
            thumbnailImageView.heightAnchor.constraint(equalToConstant: 38),

            titleField.leadingAnchor.constraint(equalTo: thumbnailImageView.trailingAnchor, constant: 12),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: statusImageView.leadingAnchor, constant: -12),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 10),

            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),

            statusImageView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            statusImageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusImageView.widthAnchor.constraint(equalToConstant: 18),
            statusImageView.heightAnchor.constraint(equalToConstant: 18),

            progressIndicator.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            progressIndicator.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -6),
            progressIndicator.widthAnchor.constraint(equalToConstant: 92),

            progressField.trailingAnchor.constraint(equalTo: progressIndicator.trailingAnchor),
            progressField.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 3),
            progressField.widthAnchor.constraint(equalToConstant: 150),

            separator.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let videoListMainColumn = NSUserInterfaceItemIdentifier("VideoListMainColumn")
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
