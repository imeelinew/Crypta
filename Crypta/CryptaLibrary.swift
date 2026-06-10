import AppKit
import Foundation
import SwiftUI

@Observable
@MainActor
final class CryptaLibrary {
    private(set) var selectedSection: LibrarySection = .video {
        didSet { selectFirstVideoIfNeeded() }
    }
    var selectedVideoIDs: Set<CryptaVideo.ID> = [] {
        didSet { normalizePrimarySelection() }
    }
    private var primarySelectedVideoID: CryptaVideo.ID?
    var renameRequest: RenameRequest?
    var deleteRequest: DeleteRequest?
    var toast: CryptaToast?
    var searchText = ""
    var sortMode = VideoSortMode.stored {
        didSet { sortMode.save() }
    }
    private(set) var videos: [CryptaVideo] = []
    private(set) var isImporting = false
    private(set) var isWorking = false
    private(set) var isAuthenticatingEncryptedSection = false
    private(set) var encryptedSectionUnlocked = false
    var errorMessage: String?

    private let store = CryptaStore()
    private var playerWindowController: PlayerWindowController?
    private var quickLookPreviewController = QuickLookPreviewController()
    private var playbackPositionSaveTasks: [CryptaVideo.ID: Task<Void, Never>] = [:]
    private var externalPlaybackCleanupURLs: Set<URL> = []
    private var externalPlayerTerminationObserver: NSObjectProtocol?

    init() {
        externalPlayerTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let bundleIdentifier = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            Task { @MainActor [weak self] in
                self?.handleExternalApplicationTermination(bundleIdentifier: bundleIdentifier)
            }
        }
    }

    var visibleVideos: [CryptaVideo] {
        guard canAccessSelectedSection else { return [] }
        let sectionVideos = videos.filter { $0.libraryKind == selectedSection.libraryKind }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filteredVideos = query.isEmpty ? sectionVideos : sectionVideos.filter { video in
            video.displayName.localizedStandardContains(query)
        }
        return sortMode.sorted(filteredVideos)
    }

    var visibleVideoSummary: String {
        let videos = visibleVideos
        let totalBytes = videos.reduce(Int64(0)) { $0 + $1.byteCount }
        let size = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "\(videos.count) 个\(selectedSection.itemNoun) · \(size)"
    }

    var canAccessSelectedSection: Bool {
        !selectedSection.requiresAuthentication || encryptedSectionUnlocked
    }

    var selectedVideo: CryptaVideo? {
        guard canAccessSelectedSection else { return nil }
        if let primarySelectedVideoID,
           let primary = visibleVideos.first(where: { $0.id == primarySelectedVideoID && selectedVideoIDs.contains($0.id) }) {
            return primary
        }
        return selectedVideos.first
    }

    var selectedVideos: [CryptaVideo] {
        guard canAccessSelectedSection else { return [] }
        return visibleVideos.filter { selectedVideoIDs.contains($0.id) }
    }

    var selectedVideoCount: Int {
        selectedVideos.count
    }

    var canActOnSelection: Bool {
        !selectedVideos.isEmpty && !isImporting && !isWorking
    }

    func load() async {
        do {
            videos = try store.loadIndex().videos.sortedForDisplay()
            selectFirstVideoIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectSection(_ section: LibrarySection) async {
        guard section != selectedSection else { return }
        selectedSection = section
    }

    func unlockEncryptedSection() async {
        guard !encryptedSectionUnlocked, !isAuthenticatingEncryptedSection else { return }
        isAuthenticatingEncryptedSection = true
        let didAuthenticate = await AuthenticationGate.authenticate(reason: "查看\(selectedSection.title)")
        isAuthenticatingEncryptedSection = false

        if didAuthenticate {
            encryptedSectionUnlocked = true
            playerWindowController?.setProtected(false)
            selectFirstVideoIfNeeded()
        } else {
            showToast("认证未通过", kind: .error)
        }
    }

    func lockEncryptedSectionAccess() {
        guard encryptedSectionUnlocked else { return }
        encryptedSectionUnlocked = false
        renameRequest = nil
        deleteRequest = nil
        quickLookPreviewController.close()
        playerWindowController?.setProtected(true)
        VideoThumbnailLoader.clearMemoryCache()
    }

    func resetEncryptedSectionAccess() {
        encryptedSectionUnlocked = false
        selectedVideoIDs.removeAll()
        primarySelectedVideoID = nil
        renameRequest = nil
        deleteRequest = nil
        quickLookPreviewController.close()
        playerWindowController?.close()
        cleanupExternalPlaybackFiles()
        VideoThumbnailLoader.clearMemoryCache()
    }

    func importFiles(from urls: [URL]) async {
        let targetSection = selectedSection
        let candidates = urls.filter { url in
            targetSection.isImageSection ? CryptaVideoImport.isSupportedImage(url) : CryptaVideoImport.isSupportedVideo(url)
        }
        guard !candidates.isEmpty else {
            errorMessage = "没有找到可导入的\(targetSection.itemNoun)"
            return
        }

        isImporting = true
        defer { isImporting = false }

        var imported: [CryptaVideo] = []
        let targetKind = targetSection.libraryKind
        for url in candidates {
            do {
                let store = self.store
                let video = try await Task.detached(priority: .userInitiated) { () async throws -> CryptaVideo in
                    if targetSection.isImageSection {
                        return try await store.importImage(from: url)
                    }
                    return try await store.importVideo(from: url, storageState: .encrypted, libraryKind: targetKind)
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
        preloadThumbnails(for: imported)
        showToast("已导入 \(imported.count) 个\(targetSection.itemNoun)")
        if targetSection.requiresAuthentication {
            playEncryptedVideoAddedSound()
        }
        if let firstImportedID = imported.first?.id {
            selectedVideoIDs = [firstImportedID]
            primarySelectedVideoID = firstImportedID
        }
    }

    func importVideos(from urls: [URL]) async {
        await importFiles(from: urls)
    }

    func playSelectedVideo() async {
        guard canAccessSelectedSection else { return }
        guard let video = selectedVideo else { return }
        await play(video)
    }

    func previewSelectedVideo() async {
        guard canAccessSelectedSection else { return }
        guard let video = selectedVideo else { return }
        guard !isImporting, !isWorking else { return }

        if quickLookPreviewController.isPreviewing(video) {
            quickLookPreviewController.close()
            return
        }

        if video.isImage {
            await previewImage(video)
            return
        }

        do {
            isWorking = true
            defer { isWorking = false }

            guard let thumbnail = await VideoThumbnailLoader.thumbnail(for: video) else {
                throw CryptaError.thumbnailFailed
            }
            try quickLookPreviewController.togglePreview(for: video, thumbnail: thumbnail)
        } catch {
            errorMessage = "预览失败：\(error.localizedDescription)"
        }
    }

    func play(_ video: CryptaVideo) async {
        guard canAccessSelectedSection else { return }
        if video.isImage {
            await previewImage(video)
            return
        }
        if video.libraryKind == .video {
            await playInExternalPlayer(video)
            return
        }

        do {
            isWorking = true
            defer { isWorking = false }

            let store = self.store
            let playback = try await Task.detached(priority: .userInitiated) {
                try store.preparePlaybackURL(for: video)
            }.value
            playerWindowController?.close()
            let playerWindowController = PlayerWindowController(
                title: video.displayName,
                url: playback.url,
                cleanupURL: playback.cleanupURL,
                startTimeSeconds: resumePosition(for: video),
                onProgress: { [weak self] seconds in
                    self?.savePlaybackPosition(for: video, seconds: seconds)
                },
                unlock: { [weak self] in
                    Task { await self?.unlockEncryptedSection() }
                },
                onClose: { [weak self] in
                    self?.playerWindowController = nil
                    VideoThumbnailLoader.clearMemoryCache()
                }
            )
            self.playerWindowController = playerWindowController
            playerWindowController.show()
        } catch {
            errorMessage = "播放失败：\(error.localizedDescription)"
        }
    }

    func requestRename(_ video: CryptaVideo) {
        guard canAccessSelectedSection else { return }
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
            playEncryptedVideoAddedSound()
        }
    }

    func decryptSelectedVideos(to destinationDirectory: URL) async {
        let targets = selectedVideos.filter { $0.storageState == .encrypted }
        guard !targets.isEmpty else { return }
        let itemNoun = targets.first?.isImage == true ? "图片" : "视频"

        isWorking = true
        defer { isWorking = false }

        let store = self.store
        var succeeded: [CryptaVideo] = []
        var failedCount = 0

        for video in targets {
            do {
                if quickLookPreviewController.isPreviewing(video) {
                    quickLookPreviewController.close()
                }
                _ = try await Task.detached(priority: .userInitiated) {
                    try store.exportAndRemoveDecryptedVideo(video, to: destinationDirectory)
                }.value
                succeeded.append(video)
            } catch {
                failedCount += 1
            }
        }

        if !succeeded.isEmpty {
            let succeededIDs = Set(succeeded.map(\.id))
            videos.removeAll { succeededIDs.contains($0.id) }
            selectedVideoIDs.subtract(succeededIDs)
            for video in succeeded {
                VideoThumbnailLoader.removeCachedThumbnail(for: video)
            }
            selectFirstVideoIfNeeded()
        }

        if failedCount > 0 {
            showToast("已解密 \(succeeded.count) 个，失败 \(failedCount) 个", kind: .error)
            errorMessage = "有 \(failedCount) 个\(itemNoun)解密失败，失败项仍保留在加密库中。"
        } else {
            showToast("已解密 \(succeeded.count) 个")
        }
    }

    func confirmDeleteVideo(_ video: CryptaVideo) {
        guard canAccessSelectedSection else { return }
        deleteRequest = DeleteRequest(videos: [video])
    }

    func delete(_ request: DeleteRequest) async {
        let itemNoun = request.primaryVideo?.isImage == true ? "图片" : "视频"
        var deleted: [CryptaVideo] = []
        var failedCount = 0
        for video in request.videos {
            do {
                if quickLookPreviewController.isPreviewing(video) {
                    quickLookPreviewController.close()
                }
                try store.delete(video)
                deleted.append(video)
            } catch {
                failedCount += 1
            }
        }

        if !deleted.isEmpty {
            let deletedIDs = Set(deleted.map(\.id))
            videos.removeAll { deletedIDs.contains($0.id) }
            selectedVideoIDs.subtract(deletedIDs)
            for video in deleted {
                VideoThumbnailLoader.removeCachedThumbnail(for: video)
            }
            deleteRequest = nil
            selectFirstVideoIfNeeded()
        }

        if failedCount > 0 {
            showToast("已删除 \(deleted.count) 个，失败 \(failedCount) 个", kind: .error)
            errorMessage = "有 \(failedCount) 个\(itemNoun)删除失败。"
        } else {
            showToast("已删除")
        }
    }

    func selectOnly(_ video: CryptaVideo) {
        selectedVideoIDs = [video.id]
        primarySelectedVideoID = video.id
    }

    func selectAllVisibleVideos() {
        let ids = Set(visibleVideos.map(\.id))
        selectedVideoIDs = ids
        primarySelectedVideoID = visibleVideos.first?.id
    }

    private func delete(_ video: CryptaVideo) async {
        do {
            if quickLookPreviewController.isPreviewing(video) {
                quickLookPreviewController.close()
            }
            try store.delete(video)
            VideoThumbnailLoader.removeCachedThumbnail(for: video)
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
        let visibleIDs = Set(visibleVideos.map(\.id))
        selectedVideoIDs = selectedVideoIDs.intersection(visibleIDs)
        if let primarySelectedVideoID,
           selectedVideoIDs.contains(primarySelectedVideoID) {
            return
        }
        if let firstSelected = visibleVideos.first(where: { selectedVideoIDs.contains($0.id) }) {
            primarySelectedVideoID = firstSelected.id
        } else if let firstVisible = visibleVideos.first {
            selectedVideoIDs = [firstVisible.id]
            primarySelectedVideoID = firstVisible.id
        } else {
            selectedVideoIDs.removeAll()
            primarySelectedVideoID = nil
        }
    }

    private func normalizePrimarySelection() {
        guard canAccessSelectedSection else {
            primarySelectedVideoID = nil
            return
        }
        if let primarySelectedVideoID,
           selectedVideoIDs.contains(primarySelectedVideoID),
           visibleVideos.contains(where: { $0.id == primarySelectedVideoID }) {
            return
        }
        primarySelectedVideoID = visibleVideos.first { selectedVideoIDs.contains($0.id) }?.id
    }

    private func showToast(_ message: String, kind: CryptaToast.Kind = .success) {
        withAnimation(.spring(duration: 0.24, bounce: 0.18)) {
            toast = CryptaToast(message: message, kind: kind)
        }
    }

    private func playInExternalPlayer(_ video: CryptaVideo) async {
        var pendingCleanupURL: URL?
        do {
            isWorking = true
            defer { isWorking = false }

            let store = self.store
            let playback = try await Task.detached(priority: .userInitiated) {
                try store.preparePlaybackURL(for: video)
            }.value
            if let cleanupURL = playback.cleanupURL {
                pendingCleanupURL = cleanupURL
                externalPlaybackCleanupURLs.insert(cleanupURL)
            }
            try await openInIINA(playback.url)
            showToast("已交给 IINA 播放")
        } catch {
            if let pendingCleanupURL {
                externalPlaybackCleanupURLs.remove(pendingCleanupURL)
                try? FileManager.default.removeItem(at: pendingCleanupURL)
            }
            showToast("播放失败", kind: .error)
            errorMessage = "播放失败：\(error.localizedDescription)"
        }
    }

    private func previewImage(_ video: CryptaVideo) async {
        if quickLookPreviewController.isPreviewing(video) {
            quickLookPreviewController.close()
            return
        }

        do {
            isWorking = true
            defer { isWorking = false }

            let store = self.store
            let playback = try await Task.detached(priority: .userInitiated) {
                try store.preparePlaybackURL(for: video)
            }.value
            try quickLookPreviewController.togglePreview(
                for: video,
                fileURL: playback.url,
                cleanupURL: playback.cleanupURL
            )
        } catch {
            errorMessage = "预览失败：\(error.localizedDescription)"
        }
    }

    private func openInIINA(_ url: URL) async throws {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.iinaBundleIdentifier) else {
            throw CryptaError.externalPlayerUnavailable
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: appURL,
                configuration: configuration
            ) { _, error in
                if error != nil {
                    continuation.resume(throwing: CryptaError.externalPlayerOpenFailed)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func handleExternalApplicationTermination(bundleIdentifier: String?) {
        guard bundleIdentifier == Self.iinaBundleIdentifier else {
            return
        }
        cleanupExternalPlaybackFiles()
    }

    private func cleanupExternalPlaybackFiles() {
        for url in externalPlaybackCleanupURLs {
            try? FileManager.default.removeItem(at: url)
        }
        externalPlaybackCleanupURLs.removeAll()
    }

    private func preloadThumbnails(for videos: [CryptaVideo]) {
        Task.detached(priority: .utility) {
            for video in videos {
                _ = await VideoThumbnailLoader.thumbnail(for: video)
            }
        }
    }

    private func playEncryptedVideoAddedSound() {
        (NSSound(named: "Pebble") ?? NSSound(named: "Pop"))?.play()
    }

    private func resumePosition(for video: CryptaVideo) -> Double {
        guard let seconds = video.playbackPositionSeconds,
              seconds.isFinite,
              seconds > 1 else {
            return 0
        }
        if let duration = video.durationSeconds, duration.isFinite, duration - seconds < 5 {
            return 0
        }
        return seconds
    }

    private func savePlaybackPosition(for video: CryptaVideo, seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        let normalizedSeconds: Double?
        if let duration = video.durationSeconds, duration.isFinite, duration - seconds < 5 {
            normalizedSeconds = nil
        } else {
            normalizedSeconds = max(0, seconds)
        }

        var updatedVideo = video
        updatedVideo.playbackPositionSeconds = normalizedSeconds
        replace(updatedVideo)

        let store = self.store
        playbackPositionSaveTasks[video.id]?.cancel()
        playbackPositionSaveTasks[video.id] = Task { [weak self] in
            do {
                let updated = try await Task.detached(priority: .utility) {
                    try store.updatePlaybackPosition(videoID: video.id, seconds: normalizedSeconds)
                }.value
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.playbackPositionSaveTasks[video.id] = nil
                }
                if let updated {
                    await MainActor.run {
                        self?.replace(updated)
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.playbackPositionSaveTasks[video.id] = nil
                    self?.errorMessage = "保存播放进度失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private static let iinaBundleIdentifier = "com.colliderli.iina"
}
