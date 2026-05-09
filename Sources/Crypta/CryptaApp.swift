import AppKit
import AVFoundation
import AVKit
import CryptoKit
import Security
import SwiftUI
import UniformTypeIdentifiers

@main
struct CryptaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var library = CryptaLibrary()

    var body: some Scene {
        WindowGroup {
            ContentView(library: library)
                .frame(minWidth: 980, minHeight: 640)
                .task {
                    await library.load()
                }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        if let iconURL = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        try? CryptaPaths.cleanPlaybackCache()
    }
}

enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case plain
    case encrypted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: return "视频"
        case .encrypted: return "加密视频"
        }
    }

    var systemImage: String {
        switch self {
        case .plain: return "video.fill"
        case .encrypted: return "lock.fill"
        }
    }

    var storageState: CryptaVideo.StorageState {
        switch self {
        case .plain: return .plain
        case .encrypted: return .encrypted
        }
    }
}

@Observable
@MainActor
final class CryptaLibrary {
    var selectedSection: LibrarySection = .encrypted {
        didSet { selectFirstVideoIfNeeded() }
    }
    var selectedVideoID: CryptaVideo.ID?
    var renameRequest: RenameRequest?
    var deleteRequest: CryptaVideo?
    var toast: CryptaToast?
    private(set) var videos: [CryptaVideo] = []
    private(set) var isImporting = false
    private(set) var isWorking = false
    var errorMessage: String?

    private let store = CryptaStore()
    private var playerWindowController: PlayerWindowController?

    var visibleVideos: [CryptaVideo] {
        videos.filter { $0.storageState == selectedSection.storageState }
    }

    var selectedVideo: CryptaVideo? {
        videos.first { $0.id == selectedVideoID && $0.storageState == selectedSection.storageState }
    }

    var canActOnSelection: Bool {
        selectedVideo != nil && !isImporting && !isWorking
    }

    func load() async {
        do {
            videos = try store.loadIndex().videos.sortedForDisplay()
            selectFirstVideoIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func importVideos(from urls: [URL]) async {
        let candidates = urls.filter { CryptaVideoImport.isSupportedVideo($0) }
        guard !candidates.isEmpty else {
            errorMessage = "没有找到可导入的视频"
            return
        }

        isImporting = true
        defer { isImporting = false }

        var imported: [CryptaVideo] = []
        for url in candidates {
            do {
                let store = self.store
                let targetState = selectedSection.storageState
                let video = try await Task.detached(priority: .userInitiated) {
                    try await store.importVideo(from: url, storageState: targetState)
                }.value
                imported.append(video)
            } catch {
                showToast("导入失败", kind: .error)
                errorMessage = "导入失败：\(url.lastPathComponent) - \(error.localizedDescription)"
            }
        }

        guard !imported.isEmpty else { return }
        videos.append(contentsOf: imported)
        videos = videos.sortedForDisplay()
        showToast("已导入 \(imported.count) 个视频")
        selectedVideoID = imported.first?.id
    }

    func playSelectedVideo() async {
        guard let video = selectedVideo else { return }
        await play(video)
    }

    func play(_ video: CryptaVideo) async {
        do {
            isWorking = true
            defer { isWorking = false }

            let store = self.store
            let playback = try await Task.detached(priority: .userInitiated) {
                try store.preparePlaybackURL(for: video)
            }.value
            playerWindowController = PlayerWindowController(
                title: video.displayName,
                url: playback.url,
                temporaryURL: playback.temporary ? playback.url : nil
            )
            playerWindowController?.show()
        } catch {
            errorMessage = "播放失败：\(error.localizedDescription)"
        }
    }

    func requestRename(_ video: CryptaVideo) {
        renameRequest = RenameRequest(video: video)
    }

    func rename(_ request: RenameRequest, to newName: String) async {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        do {
            let updated = try store.rename(request.video, to: trimmedName)
            replace(updated)
            renameRequest = nil
            showToast("已重命名")
        } catch {
            showToast("重命名失败", kind: .error)
            errorMessage = "重命名失败：\(error.localizedDescription)"
        }
    }

    func encrypt(_ video: CryptaVideo) async {
        guard video.storageState == .plain else { return }
        let didSucceed = await transform(video) { store, video in
            try store.encryptPlainVideo(video)
        }
        if didSucceed {
            selectFirstVideoIfNeeded()
            showToast("已加密")
        }
    }

    func decrypt(_ video: CryptaVideo) async {
        guard video.storageState == .encrypted else { return }
        let didSucceed = await transform(video) { store, video in
            try store.decryptEncryptedVideo(video)
        }
        if didSucceed {
            selectFirstVideoIfNeeded()
            showToast("已解密")
        }
    }

    func confirmDeleteSelectedVideo() {
        guard let selectedVideo else { return }
        deleteRequest = selectedVideo
    }

    func delete(_ video: CryptaVideo) async {
        do {
            try store.delete(video)
            videos.removeAll { $0.id == video.id }
            deleteRequest = nil
            selectFirstVideoIfNeeded()
            showToast("已删除")
        } catch {
            showToast("删除失败", kind: .error)
            errorMessage = "删除失败：\(error.localizedDescription)"
        }
    }

    private func transform(
        _ video: CryptaVideo,
        operation: @escaping @Sendable (CryptaStore, CryptaVideo) throws -> CryptaVideo
    ) async -> Bool {
        do {
            isWorking = true
            defer { isWorking = false }
            let store = self.store
            let updated = try await Task.detached(priority: .userInitiated) {
                try operation(store, video)
            }.value
            replace(updated)
            return true
        } catch {
            showToast("操作失败", kind: .error)
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func replace(_ updated: CryptaVideo) {
        if let index = videos.firstIndex(where: { $0.id == updated.id }) {
            videos[index] = updated
        } else {
            videos.append(updated)
        }
        videos = videos.sortedForDisplay()
    }

    private func selectFirstVideoIfNeeded() {
        if let selectedVideoID,
           visibleVideos.contains(where: { $0.id == selectedVideoID }) {
            return
        }
        selectedVideoID = visibleVideos.first?.id
    }

    private func showToast(_ message: String, kind: CryptaToast.Kind = .success) {
        withAnimation(.spring(duration: 0.24, bounce: 0.18)) {
            toast = CryptaToast(message: message, kind: kind)
        }
    }
}

struct RenameRequest: Identifiable {
    let id = UUID()
    let video: CryptaVideo
    var name: String

    init(video: CryptaVideo) {
        self.video = video
        self.name = video.displayName
    }
}

struct CryptaToast: Equatable, Identifiable {
    enum Kind: Equatable {
        case success
        case error
    }

    let id = UUID()
    let message: String
    let kind: Kind

    var systemImage: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }

    var foregroundStyle: Color {
        switch kind {
        case .success: return .primary
        case .error: return Color(red: 0.82, green: 0.18, blue: 0.18)
        }
    }
}

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
        switch library.selectedSection {
        case .plain: return "加密"
        case .encrypted: return "解密"
        }
    }

    private var transformSystemImage: String {
        switch library.selectedSection {
        case .plain: return "lock.fill"
        case .encrypted: return "lock.open.fill"
        }
    }

    private func transformSelectedVideo() async {
        guard let video = library.selectedVideo else { return }
        switch library.selectedSection {
        case .plain:
            await library.encrypt(video)
        case .encrypted:
            await library.decrypt(video)
        }
    }

    private var errorAlertBinding: Binding<Bool> {
        Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )
    }
}

struct SidebarView: View {
    @Bindable var library: CryptaLibrary

    var body: some View {
        List(selection: $library.selectedSection) {
            ForEach(LibrarySection.allCases) { section in
                NavigationLink(value: section) {
                    Label(section.title, systemImage: section.systemImage)
                }
            }
        }
        .navigationTitle("Crypta")
        .navigationSplitViewColumnWidth(min: 150, ideal: 180)
    }
}

struct VideoListPage: View {
    @Bindable var library: CryptaLibrary

    var body: some View {
        Group {
            if library.visibleVideos.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: library.selectedSection.systemImage)
                } description: {
                    Text(emptyDescription)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
            } else {
                List(selection: $library.selectedVideoID) {
                    ForEach(library.visibleVideos) { video in
                        VideoRow(video: video)
                            .tag(video.id)
                            .contextMenu {
                                Button("重命名") {
                                    library.requestRename(video)
                                }
                            }
                            .onTapGesture {
                                library.selectedVideoID = video.id
                            }
                    }
                }
                .listStyle(.inset)
                .scrollContentBackground(.hidden)
                .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .navigationTitle(library.selectedSection.title)
    }

    private var emptyTitle: String {
        switch library.selectedSection {
        case .plain: return "无视频"
        case .encrypted: return "无加密视频"
        }
    }

    private var emptyDescription: String {
        switch library.selectedSection {
        case .plain: return "拖拽以导入视频"
        case .encrypted: return "拖拽以导入加密视频"
        }
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
        .task(id: video.id) {
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
                Image(systemName: video.storageState == .plain ? "video.fill" : "lock.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(video.storageState == .plain ? Color.secondary : Color.accentColor)
            }
        }
        .frame(width: 64, height: 38)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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

struct CryptaVideo: Codable, Identifiable, Hashable, Sendable {
    enum StorageState: String, Codable, Sendable {
        case plain
        case encrypted
    }

    let id: UUID
    var displayName: String
    let originalExtension: String
    var storageState: StorageState
    var plainFileName: String?
    var encryptedFileName: String?
    let importedAt: Date
    let byteCount: Int64
    let durationSeconds: Double?

    var detailLine: String {
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        guard let durationSeconds else { return size }
        return "\(Self.formatDuration(durationSeconds)) · \(size)"
    }

    init(
        id: UUID,
        displayName: String,
        originalExtension: String,
        storageState: StorageState,
        plainFileName: String?,
        encryptedFileName: String?,
        importedAt: Date,
        byteCount: Int64,
        durationSeconds: Double?
    ) {
        self.id = id
        self.displayName = displayName
        self.originalExtension = originalExtension
        self.storageState = storageState
        self.plainFileName = plainFileName
        self.encryptedFileName = encryptedFileName
        self.importedAt = importedAt
        self.byteCount = byteCount
        self.durationSeconds = durationSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        originalExtension = try container.decode(String.self, forKey: .originalExtension)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        storageState = try container.decodeIfPresent(StorageState.self, forKey: .storageState) ?? .encrypted
        plainFileName = try container.decodeIfPresent(String.self, forKey: .plainFileName)
        encryptedFileName = try container.decodeIfPresent(String.self, forKey: .encryptedFileName)

    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case originalExtension
        case storageState
        case plainFileName
        case encryptedFileName
        case importedAt
        case byteCount
        case durationSeconds
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct CryptaIndex: Codable, Sendable {
    var videos: [CryptaVideo] = []
}

extension Array where Element == CryptaVideo {
    func sortedForDisplay() -> [CryptaVideo] {
        sorted { $0.importedAt > $1.importedAt }
    }
}

struct PlaybackURL: Sendable {
    let url: URL
    let temporary: Bool
}

enum VideoThumbnailLoader {
    static func thumbnail(for video: CryptaVideo) async -> NSImage? {
        await Task.detached(priority: .utility) {
            do {
                let store = CryptaStore()
                let playback = try store.preparePlaybackURL(for: video, cleanCache: false)
                defer {
                    if playback.temporary {
                        try? FileManager.default.removeItem(at: playback.url)
                    }
                }
                return try await image(from: playback.url)
            } catch {
                return nil
            }
        }.value
    }

    private static func image(from url: URL) async throws -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 192, height: 108)
        let cgImage: CGImage = try await withCheckedThrowingContinuation { continuation in
            generator.generateCGImageAsynchronously(
                for: CMTime(seconds: 0.2, preferredTimescale: 600)
            ) { cgImage, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let cgImage {
                    continuation.resume(returning: cgImage)
                } else {
                    continuation.resume(throwing: CryptaError.thumbnailFailed)
                }
            }
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
}

enum CryptaPaths {
    static let appName = "Crypta"

    static var moviesVault: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }

    static var encryptedIndex: URL {
        applicationSupport.appendingPathComponent("library.index", isDirectory: false)
    }

    static var playbackCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("Playback", isDirectory: true)
    }

    static func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: moviesVault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: playbackCache, withIntermediateDirectories: true)
    }

    static func cleanPlaybackCache() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: playbackCache.path) else { return }
        for url in try fileManager.contentsOfDirectory(at: playbackCache, includingPropertiesForKeys: nil) {
            try? fileManager.removeItem(at: url)
        }
    }
}

enum CryptaVideoImport {
    static let supportedExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "hevc"
    ]

    static func isSupportedVideo(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if supportedExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }
}

final class CryptaStore: @unchecked Sendable {
    private let keyStore = CryptaKeychainKeyStore()
    private let indexEncoder = JSONEncoder()
    private let indexDecoder = JSONDecoder()
    private let chunkSize = 4 * 1024 * 1024

    init() {
        indexEncoder.outputFormatting = [.sortedKeys]
        indexEncoder.dateEncodingStrategy = .iso8601
        indexDecoder.dateDecodingStrategy = .iso8601
    }

    func loadIndex() throws -> CryptaIndex {
        try CryptaPaths.prepareDirectories()
        guard FileManager.default.fileExists(atPath: CryptaPaths.encryptedIndex.path) else {
            return CryptaIndex()
        }
        let encrypted = try Data(contentsOf: CryptaPaths.encryptedIndex)
        let plaintext = try decryptCombined(encrypted)
        return try indexDecoder.decode(CryptaIndex.self, from: plaintext)
    }

    func saveIndex(_ index: CryptaIndex) throws {
        try CryptaPaths.prepareDirectories()
        let plaintext = try indexEncoder.encode(index)
        let encrypted = try encryptCombined(plaintext)
        try encrypted.write(to: CryptaPaths.encryptedIndex, options: [.atomic])
    }

    func importVideo(from sourceURL: URL, storageState: CryptaVideo.StorageState) async throws -> CryptaVideo {
        try CryptaPaths.prepareDirectories()

        let secureURL = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if secureURL {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let id = UUID()
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .localizedNameKey])
        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        let byteCount = Int64(values.fileSize ?? 0)
        let extensionName = sourceURL.pathExtension.lowercased()
        let duration = await Self.videoDuration(for: sourceURL)
        var plainFileName: String?
        var encryptedFileName: String?

        switch storageState {
        case .plain:
            let destinationFileName = uniquePlainFileName(displayName: displayName, extensionName: extensionName)
            let destinationURL = CryptaPaths.moviesVault.appendingPathComponent(destinationFileName, isDirectory: false)
            try moveOrCopyFile(from: sourceURL, to: destinationURL)
            plainFileName = destinationFileName
        case .encrypted:
            let destinationFileName = randomBlobName()
            let destinationURL = CryptaPaths.moviesVault.appendingPathComponent(destinationFileName, isDirectory: false)
            try encryptFile(from: sourceURL, to: destinationURL)
            try? FileManager.default.removeItem(at: sourceURL)
            encryptedFileName = destinationFileName
        }

        var index = try loadIndex()
        let video = CryptaVideo(
            id: id,
            displayName: displayName,
            originalExtension: extensionName,
            storageState: storageState,
            plainFileName: plainFileName,
            encryptedFileName: encryptedFileName,
            importedAt: Date(),
            byteCount: byteCount,
            durationSeconds: duration
        )
        index.videos.append(video)
        try saveIndex(index)
        return video
    }

    func preparePlaybackURL(for video: CryptaVideo, cleanCache: Bool = true) throws -> PlaybackURL {
        try CryptaPaths.prepareDirectories()
        switch video.storageState {
        case .plain:
            guard let plainFileName = video.plainFileName else { throw CryptaError.missingVideoFile }
            return PlaybackURL(
                url: CryptaPaths.moviesVault.appendingPathComponent(plainFileName, isDirectory: false),
                temporary: false
            )
        case .encrypted:
            guard let encryptedFileName = video.encryptedFileName else { throw CryptaError.missingVideoFile }
            if cleanCache {
                try CryptaPaths.cleanPlaybackCache()
            }
            let source = CryptaPaths.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
            let playbackName = "\(UUID().uuidString).\(video.originalExtension.isEmpty ? "mov" : video.originalExtension)"
            let playbackURL = CryptaPaths.playbackCache.appendingPathComponent(playbackName, isDirectory: false)
            try decryptFile(from: source, to: playbackURL)
            return PlaybackURL(url: playbackURL, temporary: true)
        }
    }

    func rename(_ video: CryptaVideo, to newName: String) throws -> CryptaVideo {
        var index = try loadIndex()
        guard let indexPosition = index.videos.firstIndex(where: { $0.id == video.id }) else {
            throw CryptaError.missingIndexEntry
        }

        var updated = index.videos[indexPosition]
        updated.displayName = newName

        if updated.storageState == .plain, let oldFileName = updated.plainFileName {
            let oldURL = CryptaPaths.moviesVault.appendingPathComponent(oldFileName, isDirectory: false)
            let newFileName = uniquePlainFileName(displayName: newName, extensionName: updated.originalExtension)
            let newURL = CryptaPaths.moviesVault.appendingPathComponent(newFileName, isDirectory: false)
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            updated.plainFileName = newFileName
        }

        index.videos[indexPosition] = updated
        try saveIndex(index)
        return updated
    }

    func encryptPlainVideo(_ video: CryptaVideo) throws -> CryptaVideo {
        var index = try loadIndex()
        guard let indexPosition = index.videos.firstIndex(where: { $0.id == video.id }),
              let plainFileName = index.videos[indexPosition].plainFileName else {
            throw CryptaError.missingIndexEntry
        }

        let plainURL = CryptaPaths.moviesVault.appendingPathComponent(plainFileName, isDirectory: false)
        let encryptedFileName = randomBlobName()
        let encryptedURL = CryptaPaths.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
        try encryptFile(from: plainURL, to: encryptedURL)

        var updated = index.videos[indexPosition]
        updated.storageState = .encrypted
        updated.plainFileName = nil
        updated.encryptedFileName = encryptedFileName
        index.videos[indexPosition] = updated
        try saveIndex(index)
        try? FileManager.default.removeItem(at: plainURL)
        return updated
    }

    func decryptEncryptedVideo(_ video: CryptaVideo) throws -> CryptaVideo {
        var index = try loadIndex()
        guard let indexPosition = index.videos.firstIndex(where: { $0.id == video.id }),
              let encryptedFileName = index.videos[indexPosition].encryptedFileName else {
            throw CryptaError.missingIndexEntry
        }

        let encryptedURL = CryptaPaths.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
        let plainFileName = uniquePlainFileName(
            displayName: index.videos[indexPosition].displayName,
            extensionName: index.videos[indexPosition].originalExtension
        )
        let plainURL = CryptaPaths.moviesVault.appendingPathComponent(plainFileName, isDirectory: false)
        try decryptFile(from: encryptedURL, to: plainURL)

        var updated = index.videos[indexPosition]
        updated.storageState = .plain
        updated.plainFileName = plainFileName
        updated.encryptedFileName = nil
        index.videos[indexPosition] = updated
        try saveIndex(index)
        try? FileManager.default.removeItem(at: encryptedURL)
        return updated
    }

    func delete(_ video: CryptaVideo) throws {
        switch video.storageState {
        case .plain:
            if let plainFileName = video.plainFileName {
                try? FileManager.default.removeItem(
                    at: CryptaPaths.moviesVault.appendingPathComponent(plainFileName, isDirectory: false)
                )
            }
        case .encrypted:
            if let encryptedFileName = video.encryptedFileName {
                try? FileManager.default.removeItem(
                    at: CryptaPaths.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
                )
            }
        }

        var index = try loadIndex()
        index.videos.removeAll { $0.id == video.id }
        try saveIndex(index)
    }

    private func encryptFile(from sourceURL: URL, to destinationURL: URL) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        do {
            while true {
                let chunk = try input.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                let sealed = try encryptCombined(chunk)
                try output.write(contentsOf: Self.lengthPrefix(for: sealed.count))
                try output.write(contentsOf: sealed)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func decryptFile(from sourceURL: URL, to destinationURL: URL) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        do {
            while true {
                let prefix = try input.read(upToCount: 4) ?? Data()
                if prefix.isEmpty { break }
                guard prefix.count == 4 else { throw CryptaError.invalidEncryptedFile }
                let length = Self.length(fromPrefix: prefix)
                guard length > 0 && length < chunkSize + 1024 else { throw CryptaError.invalidEncryptedFile }
                let sealed = try input.read(upToCount: length) ?? Data()
                guard sealed.count == length else { throw CryptaError.invalidEncryptedFile }
                let chunk = try decryptCombined(sealed)
                try output.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func randomBlobName() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func moveOrCopyFile(from sourceURL: URL, to destinationURL: URL) throws {
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }
    }

    private func uniquePlainFileName(displayName: String, extensionName: String) -> String {
        let cleanedExtension = extensionName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let extensionSuffix = cleanedExtension.isEmpty ? "" : ".\(cleanedExtension)"
        var base = sanitizedFileName(displayName).nonEmptyValue ?? "Video"
        if !extensionSuffix.isEmpty, base.lowercased().hasSuffix(extensionSuffix.lowercased()) {
            base.removeLast(extensionSuffix.count)
        }
        let cleanedBase = base.nonEmptyValue ?? "Video"
        let suffix = cleanedExtension.isEmpty ? "" : ".\(cleanedExtension)"
        var candidate = "\(cleanedBase)\(suffix)"
        var counter = 2
        while FileManager.default.fileExists(atPath: CryptaPaths.moviesVault.appendingPathComponent(candidate).path) {
            candidate = "\(cleanedBase) \(counter)\(suffix)"
            counter += 1
        }
        return candidate
    }

    private func sanitizedFileName(_ value: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:")
        return value
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func encryptCombined(_ plaintext: Data) throws -> Data {
        let key = try keyStore.getOrCreateKey()
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptaError.encryptionFailed
        }
        return combined
    }

    private func decryptCombined(_ encrypted: Data) throws -> Data {
        let key = try keyStore.getOrCreateKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encrypted)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw CryptaError.decryptionFailed
        }
    }

    private static func lengthPrefix(for length: Int) -> Data {
        var value = UInt32(length).bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }

    private static func length(fromPrefix data: Data) -> Int {
        data.withUnsafeBytes { rawBuffer in
            Int(rawBuffer.load(as: UInt32.self).bigEndian)
        }
    }

    private static func videoDuration(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let durationTime = try? await asset.load(.duration) else {
            return nil
        }
        let duration = CMTimeGetSeconds(durationTime)
        return duration.isFinite && duration > 0 ? duration : nil
    }
}

private extension String {
    var nonEmptyValue: String? {
        isEmpty ? nil : self
    }
}

final class CryptaKeychainKeyStore: @unchecked Sendable {
    private let service = "local.elidev.Crypta.encryption"
    private let account = "default-v1"

    func getOrCreateKey() throws -> SymmetricKey {
        if let data = try readKeyData() {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try saveKeyData(data)
        return key
    }

    private func readKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CryptaError.keychainReadFailed(status)
        }
        return data
    }

    private func saveKeyData(_ data: Data) throws {
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CryptaError.keychainWriteFailed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

enum CryptaError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case invalidEncryptedFile
    case missingIndexEntry
    case missingVideoFile
    case thumbnailFailed
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "加密失败"
        case .decryptionFailed:
            return "解密失败"
        case .invalidEncryptedFile:
            return "加密文件格式无效"
        case .missingIndexEntry:
            return "找不到视频索引"
        case .missingVideoFile:
            return "找不到视频文件"
        case .thumbnailFailed:
            return "无法生成缩略图"
        case .keychainReadFailed(let status):
            return "无法读取钥匙串密钥（\(status)）"
        case .keychainWriteFailed(let status):
            return "无法保存钥匙串密钥（\(status)）"
        }
    }
}
