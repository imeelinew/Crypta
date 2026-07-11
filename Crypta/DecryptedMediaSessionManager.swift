import Darwin
import Foundation

@MainActor
final class DecryptedMediaLease {
    let url: URL

    private let id: UUID
    private weak var manager: DecryptedMediaSessionManager?
    private var isReleased = false

    fileprivate init(id: UUID, url: URL, manager: DecryptedMediaSessionManager) {
        self.id = id
        self.url = url
        self.manager = manager
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        manager?.releaseLease(id)
    }

    deinit {
        guard !isReleased, let manager else { return }
        let leaseID = id
        Task { @MainActor in
            manager.releaseLease(leaseID)
        }
    }
}

@MainActor
final class DecryptedMediaSessionManager {
    static let shared = DecryptedMediaSessionManager(cacheRoot: CryptaStorageLocations.live.cacheRoot)

    private struct Resource {
        let directoryURL: URL
        var leaseCount: Int
    }

    private struct ImageGroupSnapshot: Sendable {
        let resourceID: UUID
        let fileURLsByVideoID: [CryptaVideo.ID: URL]
    }

    private struct PreparedImageGroup: Sendable {
        let directoryURL: URL
        let fileURLsByVideoID: [CryptaVideo.ID: URL]
    }

    private struct SessionOwner: Codable {
        let processIdentifier: Int32
        let processStartTime: UInt64
    }

    private let fileManager: FileManager
    private let sessionsRoot: URL
    private let sessionID: UUID
    private let sessionDirectory: URL
    private let processStartTimeProvider: (Int32) -> UInt64?
    private var didStart = false
    private var resources: [UUID: Resource] = [:]
    private var leaseResourceIDs: [UUID: UUID] = [:]
    private var imageGroupSnapshots: [String: ImageGroupSnapshot] = [:]
    private var imageGroupTasks: [String: Task<ImageGroupSnapshot, Error>] = [:]
    private var imageGroupTaskIDs: [String: UUID] = [:]

    init(
        cacheRoot: URL,
        fileManager: FileManager = .default,
        processStartTimeProvider: @escaping (Int32) -> UInt64? = DecryptedMediaSessionManager.processStartTime
    ) {
        self.fileManager = fileManager
        self.processStartTimeProvider = processStartTimeProvider
        sessionsRoot = cacheRoot.appendingPathComponent("Sessions", isDirectory: true)
        sessionID = UUID()
        sessionDirectory = sessionsRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
    }

    func start() throws {
        guard !didStart else { return }
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        guard let processStartTime = processStartTimeProvider(processIdentifier) else {
            throw CryptaError.temporarySessionFailed
        }
        try fileManager.createDirectory(at: sessionsRoot, withIntermediateDirectories: true)
        try cleanupOrphanedSessions()
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try Data("\(processIdentifier)".utf8).write(
            to: sessionDirectory.appendingPathComponent("owner.pid", isDirectory: false),
            options: [.atomic]
        )
        let owner = SessionOwner(
            processIdentifier: processIdentifier,
            processStartTime: processStartTime
        )
        try JSONEncoder().encode(owner).write(
            to: sessionDirectory.appendingPathComponent("owner.json", isDirectory: false),
            options: [.atomic]
        )
        didStart = true
    }

    func shutdown() {
        for task in imageGroupTasks.values {
            task.cancel()
        }
        imageGroupTasks.removeAll()
        imageGroupTaskIDs.removeAll()
        imageGroupSnapshots.removeAll()
        resources.removeAll()
        leaseResourceIDs.removeAll()
        try? fileManager.removeItem(at: sessionDirectory)
        didStart = false
    }

    func acquireMediaLease(for video: CryptaVideo, store: CryptaStore) async throws -> DecryptedMediaLease {
        try start()
        let resourceID = UUID()
        let directoryURL = sessionDirectory
            .appendingPathComponent("Media", isDirectory: true)
            .appendingPathComponent(resourceID.uuidString, isDirectory: true)
        let extensionName = video.originalExtension.isEmpty ? "bin" : video.originalExtension
        let fileURL = directoryURL.appendingPathComponent("media.\(extensionName)", isDirectory: false)

        do {
            try await Task.detached(priority: .userInitiated) {
                try store.materializeMedia(video, to: fileURL)
            }.value
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }

        resources[resourceID] = Resource(
            directoryURL: directoryURL,
            leaseCount: 0
        )
        return makeLease(resourceID: resourceID, url: fileURL)
    }

    func acquireImageGroupLease(
        for video: CryptaVideo,
        groupVideos: [CryptaVideo],
        store: CryptaStore
    ) async throws -> DecryptedMediaLease {
        let groupID = video.libraryKind.rawValue
        let snapshot = try await imageGroupSnapshot(groupID: groupID, videos: groupVideos, store: store)
        guard let fileURL = snapshot.fileURLsByVideoID[video.id],
              fileManager.fileExists(atPath: fileURL.path) else {
            invalidateImageGroup(groupID)
            let rebuilt = try await imageGroupSnapshot(groupID: groupID, videos: groupVideos, store: store)
            guard let rebuiltURL = rebuilt.fileURLsByVideoID[video.id],
                  fileManager.fileExists(atPath: rebuiltURL.path) else {
                throw CryptaError.missingVideoFile
            }
            return makeLease(resourceID: rebuilt.resourceID, url: rebuiltURL)
        }
        return makeLease(resourceID: snapshot.resourceID, url: fileURL)
    }

    func invalidateImageGroup(_ groupID: String) {
        imageGroupTasks.removeValue(forKey: groupID)?.cancel()
        imageGroupTaskIDs.removeValue(forKey: groupID)
        guard let snapshot = imageGroupSnapshots.removeValue(forKey: groupID) else { return }
        deleteResourceIfUnused(snapshot.resourceID)
    }

    fileprivate func releaseLease(_ leaseID: UUID) {
        guard let resourceID = leaseResourceIDs.removeValue(forKey: leaseID),
              var resource = resources[resourceID] else {
            return
        }
        resource.leaseCount = max(0, resource.leaseCount - 1)
        resources[resourceID] = resource
        deleteResourceIfUnused(resourceID)
    }

    private func imageGroupSnapshot(
        groupID: String,
        videos: [CryptaVideo],
        store: CryptaStore
    ) async throws -> ImageGroupSnapshot {
        try start()

        if let snapshot = imageGroupSnapshots[groupID],
           snapshot.fileURLsByVideoID.values.allSatisfy({ fileManager.fileExists(atPath: $0.path) }) {
            return snapshot
        }
        if imageGroupSnapshots[groupID] != nil {
            invalidateImageGroup(groupID)
        }
        if let task = imageGroupTasks[groupID] {
            return try await task.value
        }

        let generationID = UUID()
        let taskID = UUID()
        let stagingDirectory = sessionDirectory
            .appendingPathComponent("Staging", isDirectory: true)
            .appendingPathComponent(generationID.uuidString, isDirectory: true)
        let finalDirectory = sessionDirectory
            .appendingPathComponent("ImageGroups", isDirectory: true)
            .appendingPathComponent(groupID, isDirectory: true)
            .appendingPathComponent(generationID.uuidString, isDirectory: true)

        let task = Task<ImageGroupSnapshot, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let prepared = try await Task.detached(priority: .userInitiated) {
                let mapping = try store.materializeImageGroup(videos, to: stagingDirectory)
                try FileManager.default.createDirectory(
                    at: finalDirectory.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try FileManager.default.moveItem(at: stagingDirectory, to: finalDirectory)
                let movedMapping = mapping.mapValues {
                    finalDirectory.appendingPathComponent($0.lastPathComponent, isDirectory: false)
                }
                return PreparedImageGroup(directoryURL: finalDirectory, fileURLsByVideoID: movedMapping)
            }.value

            do {
                try Task.checkCancellation()
                let resourceID = UUID()
                self.resources[resourceID] = Resource(directoryURL: prepared.directoryURL, leaseCount: 0)
                let snapshot = ImageGroupSnapshot(
                    resourceID: resourceID,
                    fileURLsByVideoID: prepared.fileURLsByVideoID
                )
                if let previous = self.imageGroupSnapshots.updateValue(snapshot, forKey: groupID) {
                    self.deleteResourceIfUnused(previous.resourceID)
                }
                return snapshot
            } catch {
                try? self.fileManager.removeItem(at: prepared.directoryURL)
                throw error
            }
        }
        imageGroupTasks[groupID] = task
        imageGroupTaskIDs[groupID] = taskID

        do {
            let snapshot = try await task.value
            if imageGroupTaskIDs[groupID] == taskID {
                imageGroupTasks.removeValue(forKey: groupID)
                imageGroupTaskIDs.removeValue(forKey: groupID)
            }
            return snapshot
        } catch {
            if imageGroupTaskIDs[groupID] == taskID {
                imageGroupTasks.removeValue(forKey: groupID)
                imageGroupTaskIDs.removeValue(forKey: groupID)
            }
            try? fileManager.removeItem(at: stagingDirectory)
            try? fileManager.removeItem(at: finalDirectory)
            throw error
        }
    }

    private func makeLease(resourceID: UUID, url: URL) -> DecryptedMediaLease {
        let leaseID = UUID()
        if var resource = resources[resourceID] {
            resource.leaseCount += 1
            resources[resourceID] = resource
        }
        leaseResourceIDs[leaseID] = resourceID
        return DecryptedMediaLease(id: leaseID, url: url, manager: self)
    }

    private func deleteResourceIfUnused(_ resourceID: UUID) {
        guard let resource = resources[resourceID],
              resource.leaseCount == 0 else {
            return
        }
        resources.removeValue(forKey: resourceID)
        try? fileManager.removeItem(at: resource.directoryURL)
    }

    private func cleanupOrphanedSessions() throws {
        let sessionDirectories = try fileManager.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        for directory in sessionDirectories where directory != sessionDirectory {
            let ownerMetadataURL = directory.appendingPathComponent("owner.json", isDirectory: false)
            if let data = try? Data(contentsOf: ownerMetadataURL),
               let owner = try? JSONDecoder().decode(SessionOwner.self, from: data) {
                if let currentStartTime = processStartTimeProvider(owner.processIdentifier) {
                    if currentStartTime != owner.processStartTime {
                        try? fileManager.removeItem(at: directory)
                    }
                } else if !Self.isProcessAlive(owner.processIdentifier) {
                    try? fileManager.removeItem(at: directory)
                }
                continue
            }

            let ownerURL = directory.appendingPathComponent("owner.pid", isDirectory: false)
            guard let data = try? Data(contentsOf: ownerURL),
                  let value = String(data: data, encoding: .utf8),
                  let pid = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                try? fileManager.removeItem(at: directory)
                continue
            }
            if !Self.isProcessAlive(pid) {
                try? fileManager.removeItem(at: directory)
            }
        }
    }

    private static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 {
            return true
        }
        return errno == EPERM
    }

    nonisolated private static func processStartTime(_ pid: Int32) -> UInt64? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let expectedSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        let actualSize = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expectedSize)
        guard actualSize == expectedSize else { return nil }
        return info.pbi_start_tvsec
    }
}
