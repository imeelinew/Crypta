import CryptoKit
import Darwin
import Foundation
import Testing
@testable import Crypta

struct V2StoreTests {
    @Test func metadataAndTitlesAreEncryptedAtRest() throws {
        try withStore { store, directory in
            let creation = try store.createVault(
                name: "Vault-Confidential-Marker-29AF",
                encryptionLevel: .extended,
                mediaType: .video
            )
            let source = directory.appendingPathComponent("source.bin")
            try Data(repeating: 0x4C, count: 128 * 1024 + 9).write(to: source)
            let result = try store.importFile(
                from: source,
                into: creation.vault.id,
                session: creation.session,
                request: V2ImportRequest(
                    displayName: "Title-Confidential-Marker-83D1",
                    originalExtension: "mkv",
                    mediaType: .video,
                    durationSeconds: 42
                )
            )
            #expect(result.sourceRemoved)
            #expect(!FileManager.default.fileExists(atPath: source.path))

            let objects = try store.metadata.loadObjects(
                vaultID: creation.vault.id,
                session: creation.session
            )
            #expect(objects.count == 1)
            #expect(objects[0].displayName == "Title-Confidential-Marker-83D1")

            let databaseArtifacts = [
                store.locations.database,
                URL(fileURLWithPath: store.locations.database.path + "-wal"),
                URL(fileURLWithPath: store.locations.database.path + "-shm")
            ]
            let forbidden = [
                Data("Vault-Confidential-Marker-29AF".utf8),
                Data("Title-Confidential-Marker-83D1".utf8)
            ]
            for artifact in databaseArtifacts
            where FileManager.default.fileExists(atPath: artifact.path) {
                let bytes = try Data(contentsOf: artifact)
                for marker in forbidden {
                    #expect(bytes.range(of: marker) == nil)
                }
            }
        }
    }

    @Test func importCommitsBeforeRemovingSource() throws {
        let recorder = RecordingFailureInjector()
        try withStore(failureInjector: recorder) { store, directory in
            let creation = try store.createVault(
                name: "test",
                encryptionLevel: .standard,
                mediaType: .video
            )
            let source = directory.appendingPathComponent("input.mp4")
            let plaintext = Data((0..<90_000).map { UInt8(truncatingIfNeeded: $0) })
            try plaintext.write(to: source)

            let result = try store.importFile(
                from: source,
                into: creation.vault.id,
                session: creation.session,
                request: V2ImportRequest(
                    displayName: "input",
                    originalExtension: "mp4",
                    mediaType: .video,
                    durationSeconds: nil
                )
            )
            #expect(result.sourceRemoved)
            #expect(
                recorder.checkpoints == [
                    .stagedAndVerified,
                    .blobCommitted,
                    .metadataCommitted,
                    .finalVerificationComplete
                ]
            )
            #expect(!FileManager.default.fileExists(atPath: source.path))
            let reader = try store.reader(for: result.object, session: creation.session)
            #expect(try reader.data(offset: 0, length: plaintext.count) == plaintext)
        }
    }

    @Test func verifiedImportReportsSourceCleanupFailure() throws {
        try withStore { store, directory in
            let creation = try store.createVault(
                name: "cleanup warning",
                encryptionLevel: .standard,
                mediaType: .video
            )
            let sourceDirectory = directory.appendingPathComponent(
                "ReadOnlySource",
                isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: sourceDirectory,
                withIntermediateDirectories: true
            )
            let source = sourceDirectory.appendingPathComponent("input.mkv")
            let plaintext = Data(repeating: 0x73, count: 91_337)
            try plaintext.write(to: source)
            #expect(chmod(sourceDirectory.path, 0o500) == 0)
            defer { _ = chmod(sourceDirectory.path, 0o700) }

            let result = try store.importFile(
                from: source,
                into: creation.vault.id,
                session: creation.session,
                request: V2ImportRequest(
                    displayName: "input",
                    originalExtension: "mkv",
                    mediaType: .video,
                    durationSeconds: nil
                )
            )

            #expect(!result.sourceRemoved)
            #expect(FileManager.default.fileExists(atPath: source.path))
            let reader = try store.reader(
                for: result.object,
                session: creation.session,
                maximumCacheBytes: 0
            )
            #expect(
                try reader.data(offset: 0, length: plaintext.count)
                    == plaintext
            )
        }
    }

    @Test(arguments: [
        V2StoreCheckpoint.stagedAndVerified,
        .blobCommitted,
        .metadataCommitted
    ])
    func failedImportLeavesSourceAndNoCommittedObject(
        checkpoint: V2StoreCheckpoint
    ) throws {
        let injector = ThrowingFailureInjector(target: checkpoint)
        try withStore(failureInjector: injector) { store, directory in
            let creation = try store.createVault(
                name: "test",
                encryptionLevel: .standard,
                mediaType: .video
            )
            let source = directory.appendingPathComponent("source.mkv")
            try Data(repeating: 0xF1, count: 72_000).write(to: source)

            #expect(throws: InjectedStoreFailure.self) {
                _ = try store.importFile(
                    from: source,
                    into: creation.vault.id,
                    session: creation.session,
                    request: V2ImportRequest(
                        displayName: "source",
                        originalExtension: "mkv",
                        mediaType: .video,
                        durationSeconds: nil
                    )
                )
            }
            #expect(FileManager.default.fileExists(atPath: source.path))
            #expect(
                try store.metadata.loadObjects(
                    vaultID: creation.vault.id,
                    session: creation.session
                ).isEmpty
            )
            let storedObjects = try FileManager.default.contentsOfDirectory(
                at: store.locations.objects,
                includingPropertiesForKeys: nil
            )
            #expect(storedObjects.isEmpty)
        }
    }

    @Test func failureAfterFinalVerificationPreservesCommittedCopyAndSource() throws {
        let injector = ThrowingFailureInjector(target: .finalVerificationComplete)
        try withStore(failureInjector: injector) { store, directory in
            let creation = try store.createVault(
                name: "test",
                encryptionLevel: .standard,
                mediaType: .video
            )
            let source = directory.appendingPathComponent("source.mp4")
            try Data(repeating: 0x37, count: 81_000).write(to: source)

            #expect(throws: InjectedStoreFailure.self) {
                _ = try store.importFile(
                    from: source,
                    into: creation.vault.id,
                    session: creation.session,
                    request: V2ImportRequest(
                        displayName: "source",
                        originalExtension: "mp4",
                        mediaType: .video,
                        durationSeconds: nil
                    )
                )
            }
            #expect(FileManager.default.fileExists(atPath: source.path))
            let committed = try store.metadata.loadObjects(
                vaultID: creation.vault.id,
                session: creation.session
            )
            #expect(committed.count == 1)
            #expect(
                FileManager.default.fileExists(
                    atPath: store.locations.objects
                        .appendingPathComponent(committed[0].blobName).path
                )
            )
            try store.recoverFilesystem()
            #expect(
                FileManager.default.fileExists(
                    atPath: store.locations.objects
                        .appendingPathComponent(committed[0].blobName).path
                )
            )
        }
    }

    @Test func exportVerifiesBeforeRemovingEncryptedObject() throws {
        try withStore { store, directory in
            let creation = try store.createVault(
                name: "test",
                encryptionLevel: .standard,
                mediaType: .video
            )
            let source = directory.appendingPathComponent("source.webm")
            let plaintext = Data(repeating: 0x9C, count: 100_003)
            try plaintext.write(to: source)
            let imported = try store.importFile(
                from: source,
                into: creation.vault.id,
                session: creation.session,
                request: V2ImportRequest(
                    displayName: "exported",
                    originalExtension: "webm",
                    mediaType: .video,
                    durationSeconds: nil
                ),
                removeSourceAfterCommit: false
            )
            let encryptedURL = store.locations.objects
                .appendingPathComponent(imported.object.blobName)
            #expect(FileManager.default.fileExists(atPath: encryptedURL.path))

            let exportDirectory = directory.appendingPathComponent("Exports", isDirectory: true)
            let exportedURL = try store.exportAndRemove(
                object: imported.object,
                session: creation.session,
                destinationDirectory: exportDirectory
            )
            #expect(try Data(contentsOf: exportedURL) == plaintext)
            #expect(!FileManager.default.fileExists(atPath: encryptedURL.path))
            #expect(
                try store.metadata.loadObjects(
                    vaultID: creation.vault.id,
                    session: creation.session
                ).isEmpty
            )
        }
    }

    @Test func filesystemRecoveryRemovesOnlyV2OrphansAndStaging() throws {
        try withStore { store, _ in
            let orphan = store.locations.objects
                .appendingPathComponent("0123456789abcdef0123456789abcdef")
            let unknown = store.locations.objects.appendingPathComponent("do-not-touch")
            let staged = store.locations.staging.appendingPathComponent("operation.tmp")
            try Data([1]).write(to: orphan)
            try Data([2]).write(to: unknown)
            try Data([3]).write(to: staged)

            try store.recoverFilesystem()
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
            #expect(!FileManager.default.fileExists(atPath: staged.path))
            #expect(FileManager.default.fileExists(atPath: unknown.path))
        }
    }

    @Test func playbackPolicyKeepsProtectedVaultsInsideCrypta() {
        #expect(
            V2PlaybackPolicy.route(encryptionLevel: .standard, mediaType: .video)
                == .externalVideo
        )
        #expect(
            V2PlaybackPolicy.route(encryptionLevel: .standard, mediaType: .image)
                == .externalImage
        )
        #expect(
            V2PlaybackPolicy.route(encryptionLevel: .extended, mediaType: .video)
                == .builtInVideo
        )
        #expect(
            V2PlaybackPolicy.route(encryptionLevel: .maximum, mediaType: .video)
                == .builtInVideo
        )
        #expect(
            V2PlaybackPolicy.route(encryptionLevel: .extended, mediaType: .image)
                == .builtInImage
        )
        #expect(
            V2PlaybackPolicy.route(encryptionLevel: .maximum, mediaType: .image)
                == .builtInImage
        )
    }

    @Test func externalMaterializationIsLimitedToStandardVaults() throws {
        try withStore { store, directory in
            let plaintext = Data((0..<180_003).map { UInt8(truncatingIfNeeded: $0) })

            let standard = try store.createVault(
                name: "standard",
                encryptionLevel: .standard,
                mediaType: .video
            )
            let standardSource = directory.appendingPathComponent("standard.mkv")
            try plaintext.write(to: standardSource)
            let standardObject = try store.importFile(
                from: standardSource,
                into: standard.vault.id,
                session: standard.session,
                request: V2ImportRequest(
                    displayName: "standard",
                    originalExtension: "mkv",
                    mediaType: .video,
                    durationSeconds: nil
                ),
                removeSourceAfterCommit: false
            ).object
            let playback = try store.materializeForExternalPlayback(
                object: standardObject,
                vault: standard.vault,
                session: standard.session
            )
            defer {
                if let cleanupURL = playback.cleanupURL {
                    try? FileManager.default.removeItem(at: cleanupURL)
                }
            }
            #expect(try Data(contentsOf: playback.url) == plaintext)

            let protected = try store.createVault(
                name: "protected",
                encryptionLevel: .maximum,
                mediaType: .video
            )
            let protectedSource = directory.appendingPathComponent("protected.mkv")
            try plaintext.write(to: protectedSource)
            let protectedObject = try store.importFile(
                from: protectedSource,
                into: protected.vault.id,
                session: protected.session,
                request: V2ImportRequest(
                    displayName: "protected",
                    originalExtension: "mkv",
                    mediaType: .video,
                    durationSeconds: nil
                ),
                removeSourceAfterCommit: false
            ).object

            #expect(throws: V2Error.self) {
                _ = try store.materializeForExternalPlayback(
                    object: protectedObject,
                    vault: protected.vault,
                    session: protected.session
                )
            }
        }
    }

    @Test func thumbnailsAreEncryptedAndBoundToObjectRevision() throws {
        try withStore { store, directory in
            let creation = try store.createVault(
                name: "test",
                encryptionLevel: .extended,
                mediaType: .video
            )
            let source = directory.appendingPathComponent("thumbnail-source.mp4")
            try Data(repeating: 0xA1, count: 32_000).write(to: source)
            let object = try store.importFile(
                from: source,
                into: creation.vault.id,
                session: creation.session,
                request: V2ImportRequest(
                    displayName: "thumbnail",
                    originalExtension: "mp4",
                    mediaType: .video,
                    durationSeconds: nil
                )
            ).object
            let thumbnail = Data((0..<4_097).map { UInt8(truncatingIfNeeded: $0 * 7) })

            try store.saveThumbnail(
                thumbnail,
                for: object,
                session: creation.session
            )
            #expect(
                try store.loadThumbnail(
                    for: object,
                    session: creation.session
                ) == thumbnail
            )

            let thumbnailURL = store.locations.thumbnails.appendingPathComponent(
                "\(object.id.uuidString.lowercased()).thumb"
            )
            #expect(try Data(contentsOf: thumbnailURL).range(of: thumbnail) == nil)

            let mismatchedRevision = V2ObjectRecord(
                id: object.id,
                vaultID: object.vaultID,
                revisionID: UUID(),
                blobName: object.blobName,
                displayName: object.displayName,
                originalExtension: object.originalExtension,
                mediaType: object.mediaType,
                importedAt: object.importedAt,
                byteCount: object.byteCount,
                durationSeconds: object.durationSeconds,
                playbackPositionSeconds: object.playbackPositionSeconds
            )
            #expect(throws: V2Error.self) {
                _ = try store.loadThumbnail(
                    for: mismatchedRevision,
                    session: creation.session
                )
            }
        }
    }

    @Test func recoveryConfirmationAndReplacementPersist() throws {
        try withStore { store, _ in
            let creation = try store.createVault(
                name: "recovery",
                encryptionLevel: .maximum,
                mediaType: .video,
                recoveryConfirmed: false
            )
            #expect(
                try store.metadata.vault(id: creation.vault.id)
                    .recoveryConfirmed == false
            )

            try store.confirmRecoveryKey(vaultID: creation.vault.id)
            #expect(
                try store.metadata.vault(id: creation.vault.id)
                    .recoveryConfirmed
            )

            let replacement = try store.replaceRecoveryKey(
                session: creation.session
            )
            #expect(
                try store.metadata.vault(id: creation.vault.id)
                    .recoveryConfirmed == false
            )
            let recovered = try store.recover(
                vaultID: creation.vault.id,
                recoveryKey: replacement
            )
            recovered.invalidate()

            try store.confirmRecoveryKey(vaultID: creation.vault.id)
            #expect(
                try store.metadata.vault(id: creation.vault.id)
                    .recoveryConfirmed
            )
        }
    }

    @Test func recoveryRestoresCatalogAndReenrollsLostDeviceAccess() throws {
        try withStore { originalStore, directory in
            let creation = try originalStore.createVault(
                name: "catalog recovery",
                encryptionLevel: .maximum,
                mediaType: .image
            )
            let source = directory.appendingPathComponent("recovery-source.bin")
            let plaintext = Data((0..<120_000).map { UInt8(truncatingIfNeeded: $0 * 29) })
            try plaintext.write(to: source)
            let imported = try originalStore.importFile(
                from: source,
                into: creation.vault.id,
                session: creation.session,
                request: V2ImportRequest(
                    displayName: "confidential title",
                    originalExtension: "bin",
                    mediaType: .image,
                    durationSeconds: nil
                ),
                removeSourceAfterCommit: false
            )

            let repository = StoreTestKeyRepository()
            let recoveredProtector = StoreTestDeviceProtector()
            let recovered = try V2VaultStore.recoverAccess(
                recoveryKey: creation.recoveryKey,
                locations: originalStore.locations,
                repository: repository,
                keyManager: V2KeyManager(deviceProtector: recoveredProtector)
            )

            #expect(
                try repository.catalogKeyData()
                    == V2Crypto.keyData(originalStore.metadata.catalogKeyForRecovery())
            )
            #expect(try recovered.store.metadata.loadVaults().map(\.name) == ["catalog recovery"])
            #expect(
                try recovered.store.metadata.loadObjects(
                    vaultID: creation.vault.id,
                    session: recovered.session
                ).map(\.displayName) == ["confidential title"]
            )

            let output = directory.appendingPathComponent("recovered-output.bin")
            _ = try recovered.store.reader(
                for: imported.object,
                session: recovered.session,
                maximumCacheBytes: 0
            ).decrypt(to: output)
            #expect(try Data(contentsOf: output) == plaintext)

            recovered.session.invalidate()
            let reenrolled = try recovered.store.unlock(
                vaultID: creation.vault.id,
                reason: "test"
            )
            #expect(
                try recovered.store.metadata.loadObjects(
                    vaultID: creation.vault.id,
                    session: reenrolled
                ).count == 1
            )
        }
    }

    @Test func invalidRecoveryKeyCannotRestoreCatalog() throws {
        try withStore { originalStore, _ in
            _ = try originalStore.createVault(
                name: "protected",
                encryptionLevel: .extended,
                mediaType: .video
            )
            let repository = StoreTestKeyRepository()
            #expect(throws: V2Error.invalidRecoveryKey) {
                _ = try V2VaultStore.recoverAccess(
                    recoveryKey: V2RecoveryKey(),
                    locations: originalStore.locations,
                    repository: repository,
                    keyManager: V2KeyManager(
                        deviceProtector: StoreTestDeviceProtector()
                    )
                )
            }
            #expect(try repository.catalogKeyData() == nil)
        }
    }

    @Test func recoveryKeyCannotReenrollADifferentVault() throws {
        try withStore { originalStore, _ in
            let first = try originalStore.createVault(
                name: "first",
                encryptionLevel: .extended,
                mediaType: .video
            )
            let second = try originalStore.createVault(
                name: "second",
                encryptionLevel: .maximum,
                mediaType: .image
            )
            let repository = StoreTestKeyRepository()

            #expect(throws: V2Error.invalidRecoveryKey) {
                _ = try V2VaultStore.recoverAccess(
                    recoveryKey: second.recoveryKey,
                    expectedVaultID: first.vault.id,
                    locations: originalStore.locations,
                    repository: repository,
                    keyManager: V2KeyManager(
                        deviceProtector: StoreTestDeviceProtector()
                    )
                )
            }
            #expect(try repository.catalogKeyData() == nil)

            let recovered = try V2VaultStore.recoverAccess(
                recoveryKey: first.recoveryKey,
                expectedVaultID: first.vault.id,
                locations: originalStore.locations,
                repository: repository,
                keyManager: V2KeyManager(
                    deviceProtector: StoreTestDeviceProtector()
                )
            )
            #expect(recovered.session.vaultID == first.vault.id)
            recovered.session.invalidate()
        }
    }

    private func withStore(
        failureInjector: any V2StoreFailureInjector = V2NoFailureInjector(),
        operation: (V2VaultStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Crypta-V2StoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let locations = V2StorageLocations(
            root: directory.appendingPathComponent("Vault", isDirectory: true),
            cacheRoot: directory.appendingPathComponent("Cache", isDirectory: true)
        )
        let metadata = try V2MetadataStore(
            databaseURL: locations.database,
            catalogKey: SymmetricKey(size: .bits256)
        )
        let keyManager = V2KeyManager(
            deviceProtector: StoreTestDeviceProtector()
        )
        let store = try V2VaultStore(
            locations: locations,
            metadata: metadata,
            keyManager: keyManager,
            failureInjector: failureInjector
        )
        try operation(store, directory)
    }
}

private nonisolated struct InjectedStoreFailure: Error {}

private nonisolated final class ThrowingFailureInjector: V2StoreFailureInjector, @unchecked Sendable {
    let target: V2StoreCheckpoint

    init(target: V2StoreCheckpoint) {
        self.target = target
    }

    func reach(_ checkpoint: V2StoreCheckpoint) throws {
        if checkpoint == target {
            throw InjectedStoreFailure()
        }
    }
}

private nonisolated final class RecordingFailureInjector: V2StoreFailureInjector, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var checkpoints: [V2StoreCheckpoint] = []

    func reach(_ checkpoint: V2StoreCheckpoint) throws {
        lock.lock()
        checkpoints.append(checkpoint)
        lock.unlock()
    }
}

private nonisolated final class StoreTestDeviceProtector: V2DeviceKeyProtector, @unchecked Sendable {
    private let key = SymmetricKey(size: .bits256)

    func wrap(
        masterKey: SymmetricKey,
        vaultID: UUID,
        protection: V2VaultProtection
    ) throws -> V2DeviceEnvelope {
        V2DeviceEnvelope(
            protection: protection,
            sealedMasterKey: try V2Crypto.seal(
                V2Crypto.keyData(masterKey),
                using: wrappingKey(vaultID: vaultID),
                authenticating: additionalData(vaultID: vaultID, protection: protection)
            ),
            ephemeralPublicKey: protection == .userPresence ? Data([1]) : nil
        )
    }

    func unwrap(
        envelope: V2DeviceEnvelope,
        vaultID: UUID,
        reason: String
    ) throws -> SymmetricKey {
        SymmetricKey(
            data: try V2Crypto.open(
                envelope.sealedMasterKey,
                using: wrappingKey(vaultID: vaultID),
                authenticating: additionalData(
                    vaultID: vaultID,
                    protection: envelope.protection
                )
            )
        )
    }

    func removeDeviceKey(envelope: V2DeviceEnvelope, vaultID: UUID) throws {}

    private func wrappingKey(vaultID: UUID) -> SymmetricKey {
        V2Crypto.deriveKey(
            from: key,
            salt: vaultID.v2Data,
            purpose: "store-test-device"
        )
    }

    private func additionalData(
        vaultID: UUID,
        protection: V2VaultProtection
    ) -> Data {
        vaultID.v2Data + Data(protection.rawValue.utf8)
    }
}

private nonisolated final class StoreTestKeyRepository: V2KeyRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var catalogData: Data?
    private var enclaveData: [UUID: Data] = [:]

    func catalogKeyData() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return catalogData
    }

    func saveCatalogKeyData(_ data: Data) throws {
        lock.lock()
        catalogData = data
        lock.unlock()
    }

    func secureEnclaveKeyData(keyIdentifier: UUID) throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return enclaveData[keyIdentifier]
    }

    func saveSecureEnclaveKeyData(_ data: Data, keyIdentifier: UUID) throws {
        lock.lock()
        enclaveData[keyIdentifier] = data
        lock.unlock()
    }

    func removeSecureEnclaveKeyData(keyIdentifier: UUID) throws {
        lock.lock()
        enclaveData.removeValue(forKey: keyIdentifier)
        lock.unlock()
    }
}
