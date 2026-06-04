import Foundation

@main
struct DataSafetyTests {
    static func main() async throws {
        try await testMissingKeyDoesNotCreateReplacementWhenIndexExists()
        try await testMissingKeyDoesNotCreateReplacementWhenVaultContainsProtectedFiles()
        try await testCorruptedIndexFallsBackToBackup()
        try await testFailedImportKeepsSourceFileUntilIndexIsSaved()
        try await testFailedDeleteKeepsBlobWhenIndexCannotBeSaved()
        try await testPlaybackCacheCleanupRemovesCrashLeftovers()
        print("Data safety tests passed")
    }

    private static func testMissingKeyDoesNotCreateReplacementWhenIndexExists() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let seededStore = CryptaStore(
            locations: harness.locations,
            keyStore: InMemoryKeyStore(data: harness.keyData)
        )
        try seededStore.saveIndex(CryptaIndex(videos: [harness.sampleVideo(encryptedFileName: "blob")]))

        let missingKeyStore = InMemoryKeyStore(data: nil)
        let store = CryptaStore(locations: harness.locations, keyStore: missingKeyStore)

        do {
            _ = try store.loadIndex()
            throw TestFailure("Loading an existing encrypted index without a key should fail closed.")
        } catch CryptaError.missingEncryptionKey {
            try expect(missingKeyStore.savedKeyCount == 0, "Missing-key load created a replacement key.")
        }
    }

    private static func testMissingKeyDoesNotCreateReplacementWhenVaultContainsProtectedFiles() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        try FileManager.default.createDirectory(at: harness.locations.moviesVault, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: harness.locations.moviesVault.appendingPathComponent("orphaned-blob"))

        let keyStore = InMemoryKeyStore(data: nil)
        let store = CryptaStore(locations: harness.locations, keyStore: keyStore)

        do {
            try store.saveIndex(CryptaIndex())
            throw TestFailure("Saving with protected vault files but no key should fail closed.")
        } catch CryptaError.protectedDataRequiresExistingKey {
            try expect(keyStore.savedKeyCount == 0, "Protected vault save created a replacement key.")
        }
    }

    private static func testCorruptedIndexFallsBackToBackup() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        try store.saveIndex(CryptaIndex(videos: [harness.sampleVideo(displayName: "First", encryptedFileName: "first-blob")]))
        try store.saveIndex(CryptaIndex(videos: [harness.sampleVideo(displayName: "Second", encryptedFileName: "second-blob")]))
        try Data("corrupted".utf8).write(to: harness.locations.encryptedIndex, options: [.atomic])

        let recovered = try store.loadIndex()
        try expect(recovered.videos.map(\.displayName) == ["First"], "Corrupted index did not recover from backup.")
    }

    private static func testFailedImportKeepsSourceFileUntilIndexIsSaved() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        try harness.makeIndexPathUnwritableAsDirectory()
        let source = harness.root.appendingPathComponent("source.mp4")
        try Data("company-video".utf8).write(to: source)

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        do {
            _ = try await store.importVideo(from: source, storageState: .encrypted)
            throw TestFailure("Import should fail because the index path is a directory.")
        } catch {
            try expect(FileManager.default.fileExists(atPath: source.path), "Failed import removed the source file.")
        }
    }

    private static func testFailedDeleteKeepsBlobWhenIndexCannotBeSaved() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let blobName = "encrypted-blob"
        let blob = harness.locations.moviesVault.appendingPathComponent(blobName)
        try FileManager.default.createDirectory(at: harness.locations.moviesVault, withIntermediateDirectories: true)
        try Data("encrypted".utf8).write(to: blob)
        try harness.makeIndexPathUnwritableAsDirectory()

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        do {
            try store.delete(harness.sampleVideo(encryptedFileName: blobName))
            throw TestFailure("Delete should fail before removing a blob when the index cannot be loaded or saved.")
        } catch {
            try expect(FileManager.default.fileExists(atPath: blob.path), "Failed delete removed the blob.")
        }
    }

    private static func testPlaybackCacheCleanupRemovesCrashLeftovers() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let leftoverDirectory = harness.locations.playbackCache.appendingPathComponent("leftover", isDirectory: true)
        try FileManager.default.createDirectory(at: leftoverDirectory, withIntermediateDirectories: true)
        try Data("plaintext".utf8).write(to: leftoverDirectory.appendingPathComponent("video.mp4"))

        try harness.locations.cleanPlaybackCache()
        let isEmpty = (try? FileManager.default.contentsOfDirectory(atPath: harness.locations.playbackCache.path).isEmpty) ?? true
        try expect(isEmpty, "Playback cache cleanup left plaintext files behind.")
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw TestFailure(message)
        }
    }
}

private struct TestFailure: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

private final class StoreHarness {
    let root: URL
    let locations: CryptaStorageLocations
    let keyData = Data(repeating: 7, count: 32)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CryptaDataSafety-\(UUID().uuidString)", isDirectory: true)
        locations = CryptaStorageLocations(
            vaultPackage: root.appendingPathComponent("Movies/Crypta.vault", isDirectory: true),
            moviesVault: root.appendingPathComponent("Movies/Crypta.vault/Objects", isDirectory: true),
            applicationSupport: root.appendingPathComponent("Movies/Crypta.vault", isDirectory: true),
            playbackCache: root.appendingPathComponent("Caches/Crypta/Playback", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeIndexPathUnwritableAsDirectory() throws {
        try FileManager.default.createDirectory(at: locations.applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: locations.encryptedIndex, withIntermediateDirectories: true)
    }

    func sampleVideo(displayName: String = "Video", encryptedFileName: String) -> CryptaVideo {
        CryptaVideo(
            id: UUID(),
            displayName: displayName,
            originalExtension: "mp4",
            storageState: .encrypted,
            plainFileName: nil,
            encryptedFileName: encryptedFileName,
            importedAt: Date(),
            byteCount: 12,
            durationSeconds: nil
        )
    }
}

private final class InMemoryKeyStore: CryptaEncryptionKeyStore, @unchecked Sendable {
    private var data: Data?
    private(set) var savedKeyCount = 0

    init(data: Data?) {
        self.data = data
    }

    func readKeyData() throws -> Data? {
        data
    }

    func saveKeyData(_ data: Data) throws {
        savedKeyCount += 1
        self.data = data
    }
}
