import AppKit
import AVFoundation
import Foundation
import SwiftUI

@Observable
@MainActor
final class CryptaLibrary {
    var groups: [LibraryGroup] = []
    var selectedGroupID: String? = nil {
        didSet { selectFirstVideoIfNeeded() }
    }
    var selectedVideoIDs: Set<CryptaVideo.ID> = [] {
        didSet { normalizePrimarySelection() }
    }
    private var primarySelectedVideoID: CryptaVideo.ID?
    var renameRequest: RenameRequest?
    var deleteRequest: DeleteRequest?
    var subtitleOverwriteRequest: SubtitleOverwriteRequest?
    var editGroupRequest: EditGroupRequest?
    var newGroupFormPresented = false
    var toast: CryptaToast?
    var searchText = ""
    var sortMode = VideoSortMode.stored {
        didSet { sortMode.save() }
    }
    private(set) var videos: [CryptaVideo] = []
    private(set) var isImporting = false
    private(set) var isWorking = false
    private(set) var isAuthenticatingEncryptedSection = false
    private(set) var unlockedGroupIDs: Set<String> = []
    var errorMessage: String?

    let store = CryptaStore()
    private var playerWindowController: PlayerWindowController?
    private var playerGroupID: String?
    private var quickLookPreviewController = QuickLookPreviewController()
    private var quickLookGroupID: String?
    private var extendedLockTask: Task<Void, Never>?
    private var playbackPositionSaveTasks: [CryptaVideo.ID: Task<Void, Never>] = [:]
    private var subtitleTask: Task<Void, Never>?
    private let mediaSessions: DecryptedMediaSessionManager
    private let externalApplications = ExternalMediaApplicationController()
    private(set) var subtitleJob: SubtitleJobProgress?

    init(mediaSessions: DecryptedMediaSessionManager? = nil) {
        self.mediaSessions = mediaSessions ?? .shared
    }

    var selectedGroup: LibraryGroup? {
        guard let id = selectedGroupID else { return nil }
        return groups.first { $0.id == id }
    }

    var visibleVideos: [CryptaVideo] {
        guard canAccessSelectedGroup else { return [] }
        guard let group = selectedGroup else { return [] }
        let sectionVideos = videos.filter { $0.libraryKind.rawValue == group.id }
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
        let noun = selectedGroup?.itemNoun ?? "文件"
        return "\(videos.count) 个\(noun) · \(size)"
    }

    var canAccessSelectedGroup: Bool {
        guard let group = selectedGroup else { return false }
        return canAccess(group)
    }

    var selectedVideo: CryptaVideo? {
        guard canAccessSelectedGroup else { return nil }
        if let primarySelectedVideoID,
           let primary = visibleVideos.first(where: { $0.id == primarySelectedVideoID && selectedVideoIDs.contains($0.id) }) {
            return primary
        }
        return selectedVideos.first
    }

    var selectedVideos: [CryptaVideo] {
        guard canAccessSelectedGroup else { return [] }
        return visibleVideos.filter { selectedVideoIDs.contains($0.id) }
    }

    var selectedVideoCount: Int {
        selectedVideos.count
    }

    var canActOnSelection: Bool {
        !selectedVideos.isEmpty && !isImporting && !isWorking
    }

    func subtitleProgress(for video: CryptaVideo) -> SubtitleJobProgress? {
        guard subtitleJob?.videoID == video.id else { return nil }
        return subtitleJob
    }

    func subtitleActionTitle(for video: CryptaVideo) -> String {
        if subtitleJob?.videoID == video.id {
            return "停止生成字幕"
        }
        return video.hasEmbeddedSubtitles ? "重新生成字幕" : "生成字幕"
    }

    func canGenerateSubtitles(for video: CryptaVideo) -> Bool {
        guard let group = selectedGroup,
              canAccessSelectedGroup,
              group.encryptionLevel == .standard,
              video.mediaType == .video,
              SubtitleEmbedder.supportsContainerExtension(video.originalExtension),
              !isImporting,
              !isWorking else {
            return false
        }
        return subtitleJob == nil || subtitleJob?.videoID == video.id
    }

    func load() async {
        do {
            let index = try store.loadIndex()
            groups = index.groups
            videos = index.videos.sortedForDisplay()
            if selectedGroupID == nil, let firstGroup = groups.first {
                selectedGroupID = firstGroup.id
            }
            selectFirstVideoIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func selectGroup(_ group: LibraryGroup) async {
        guard group.id != selectedGroupID else { return }
        if let previousGroup = selectedGroup, previousGroup.encryptionLevel.locksOnGroupChange {
            lockGroupAccess(previousGroup.id)
        }
        selectedGroupID = group.id
    }

    func unlockEncryptedSection() async {
        guard let group = selectedGroup else { return }
        await unlock(group)
    }

    private func unlock(_ group: LibraryGroup) async {
        guard group.requiresAuthentication,
              !unlockedGroupIDs.contains(group.id),
              !isAuthenticatingEncryptedSection else {
            return
        }

        isAuthenticatingEncryptedSection = true
        defer { isAuthenticatingEncryptedSection = false }
        let didAuthenticate = await AuthenticationGate.authenticate(reason: "查看\(group.name)")

        guard didAuthenticate else {
            showToast("认证未通过", kind: .error)
            return
        }

        unlockedGroupIDs.insert(group.id)
        if group.encryptionLevel == .extended, !NSApp.isActive {
            scheduleExtendedLock()
        }
        if group.encryptionLevel == .maximum, !NSApp.isActive {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self,
                      !NSApp.isActive,
                      unlockedGroupIDs.contains(group.id) else {
                    return
                }
                lockGroupAccess(group.id)
            }
        }
        if playerGroupID == group.id {
            playerWindowController?.setProtected(false)
        }
        if selectedGroupID == group.id {
            selectFirstVideoIfNeeded()
        }
    }

    func appDidResignActive() {
        guard !isAuthenticatingEncryptedSection else { return }
        lockGroups { $0.encryptionLevel.locksWhenAppResignsActive }
        scheduleExtendedLock()
    }

    func appDidBecomeActive() {
        extendedLockTask?.cancel()
        extendedLockTask = nil
    }

    func isGroupUnlocked(_ group: LibraryGroup) -> Bool {
        canAccess(group)
    }

    func canDeleteGroup(_ group: LibraryGroup) -> Bool {
        !videos.contains(where: { $0.libraryKind.rawValue == group.id })
    }

    func canManuallyLock(_ group: LibraryGroup) -> Bool {
        group.encryptionLevel.allowsManualLock && unlockedGroupIDs.contains(group.id)
    }

    func manuallyLock(_ group: LibraryGroup) {
        guard canManuallyLock(group) else { return }
        lockGroupAccess(group.id)
    }

    func importFiles(from urls: [URL]) async {
        guard let targetGroup = selectedGroup else { return }
        let candidates = urls.filter { url in
            targetGroup.mediaType == .image ? CryptaVideoImport.isSupportedImage(url) : CryptaVideoImport.isSupportedVideo(url)
        }
        guard !candidates.isEmpty else {
            errorMessage = "没有找到可导入的\(targetGroup.itemNoun)"
            return
        }

        isImporting = true
        defer { isImporting = false }

        var imported: [CryptaVideo] = []
        let targetKind = LibraryKind(rawValue: targetGroup.id)
        for url in candidates {
            do {
                let store = self.store
                let video = try await Task.detached(priority: .userInitiated) { () async throws -> CryptaVideo in
                    if targetGroup.mediaType == .image {
                        return try await store.importImage(from: url, libraryKind: targetKind)
                    }
                    return try await store.importVideo(from: url, storageState: .encrypted, libraryKind: targetKind, mediaType: targetGroup.mediaType)
                }.value
                imported.append(video)
            } catch {
                showToast("导入失败", kind: .error)
                errorMessage = "导入失败：\(url.lastPathComponent) - \(error.localizedDescription)"
            }
        }

        guard !imported.isEmpty else { return }
        mediaSessions.invalidateImageGroup(targetGroup.id)
        videos.append(contentsOf: imported)
        videos = videos.sortedForDisplay()
        preloadThumbnails(for: imported)
        showToast("已导入 \(imported.count) 个\(targetGroup.itemNoun)")
        if targetGroup.requiresAuthentication {
            playEncryptedVideoAddedSound()
        }
        if let firstImportedID = imported.first?.id {
            selectedVideoIDs = [firstImportedID]
            primarySelectedVideoID = firstImportedID
        }
    }

    func requestGenerateSubtitles(_ video: CryptaVideo) {
        guard canGenerateSubtitles(for: video) else { return }
        if subtitleJob?.videoID == video.id {
            cancelSubtitleGeneration()
            return
        }
        if video.hasEmbeddedSubtitles {
            subtitleOverwriteRequest = SubtitleOverwriteRequest(video: video)
            return
        }
        generateSubtitles(for: video)
    }

    func confirmRegenerateSubtitles(_ request: SubtitleOverwriteRequest) {
        subtitleOverwriteRequest = nil
        generateSubtitles(for: request.video)
    }

    func cancelSubtitleGeneration() {
        subtitleTask?.cancel()
    }

    func previewSelectedVideo() async {
        guard canAccessSelectedGroup else { return }
        guard let video = selectedVideo else { return }
        guard !isImporting, !isWorking else { return }

        if quickLookPreviewController.isPreviewing(video) {
            quickLookPreviewController.close()
            quickLookGroupID = nil
            return
        }

        do {
            isWorking = true
            defer { isWorking = false }

            if video.isImage {
                let lease = try await mediaSessions.acquireImageGroupLease(
                    for: video,
                    groupVideos: imageGroupVideos(for: video.libraryKind.rawValue),
                    store: store
                )
                try quickLookPreviewController.togglePreview(
                    for: video,
                    mediaLease: lease
                )
            } else {
                guard let thumbnail = await VideoThumbnailLoader.thumbnail(for: video) else {
                    throw CryptaError.thumbnailFailed
                }
                try quickLookPreviewController.togglePreview(for: video, thumbnail: thumbnail)
            }
            quickLookGroupID = video.libraryKind.rawValue
        } catch {
            errorMessage = "预览失败：\(error.localizedDescription)"
        }
    }

    func play(_ video: CryptaVideo) async {
        guard canAccessSelectedGroup else { return }
        if video.isImage {
            await openImageWithPixea(video)
            return
        }
        if selectedGroup?.requiresAuthentication == false {
            await playInExternalPlayer(video)
            return
        }

        do {
            isWorking = true
            defer { isWorking = false }

            guard let group = selectedGroup else { return }
            let playerItem: AVPlayerItem
            let inMemoryPlaybackSource: InMemoryMediaPlaybackSource?
            if video.storageState == .encrypted {
                let dataSource = try store.inMemoryMediaDataSource(for: video)
                let playbackSource = InMemoryMediaPlaybackSource(dataSource: dataSource)
                playerItem = playbackSource.makePlayerItem(for: video)
                inMemoryPlaybackSource = playbackSource
            } else {
                let url = try store.storedPlainMediaURL(for: video)
                playerItem = AVPlayerItem(url: url)
                inMemoryPlaybackSource = nil
            }
            playerWindowController?.close()
            let playerWindowController = PlayerWindowController(
                title: video.displayName,
                playerItem: playerItem,
                inMemoryPlaybackSource: inMemoryPlaybackSource,
                startTimeSeconds: resumePosition(for: video),
                onProgress: { [weak self] seconds in
                    self?.savePlaybackPosition(for: video, seconds: seconds)
                },
                unlock: { [weak self] in
                    Task { await self?.unlock(group) }
                },
                onClose: { [weak self] in
                    self?.playerWindowController = nil
                    self?.playerGroupID = nil
                    VideoThumbnailLoader.clearMemoryCache()
                }
            )
            self.playerWindowController = playerWindowController
            playerGroupID = group.id
            playerWindowController.show()
        } catch {
            errorMessage = "播放失败：\(error.localizedDescription)"
        }
    }

    func requestRename(_ video: CryptaVideo) {
        guard canAccessSelectedGroup else { return }
        renameRequest = RenameRequest(video: video)
    }

    func rename(_ request: RenameRequest, to newName: String) async {
        let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return }

        do {
            let updated = try store.rename(request.video, to: trimmedName)
            replace(updated)
            mediaSessions.invalidateImageGroup(updated.libraryKind.rawValue)
            renameRequest = nil
            showToast("已重命名")
        } catch {
            showToast("重命名失败", kind: .error)
            errorMessage = "重命名失败：\(error.localizedDescription)"
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
                    quickLookGroupID = nil
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
            let affectedGroupIDs = Set(succeeded.map(\.libraryKind.rawValue))
            videos.removeAll { succeededIDs.contains($0.id) }
            selectedVideoIDs.subtract(succeededIDs)
            for video in succeeded {
                VideoThumbnailLoader.removeCachedThumbnail(for: video)
            }
            for groupID in affectedGroupIDs {
                mediaSessions.invalidateImageGroup(groupID)
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
        guard canAccessSelectedGroup else { return }
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
                    quickLookGroupID = nil
                }
                try store.delete(video)
                deleted.append(video)
            } catch {
                failedCount += 1
            }
        }

        if !deleted.isEmpty {
            let deletedIDs = Set(deleted.map(\.id))
            let affectedGroupIDs = Set(deleted.map(\.libraryKind.rawValue))
            videos.removeAll { deletedIDs.contains($0.id) }
            selectedVideoIDs.subtract(deletedIDs)
            for video in deleted {
                VideoThumbnailLoader.removeCachedThumbnail(for: video)
            }
            for groupID in affectedGroupIDs {
                mediaSessions.invalidateImageGroup(groupID)
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

    func selectVideoIDs(_ ids: Set<CryptaVideo.ID>, primaryID: CryptaVideo.ID?) {
        selectedVideoIDs = ids
        if let primaryID, ids.contains(primaryID) {
            primarySelectedVideoID = primaryID
        } else {
            primarySelectedVideoID = visibleVideos.first { ids.contains($0.id) }?.id
        }
    }

    func selectAllVisibleVideos() {
        let ids = Set(visibleVideos.map(\.id))
        selectedVideoIDs = ids
        primarySelectedVideoID = visibleVideos.first?.id
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
        guard canAccessSelectedGroup else {
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

    func showToast(_ message: String, kind: CryptaToast.Kind = .success) {
        withAnimation(.spring(duration: 0.24, bounce: 0.18)) {
            toast = CryptaToast(message: message, kind: kind)
        }
    }

    private func playInExternalPlayer(_ video: CryptaVideo) async {
        var lease: DecryptedMediaLease?
        do {
            isWorking = true
            defer { isWorking = false }

            let acquiredLease = try await mediaSessions.acquireMediaLease(for: video, store: store)
            lease = acquiredLease
            try await externalApplications.open(acquiredLease, with: .iina)
            lease = nil
            showToast("已交给 IINA 播放")
        } catch {
            lease?.release()
            showToast("播放失败", kind: .error)
            errorMessage = "播放失败：\(error.localizedDescription)"
        }
    }

    private func generateSubtitles(for video: CryptaVideo) {
        guard canGenerateSubtitles(for: video), subtitleTask == nil else { return }
        subtitleJob = SubtitleJobProgress(videoID: video.id, percent: 0, desc: "准备生成字幕")
        subtitleTask = Task { [weak self] in
            guard let self else { return }
            var lease: DecryptedMediaLease?
            do {
                let acquiredLease = try await mediaSessions.acquireMediaLease(for: video, store: store)
                lease = acquiredLease
                let generator = SubtitleGenerator { [weak self] percent, desc in
                    guard let self else { return }
                    self.subtitleJob = SubtitleJobProgress(videoID: video.id, percent: percent, desc: desc)
                }
                let force = video.hasEmbeddedSubtitles
                try await generator.generate(from: acquiredLease.url, force: force)
                try Task.checkCancellation()
                let updated = try await Task.detached(priority: .userInitiated) {
                    try self.store.commitModifiedVideo(at: acquiredLease.url, for: video)
                }.value
                replace(updated)
                subtitleJob = SubtitleJobProgress(videoID: video.id, percent: 100, desc: "字幕已写入视频")
                showToast("字幕已写入视频")
            } catch is CancellationError {
                showToast("已停止生成字幕")
            } catch {
                showToast(error.localizedDescription, kind: .error)
                errorMessage = error.localizedDescription
            }
            lease?.release()
            subtitleTask = nil
            subtitleJob = nil
        }
    }

    private func openImageWithPixea(_ video: CryptaVideo) async {
        var lease: DecryptedMediaLease?
        do {
            isWorking = true
            defer { isWorking = false }

            let acquiredLease = try await mediaSessions.acquireImageGroupLease(
                for: video,
                groupVideos: imageGroupVideos(for: video.libraryKind.rawValue),
                store: store
            )
            lease = acquiredLease
            try await externalApplications.open(acquiredLease, with: .pixea)
            lease = nil
            showToast("已交给 Pixea 打开")
        } catch {
            lease?.release()
            showToast("打开失败", kind: .error)
            errorMessage = "打开失败：\(error.localizedDescription)"
        }
    }

    private func canAccess(_ group: LibraryGroup) -> Bool {
        !group.requiresAuthentication || unlockedGroupIDs.contains(group.id)
    }

    func lockGroupAccess(_ groupID: String) {
        unlockedGroupIDs.remove(groupID)

        if selectedGroupID == groupID {
            renameRequest = nil
            deleteRequest = nil
            selectFirstVideoIfNeeded()
        }
        if quickLookGroupID == groupID {
            quickLookPreviewController.close()
            quickLookGroupID = nil
        }
        if playerGroupID == groupID {
            playerWindowController?.setProtected(true)
        }
        mediaSessions.invalidateImageGroup(groupID)
        VideoThumbnailLoader.clearMemoryCache()
    }

    private func lockGroups(where shouldLock: (LibraryGroup) -> Bool) {
        let groupIDs = groups
            .filter { unlockedGroupIDs.contains($0.id) && shouldLock($0) }
            .map(\.id)
        for groupID in groupIDs {
            lockGroupAccess(groupID)
        }
    }

    private func scheduleExtendedLock() {
        extendedLockTask?.cancel()
        guard groups.contains(where: {
            $0.encryptionLevel == .extended && unlockedGroupIDs.contains($0.id)
        }) else {
            extendedLockTask = nil
            return
        }

        extendedLockTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(180))
            guard !Task.isCancelled, let self else { return }
            lockGroups { $0.encryptionLevel == .extended }
            extendedLockTask = nil
        }
    }

    private func preloadThumbnails(for videos: [CryptaVideo]) {
        Task.detached(priority: .utility) {
            for video in videos {
                _ = await VideoThumbnailLoader.thumbnail(for: video)
            }
        }
    }

    private func imageGroupVideos(for groupID: String) -> [CryptaVideo] {
        videos.filter {
            $0.libraryKind.rawValue == groupID && $0.mediaType == .image
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
