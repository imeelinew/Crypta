import CryptoKit
import Darwin
import Foundation

nonisolated struct V2StorageLocations: Sendable {
    let root: URL
    let cacheRoot: URL

    var database: URL { root.appendingPathComponent("metadata.sqlite3", isDirectory: false) }
    var objects: URL { root.appendingPathComponent("Objects", isDirectory: true) }
    var staging: URL { root.appendingPathComponent("Staging", isDirectory: true) }
    var thumbnails: URL { root.appendingPathComponent("Thumbnails", isDirectory: true) }
    var playback: URL { cacheRoot.appendingPathComponent("Playback", isDirectory: true) }

    static var live: V2StorageLocations {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        )[0]
        let caches = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        )[0]
        return V2StorageLocations(
            root: applicationSupport
                .appendingPathComponent("Crypta", isDirectory: true)
                .appendingPathComponent("Vault-v2", isDirectory: true),
            cacheRoot: caches
                .appendingPathComponent("Crypta", isDirectory: true)
                .appendingPathComponent("V2", isDirectory: true)
        )
    }

    func prepare() throws {
        for directory in [root, objects, staging, thumbnails, cacheRoot, playback] {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directory.path
            )
        }
    }

    func contains(_ url: URL) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let boundary = root.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate == boundary || candidate.hasPrefix(boundary + "/")
    }
}

nonisolated struct V2VaultCreation: Sendable {
    let vault: V2VaultRecord
    let recoveryKey: V2RecoveryKey
    let session: V2VaultSession
}

nonisolated struct V2ImportRequest: Sendable {
    let displayName: String
    let originalExtension: String
    let mediaType: MediaType
    let durationSeconds: Double?
    let importedAt: Date

    init(
        displayName: String,
        originalExtension: String,
        mediaType: MediaType,
        durationSeconds: Double?,
        importedAt: Date = Date()
    ) {
        self.displayName = displayName
        self.originalExtension = originalExtension
        self.mediaType = mediaType
        self.durationSeconds = durationSeconds
        self.importedAt = importedAt
    }
}

nonisolated struct V2ImportResult: Sendable {
    let object: V2ObjectRecord
    let sourceRemoved: Bool
}

nonisolated enum V2StoreCheckpoint: Equatable, Sendable {
    case stagedAndVerified
    case blobCommitted
    case metadataCommitted
    case finalVerificationComplete
}

nonisolated protocol V2StoreFailureInjector: Sendable {
    func reach(_ checkpoint: V2StoreCheckpoint) throws
}

nonisolated struct V2NoFailureInjector: V2StoreFailureInjector {
    func reach(_ checkpoint: V2StoreCheckpoint) throws {}
}

nonisolated final class V2VaultStore: @unchecked Sendable {
    let locations: V2StorageLocations
    let metadata: V2MetadataStore
    let keyManager: V2KeyManager

    private let operationLock = NSRecursiveLock()
    private let failureInjector: any V2StoreFailureInjector

    init(
        locations: V2StorageLocations,
        metadata: V2MetadataStore,
        keyManager: V2KeyManager,
        failureInjector: any V2StoreFailureInjector = V2NoFailureInjector()
    ) throws {
        self.locations = locations
        self.metadata = metadata
        self.keyManager = keyManager
        self.failureInjector = failureInjector
        try locations.prepare()
    }

    static func openLive() throws -> V2VaultStore {
        let locations = V2StorageLocations.live
        try locations.prepare()
        let repository = V2KeychainRepository()
        let catalogKey = try loadCatalogKey(
            repository: repository,
            databaseExists: FileManager.default.fileExists(atPath: locations.database.path),
            objectsDirectory: locations.objects
        )
        let metadata = try V2MetadataStore(
            databaseURL: locations.database,
            catalogKey: catalogKey
        )
        let keyManager = V2KeyManager(
            deviceProtector: V2ProductionDeviceKeyProtector(repository: repository)
        )
        return try V2VaultStore(
            locations: locations,
            metadata: metadata,
            keyManager: keyManager
        )
    }

    static func recoverLiveAccess(
        recoveryKey: V2RecoveryKey,
        expectedVaultID: UUID? = nil
    ) throws -> (store: V2VaultStore, session: V2VaultSession) {
        let repository = V2KeychainRepository()
        return try recoverAccess(
            recoveryKey: recoveryKey,
            expectedVaultID: expectedVaultID,
            locations: .live,
            repository: repository,
            keyManager: V2KeyManager(
                deviceProtector: V2ProductionDeviceKeyProtector(repository: repository)
            )
        )
    }

    static func recoverAccess(
        recoveryKey: V2RecoveryKey,
        expectedVaultID: UUID? = nil,
        locations: V2StorageLocations,
        repository: any V2KeyRepository,
        keyManager: V2KeyManager
    ) throws -> (store: V2VaultStore, session: V2VaultSession) {
        guard FileManager.default.fileExists(atPath: locations.database.path) else {
            throw V2Error.missingVault
        }
        let envelopes = try V2MetadataStore.recoveryEnvelopes(
            databaseURL: locations.database
        )
        var matchingMaterial: (envelope: V2RecoveryEnvelope, material: V2RecoveredKeyMaterial)?
        for envelope in envelopes
        where expectedVaultID == nil || envelope.vaultID == expectedVaultID {
            do {
                matchingMaterial = (
                    envelope,
                    try envelope.recover(using: recoveryKey)
                )
                break
            } catch V2Error.authenticationFailed {
                continue
            }
        }
        guard let matchingMaterial else {
            throw V2Error.invalidRecoveryKey
        }

        let metadata = try V2MetadataStore(
            databaseURL: locations.database,
            catalogKey: matchingMaterial.material.catalogKey
        )
        let vaults = try metadata.loadVaults()
        guard let vault = vaults.first(where: {
            $0.id == matchingMaterial.envelope.vaultID &&
            $0.recoveryEnvelope == matchingMaterial.envelope
        }) else {
            throw V2Error.invalidEnvelope
        }

        try repository.saveCatalogKeyData(
            V2Crypto.keyData(matchingMaterial.material.catalogKey)
        )
        let store = try V2VaultStore(
            locations: locations,
            metadata: metadata,
            keyManager: keyManager
        )
        let session = V2VaultSession(
            vaultID: vault.id,
            masterKey: matchingMaterial.material.masterKey
        )
        do {
            let replacementDeviceEnvelope = try keyManager.reenrollDevice(
                session: session,
                protection: vault.protection
            )
            do {
                try metadata.updateDeviceEnvelope(
                    vaultID: vault.id,
                    envelope: replacementDeviceEnvelope
                )
            } catch {
                try? keyManager.removeDeviceKey(
                    envelope: replacementDeviceEnvelope,
                    vaultID: vault.id
                )
                throw error
            }
        } catch {
            session.invalidate()
            throw error
        }
        return (store, session)
    }

    static func liveRecoveryIsAvailable() -> Bool {
        let databaseURL = V2StorageLocations.live.database
        guard FileManager.default.fileExists(atPath: databaseURL.path),
              let envelopes = try? V2MetadataStore.recoveryEnvelopes(
                databaseURL: databaseURL
              ) else {
            return false
        }
        return !envelopes.isEmpty
    }

    func createVault(
        id: UUID = UUID(),
        name: String,
        encryptionLevel: EncryptionLevel,
        mediaType: MediaType,
        recoveryKey: V2RecoveryKey? = nil,
        recoveryConfirmed: Bool = true
    ) throws -> V2VaultCreation {
        try withOperationLock {
            let vaults = try metadata.loadVaults()
            let setup = try keyManager.createVaultKeys(
                vaultID: id,
                protection: V2VaultProtection(level: encryptionLevel),
                catalogKey: metadata.catalogKeyForRecovery(),
                recoveryKey: recoveryKey
            )
            let record = V2VaultRecord(
                id: id,
                name: name,
                encryptionLevel: encryptionLevel,
                mediaType: mediaType,
                position: vaults.count,
                protection: V2VaultProtection(level: encryptionLevel),
                deviceEnvelope: setup.deviceEnvelope,
                recoveryEnvelope: setup.recoveryEnvelope,
                recoveryConfirmed: recoveryConfirmed,
                createdAt: Date()
            )
            do {
                try metadata.createVault(record)
                return V2VaultCreation(
                    vault: record,
                    recoveryKey: setup.recoveryKey,
                    session: setup.session
                )
            } catch {
                setup.session.invalidate()
                try? keyManager.removeDeviceKey(
                    envelope: setup.deviceEnvelope,
                    vaultID: id
                )
                throw error
            }
        }
    }

    func unlock(vaultID: UUID, reason: String) throws -> V2VaultSession {
        let vault = try metadata.vault(id: vaultID)
        return try keyManager.unlock(
            vaultID: vaultID,
            envelope: vault.deviceEnvelope,
            reason: reason
        )
    }

    func recover(vaultID: UUID, recoveryKey: V2RecoveryKey) throws -> V2VaultSession {
        let vault = try metadata.vault(id: vaultID)
        let recovered = try keyManager.recover(
            envelope: vault.recoveryEnvelope,
            recoveryKey: recoveryKey
        )
        guard V2Crypto.keyData(recovered.catalogKey)
                == V2Crypto.keyData(metadata.catalogKeyForRecovery()) else {
            recovered.session.invalidate()
            throw V2Error.invalidEnvelope
        }
        return recovered.session
    }

    func replaceRecoveryKey(
        session: V2VaultSession,
        confirmed: Bool = false
    ) throws -> V2RecoveryKey {
        let replacement = try keyManager.replaceRecoveryEnvelope(
            session: session,
            catalogKey: metadata.catalogKeyForRecovery()
        )
        try metadata.updateRecoveryEnvelope(
            vaultID: session.vaultID,
            envelope: replacement.envelope,
            confirmed: confirmed
        )
        return replacement.recoveryKey
    }

    func confirmRecoveryKey(vaultID: UUID) throws {
        try metadata.markRecoveryConfirmed(vaultID: vaultID)
    }

    func reenrollDevice(
        session: V2VaultSession,
        encryptionLevel: EncryptionLevel
    ) throws {
        let vault = try metadata.vault(id: session.vaultID)
        guard vault.encryptionLevel == encryptionLevel else {
            throw V2Error.authenticationFailed
        }
        let envelope = try keyManager.reenrollDevice(
            session: session,
            protection: vault.protection
        )
        do {
            try metadata.updateDeviceEnvelope(
                vaultID: session.vaultID,
                envelope: envelope
            )
        } catch {
            try? keyManager.removeDeviceKey(
                envelope: envelope,
                vaultID: session.vaultID
            )
            throw error
        }
        try? keyManager.removeDeviceKey(
            envelope: vault.deviceEnvelope,
            vaultID: session.vaultID
        )
    }

    func importFile(
        from sourceURL: URL,
        into vaultID: UUID,
        session: V2VaultSession,
        request: V2ImportRequest,
        removeSourceAfterCommit: Bool = true
    ) throws -> V2ImportResult {
        try withOperationLock {
            guard session.vaultID == vaultID,
                  !locations.contains(sourceURL) else {
                throw V2Error.unsafePath
            }
            let input = try V2FilePlaintextInput(url: sourceURL)
            return try importPlaintext(
                input,
                sourceURLToRemove: removeSourceAfterCommit ? sourceURL : nil,
                into: vaultID,
                session: session,
                request: request
            )
        }
    }

    func importPlaintext(
        _ input: V2PlaintextInput,
        sourceURLToRemove: URL?,
        into vaultID: UUID,
        session: V2VaultSession,
        request: V2ImportRequest,
        objectID: UUID = UUID(),
        revisionID: UUID = UUID()
    ) throws -> V2ImportResult {
        try withOperationLock {
            let vault = try metadata.vault(id: vaultID)
            guard session.vaultID == vaultID,
                  request.mediaType == vault.mediaType,
                  input.byteCount >= 0,
                  sourceURLToRemove.map({ !locations.contains($0) }) ?? true else {
                throw V2Error.unsafePath
            }
            let blobName = Self.randomBlobName()
            let stagedURL = locations.staging.appendingPathComponent(
                "\(UUID().uuidString).tmp",
                isDirectory: false
            )
            let finalURL = locations.objects.appendingPathComponent(
                blobName,
                isDirectory: false
            )
            var blobCommitted = false
            var metadataCommitted = false
            var finalVerificationComplete = false

            do {
                try session.withMasterKey { masterKey in
                    _ = try V2MediaContainer.encrypt(
                        input: input,
                        to: stagedURL,
                        vaultID: vaultID,
                        masterKey: masterKey,
                        objectID: objectID,
                        revisionID: revisionID
                    )
                    let stagedReader = try V2MediaReader(
                        sourceURL: stagedURL,
                        expectedVaultID: vaultID,
                        masterKey: masterKey,
                        maximumCacheBytes: 0
                    )
                    _ = try stagedReader.verifyAllChunks()
                }
                try failureInjector.reach(.stagedAndVerified)

                try FileManager.default.moveItem(at: stagedURL, to: finalURL)
                try Self.synchronizeDirectory(locations.objects)
                blobCommitted = true
                try failureInjector.reach(.blobCommitted)

                let object = V2ObjectRecord(
                    id: objectID,
                    vaultID: vaultID,
                    revisionID: revisionID,
                    blobName: blobName,
                    displayName: request.displayName,
                    originalExtension: request.originalExtension,
                    mediaType: request.mediaType,
                    importedAt: request.importedAt,
                    byteCount: input.byteCount,
                    durationSeconds: request.durationSeconds,
                    playbackPositionSeconds: nil
                )
                try metadata.insertObject(object, session: session)
                metadataCommitted = true
                try failureInjector.reach(.metadataCommitted)

                try session.withMasterKey { masterKey in
                    let finalReader = try V2MediaReader(
                        sourceURL: finalURL,
                        expectedVaultID: vaultID,
                        masterKey: masterKey,
                        maximumCacheBytes: 0
                    )
                    guard finalReader.descriptor.objectID == objectID,
                          finalReader.descriptor.revisionID == revisionID,
                          finalReader.descriptor.plaintextLength == input.byteCount else {
                        throw V2Error.invalidContainer
                    }
                    _ = try finalReader.verifyAllChunks()
                }
                finalVerificationComplete = true
                try failureInjector.reach(.finalVerificationComplete)

                var sourceRemoved = false
                if let sourceURLToRemove {
                    do {
                        try FileManager.default.removeItem(at: sourceURLToRemove)
                        sourceRemoved = true
                    } catch {
                        sourceRemoved = false
                    }
                }
                return V2ImportResult(object: object, sourceRemoved: sourceRemoved)
            } catch {
                try? FileManager.default.removeItem(at: stagedURL)
                if metadataCommitted {
                    if !finalVerificationComplete {
                        _ = try? metadata.deleteObject(id: objectID, vaultID: vaultID)
                        try? FileManager.default.removeItem(at: finalURL)
                        try? Self.synchronizeDirectory(locations.objects)
                    }
                    // Once final verification completed, preserve both copies. The import is
                    // committed and source cleanup can be retried without any data loss.
                    throw error
                }
                if blobCommitted {
                    try? FileManager.default.removeItem(at: finalURL)
                    try? Self.synchronizeDirectory(locations.objects)
                }
                throw error
            }
        }
    }

    func reader(
        for object: V2ObjectRecord,
        session: V2VaultSession,
        maximumCacheBytes: Int = 64 * 1024 * 1024
    ) throws -> V2MediaReader {
        guard object.vaultID == session.vaultID else {
            throw V2Error.authenticationFailed
        }
        let url = try objectURL(blobName: object.blobName)
        return try session.withMasterKey { masterKey in
            let reader = try V2MediaReader(
                sourceURL: url,
                expectedVaultID: object.vaultID,
                masterKey: masterKey,
                maximumCacheBytes: maximumCacheBytes
            )
            guard reader.descriptor.objectID == object.id,
                  reader.descriptor.revisionID == object.revisionID,
                  reader.descriptor.plaintextLength == object.byteCount else {
                throw V2Error.authenticationFailed
            }
            return reader
        }
    }

    func renameObject(
        _ object: V2ObjectRecord,
        to displayName: String,
        session: V2VaultSession
    ) throws -> V2ObjectRecord {
        var updated = object
        updated.displayName = displayName
        try metadata.updateObject(updated, session: session)
        return updated
    }

    func updatePlaybackPosition(
        _ object: V2ObjectRecord,
        seconds: Double?,
        session: V2VaultSession
    ) throws -> V2ObjectRecord {
        var updated = object
        updated.playbackPositionSeconds = seconds
        try metadata.updateObject(updated, session: session)
        return updated
    }

    func renameVault(id: UUID, to name: String) throws {
        try metadata.renameVault(id: id, to: name)
    }

    func saveVaultOrder(_ ids: [UUID]) throws {
        try metadata.saveVaultOrder(ids)
    }

    func deleteVault(id: UUID) throws {
        try withOperationLock {
            let vault = try metadata.vault(id: id)
            try metadata.deleteVault(id: id)
            try? keyManager.removeDeviceKey(
                envelope: vault.deviceEnvelope,
                vaultID: id
            )
        }
    }

    func deleteObject(id: UUID, vaultID: UUID) throws {
        try withOperationLock {
            let locator = try metadata.deleteObject(id: id, vaultID: vaultID)
            let url = try objectURL(blobName: locator.blobName)
            try? FileManager.default.removeItem(at: url)
            try? Self.synchronizeDirectory(locations.objects)
            try? FileManager.default.removeItem(
                at: locations.thumbnails.appendingPathComponent(
                    "\(locator.id.uuidString.lowercased()).thumb",
                    isDirectory: false
                )
            )
        }
    }

    func exportAndRemove(
        object: V2ObjectRecord,
        session: V2VaultSession,
        destinationDirectory: URL
    ) throws -> URL {
        try withOperationLock {
            guard !locations.contains(destinationDirectory) else {
                throw V2Error.unsafePath
            }
            try FileManager.default.createDirectory(
                at: destinationDirectory,
                withIntermediateDirectories: true
            )
            let finalURL = uniqueExportURL(
                displayName: object.displayName,
                originalExtension: object.originalExtension,
                directory: destinationDirectory
            )
            let temporaryURL = destinationDirectory.appendingPathComponent(
                ".crypta-v2-export-\(UUID().uuidString).tmp",
                isDirectory: false
            )
            let reader = try reader(
                for: object,
                session: session,
                maximumCacheBytes: 0
            )
            do {
                let exportedDigest = try reader.decrypt(to: temporaryURL)
                let verifiedDigest = try reader.verifyAllChunks()
                guard Data(exportedDigest) == Data(verifiedDigest) else {
                    throw V2Error.authenticationFailed
                }
                try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
                try Self.synchronizeDirectory(destinationDirectory)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }

            do {
                let locator = try metadata.deleteObject(
                    id: object.id,
                    vaultID: object.vaultID
                )
                try? FileManager.default.removeItem(
                    at: try objectURL(blobName: locator.blobName)
                )
                try? Self.synchronizeDirectory(locations.objects)
                try? FileManager.default.removeItem(
                    at: locations.thumbnails.appendingPathComponent(
                        "\(locator.id.uuidString.lowercased()).thumb",
                        isDirectory: false
                    )
                )
                return finalURL
            } catch {
                // The verified export is intentionally preserved. Metadata and the encrypted
                // object remain authoritative if the removal transaction did not commit.
                throw error
            }
        }
    }

    func recoverFilesystem() throws {
        try withOperationLock {
            try locations.prepare()
            let fileManager = FileManager.default
            let staged = try fileManager.contentsOfDirectory(
                at: locations.staging,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for url in staged {
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                if values?.isRegularFile == true, url.pathExtension == "tmp" {
                    try? fileManager.removeItem(at: url)
                }
            }

            let referenced = try metadata.referencedBlobNames()
            let stored = try fileManager.contentsOfDirectory(
                at: locations.objects,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
            for url in stored {
                let name = url.lastPathComponent
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                guard values?.isRegularFile == true,
                      Self.isSafeBlobName(name),
                      !referenced.contains(name) else {
                    continue
                }
                try? fileManager.removeItem(at: url)
            }
            try? Self.synchronizeDirectory(locations.objects)
            let playbackDirectories = try fileManager.contentsOfDirectory(
                at: locations.playback,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            for url in playbackDirectories {
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                guard values?.isDirectory == true,
                      UUID(uuidString: url.lastPathComponent) != nil else {
                    continue
                }
                try? fileManager.removeItem(at: url)
            }
            try metadata.integrityCheck()
        }
    }

    private func objectURL(blobName: String) throws -> URL {
        guard Self.isSafeBlobName(blobName) else {
            throw V2Error.unsafePath
        }
        return locations.objects.appendingPathComponent(blobName, isDirectory: false)
    }

    private func uniqueExportURL(
        displayName: String,
        originalExtension: String,
        directory: URL
    ) -> URL {
        let illegal = CharacterSet(charactersIn: "/:")
        let base = displayName
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = base.isEmpty ? "File" : base
        let cleanedExtension = originalExtension
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let suffix = cleanedExtension.isEmpty ? "" : ".\(cleanedExtension)"
        var candidate = directory.appendingPathComponent("\(safeBase)\(suffix)")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(safeBase) \(counter)\(suffix)")
            counter += 1
        }
        return candidate
    }

    private func withOperationLock<T>(_ operation: () throws -> T) rethrows -> T {
        operationLock.lock()
        defer { operationLock.unlock() }
        return try operation()
    }

    private static func loadCatalogKey(
        repository: any V2KeyRepository,
        databaseExists: Bool,
        objectsDirectory: URL
    ) throws -> SymmetricKey {
        if let existing = try repository.catalogKeyData() {
            guard existing.count == V2Crypto.keyByteCount else {
                throw V2Error.invalidEnvelope
            }
            return SymmetricKey(data: existing)
        }
        let hasObjects = ((try? FileManager.default.contentsOfDirectory(
            at: objectsDirectory,
            includingPropertiesForKeys: nil
        )) ?? []).isEmpty == false
        guard !databaseExists, !hasObjects else {
            throw V2Error.invalidEnvelope
        }
        let data = try V2Crypto.randomData(count: V2Crypto.keyByteCount)
        try repository.saveCatalogKeyData(data)
        return SymmetricKey(data: data)
    }

    private static func randomBlobName() -> String {
        UUID().uuidString
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }

    private static func isSafeBlobName(_ value: String) -> Bool {
        value.count == 32 &&
        value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw V2Error.unsafePath
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw V2Error.unsafePath
        }
    }
}
