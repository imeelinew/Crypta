import Foundation
import Testing
@testable import Crypta

@MainActor
struct SubtitleSmokeTests {
    @Test func subtitleGenerationSmokeTest() async throws {
        guard let mediaPath = Self.smokeMediaPath(),
              !mediaPath.isEmpty else {
            return
        }

        let sourceURL = URL(fileURLWithPath: mediaPath)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CryptaSubtitleSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let importURL = root.appendingPathComponent(sourceURL.lastPathComponent, isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: importURL)

        let locations = CryptaStorageLocations(
            vaultPackage: root.appendingPathComponent("Movies/Crypta.vault", isDirectory: true),
            moviesVault: root.appendingPathComponent("Movies/Crypta.vault/Objects", isDirectory: true),
            applicationSupport: root.appendingPathComponent("Movies/Crypta.vault", isDirectory: true),
            playbackCache: root.appendingPathComponent("Caches/Crypta/Playback", isDirectory: true)
        )
        let store = CryptaStore(
            locations: locations,
            keyStore: SmokeKeyStore(data: Data(repeating: 8, count: 32))
        )
        let video = try await store.importVideo(from: importURL, libraryKind: .video, mediaType: .video)

        let manager = DecryptedMediaSessionManager(cacheRoot: locations.cacheRoot)
        let generationLease = try await manager.acquireMediaLease(for: video, store: store)
        let generator = SubtitleGenerator { _, _ in }
        try await generator.generate(from: generationLease.url, force: false)
        let updated = try store.commitModifiedVideo(at: generationLease.url, for: video)
        generationLease.release()
        #expect(updated.hasEmbeddedSubtitles)

        let playbackLease = try await manager.acquireMediaLease(for: updated, store: store)
        #expect(try SubtitleEmbedder.subtitleStreamCount(at: playbackLease.url) == 1)
        playbackLease.release()
        manager.shutdown()
    }

    private static func smokeMediaPath() -> String? {
        if let value = ProcessInfo.processInfo.environment["CRYPTA_SUBTITLE_SMOKE_MEDIA"],
           !value.isEmpty {
            return value
        }
        return nil
    }
}

private final class SmokeKeyStore: CryptaEncryptionKeyStore, @unchecked Sendable {
    private var data: Data?

    init(data: Data?) {
        self.data = data
    }

    func readKeyData() throws -> Data? {
        data
    }

    func saveKeyData(_ data: Data) throws {
        self.data = data
    }
}
