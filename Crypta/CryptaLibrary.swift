import AppKit
import Foundation
import SwiftUI

@Observable
@MainActor
final class CryptaLibrary {
    private(set) var selectedSection: LibrarySection = .encrypted {
        didSet { selectFirstVideoIfNeeded() }
    }
    var selectedVideoID: CryptaVideo.ID?
    var renameRequest: RenameRequest?
    var deleteRequest: CryptaVideo?
    var toast: CryptaToast?
    var searchText = ""
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

    var visibleVideos: [CryptaVideo] {
        guard encryptedSectionUnlocked else { return [] }
        let sectionVideos = videos.filter { $0.storageState == selectedSection.storageState }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sectionVideos }
        return sectionVideos.filter { video in
            video.displayName.localizedStandardContains(query)
        }
    }

    var selectedVideo: CryptaVideo? {
        guard encryptedSectionUnlocked else { return nil }
        return videos.first { $0.id == selectedVideoID && $0.storageState == selectedSection.storageState }
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

    func selectSection(_ section: LibrarySection) async {
        guard section != selectedSection else { return }
        selectedSection = section
    }

    func unlockEncryptedSection() async {
        guard !encryptedSectionUnlocked, !isAuthenticatingEncryptedSection else { return }
        isAuthenticatingEncryptedSection = true
        let didAuthenticate = await AuthenticationGate.authenticate(reason: "查看加密视频")
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
        selectedVideoID = nil
        renameRequest = nil
        deleteRequest = nil
        quickLookPreviewController.close()
        playerWindowController?.close()
        VideoThumbnailLoader.clearMemoryCache()
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
        let targetState = selectedSection.storageState
        for url in candidates {
            do {
                let store = self.store
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
        preloadThumbnails(for: imported)
        showToast("已导入 \(imported.count) 个视频")
        if targetState == .encrypted {
            playEncryptedVideoAddedSound()
        }
        selectedVideoID = imported.first?.id
    }

    func playSelectedVideo() async {
        guard encryptedSectionUnlocked else { return }
        guard let video = selectedVideo else { return }
        await play(video)
    }

    func previewSelectedVideo() async {
        guard encryptedSectionUnlocked else { return }
        guard let video = selectedVideo else { return }
        guard !isImporting, !isWorking else { return }

        if quickLookPreviewController.isPreviewing(video) {
            quickLookPreviewController.close()
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
        guard encryptedSectionUnlocked else { return }
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
        guard encryptedSectionUnlocked else { return }
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
        guard encryptedSectionUnlocked else { return }
        guard let selectedVideo else { return }
        deleteRequest = selectedVideo
    }

    func delete(_ video: CryptaVideo) async {
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

}
