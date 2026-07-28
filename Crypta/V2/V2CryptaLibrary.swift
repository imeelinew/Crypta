import AppKit
import AVFoundation
import Darwin
import Foundation
import LocalAuthentication
import SwiftUI

nonisolated private enum V2LibraryLoadError: Error, Sendable {
    case recoveryRequired(vaultID: UUID)
}

@Observable
@MainActor
final class CryptaLibrary {
    var groups: [LibraryGroup] = []
    var selectedGroupID: String? {
        didSet { selectFirstVideoIfNeeded() }
    }
    var selectedVideoIDs: Set<CryptaVideo.ID> = [] {
        didSet { normalizePrimarySelection() }
    }
    private var primarySelectedVideoID: CryptaVideo.ID?

    var renameRequest: RenameRequest?
    var deleteRequest: DeleteRequest?
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
    var protectedFormatErrorPresented = false
    var sourceCleanupWarningCount: Int?

    var recoveryKeyPresentation: RecoveryKeyPresentation?
    var recoveryAccessPresentation: RecoveryAccessPresentation?
    private(set) var isRecoveryAccessRequired = false
    private(set) var isRecoveringAccess = false
    var migrationSheetPresented = false
    private(set) var migrationPresentationState: MigrationPresentationState = .ready
    private(set) var migrationProgress = V2MigrationProgress(
        phase: .preparing,
        completedCount: 0,
        totalCount: 0
    )

    private var store: V2VaultStore?
    private var legacyReader: V1LegacyReader?
    private let mediaSessions: DecryptedMediaSessionManager
    private let externalApplications = ExternalMediaApplicationController()
    private var vaultRecords: [UUID: V2VaultRecord] = [:]
    private var vaultObjectCounts: [UUID: Int] = [:]
    private var objectRecords: [UUID: V2ObjectRecord] = [:]
    private var vaultSessions: [UUID: V2VaultSession] = [:]
    private var pendingMigrationRecoveryKey: V2RecoveryKey?

    private var playerWindowController: PlayerWindowController?
    private var playerGroupID: String?
    private let imageWindowController = ProtectedImageWindowController()
    private var imageWindowGroupID: String?
    private var extendedLockTask: Task<Void, Never>?
    private var playbackPositionSaveTasks: [CryptaVideo.ID: Task<Void, Never>] = [:]
    private let thumbnailCache = NSCache<NSUUID, NSImage>()
    private var thumbnailTasks: [UUID: Task<NSImage?, Never>] = [:]

    init(
        store: V2VaultStore? = nil,
        legacyReader: V1LegacyReader? = nil,
        mediaSessions: DecryptedMediaSessionManager? = nil
    ) {
        self.store = store
        self.legacyReader = legacyReader
        self.mediaSessions = mediaSessions ?? .shared
        thumbnailCache.countLimit = 80
        thumbnailCache.totalCostLimit = 64 * 1024 * 1024
    }

    isolated deinit {
        for session in vaultSessions.values {
            session.invalidate()
        }
        for task in playbackPositionSaveTasks.values {
            task.cancel()
        }
        for task in thumbnailTasks.values {
            task.cancel()
        }
    }

    var selectedGroup: LibraryGroup? {
        guard let selectedGroupID else { return nil }
        return groups.first { $0.id == selectedGroupID }
    }

    var visibleVideos: [CryptaVideo] {
        guard canAccessSelectedGroup, let group = selectedGroup else { return [] }
        let groupVideos = videos.filter {
            $0.libraryKind.rawValue == group.id
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? groupVideos : groupVideos.filter {
            $0.displayName.localizedStandardContains(query)
        }
        return sortMode.sorted(filtered)
    }

    var visibleVideoSummary: String {
        let visible = visibleVideos
        let totalBytes = visible.reduce(Int64(0)) { $0 + $1.byteCount }
        let size = ByteCountFormatter.string(
            fromByteCount: totalBytes,
            countStyle: .file
        )
        return "\(visible.count) 个\(selectedGroup?.itemNoun ?? "文件") · \(size)"
    }

    var canAccessSelectedGroup: Bool {
        guard let group = selectedGroup else { return false }
        return canAccess(group)
    }

    var selectedVideo: CryptaVideo? {
        guard canAccessSelectedGroup else { return nil }
        if let primarySelectedVideoID,
           let primary = visibleVideos.first(where: {
               $0.id == primarySelectedVideoID
                   && selectedVideoIDs.contains($0.id)
           }) {
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

    func load() async {
        do {
            let store = try await resolveStore()
            try await Task.detached(priority: .utility) {
                try store.recoverFilesystem()
            }.value

            let legacyReader = legacyReader ?? V1LegacyReader()
            self.legacyReader = legacyReader
            let legacyExists = FileManager.default.fileExists(
                atPath: legacyReader.locations.encryptedIndex.path
            )
            let migrationState = try await Task.detached(priority: .utility) {
                try store.metadata.migrationState()
            }.value

            if legacyExists {
                if migrationState == nil {
                    let existingVaults = try await Task.detached(priority: .utility) {
                        try store.metadata.loadVaults()
                    }.value
                    guard existingVaults.isEmpty else {
                        throw V2Error.migrationIncomplete
                    }
                    recoveryKeyPresentation = RecoveryKeyPresentation(
                        purpose: .migration,
                        recoveryKey: try V2RecoveryKey()
                    )
                } else {
                    migrationPresentationState = .ready
                    migrationProgress = V2MigrationProgress(
                        phase: migrationState?.phase ?? .preparing,
                        completedCount: migrationState?.committedCount ?? 0,
                        totalCount: migrationState?.totalCount ?? 0
                    )
                    migrationSheetPresented = true
                }
                return
            }

            try await loadV2Library()
        } catch V2LibraryLoadError.recoveryRequired(let vaultID) {
            isRecoveryAccessRequired = true
            presentRecoveryAccess(for: vaultID)
        } catch {
            let recoveryAvailable = await Task.detached(priority: .utility) {
                V2VaultStore.liveRecoveryIsAvailable()
            }.value
            if recoveryAvailable {
                isRecoveryAccessRequired = true
                presentRecoveryAccess()
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }

    func selectGroup(_ group: LibraryGroup) async {
        guard group.id != selectedGroupID else { return }
        if let previous = selectedGroup,
           previous.encryptionLevel.locksOnGroupChange {
            lockGroupAccess(previous.id)
        }
        selectedGroupID = group.id
    }

    func unlockEncryptedSection() async {
        guard let group = selectedGroup else { return }
        await unlock(group)
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
        guard let vaultID = UUID(uuidString: group.id) else { return false }
        return vaultObjectCounts[vaultID] == 0
    }

    func canManuallyLock(_ group: LibraryGroup) -> Bool {
        group.encryptionLevel.allowsManualLock
            && unlockedGroupIDs.contains(group.id)
    }

    func manuallyLock(_ group: LibraryGroup) {
        guard canManuallyLock(group) else { return }
        lockGroupAccess(group.id)
    }

    func importFiles(from urls: [URL]) async {
        guard let targetGroup = selectedGroup,
              canAccess(targetGroup),
              let context = try? vaultContext(for: targetGroup.id) else {
            return
        }
        let candidates = urls.filter { url in
            targetGroup.mediaType == .image
                ? CryptaVideoImport.isSupportedImage(url)
                : CryptaVideoImport.isSupportedVideo(url)
        }
        guard !candidates.isEmpty else {
            errorMessage = "没有找到可导入的\(targetGroup.itemNoun)"
            return
        }

        isImporting = true
        defer { isImporting = false }
        var importedRecords: [V2ObjectRecord] = []
        var sourceCleanupFailures = 0

        for url in candidates {
            do {
                let store = context.store
                let session = context.session
                let mediaType = targetGroup.mediaType
                let imported = try await Task.detached(
                    priority: .userInitiated
                ) { () async throws -> (V2ImportResult, Data?) in
                    let inspection = await V2ImportInspection.inspect(
                        url: url,
                        mediaType: mediaType
                    )
                    let result = try store.importFile(
                        from: url,
                        into: session.vaultID,
                        session: session,
                        request: V2ImportRequest(
                            displayName: url.deletingPathExtension().lastPathComponent,
                            originalExtension: url.pathExtension.lowercased(),
                            mediaType: mediaType,
                            durationSeconds: inspection.durationSeconds
                        )
                    )
                    if let thumbnailData = inspection.thumbnailData {
                        try? store.saveThumbnail(
                            thumbnailData,
                            for: result.object,
                            session: session
                        )
                    }
                    return (result, inspection.thumbnailData)
                }.value

                importedRecords.append(imported.0.object)
                objectRecords[imported.0.object.id] = imported.0.object
                vaultObjectCounts[imported.0.object.vaultID, default: 0] += 1
                if let thumbnailData = imported.1,
                   let image = NSImage(data: thumbnailData) {
                    cacheThumbnail(image, objectID: imported.0.object.id)
                }
                if !imported.0.sourceRemoved {
                    sourceCleanupFailures += 1
                }
            } catch {
                showToast("导入失败", kind: .error)
                errorMessage =
                    "导入失败：\(url.lastPathComponent) - \(error.localizedDescription)"
            }
        }

        guard !importedRecords.isEmpty else { return }
        let importedVideos = importedRecords.map(\.libraryVideo)
        videos.append(contentsOf: importedVideos)
        videos = videos.sortedForDisplay()
        if let firstID = importedVideos.first?.id {
            selectedVideoIDs = [firstID]
            primarySelectedVideoID = firstID
        }
        showToast("已导入 \(importedVideos.count) 个\(targetGroup.itemNoun)")
        if targetGroup.requiresAuthentication {
            playEncryptedVideoAddedSound()
        }
        if sourceCleanupFailures > 0 {
            sourceCleanupWarningCount = sourceCleanupFailures
        }
    }

    func previewSelectedVideo() async {
        guard canAccessSelectedGroup,
              let video = selectedVideo,
              !isImporting,
              !isWorking else {
            return
        }
        if imageWindowController.isShowing(objectID: video.id) {
            imageWindowController.close()
            imageWindowGroupID = nil
            return
        }
        do {
            isWorking = true
            defer { isWorking = false }
            guard let image = await thumbnail(for: video) else {
                throw CryptaError.thumbnailFailed
            }
            showImageWindow(image: image, video: video, toggles: true)
        } catch {
            errorMessage = "预览失败：\(error.localizedDescription)"
        }
    }

    func play(_ video: CryptaVideo) async {
        guard canAccessSelectedGroup,
              let group = selectedGroup,
              let vaultID = UUID(uuidString: group.id),
              let vault = vaultRecords[vaultID] else {
            return
        }
        let route = V2PlaybackPolicy.route(
            encryptionLevel: vault.encryptionLevel,
            mediaType: vault.mediaType
        )
        switch route {
        case .externalVideo:
            await openExternally(video, target: .iina)
        case .externalImage:
            await openExternally(video, target: .pixea)
        case .builtInImage:
            await openProtectedImage(video)
        case .builtInVideo:
            await playProtectedVideo(video, group: group)
        }
    }

    func requestRename(_ video: CryptaVideo) {
        guard canAccessSelectedGroup else { return }
        renameRequest = RenameRequest(video: video)
    }

    func rename(_ request: RenameRequest, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            let context = try objectContext(for: request.video.id)
            let updated = try await Task.detached(priority: .userInitiated) {
                try context.store.renameObject(
                    context.object,
                    to: trimmed,
                    session: context.session
                )
            }.value
            objectRecords[updated.id] = updated
            replace(updated.libraryVideo)
            renameRequest = nil
            showToast("已重命名")
        } catch {
            showToast("重命名失败", kind: .error)
            errorMessage = "重命名失败：\(error.localizedDescription)"
        }
    }

    func decryptSelectedVideos(to destinationDirectory: URL) async {
        let targets = selectedVideos
        guard !targets.isEmpty else { return }
        let itemNoun = targets.first?.isImage == true ? "图片" : "视频"
        isWorking = true
        defer { isWorking = false }

        var succeeded: [CryptaVideo] = []
        var failedCount = 0
        for video in targets {
            do {
                closeViewerIfNeeded(for: video)
                let context = try objectContext(for: video.id)
                _ = try await Task.detached(priority: .userInitiated) {
                    try context.store.exportAndRemove(
                        object: context.object,
                        session: context.session,
                        destinationDirectory: destinationDirectory
                    )
                }.value
                succeeded.append(video)
            } catch {
                failedCount += 1
            }
        }
        removeVideos(succeeded)
        if failedCount > 0 {
            showToast(
                "已解密 \(succeeded.count) 个，失败 \(failedCount) 个",
                kind: .error
            )
            errorMessage =
                "有 \(failedCount) 个\(itemNoun)解密失败，失败项仍保留在加密库中。"
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
                closeViewerIfNeeded(for: video)
                let context = try objectContext(for: video.id)
                try await Task.detached(priority: .userInitiated) {
                    try context.store.deleteObject(
                        id: context.object.id,
                        vaultID: context.object.vaultID
                    )
                }.value
                deleted.append(video)
            } catch {
                failedCount += 1
            }
        }
        removeVideos(deleted)
        deleteRequest = nil
        if failedCount > 0 {
            showToast(
                "已删除 \(deleted.count) 个，失败 \(failedCount) 个",
                kind: .error
            )
            errorMessage = "有 \(failedCount) 个\(itemNoun)删除失败。"
        } else {
            showToast("已删除")
        }
    }

    func selectOnly(_ video: CryptaVideo) {
        selectedVideoIDs = [video.id]
        primarySelectedVideoID = video.id
    }

    func selectVideoIDs(
        _ ids: Set<CryptaVideo.ID>,
        primaryID: CryptaVideo.ID?
    ) {
        selectedVideoIDs = ids
        if let primaryID, ids.contains(primaryID) {
            primarySelectedVideoID = primaryID
        } else {
            primarySelectedVideoID = visibleVideos.first {
                ids.contains($0.id)
            }?.id
        }
    }

    func selectAllVisibleVideos() {
        let ids = Set(visibleVideos.map(\.id))
        selectedVideoIDs = ids
        primarySelectedVideoID = visibleVideos.first?.id
    }

    func cachedThumbnail(for video: CryptaVideo) -> NSImage? {
        thumbnailCache.object(forKey: video.id as NSUUID)
    }

    func thumbnail(for video: CryptaVideo) async -> NSImage? {
        if let cached = cachedThumbnail(for: video) {
            return cached
        }
        if let existing = thumbnailTasks[video.id] {
            return await existing.value
        }
        let task = Task<NSImage?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.loadThumbnail(for: video)
        }
        thumbnailTasks[video.id] = task
        let image = await task.value
        thumbnailTasks[video.id] = nil
        if let image {
            cacheThumbnail(image, objectID: video.id)
        }
        return image
    }

    func createGroup(
        name: String,
        encryptionLevel: EncryptionLevel,
        mediaType: MediaType
    ) async {
        do {
            let store = try requireStore()
            let creation = try await Task.detached(priority: .userInitiated) {
                try store.createVault(
                    name: name,
                    encryptionLevel: encryptionLevel,
                    mediaType: mediaType,
                    recoveryConfirmed: false
                )
            }.value
            vaultRecords[creation.vault.id] = creation.vault
            vaultObjectCounts[creation.vault.id] = 0
            vaultSessions[creation.vault.id] = creation.session
            unlockedGroupIDs.insert(creation.vault.id.uuidString)
            groups.append(creation.vault.libraryGroup)
            selectedGroupID = creation.vault.id.uuidString
            recoveryKeyPresentation = RecoveryKeyPresentation(
                purpose: .vault(creation.vault.id),
                recoveryKey: creation.recoveryKey
            )
            showToast("已创建保险箱")
        } catch {
            showToast("创建保险箱失败", kind: .error)
            errorMessage = error.localizedDescription
        }
    }

    func renameGroup(_ request: EditGroupRequest, to newName: String) async {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = UUID(uuidString: request.group.id) else {
            return
        }
        do {
            let store = try requireStore()
            try await Task.detached(priority: .userInitiated) {
                try store.renameVault(id: id, to: trimmed)
            }.value
            if var record = vaultRecords[id] {
                record.name = trimmed
                vaultRecords[id] = record
            }
            if let index = groups.firstIndex(where: { $0.id == request.group.id }) {
                groups[index].name = trimmed
            }
            editGroupRequest = nil
            showToast("已重命名")
        } catch {
            showToast("重命名失败", kind: .error)
            errorMessage = error.localizedDescription
        }
    }

    func deleteGroup(_ group: LibraryGroup) async {
        guard canDeleteGroup(group), let id = UUID(uuidString: group.id) else {
            showToast("保险箱内仍有文件，无法删除", kind: .error)
            return
        }
        do {
            let store = try requireStore()
            try await Task.detached(priority: .userInitiated) {
                try store.deleteVault(id: id)
            }.value
            vaultSessions.removeValue(forKey: id)?.invalidate()
            lockGroupAccess(group.id)
            vaultRecords.removeValue(forKey: id)
            vaultObjectCounts.removeValue(forKey: id)
            groups.removeAll { $0.id == group.id }
            if selectedGroupID == group.id {
                selectedGroupID = groups.first?.id
            }
            showToast("已删除保险箱")
        } catch {
            showToast("删除保险箱失败", kind: .error)
            errorMessage = error.localizedDescription
        }
    }

    func requestEditGroup(_ group: LibraryGroup) {
        editGroupRequest = EditGroupRequest(group: group)
    }

    func moveGroups(from source: IndexSet, to destination: Int) {
        var updated = groups
        updated.move(fromOffsets: source, toOffset: destination)
        let previous = groups
        groups = updated
        let ids = updated.compactMap { UUID(uuidString: $0.id) }
        guard ids.count == updated.count, let store else {
            groups = previous
            return
        }
        do {
            try store.saveVaultOrder(ids)
            for (position, id) in ids.enumerated() {
                vaultRecords[id]?.position = position
            }
        } catch {
            groups = previous
            showToast("调整顺序失败", kind: .error)
            errorMessage = error.localizedDescription
        }
    }

    func copyRecoveryKey(_ presentation: RecoveryKeyPresentation) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(
            presentation.recoveryKey.description,
            forType: .string
        )
    }

    func saveRecoveryKey(_ presentation: RecoveryKeyPresentation) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = ApprovedCopy.recoveryFileDefaultName
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try V2SecureFileWriter.write(
                Data((presentation.recoveryKey.description + "\n").utf8),
                to: url
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func confirmRecoveryKey(_ presentation: RecoveryKeyPresentation) {
        guard recoveryKeyPresentation?.id == presentation.id else { return }
        switch presentation.purpose {
        case .migration:
            pendingMigrationRecoveryKey = presentation.recoveryKey
            recoveryKeyPresentation = nil
            migrationPresentationState = .ready
            migrationProgress = V2MigrationProgress(
                phase: .preparing,
                completedCount: 0,
                totalCount: 0
            )
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.migrationSheetPresented = true
            }
        case .vault(let vaultID):
            do {
                try requireStore().confirmRecoveryKey(vaultID: vaultID)
                vaultRecords[vaultID]?.recoveryConfirmed = true
                recoveryKeyPresentation = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func presentRecoveryAccess(for vaultID: UUID? = nil) {
        recoveryAccessPresentation = RecoveryAccessPresentation(
            expectedVaultID: vaultID
        )
    }

    func recoverAccess(
        phrase: String,
        presentation: RecoveryAccessPresentation
    ) async -> RecoveryAccessAttemptResult {
        guard recoveryAccessPresentation?.id == presentation.id,
              !isRecoveringAccess else {
            return .failure
        }
        let recoveryKey: V2RecoveryKey
        do {
            recoveryKey = try V2RecoveryKey(phrase: phrase)
        } catch {
            return .invalidKey
        }

        isRecoveringAccess = true
        defer { isRecoveringAccess = false }
        do {
            let expectedVaultID = presentation.expectedVaultID
            let recovered = try await Task.detached(priority: .userInitiated) {
                try V2VaultStore.recoverLiveAccess(
                    recoveryKey: recoveryKey,
                    expectedVaultID: expectedVaultID
                )
            }.value
            store = recovered.store
            do {
                try await loadV2Library(initialSession: recovered.session)
            } catch {
                recovered.session.invalidate()
                throw error
            }
            selectedGroupID = recovered.session.vaultID.uuidString
            isRecoveryAccessRequired = false
            recoveryAccessPresentation = nil
            showToast(ApprovedCopy.recoveryAccessComplete)
            return .success
        } catch V2Error.invalidRecoveryKey {
            return .invalidKey
        } catch V2Error.authenticationFailed {
            return .invalidKey
        } catch {
            return .failure
        }
    }

    func startMigration() async {
        guard migrationPresentationState == .ready
                || migrationPresentationState == .failed,
              let store,
              let legacyReader else {
            return
        }
        migrationPresentationState = .running
        let recoveryKey = pendingMigrationRecoveryKey
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try V2LegacyMigrator(
                    source: legacyReader,
                    target: store
                ).migrate(
                    recoveryKey: recoveryKey,
                    removeLegacyAfterCommit: true
                ) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        self?.migrationProgress = progress
                    }
                }
            }.value
            pendingMigrationRecoveryKey = nil
            try await loadV2Library()
            migrationPresentationState = .complete
            try? await Task.sleep(for: .seconds(1.2))
            migrationSheetPresented = false
        } catch {
            migrationPresentationState = .failed
        }
    }

    func showToast(
        _ message: String,
        kind: CryptaToast.Kind = .success
    ) {
        withAnimation(.spring(duration: 0.24, bounce: 0.18)) {
            toast = CryptaToast(message: message, kind: kind)
        }
    }

    func lockGroupAccess(_ groupID: String) {
        guard let vaultID = UUID(uuidString: groupID),
              vaultRecords[vaultID]?.encryptionLevel != .standard else {
            return
        }
        unlockedGroupIDs.remove(groupID)
        vaultSessions.removeValue(forKey: vaultID)?.invalidate()
        let removedIDs = Set(
            videos.filter { $0.libraryKind.rawValue == groupID }.map(\.id)
        )
        videos.removeAll { removedIDs.contains($0.id) }
        for id in removedIDs {
            objectRecords.removeValue(forKey: id)
            thumbnailCache.removeObject(forKey: id as NSUUID)
            thumbnailTasks.removeValue(forKey: id)?.cancel()
        }
        selectedVideoIDs.subtract(removedIDs)
        if selectedGroupID == groupID {
            renameRequest = nil
            deleteRequest = nil
            selectFirstVideoIfNeeded()
        }
        if imageWindowGroupID == groupID {
            imageWindowController.close()
            imageWindowGroupID = nil
        }
        if playerGroupID == groupID {
            playerWindowController?.close()
            playerWindowController = nil
            playerGroupID = nil
        }
    }

    private func resolveStore() async throws -> V2VaultStore {
        if let store { return store }
        let opened = try await Task.detached(priority: .userInitiated) {
            try V2VaultStore.openLive()
        }.value
        store = opened
        return opened
    }

    private func loadV2Library(
        initialSession: V2VaultSession? = nil
    ) async throws {
        let store = try requireStore()
        for session in vaultSessions.values {
            session.invalidate()
        }
        vaultSessions.removeAll()
        objectRecords.removeAll()
        videos.removeAll()
        unlockedGroupIDs.removeAll()
        clearThumbnailCache()

        let vaults = try await Task.detached(priority: .userInitiated) {
            try store.metadata.loadVaults()
        }.value
        let objectCounts = try await Task.detached(priority: .userInitiated) {
            try store.metadata.objectCountsByVault()
        }.value
        vaultRecords = Dictionary(uniqueKeysWithValues: vaults.map { ($0.id, $0) })
        vaultObjectCounts = Dictionary(
            uniqueKeysWithValues: vaults.map {
                ($0.id, objectCounts[$0.id, default: 0])
            }
        )
        groups = vaults.map(\.libraryGroup)

        for vault in vaults where vault.encryptionLevel == .standard {
            do {
                let session: V2VaultSession
                if let initialSession,
                   initialSession.vaultID == vault.id,
                   initialSession.isUnlocked {
                    session = initialSession
                } else {
                    session = try await Task.detached(priority: .userInitiated) {
                        try store.unlock(vaultID: vault.id, reason: "")
                    }.value
                }
                let objects = try await Task.detached(priority: .userInitiated) {
                    try store.metadata.loadObjects(
                        vaultID: vault.id,
                        session: session
                    )
                }.value
                vaultSessions[vault.id] = session
                unlockedGroupIDs.insert(vault.id.uuidString)
                for object in objects {
                    objectRecords[object.id] = object
                    videos.append(object.libraryVideo)
                }
            } catch {
                throw V2LibraryLoadError.recoveryRequired(vaultID: vault.id)
            }
        }
        if let initialSession,
           initialSession.isUnlocked,
           let recoveredVault = vaultRecords[initialSession.vaultID],
           recoveredVault.encryptionLevel != .standard {
            let objects = try await Task.detached(priority: .userInitiated) {
                try store.metadata.loadObjects(
                    vaultID: initialSession.vaultID,
                    session: initialSession
                )
            }.value
            vaultSessions[initialSession.vaultID] = initialSession
            unlockedGroupIDs.insert(initialSession.vaultID.uuidString)
            for object in objects {
                objectRecords[object.id] = object
                videos.append(object.libraryVideo)
            }
        } else if let initialSession,
                  vaultRecords[initialSession.vaultID] == nil {
            initialSession.invalidate()
            throw V2Error.missingVault
        }
        videos = videos.sortedForDisplay()
        if let selectedGroupID,
           !groups.contains(where: { $0.id == selectedGroupID }) {
            self.selectedGroupID = groups.first?.id
        } else if selectedGroupID == nil {
            selectedGroupID = groups.first?.id
        }
        selectFirstVideoIfNeeded()
        try presentPendingStandardRecoveryIfNeeded()
    }

    private func unlock(_ group: LibraryGroup) async {
        guard group.requiresAuthentication,
              !unlockedGroupIDs.contains(group.id),
              !isAuthenticatingEncryptedSection,
              let vaultID = UUID(uuidString: group.id) else {
            return
        }
        isAuthenticatingEncryptedSection = true
        defer { isAuthenticatingEncryptedSection = false }
        do {
            let store = try requireStore()
            let session = try await Task.detached(priority: .userInitiated) {
                try store.unlock(
                    vaultID: vaultID,
                    reason: "查看\(group.name)"
                )
            }.value
            let objects = try await Task.detached(priority: .userInitiated) {
                try store.metadata.loadObjects(
                    vaultID: vaultID,
                    session: session
                )
            }.value
            vaultSessions[vaultID]?.invalidate()
            vaultSessions[vaultID] = session
            unlockedGroupIDs.insert(group.id)
            videos.removeAll { $0.libraryKind.rawValue == group.id }
            for object in objects {
                objectRecords[object.id] = object
                videos.append(object.libraryVideo)
            }
            videos = videos.sortedForDisplay()
            selectFirstVideoIfNeeded()

            if vaultRecords[vaultID]?.recoveryConfirmed == false {
                let key = try await Task.detached(priority: .userInitiated) {
                    try store.replaceRecoveryKey(session: session)
                }.value
                vaultRecords[vaultID]?.recoveryConfirmed = false
                recoveryKeyPresentation = RecoveryKeyPresentation(
                    purpose: .vault(vaultID),
                    recoveryKey: key
                )
            }
            if group.encryptionLevel == .extended, !NSApp.isActive {
                scheduleExtendedLock()
            }
            if group.encryptionLevel == .maximum, !NSApp.isActive {
                lockGroupAccess(group.id)
            }
        } catch let error as LAError
        where error.code == .userCancel || error.code == .appCancel {
            return
        } catch {
            presentRecoveryAccess(for: vaultID)
        }
    }

    private func presentPendingStandardRecoveryIfNeeded() throws {
        guard recoveryKeyPresentation == nil,
              let vault = vaultRecords.values
                .filter({
                    $0.encryptionLevel == .standard && !$0.recoveryConfirmed
                })
                .sorted(by: { $0.position < $1.position })
                .first,
              let session = vaultSessions[vault.id],
              let store else {
            return
        }
        let key = try store.replaceRecoveryKey(session: session)
        vaultRecords[vault.id]?.recoveryConfirmed = false
        recoveryKeyPresentation = RecoveryKeyPresentation(
            purpose: .vault(vault.id),
            recoveryKey: key
        )
    }

    private func openExternally(
        _ video: CryptaVideo,
        target: ExternalMediaApplicationController.Target
    ) async {
        var lease: DecryptedMediaLease?
        var unadoptedCleanupURL: URL?
        do {
            isWorking = true
            defer { isWorking = false }
            let context = try objectContext(for: video.id)
            let playback = try await Task.detached(priority: .userInitiated) {
                try context.store.materializeForExternalPlayback(
                    object: context.object,
                    vault: context.vault,
                    session: context.session
                )
            }.value
            unadoptedCleanupURL = playback.cleanupURL
            let adoptedLease = try mediaSessions.adoptPlaybackURL(playback)
            unadoptedCleanupURL = nil
            lease = adoptedLease
            try await externalApplications.open(adoptedLease, with: target)
            lease = nil
            showToast(
                target == .iina
                    ? "已交给 IINA 播放"
                    : "已交给 Pixea 打开"
            )
        } catch {
            lease?.release()
            if let unadoptedCleanupURL {
                try? FileManager.default.removeItem(at: unadoptedCleanupURL)
            }
            showToast(video.isImage ? "打开失败" : "播放失败", kind: .error)
            errorMessage =
                "\(video.isImage ? "打开" : "播放")失败：\(error.localizedDescription)"
        }
    }

    private func playProtectedVideo(
        _ video: CryptaVideo,
        group: LibraryGroup
    ) async {
        do {
            isWorking = true
            defer { isWorking = false }
            let context = try objectContext(for: video.id)
            let source = try await Task.detached(priority: .userInitiated) {
                try context.store.inMemoryMediaDataSource(
                    for: context.object,
                    session: context.session
                )
            }.value
            let playbackSource = InMemoryMediaPlaybackSource(dataSource: source)
            let item = playbackSource.makePlayerItem(for: context.object)
            let isPlayable = try await item.asset.load(.isPlayable)
            guard isPlayable else {
                playbackSource.invalidate()
                protectedFormatErrorPresented = true
                return
            }

            playerWindowController?.close()
            let controller = PlayerWindowController(
                title: video.displayName,
                playerItem: item,
                inMemoryPlaybackSource: playbackSource,
                startTimeSeconds: resumePosition(for: video),
                onProgress: { [weak self] seconds in
                    self?.savePlaybackPosition(for: video, seconds: seconds)
                },
                unlock: {},
                onFailure: { [weak self] in
                    self?.protectedFormatErrorPresented = true
                },
                onClose: { [weak self] in
                    self?.playerWindowController = nil
                    self?.playerGroupID = nil
                }
            )
            playerWindowController = controller
            playerGroupID = group.id
            controller.show()
        } catch {
            protectedFormatErrorPresented = true
        }
    }

    private func openProtectedImage(_ video: CryptaVideo) async {
        do {
            isWorking = true
            defer { isWorking = false }
            let context = try objectContext(for: video.id)
            let data = try await Task.detached(priority: .userInitiated) {
                guard context.object.byteCount <= Int64(Int.max) else {
                    throw V2Error.rangeOutOfBounds
                }
                return try context.store.reader(
                    for: context.object,
                    session: context.session,
                    maximumCacheBytes: 16 * 1024 * 1024
                ).data(
                    offset: 0,
                    length: Int(context.object.byteCount)
                )
            }.value
            guard let image = NSImage(data: data) else {
                throw CryptaError.thumbnailFailed
            }
            showImageWindow(image: image, video: video, toggles: false)
        } catch {
            showToast("打开失败", kind: .error)
            errorMessage = "打开失败：\(error.localizedDescription)"
        }
    }

    private func showImageWindow(
        image: NSImage,
        video: CryptaVideo,
        toggles: Bool
    ) {
        imageWindowGroupID = video.libraryKind.rawValue
        let onClose: () -> Void = { [weak self] in
            self?.imageWindowGroupID = nil
        }
        if toggles {
            imageWindowController.toggle(
                image: image,
                title: video.displayName,
                objectID: video.id,
                onClose: onClose
            )
        } else {
            imageWindowController.show(
                image: image,
                title: video.displayName,
                objectID: video.id,
                onClose: onClose
            )
        }
    }

    private func loadThumbnail(for video: CryptaVideo) async -> NSImage? {
        guard let context = try? objectContext(for: video.id) else { return nil }
        do {
            let thumbnailTask = Task.detached(priority: .utility) {
                try context.store.loadThumbnail(
                    for: context.object,
                    session: context.session
                )
            }
            if let encryptedThumbnail = try await thumbnailTask.value {
                return NSImage(data: encryptedThumbnail)
            }

            if video.isImage {
                let data = try await Task.detached(priority: .utility) {
                    guard context.object.byteCount <= Int64(Int.max) else {
                        throw V2Error.rangeOutOfBounds
                    }
                    return try context.store.reader(
                        for: context.object,
                        session: context.session,
                        maximumCacheBytes: 8 * 1024 * 1024
                    ).data(
                        offset: 0,
                        length: Int(context.object.byteCount)
                    )
                }.value
                guard let image = NSImage(data: data) else { return nil }
                if let thumbnailData = V2ImportInspection.jpegThumbnailData(
                    from: image
                ) {
                    try? await Task.detached(priority: .utility) {
                        try context.store.saveThumbnail(
                            thumbnailData,
                            for: context.object,
                            session: context.session
                        )
                    }.value
                    return NSImage(data: thumbnailData)
                }
                return image
            }

            guard context.vault.encryptionLevel == .standard else {
                return nil
            }
            let thumbnailData = await Task.detached(
                priority: .utility
            ) { () async -> Data? in
                guard let playback = try? context.store
                    .materializeForExternalPlayback(
                        object: context.object,
                        vault: context.vault,
                        session: context.session
                    ) else {
                    return nil
                }
                defer {
                    if let cleanupURL = playback.cleanupURL {
                        try? FileManager.default.removeItem(at: cleanupURL)
                    }
                }
                return await VideoThumbnailLoader.thumbnailData(
                    from: playback.url
                )
            }.value
            if let thumbnailData {
                try? await Task.detached(priority: .utility) {
                    try context.store.saveThumbnail(
                        thumbnailData,
                        for: context.object,
                        session: context.session
                    )
                }.value
                return NSImage(data: thumbnailData)
            }
        } catch {
            return nil
        }
        return nil
    }

    private func cacheThumbnail(_ image: NSImage, objectID: UUID) {
        let cost: Int
        if let representation = image.representations.first {
            cost = max(
                1,
                representation.pixelsWide
                    * representation.pixelsHigh
                    * 4
            )
        } else {
            cost = max(1, Int(image.size.width * image.size.height * 4))
        }
        thumbnailCache.setObject(
            image,
            forKey: objectID as NSUUID,
            cost: cost
        )
    }

    private func clearThumbnailCache() {
        thumbnailCache.removeAllObjects()
        for task in thumbnailTasks.values {
            task.cancel()
        }
        thumbnailTasks.removeAll()
    }

    private func canAccess(_ group: LibraryGroup) -> Bool {
        !group.requiresAuthentication || unlockedGroupIDs.contains(group.id)
    }

    private func lockGroups(
        where shouldLock: (LibraryGroup) -> Bool
    ) {
        let ids = groups
            .filter {
                unlockedGroupIDs.contains($0.id) && shouldLock($0)
            }
            .map(\.id)
        for id in ids {
            lockGroupAccess(id)
        }
    }

    private func scheduleExtendedLock() {
        extendedLockTask?.cancel()
        guard groups.contains(where: {
            $0.encryptionLevel == .extended
                && unlockedGroupIDs.contains($0.id)
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

    private func closeViewerIfNeeded(for video: CryptaVideo) {
        if imageWindowController.isShowing(objectID: video.id) {
            imageWindowController.close()
            imageWindowGroupID = nil
        }
    }

    private func removeVideos(_ removed: [CryptaVideo]) {
        guard !removed.isEmpty else { return }
        let ids = Set(removed.map(\.id))
        videos.removeAll { ids.contains($0.id) }
        selectedVideoIDs.subtract(ids)
        for id in ids {
            if let vaultID = objectRecords[id]?.vaultID {
                vaultObjectCounts[vaultID] = max(
                    0,
                    vaultObjectCounts[vaultID, default: 0] - 1
                )
            }
            objectRecords.removeValue(forKey: id)
            thumbnailCache.removeObject(forKey: id as NSUUID)
            thumbnailTasks.removeValue(forKey: id)?.cancel()
        }
        selectFirstVideoIfNeeded()
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
        if let selected = visibleVideos.first(where: {
            selectedVideoIDs.contains($0.id)
        }) {
            primarySelectedVideoID = selected.id
        } else if let first = visibleVideos.first {
            selectedVideoIDs = [first.id]
            primarySelectedVideoID = first.id
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
           visibleVideos.contains(where: {
               $0.id == primarySelectedVideoID
           }) {
            return
        }
        primarySelectedVideoID = visibleVideos.first {
            selectedVideoIDs.contains($0.id)
        }?.id
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
        if let duration = video.durationSeconds,
           duration.isFinite,
           duration - seconds < 5 {
            return 0
        }
        return seconds
    }

    private func savePlaybackPosition(
        for video: CryptaVideo,
        seconds: Double
    ) {
        guard seconds.isFinite,
              seconds >= 0,
              let context = try? objectContext(for: video.id) else {
            return
        }
        let normalized: Double?
        if let duration = video.durationSeconds,
           duration.isFinite,
           duration - seconds < 5 {
            normalized = nil
        } else {
            normalized = max(0, seconds)
        }
        var immediate = video
        immediate.playbackPositionSeconds = normalized
        replace(immediate)

        playbackPositionSaveTasks[video.id]?.cancel()
        playbackPositionSaveTasks[video.id] = Task { [weak self] in
            do {
                let updated = try await Task.detached(priority: .utility) {
                    try context.store.updatePlaybackPosition(
                        context.object,
                        seconds: normalized,
                        session: context.session
                    )
                }.value
                guard !Task.isCancelled else { return }
                self?.objectRecords[updated.id] = updated
                self?.replace(updated.libraryVideo)
                self?.playbackPositionSaveTasks[video.id] = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.playbackPositionSaveTasks[video.id] = nil
                self?.errorMessage =
                    "保存播放进度失败：\(error.localizedDescription)"
            }
        }
    }

    private func requireStore() throws -> V2VaultStore {
        guard let store else { throw V2Error.missingVault }
        return store
    }

    private func vaultContext(
        for groupID: String
    ) throws -> (
        store: V2VaultStore,
        vault: V2VaultRecord,
        session: V2VaultSession
    ) {
        let store = try requireStore()
        guard let id = UUID(uuidString: groupID),
              let vault = vaultRecords[id],
              let session = vaultSessions[id],
              session.isUnlocked else {
            throw V2Error.sessionLocked
        }
        return (store, vault, session)
    }

    private func objectContext(
        for objectID: UUID
    ) throws -> (
        store: V2VaultStore,
        vault: V2VaultRecord,
        object: V2ObjectRecord,
        session: V2VaultSession
    ) {
        guard let object = objectRecords[objectID] else {
            throw V2Error.missingObject
        }
        let vaultContext = try vaultContext(
            for: object.vaultID.uuidString
        )
        return (
            vaultContext.store,
            vaultContext.vault,
            object,
            vaultContext.session
        )
    }
}

nonisolated enum V2SecureFileWriter {
    static func write(_ data: Data, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(
            ".Crypta-Recovery-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary {
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        try data.withUnsafeBytes { rawBuffer in
            guard var cursor = rawBuffer.baseAddress else { return }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = Darwin.write(descriptor, cursor, remaining)
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                cursor = cursor.advanced(by: written)
                remaining -= written
            }
        }
        guard fsync(descriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        shouldRemoveTemporary = false

        let directoryDescriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard directoryDescriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
