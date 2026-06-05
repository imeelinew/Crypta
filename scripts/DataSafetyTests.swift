import Foundation

@main
struct DataSafetyTests {
    static func main() async throws {
        try testVideoSortModes()
        try testLegacyVideosDefaultToSafeLibraryKind()
        try await testMissingKeyDoesNotCreateReplacementWhenIndexExists()
        try await testMissingKeyDoesNotCreateReplacementWhenVaultContainsProtectedFiles()
        try await testCorruptedIndexFallsBackToBackup()
        try await testVideoLibraryImportsStayEncrypted()
        try await testFailedImportKeepsSourceFileUntilIndexIsSaved()
        try await testFailedDeleteKeepsBlobWhenIndexCannotBeSaved()
        try await testPlaybackCacheCleanupRemovesCrashLeftovers()
        try await testExportDecryptRemovesVideoFromVaultAfterIndexSave()
        try await testExportDecryptUsesUniqueDestinationName()
        try await testFailedExportKeepsEncryptedBlobAndIndexEntry()
        try await testFailedIndexSaveAfterExportKeepsEncryptedBlobAndIndexEntry()
        try await testExportRejectsVaultInternalDestination()
        print("Data safety tests passed")
    }

    private static func testVideoSortModes() throws {
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let newer = Date(timeIntervalSince1970: 1_800_000_000)
        let videos = [
            sampleVideo(displayName: "Video 10", importedAt: older),
            sampleVideo(displayName: "Video 2", importedAt: older),
            sampleVideo(displayName: "Alpha", importedAt: newer)
        ]

        try expect(
            VideoSortMode.name.sorted(videos).map(\.displayName) == ["Alpha", "Video 2", "Video 10"],
            "Name sort should use localized standard ordering."
        )
        try expect(
            VideoSortMode.recentlyAdded.sorted(videos).map(\.displayName) == ["Alpha", "Video 2", "Video 10"],
            "Recently-added sort should use imported date with name fallback."
        )
    }

    private static func testLegacyVideosDefaultToSafeLibraryKind() throws {
        let encryptedJSON = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "displayName": "Legacy Secret",
          "originalExtension": "mp4",
          "storageState": "encrypted",
          "plainFileName": null,
          "encryptedFileName": "blob",
          "importedAt": 0,
          "byteCount": 12,
          "durationSeconds": null
        }
        """.utf8)
        let plainJSON = Data("""
        {
          "id": "00000000-0000-0000-0000-000000000002",
          "displayName": "Legacy Plain",
          "originalExtension": "mp4",
          "storageState": "plain",
          "plainFileName": "Legacy Plain.mp4",
          "encryptedFileName": null,
          "importedAt": 0,
          "byteCount": 12,
          "durationSeconds": null
        }
        """.utf8)
        let decoder = JSONDecoder()

        let encryptedVideo = try decoder.decode(CryptaVideo.self, from: encryptedJSON)
        let plainVideo = try decoder.decode(CryptaVideo.self, from: plainJSON)

        try expect(
            encryptedVideo.libraryKind == .encrypted,
            "Legacy encrypted videos should default to the encrypted section."
        )
        try expect(
            plainVideo.libraryKind == .encrypted,
            "Legacy plain videos without an explicit category should stay out of the video section."
        )
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

    private static func testVideoLibraryImportsStayEncrypted() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let plaintext = Data("casual-but-private-video".utf8)
        let source = harness.root.appendingPathComponent("Casual.mkv", isDirectory: false)
        try plaintext.write(to: source)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))

        let video = try await store.importVideo(from: source, libraryKind: .video)

        try expect(video.libraryKind == .video, "Video-section import did not keep its semantic category.")
        try expect(video.storageState == .encrypted, "Video-section import should still be encrypted by default.")
        try expect(video.plainFileName == nil, "Video-section import created a long-lived plain file.")
        guard let encryptedFileName = video.encryptedFileName else {
            throw TestFailure("Video-section import did not create an encrypted blob.")
        }

        let blob = harness.locations.moviesVault.appendingPathComponent(encryptedFileName)
        try expect(FileManager.default.fileExists(atPath: blob.path), "Encrypted blob was not written.")
        try expect(try Data(contentsOf: blob) != plaintext, "Encrypted blob contains plaintext bytes.")

        let playback = try store.preparePlaybackURL(for: video)
        defer {
            if let cleanupURL = playback.cleanupURL {
                try? FileManager.default.removeItem(at: cleanupURL)
            }
        }
        try expect(try Data(contentsOf: playback.url) == plaintext, "Temporary playback file did not restore plaintext.")
        try expect(playback.cleanupURL != nil, "Encrypted video playback did not use a cleanup directory.")
        try expect(
            !playback.url.path.hasPrefix(harness.locations.vaultPackage.path + "/"),
            "Temporary playback file was written inside the vault package."
        )
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

    private static func testExportDecryptRemovesVideoFromVaultAfterIndexSave() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let plaintext = Data("synthetic-video".utf8)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await harness.importEncryptedVideo(named: "ExportMe.mp4", data: plaintext, store: store)
        try store.saveThumbnailData(Data("synthetic-thumbnail".utf8), for: video)
        let blob = harness.locations.moviesVault.appendingPathComponent(video.encryptedFileName ?? "")
        let outputDirectory = harness.root.appendingPathComponent("Exports", isDirectory: true)

        let output = try store.exportAndRemoveDecryptedVideo(video, to: outputDirectory)

        try expect(try Data(contentsOf: output) == plaintext, "Exported plaintext bytes were not restored.")
        try expect(!FileManager.default.fileExists(atPath: blob.path), "Encrypted blob remained after successful export.")
        try expect(try store.loadThumbnailData(for: video) == nil, "Thumbnail remained after successful export.")
        try expect(!store.loadIndex().videos.contains(where: { $0.id == video.id }), "Index entry remained after successful export.")
        try expect(
            !FileManager.default.fileExists(atPath: harness.locations.moviesVault.appendingPathComponent(output.lastPathComponent).path),
            "Plain export was written inside the vault Objects directory."
        )
    }

    private static func testExportDecryptUsesUniqueDestinationName() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await harness.importEncryptedVideo(named: "Video.mp4", data: Data("synthetic".utf8), store: store)
        let outputDirectory = harness.root.appendingPathComponent("Exports", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        try Data("existing".utf8).write(to: outputDirectory.appendingPathComponent("Video.mp4"))

        let output = try store.exportAndRemoveDecryptedVideo(video, to: outputDirectory)

        try expect(output.lastPathComponent == "Video 2.mp4", "Export overwrote or failed to uniquify an existing file.")
    }

    private static func testFailedExportKeepsEncryptedBlobAndIndexEntry() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = harness.sampleVideo(encryptedFileName: "invalid-blob")
        try store.saveIndex(CryptaIndex(videos: [video]))
        let blob = harness.locations.moviesVault.appendingPathComponent("invalid-blob")
        try FileManager.default.createDirectory(at: harness.locations.moviesVault, withIntermediateDirectories: true)
        try Data("not-a-valid-encrypted-file".utf8).write(to: blob)
        let outputDirectory = harness.root.appendingPathComponent("Exports", isDirectory: true)

        do {
            _ = try store.exportAndRemoveDecryptedVideo(video, to: outputDirectory)
            throw TestFailure("Invalid encrypted blob should not export successfully.")
        } catch {
            let outputFiles = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
            try expect(outputFiles.isEmpty, "Failed export left a partial plaintext output.")
            try expect(FileManager.default.fileExists(atPath: blob.path), "Failed export removed the encrypted blob.")
            try expect(store.loadIndex().videos.contains(where: { $0.id == video.id }), "Failed export removed the index entry.")
        }
    }

    private static func testFailedIndexSaveAfterExportKeepsEncryptedBlobAndIndexEntry() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let plaintext = Data("synthetic-video".utf8)
        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await harness.importEncryptedVideo(named: "SaveFails.mp4", data: plaintext, store: store)
        _ = try store.updatePlaybackPosition(videoID: video.id, seconds: 1)
        let blob = harness.locations.moviesVault.appendingPathComponent(video.encryptedFileName ?? "")
        let outputDirectory = harness.root.appendingPathComponent("Exports", isDirectory: true)

        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: harness.locations.vaultPackage.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.locations.vaultPackage.path)
        }

        do {
            _ = try store.exportAndRemoveDecryptedVideo(video, to: outputDirectory)
            throw TestFailure("Export should fail when the index cannot be saved.")
        } catch {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: harness.locations.vaultPackage.path)
            try expect(FileManager.default.fileExists(atPath: blob.path), "Index-save failure removed the encrypted blob.")
            try expect(store.loadIndex().videos.contains(where: { $0.id == video.id }), "Index-save failure removed the index entry.")
            let outputFiles = (try? FileManager.default.contentsOfDirectory(atPath: outputDirectory.path)) ?? []
            try expect(outputFiles.count == 1, "Index-save failure should leave the already exported plaintext for the user.")
        }
    }

    private static func testExportRejectsVaultInternalDestination() async throws {
        let harness = try StoreHarness()
        defer { harness.cleanup() }

        let store = CryptaStore(locations: harness.locations, keyStore: InMemoryKeyStore(data: harness.keyData))
        let video = try await harness.importEncryptedVideo(named: "NoVaultOutput.mp4", data: Data("synthetic".utf8), store: store)
        let blob = harness.locations.moviesVault.appendingPathComponent(video.encryptedFileName ?? "")

        do {
            _ = try store.exportAndRemoveDecryptedVideo(video, to: harness.locations.moviesVault)
            throw TestFailure("Exporting into the vault should be rejected.")
        } catch CryptaError.invalidExportDestination {
            try expect(FileManager.default.fileExists(atPath: blob.path), "Rejected vault export removed the encrypted blob.")
            try expect(store.loadIndex().videos.contains(where: { $0.id == video.id }), "Rejected vault export removed the index entry.")
        }
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else {
            throw TestFailure(message)
        }
    }

    private static func sampleVideo(displayName: String, importedAt: Date) -> CryptaVideo {
        CryptaVideo(
            id: UUID(),
            displayName: displayName,
            originalExtension: "mp4",
            storageState: .encrypted,
            plainFileName: nil,
            encryptedFileName: UUID().uuidString,
            importedAt: importedAt,
            byteCount: 12,
            durationSeconds: nil
        )
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

    func importEncryptedVideo(named name: String, data: Data, store: CryptaStore) async throws -> CryptaVideo {
        let source = root.appendingPathComponent(name, isDirectory: false)
        try data.write(to: source)
        return try await store.importVideo(from: source, storageState: .encrypted)
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
