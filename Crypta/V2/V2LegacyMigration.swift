import CryptoKit
import Foundation

nonisolated struct V1LegacySnapshot: Sendable {
    let groups: [LibraryGroup]
    let videos: [CryptaVideo]
}

nonisolated final class V1LegacyReader: @unchecked Sendable {
    let locations: CryptaStorageLocations

    private let keyStore: any CryptaEncryptionKeyStore
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var cachedKey: SymmetricKey?

    init(
        locations: CryptaStorageLocations = .live,
        keyStore: any CryptaEncryptionKeyStore = CryptaKeychainKeyStore()
    ) {
        self.locations = locations
        self.keyStore = keyStore
        decoder.dateDecodingStrategy = .iso8601
    }

    func loadSnapshot() throws -> V1LegacySnapshot {
        let encrypted = try Data(contentsOf: locations.encryptedIndex)
        let plaintext = try decryptCombined(encrypted)
        let index = try decoder.decode(CryptaIndex.self, from: plaintext)
        return V1LegacySnapshot(groups: index.groups, videos: index.videos)
    }

    func plaintextInput(for video: CryptaVideo) throws -> V2PlaintextInput {
        switch video.storageState {
        case .plain:
            guard let fileName = video.plainFileName else {
                throw V2Error.migrationIncomplete
            }
            return try V2FilePlaintextInput(url: try safeLegacyObjectURL(fileName))

        case .encrypted:
            guard let fileName = video.encryptedFileName else {
                throw V2Error.migrationIncomplete
            }
            return try V1EncryptedPlaintextInput(
                sourceURL: safeLegacyObjectURL(fileName),
                key: encryptionKey()
            )
        }
    }

    func thumbnailData(for video: CryptaVideo) throws -> Data? {
        let fileName = "\(video.id.uuidString).v3.thumb"
        let url = locations.thumbnailCache.appendingPathComponent(
            fileName,
            isDirectory: false
        )
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        let thumbnailRoot = locations.thumbnailCache.standardizedFileURL
            .resolvingSymlinksInPath().path
        guard resolved.hasPrefix(thumbnailRoot + "/") else {
            throw V2Error.unsafePath
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        return try decryptCombined(Data(contentsOf: url))
    }

    func removeLegacyVaultAndKey() throws {
        let vaultURL = locations.vaultPackage.standardizedFileURL.resolvingSymlinksInPath()
        guard vaultURL.pathExtension == "vault",
              vaultURL.pathComponents.count >= 4,
              vaultURL.path != "/",
              vaultURL.path != FileManager.default.homeDirectoryForCurrentUser.path else {
            throw V2Error.unsafePath
        }
        if FileManager.default.fileExists(atPath: vaultURL.path) {
            try FileManager.default.removeItem(at: vaultURL)
        }
        try keyStore.deleteKeyData()
        lock.lock()
        cachedKey = nil
        lock.unlock()
    }

    private func decryptCombined(_ encrypted: Data) throws -> Data {
        do {
            let sealed = try AES.GCM.SealedBox(combined: encrypted)
            return try AES.GCM.open(sealed, using: encryptionKey())
        } catch let error as V2Error {
            throw error
        } catch {
            throw V2Error.authenticationFailed
        }
    }

    private func encryptionKey() throws -> SymmetricKey {
        lock.lock()
        defer { lock.unlock() }
        if let cachedKey {
            return cachedKey
        }
        guard let keyData = try keyStore.readKeyData(),
              keyData.count == V2Crypto.keyByteCount else {
            throw V2Error.authenticationFailed
        }
        let key = SymmetricKey(data: keyData)
        cachedKey = key
        return key
    }

    private func safeLegacyObjectURL(_ fileName: String) throws -> URL {
        guard !fileName.isEmpty,
              fileName == URL(fileURLWithPath: fileName).lastPathComponent,
              !fileName.contains(".."),
              !fileName.contains("/") else {
            throw V2Error.unsafePath
        }
        let url = locations.moviesVault.appendingPathComponent(fileName, isDirectory: false)
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        let objectRoot = locations.moviesVault.standardizedFileURL
            .resolvingSymlinksInPath().path
        guard resolved.hasPrefix(objectRoot + "/") else {
            throw V2Error.unsafePath
        }
        return url
    }
}

nonisolated final class V1EncryptedPlaintextInput: V2PlaintextInput {
    let byteCount: Int64

    private let handle: FileHandle
    private let fileSize: UInt64
    private let key: SymmetricKey
    private var encryptedOffset: UInt64 = 0
    private var pendingPlaintext = Data()

    init(sourceURL: URL, key: SymmetricKey) throws {
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSizeValue = values.fileSize,
              fileSizeValue >= 0 else {
            throw V2Error.migrationIncomplete
        }
        fileSize = UInt64(fileSizeValue)
        self.key = key
        byteCount = try Self.scanPlaintextLength(sourceURL: sourceURL, fileSize: fileSize)
        handle = try FileHandle(forReadingFrom: sourceURL)
    }

    deinit {
        try? handle.close()
    }

    func read(upToCount count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        while pendingPlaintext.count < count, encryptedOffset < fileSize {
            try autoreleasepool {
                pendingPlaintext.append(try readNextChunk())
            }
        }
        let outputCount = min(count, pendingPlaintext.count)
        guard outputCount > 0 else { return Data() }
        let output = pendingPlaintext.prefix(outputCount)
        pendingPlaintext.removeFirst(outputCount)
        return Data(output)
    }

    private func readNextChunk() throws -> Data {
        guard encryptedOffset < fileSize,
              fileSize - encryptedOffset >= 4 else {
            throw V2Error.migrationIncomplete
        }
        try handle.seek(toOffset: encryptedOffset)
        let prefix = try handle.read(upToCount: 4) ?? Data()
        guard prefix.count == 4 else {
            throw V2Error.migrationIncomplete
        }
        let length = EncryptedMediaFormat.length(fromPrefix: prefix)
        guard EncryptedMediaFormat.isValidEncryptedChunkLength(length),
              UInt64(length) <= fileSize - encryptedOffset - 4 else {
            throw V2Error.migrationIncomplete
        }
        let encrypted = try handle.read(upToCount: length) ?? Data()
        guard encrypted.count == length else {
            throw V2Error.migrationIncomplete
        }
        encryptedOffset += UInt64(4 + length)
        do {
            let sealed = try AES.GCM.SealedBox(combined: encrypted)
            return try AES.GCM.open(sealed, using: key)
        } catch {
            throw V2Error.authenticationFailed
        }
    }

    private static func scanPlaintextLength(
        sourceURL: URL,
        fileSize: UInt64
    ) throws -> Int64 {
        let handle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? handle.close() }
        var encryptedOffset: UInt64 = 0
        var plaintextLength: UInt64 = 0
        while encryptedOffset < fileSize {
            let chunkLengths = try autoreleasepool {
                guard fileSize - encryptedOffset >= 4 else {
                    throw V2Error.migrationIncomplete
                }
                try handle.seek(toOffset: encryptedOffset)
                let prefix = try handle.read(upToCount: 4) ?? Data()
                guard prefix.count == 4 else {
                    throw V2Error.migrationIncomplete
                }
                let encryptedLength = EncryptedMediaFormat.length(fromPrefix: prefix)
                guard EncryptedMediaFormat.isValidEncryptedChunkLength(encryptedLength),
                      UInt64(encryptedLength) <= fileSize - encryptedOffset - 4 else {
                    throw V2Error.migrationIncomplete
                }
                return (
                    encrypted: encryptedLength,
                    plaintext: encryptedLength - EncryptedMediaFormat.sealedBoxOverhead
                )
            }
            let addition = plaintextLength.addingReportingOverflow(
                UInt64(chunkLengths.plaintext)
            )
            guard !addition.overflow, addition.partialValue <= UInt64(Int64.max) else {
                throw V2Error.migrationIncomplete
            }
            plaintextLength = addition.partialValue
            encryptedOffset += UInt64(4 + chunkLengths.encrypted)
        }
        return Int64(plaintextLength)
    }
}

nonisolated struct V2MigrationProgress: Equatable, Sendable {
    let phase: V2MigrationPhase
    let completedCount: Int
    let totalCount: Int
}

nonisolated struct V2MigrationResult: Sendable {
    let recoveryKey: V2RecoveryKey?
    let migratedObjectCount: Int
    let legacyDataRemoved: Bool
}

nonisolated final class V2LegacyMigrator: @unchecked Sendable {
    private let source: V1LegacyReader
    private let target: V2VaultStore
    private let lock = NSLock()
    private var isRunning = false

    init(source: V1LegacyReader, target: V2VaultStore) {
        self.source = source
        self.target = target
    }

    func migrate(
        recoveryKey: V2RecoveryKey?,
        removeLegacyAfterCommit: Bool,
        progress: @Sendable (V2MigrationProgress) -> Void = { _ in }
    ) throws -> V2MigrationResult {
        lock.lock()
        guard !isRunning else {
            lock.unlock()
            throw V2Error.migrationAlreadyRunning
        }
        isRunning = true
        lock.unlock()
        defer {
            lock.lock()
            isRunning = false
            lock.unlock()
        }

        if let existingState = try target.metadata.migrationState() {
            if existingState.phase == .complete {
                if removeLegacyAfterCommit {
                    let sessions = try unlockAllTargetSessions()
                    defer { sessions.values.forEach { $0.invalidate() } }
                    try verifyTarget(sessions: sessions, progress: progress)
                    try source.removeLegacyVaultAndKey()
                }
                return V2MigrationResult(
                    recoveryKey: recoveryKey,
                    migratedObjectCount: existingState.committedCount,
                    legacyDataRemoved: removeLegacyAfterCommit
                )
            }
            if existingState.phase == .cleaningLegacy {
                let sessions = try unlockAllTargetSessions()
                defer { sessions.values.forEach { $0.invalidate() } }
                try verifyTarget(sessions: sessions, progress: progress)
                if removeLegacyAfterCommit {
                    try source.removeLegacyVaultAndKey()
                }
                try finishMigration(from: existingState)
                return V2MigrationResult(
                    recoveryKey: recoveryKey,
                    migratedObjectCount: existingState.committedCount,
                    legacyDataRemoved: removeLegacyAfterCommit
                )
            }
        }

        let snapshot = try source.loadSnapshot()
        let existingState = try target.metadata.migrationState()
        let sessions: [UUID: V2VaultSession]
        var state: V2MigrationState
        if let existingState {
            guard existingState.totalCount == snapshot.videos.count else {
                throw V2Error.migrationIncomplete
            }
            sessions = try unlockAllTargetSessions()
            state = existingState
        } else {
            guard let recoveryKey else {
                throw V2Error.invalidRecoveryKey
            }
            progress(
                V2MigrationProgress(
                    phase: .preparing,
                    completedCount: 0,
                    totalCount: snapshot.videos.count
                )
            )
            state = V2MigrationState(
                phase: .copying,
                totalCount: snapshot.videos.count,
                committedCount: 0,
                startedAt: Date(),
                updatedAt: Date()
            )
            sessions = try prepareVaultsAtomically(
                groups: snapshot.groups,
                recoveryKey: recoveryKey,
                initialState: state
            )
        }
        defer { sessions.values.forEach { $0.invalidate() } }

        let groupMapping = Dictionary(
            uniqueKeysWithValues: snapshot.groups.map {
                ($0.id, Self.stableVaultID(legacyID: $0.id))
            }
        )
        let expectedVaultIDs = Set(groupMapping.values)
        guard Set(sessions.keys) == expectedVaultIDs else {
            throw V2Error.migrationIncomplete
        }
        var expectedObjectIDsByVault: [UUID: Set<UUID>] = [:]
        for video in snapshot.videos {
            guard let vaultID = groupMapping[video.libraryKind.rawValue] else {
                throw V2Error.migrationIncomplete
            }
            expectedObjectIDsByVault[vaultID, default: []].insert(video.id)
        }

        var existingObjects: [UUID: [UUID: V2ObjectRecord]] = [:]
        for (vaultID, session) in sessions {
            let objects = try target.metadata.loadObjects(
                vaultID: vaultID,
                session: session
            )
            guard Set(objects.map(\.id)).isSubset(
                of: expectedObjectIDsByVault[vaultID, default: []]
            ) else {
                throw V2Error.migrationIncomplete
            }
            existingObjects[vaultID] = Dictionary(
                uniqueKeysWithValues: objects.map { ($0.id, $0) }
            )
        }
        let alreadyCommitted = existingObjects.values.reduce(0) { $0 + $1.count }
        state = V2MigrationState(
            phase: .copying,
            totalCount: snapshot.videos.count,
            committedCount: alreadyCommitted,
            startedAt: state.startedAt,
            updatedAt: Date()
        )
        try target.metadata.saveMigrationState(state)

        for video in snapshot.videos {
            guard let vaultID = groupMapping[video.libraryKind.rawValue],
                  let session = sessions[vaultID] else {
                throw V2Error.migrationIncomplete
            }
            if let existing = existingObjects[vaultID]?[video.id] {
                try autoreleasepool {
                    try migrateThumbnail(
                        for: video,
                        object: existing,
                        session: session
                    )
                }
                continue
            }
            let imported = try autoreleasepool {
                let input = try source.plaintextInput(for: video)
                let result = try target.importPlaintext(
                    input,
                    sourceURLToRemove: nil,
                    into: vaultID,
                    session: session,
                    request: V2ImportRequest(
                        displayName: video.displayName,
                        originalExtension: video.originalExtension,
                        mediaType: video.mediaType,
                        durationSeconds: video.durationSeconds,
                        importedAt: video.importedAt
                    ),
                    objectID: video.id,
                    revisionID: Self.stableRevisionID(objectID: video.id)
                )
                try migrateThumbnail(
                    for: video,
                    object: result.object,
                    session: session
                )
                return result
            }
            existingObjects[vaultID, default: [:]][video.id] = imported.object
            state = V2MigrationState(
                phase: .copying,
                totalCount: snapshot.videos.count,
                committedCount: state.committedCount + 1,
                startedAt: state.startedAt,
                updatedAt: Date()
            )
            try target.metadata.saveMigrationState(state)
            progress(
                V2MigrationProgress(
                    phase: .copying,
                    completedCount: state.committedCount,
                    totalCount: state.totalCount
                )
            )
        }

        state = V2MigrationState(
            phase: .verifying,
            totalCount: snapshot.videos.count,
            committedCount: snapshot.videos.count,
            startedAt: state.startedAt,
            updatedAt: Date()
        )
        try target.metadata.saveMigrationState(state)
        try verifyTarget(sessions: sessions, progress: progress)

        state = V2MigrationState(
            phase: .cleaningLegacy,
            totalCount: snapshot.videos.count,
            committedCount: snapshot.videos.count,
            startedAt: state.startedAt,
            updatedAt: Date()
        )
        try target.metadata.saveMigrationState(state)
        progress(
            V2MigrationProgress(
                phase: .cleaningLegacy,
                completedCount: snapshot.videos.count,
                totalCount: snapshot.videos.count
            )
        )
        if removeLegacyAfterCommit {
            try source.removeLegacyVaultAndKey()
        }
        try finishMigration(from: state)
        return V2MigrationResult(
            recoveryKey: recoveryKey,
            migratedObjectCount: snapshot.videos.count,
            legacyDataRemoved: removeLegacyAfterCommit
        )
    }

    private func prepareVaultsAtomically(
        groups: [LibraryGroup],
        recoveryKey: V2RecoveryKey,
        initialState: V2MigrationState
    ) throws -> [UUID: V2VaultSession] {
        guard try target.metadata.loadVaults().isEmpty else {
            throw V2Error.migrationIncomplete
        }
        var setups: [(record: V2VaultRecord, setup: V2VaultKeySetup)] = []
        do {
            for (position, group) in groups.enumerated() {
                let vaultID = Self.stableVaultID(legacyID: group.id)
                let protection = V2VaultProtection(level: group.encryptionLevel)
                let setup = try target.keyManager.createVaultKeys(
                    vaultID: vaultID,
                    protection: protection,
                    catalogKey: target.metadata.catalogKeyForRecovery(),
                    recoveryKey: recoveryKey
                )
                let record = V2VaultRecord(
                    id: vaultID,
                    name: group.name,
                    encryptionLevel: group.encryptionLevel,
                    mediaType: group.mediaType,
                    position: position,
                    protection: protection,
                    deviceEnvelope: setup.deviceEnvelope,
                    recoveryEnvelope: setup.recoveryEnvelope,
                    recoveryConfirmed: true,
                    createdAt: Date()
                )
                setups.append((record, setup))
            }
            try target.metadata.createMigrationVaults(
                setups.map { $0.record },
                state: initialState
            )
            return Dictionary(
                uniqueKeysWithValues: setups.map {
                    ($0.record.id, $0.setup.session)
                }
            )
        } catch {
            for entry in setups {
                entry.setup.session.invalidate()
                try? target.keyManager.removeDeviceKey(
                    envelope: entry.setup.deviceEnvelope,
                    vaultID: entry.record.id
                )
            }
            throw error
        }
    }

    private func unlockAllTargetSessions() throws -> [UUID: V2VaultSession] {
        var sessions: [UUID: V2VaultSession] = [:]
        do {
            for vault in try target.metadata.loadVaults() {
                sessions[vault.id] = try target.unlock(
                    vaultID: vault.id,
                    reason: ApprovedCopy.migrationTitle
                )
            }
            return sessions
        } catch {
            sessions.values.forEach { $0.invalidate() }
            throw error
        }
    }

    private func migrateThumbnail(
        for video: CryptaVideo,
        object: V2ObjectRecord,
        session: V2VaultSession
    ) throws {
        let thumbnail: Data?
        do {
            thumbnail = try source.thumbnailData(for: video)
        } catch {
            // A corrupt legacy thumbnail must not strand otherwise valid media.
            return
        }
        guard let thumbnail else {
            return
        }
        try target.saveThumbnail(thumbnail, for: object, session: session)
    }

    private func verifyTarget(
        sessions: [UUID: V2VaultSession],
        progress: @Sendable (V2MigrationProgress) -> Void
    ) throws {
        let total = try target.metadata.migrationState()?.totalCount ?? 0
        var completed = 0
        for (vaultID, session) in sessions {
            let objects = try target.metadata.loadObjects(vaultID: vaultID, session: session)
            for object in objects {
                try autoreleasepool {
                    _ = try target.reader(
                        for: object,
                        session: session,
                        maximumCacheBytes: 0
                    ).verifyAllChunks()
                }
                completed += 1
                progress(
                    V2MigrationProgress(
                        phase: .verifying,
                        completedCount: completed,
                        totalCount: total
                    )
                )
            }
        }
        guard completed == total else {
            throw V2Error.migrationIncomplete
        }
    }

    private func finishMigration(from state: V2MigrationState) throws {
        let completed = V2MigrationState(
            phase: .complete,
            totalCount: state.totalCount,
            committedCount: state.committedCount,
            startedAt: state.startedAt,
            updatedAt: Date()
        )
        try target.metadata.saveMigrationState(completed)
    }

    private static func stableVaultID(legacyID: String) -> UUID {
        if let existing = UUID(uuidString: legacyID) {
            return existing
        }
        return deterministicUUID(Data("vault:\(legacyID)".utf8))
    }

    private static func stableRevisionID(objectID: UUID) -> UUID {
        deterministicUUID(Data("revision:".utf8) + objectID.v2Data)
    }

    private static func deterministicUUID(_ input: Data) -> UUID {
        var bytes = Array(SHA256.hash(data: input).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }
}
