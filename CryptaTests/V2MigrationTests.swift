import CryptoKit
import Foundation
import Testing
@testable import Crypta

struct V2MigrationTests {
    @Test func migrationStreamsLegacyDataAndPreservesItUntilVerification() async throws {
        try await withMigrationEnvironment { environment in
            let legacy = try await environment.makeLegacyLibrary(itemCount: 2)
            let recoveryKey = try V2RecoveryKey()
            let progressRecorder = MigrationProgressRecorder()
            let migrator = V2LegacyMigrator(
                source: environment.legacyReader,
                target: environment.targetStore
            )

            let result = try migrator.migrate(
                recoveryKey: recoveryKey,
                removeLegacyAfterCommit: false
            ) { event in
                progressRecorder.append(event)
            }
            let progressEvents = progressRecorder.events
            #expect(result.migratedObjectCount == 2)
            #expect(!result.legacyDataRemoved)
            #expect(
                FileManager.default.fileExists(
                    atPath: environment.legacyLocations.vaultPackage.path
                )
            )
            #expect(!environment.legacyKeyStore.wasDeleted)
            #expect(progressEvents.allSatisfy { $0.totalCount == 2 })
            #expect(progressEvents.last?.phase == .cleaningLegacy)

            let vaults = try environment.targetStore.metadata.loadVaults()
            #expect(vaults.count == 1)
            let session = try environment.targetStore.recover(
                vaultID: vaults[0].id,
                recoveryKey: recoveryKey
            )
            defer { session.invalidate() }
            let migrated = try environment.targetStore.metadata.loadObjects(
                vaultID: vaults[0].id,
                session: session
            )
            #expect(Set(migrated.map(\.displayName)) == Set(legacy.titles))
            #expect(Set(migrated.map(\.id)) == Set(legacy.videoIDs))

            for object in migrated {
                let plaintext = try environment.targetStore.reader(
                    for: object,
                    session: session,
                    maximumCacheBytes: 0
                ).data(offset: 0, length: Int(object.byteCount))
                #expect(plaintext == legacy.contents[object.displayName])
                #expect(
                    try environment.targetStore.loadThumbnail(
                        for: object,
                        session: session
                    ) == legacy.thumbnails[object.id]
                )
            }
        }
    }

    @Test func cleanupRunsOnlyAfterACompleteVerifiedMigration() async throws {
        try await withMigrationEnvironment { environment in
            _ = try await environment.makeLegacyLibrary(itemCount: 1)
            let recoveryKey = try V2RecoveryKey()
            let migrator = V2LegacyMigrator(
                source: environment.legacyReader,
                target: environment.targetStore
            )

            let result = try migrator.migrate(
                recoveryKey: recoveryKey,
                removeLegacyAfterCommit: true
            )
            #expect(result.legacyDataRemoved)
            #expect(
                !FileManager.default.fileExists(
                    atPath: environment.legacyLocations.vaultPackage.path
                )
            )
            #expect(environment.legacyKeyStore.wasDeleted)
            #expect(try environment.targetStore.metadata.migrationState()?.phase == .complete)
        }
    }

    @Test func interruptedMigrationKeepsLegacyDataAndCanResume() async throws {
        let injector = OneShotMigrationFailureInjector(target: .blobCommitted)
        try await withMigrationEnvironment(failureInjector: injector) { environment in
            let legacy = try await environment.makeLegacyLibrary(itemCount: 2)
            let recoveryKey = try V2RecoveryKey()
            let migrator = V2LegacyMigrator(
                source: environment.legacyReader,
                target: environment.targetStore
            )

            #expect(throws: MigrationInjectedFailure.self) {
                _ = try migrator.migrate(
                    recoveryKey: recoveryKey,
                    removeLegacyAfterCommit: true
                )
            }
            #expect(
                FileManager.default.fileExists(
                    atPath: environment.legacyLocations.vaultPackage.path
                )
            )
            #expect(!environment.legacyKeyStore.wasDeleted)

            let result = try migrator.migrate(
                recoveryKey: nil,
                removeLegacyAfterCommit: true
            )
            #expect(result.migratedObjectCount == 2)
            #expect(environment.legacyKeyStore.wasDeleted)
            let vault = try #require(environment.targetStore.metadata.loadVaults().first)
            let session = try environment.targetStore.recover(
                vaultID: vault.id,
                recoveryKey: recoveryKey
            )
            defer { session.invalidate() }
            let objects = try environment.targetStore.metadata.loadObjects(
                vaultID: vault.id,
                session: session
            )
            #expect(Set(objects.map(\.displayName)) == Set(legacy.titles))
        }
    }

    @Test func deferredCleanupReverifiesBeforeDeletingLegacyData() async throws {
        try await withMigrationEnvironment { environment in
            _ = try await environment.makeLegacyLibrary(itemCount: 1)
            let recoveryKey = try V2RecoveryKey()
            let migrator = V2LegacyMigrator(
                source: environment.legacyReader,
                target: environment.targetStore
            )
            _ = try migrator.migrate(
                recoveryKey: recoveryKey,
                removeLegacyAfterCommit: false
            )

            let vault = try #require(environment.targetStore.metadata.loadVaults().first)
            let session = try environment.targetStore.recover(
                vaultID: vault.id,
                recoveryKey: recoveryKey
            )
            let object = try #require(
                environment.targetStore.metadata.loadObjects(
                    vaultID: vault.id,
                    session: session
                ).first
            )
            session.invalidate()
            let blobURL = environment.targetStore.locations.objects
                .appendingPathComponent(object.blobName)
            let handle = try FileHandle(forUpdating: blobURL)
            try handle.seek(toOffset: UInt64(V2MediaContainer.headerSize))
            let byte = try #require(try handle.read(upToCount: 1)?.first)
            try handle.seek(toOffset: UInt64(V2MediaContainer.headerSize))
            try handle.write(contentsOf: Data([byte ^ 0x80]))
            try handle.close()

            #expect(throws: V2Error.self) {
                _ = try migrator.migrate(
                    recoveryKey: recoveryKey,
                    removeLegacyAfterCommit: true
                )
            }
            #expect(
                FileManager.default.fileExists(
                    atPath: environment.legacyLocations.vaultPackage.path
                )
            )
            #expect(!environment.legacyKeyStore.wasDeleted)
        }
    }

    private func withMigrationEnvironment(
        failureInjector: any V2StoreFailureInjector = V2NoFailureInjector(),
        operation: (MigrationTestEnvironment) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Crypta-V2MigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let legacyPackage = directory.appendingPathComponent("Legacy.vault", isDirectory: true)
        let legacyLocations = CryptaStorageLocations(
            vaultPackage: legacyPackage,
            moviesVault: legacyPackage.appendingPathComponent("Objects", isDirectory: true),
            playbackCache: directory.appendingPathComponent("LegacyPlayback", isDirectory: true)
        )
        let legacyKeyStore = MigrationLegacyKeyStore()
        let legacyReader = V1LegacyReader(
            locations: legacyLocations,
            keyStore: legacyKeyStore
        )
        let targetLocations = V2StorageLocations(
            root: directory.appendingPathComponent("V2", isDirectory: true),
            cacheRoot: directory.appendingPathComponent("V2Cache", isDirectory: true)
        )
        let metadata = try V2MetadataStore(
            databaseURL: targetLocations.database,
            catalogKey: SymmetricKey(size: .bits256)
        )
        let targetStore = try V2VaultStore(
            locations: targetLocations,
            metadata: metadata,
            keyManager: V2KeyManager(
                deviceProtector: MigrationTestDeviceProtector()
            ),
            failureInjector: failureInjector
        )
        let environment = MigrationTestEnvironment(
            root: directory,
            legacyLocations: legacyLocations,
            legacyKeyStore: legacyKeyStore,
            legacyReader: legacyReader,
            targetStore: targetStore
        )
        try await operation(environment)
    }
}

private nonisolated final class MigrationProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [V2MigrationProgress] = []

    var events: [V2MigrationProgress] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ event: V2MigrationProgress) {
        lock.lock()
        storage.append(event)
        lock.unlock()
    }
}

private nonisolated struct LegacyFixture {
    let titles: [String]
    let videoIDs: [UUID]
    let contents: [String: Data]
    let thumbnails: [UUID: Data]
}

private nonisolated final class MigrationTestEnvironment: @unchecked Sendable {
    let root: URL
    let legacyLocations: CryptaStorageLocations
    let legacyKeyStore: MigrationLegacyKeyStore
    let legacyReader: V1LegacyReader
    let targetStore: V2VaultStore

    init(
        root: URL,
        legacyLocations: CryptaStorageLocations,
        legacyKeyStore: MigrationLegacyKeyStore,
        legacyReader: V1LegacyReader,
        targetStore: V2VaultStore
    ) {
        self.root = root
        self.legacyLocations = legacyLocations
        self.legacyKeyStore = legacyKeyStore
        self.legacyReader = legacyReader
        self.targetStore = targetStore
    }

    func makeLegacyLibrary(itemCount: Int) async throws -> LegacyFixture {
        let store = CryptaStore(
            locations: legacyLocations,
            keyStore: legacyKeyStore
        )
        let group = LibraryGroup(
            name: "Legacy Vault",
            encryptionLevel: .extended,
            mediaType: .image
        )
        try store.createGroup(group)

        var titles: [String] = []
        var ids: [UUID] = []
        var contents: [String: Data] = [:]
        var thumbnails: [UUID: Data] = [:]
        for index in 0..<itemCount {
            let title = "Synthetic-Title-\(index)"
            let source = root.appendingPathComponent("\(title).png")
            let data = Data((0..<(70_000 + index * 997)).map {
                UInt8(truncatingIfNeeded: ($0 * 17) + index)
            })
            try data.write(to: source)
            let video = try await store.importImage(
                from: source,
                libraryKind: LibraryKind(rawValue: group.id)
            )
            titles.append(title)
            ids.append(video.id)
            contents[title] = data
            let thumbnail = Data((0..<1_111).map {
                UInt8(truncatingIfNeeded: ($0 * 13) + index)
            })
            let keyData = try #require(try legacyKeyStore.readKeyData())
            let sealed = try AES.GCM.seal(
                thumbnail,
                using: SymmetricKey(data: keyData)
            )
            let thumbnailURL = legacyLocations.thumbnailCache
                .appendingPathComponent("\(video.id.uuidString).v3.thumb")
            try FileManager.default.createDirectory(
                at: legacyLocations.thumbnailCache,
                withIntermediateDirectories: true
            )
            try #require(sealed.combined).write(to: thumbnailURL)
            thumbnails[video.id] = thumbnail
        }
        return LegacyFixture(
            titles: titles,
            videoIDs: ids,
            contents: contents,
            thumbnails: thumbnails
        )
    }
}

private nonisolated final class MigrationLegacyKeyStore: CryptaEncryptionKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private(set) var wasDeleted = false

    func readKeyData() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return data
    }

    func saveKeyData(_ data: Data) throws {
        lock.lock()
        self.data = data
        lock.unlock()
    }

    func deleteKeyData() throws {
        lock.lock()
        data = nil
        wasDeleted = true
        lock.unlock()
    }
}

private nonisolated struct MigrationInjectedFailure: Error {}

private nonisolated final class OneShotMigrationFailureInjector: V2StoreFailureInjector, @unchecked Sendable {
    private let lock = NSLock()
    private let target: V2StoreCheckpoint
    private var didThrow = false

    init(target: V2StoreCheckpoint) {
        self.target = target
    }

    func reach(_ checkpoint: V2StoreCheckpoint) throws {
        lock.lock()
        defer { lock.unlock() }
        if checkpoint == target, !didThrow {
            didThrow = true
            throw MigrationInjectedFailure()
        }
    }
}

private nonisolated final class MigrationTestDeviceProtector: V2DeviceKeyProtector, @unchecked Sendable {
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
                authenticating: vaultID.v2Data
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
                authenticating: vaultID.v2Data
            )
        )
    }

    func removeDeviceKey(envelope: V2DeviceEnvelope, vaultID: UUID) throws {}

    private func wrappingKey(vaultID: UUID) -> SymmetricKey {
        V2Crypto.deriveKey(
            from: key,
            salt: vaultID.v2Data,
            purpose: "migration-test-device"
        )
    }
}
