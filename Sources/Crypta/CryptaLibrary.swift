import AppKit
import Foundation
import SwiftUI

@Observable
@MainActor
final class CryptaLibrary {
    private(set) var selectedSection: LibrarySection = .plain {
        didSet { selectFirstVideoIfNeeded() }
    }
    var selectedVideoID: CryptaVideo.ID?
    var renameRequest: RenameRequest?
    var deleteRequest: CryptaVideo?
    var toast: CryptaToast?
    private(set) var videos: [CryptaVideo] = []
    private(set) var isImporting = false
    private(set) var isWorking = false
    private(set) var isAuthenticatingEncryptedSection = false
    private(set) var encryptedSectionUnlocked = false
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

    func selectSection(_ section: LibrarySection) async {
        guard section != selectedSection else { return }

        switch section {
        case .plain:
            selectedSection = .plain
        case .encrypted:
            if encryptedSectionUnlocked {
                selectedSection = .encrypted
                return
            }

            guard !isAuthenticatingEncryptedSection else { return }
            isAuthenticatingEncryptedSection = true
            let didAuthenticate = await AuthenticationGate.authenticate(reason: "查看加密视频")
            isAuthenticatingEncryptedSection = false

            if didAuthenticate {
                encryptedSectionUnlocked = true
                selectedSection = .encrypted
            } else {
                showToast("认证未通过", kind: .error)
            }
        }
    }

    func resetEncryptedSectionAccess() {
        encryptedSectionUnlocked = false
        if selectedSection == .encrypted {
            selectedSection = .plain
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
        showToast("已导入 \(imported.count) 个视频")
        if targetState == .encrypted {
            playEncryptedVideoAddedSound()
        }
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
            playerWindowController?.close()
            let playerWindowController = PlayerWindowController(
                title: video.displayName,
                url: playback.url,
                cleanupURL: playback.cleanupURL,
                onClose: { [weak self] in
                    self?.playerWindowController = nil
                }
            )
            self.playerWindowController = playerWindowController
            playerWindowController.show()
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

    private func playEncryptedVideoAddedSound() {
        (NSSound(named: "Pebble") ?? NSSound(named: "Pop"))?.play()
    }
}
