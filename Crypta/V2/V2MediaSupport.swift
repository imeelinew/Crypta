import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

nonisolated final class V2EncryptedMediaDataSource: RandomAccessMediaDataSource, @unchecked Sendable {
    let byteCount: Int64
    let contentTypeIdentifier: String

    private let reader: V2MediaReader

    init(reader: V2MediaReader, originalExtension: String) {
        self.reader = reader
        byteCount = reader.descriptor.plaintextLength
        let cleanedExtension = originalExtension.trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        )
        contentTypeIdentifier = UTType(filenameExtension: cleanedExtension)?.identifier
            ?? UTType.data.identifier
    }

    func data(offset: Int64, length: Int) throws -> Data {
        try reader.data(offset: offset, length: length)
    }

    func clearCache() {
        reader.clearCache()
    }
}

nonisolated enum V2PlaybackRoute: Equatable, Sendable {
    case externalVideo
    case builtInVideo
    case externalImage
    case builtInImage
}

nonisolated enum V2PlaybackPolicy {
    static func route(
        encryptionLevel: EncryptionLevel,
        mediaType: MediaType
    ) -> V2PlaybackRoute {
        switch (encryptionLevel, mediaType) {
        case (.standard, .video):
            return .externalVideo
        case (.standard, .image):
            return .externalImage
        case (.extended, .video), (.maximum, .video):
            return .builtInVideo
        case (.extended, .image), (.maximum, .image):
            return .builtInImage
        }
    }
}

nonisolated extension V2VaultStore {
    func inMemoryMediaDataSource(
        for object: V2ObjectRecord,
        session: V2VaultSession
    ) throws -> V2EncryptedMediaDataSource {
        V2EncryptedMediaDataSource(
            reader: try reader(for: object, session: session),
            originalExtension: object.originalExtension
        )
    }

    func materializeForExternalPlayback(
        object: V2ObjectRecord,
        vault: V2VaultRecord,
        session: V2VaultSession
    ) throws -> PlaybackURL {
        guard vault.id == object.vaultID,
              vault.id == session.vaultID,
              V2PlaybackPolicy.route(
                encryptionLevel: vault.encryptionLevel,
                mediaType: vault.mediaType
              ) == (object.mediaType == .video ? .externalVideo : .externalImage) else {
            throw V2Error.authenticationFailed
        }
        let directory = locations.playback.appendingPathComponent(
            UUID().uuidString,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let cleanedExtension = object.originalExtension.trimmingCharacters(
            in: CharacterSet(charactersIn: ".")
        )
        let suffix = cleanedExtension.isEmpty ? "" : ".\(cleanedExtension)"
        let url = directory.appendingPathComponent(
            "\(UUID().uuidString)\(suffix)",
            isDirectory: false
        )
        do {
            _ = try reader(
                for: object,
                session: session,
                maximumCacheBytes: 0
            ).decrypt(to: url)
            return PlaybackURL(url: url, cleanupURL: directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func saveThumbnail(
        _ data: Data,
        for object: V2ObjectRecord,
        session: V2VaultSession
    ) throws {
        guard object.vaultID == session.vaultID else {
            throw V2Error.authenticationFailed
        }
        let sealed = try session.withMasterKey { masterKey in
            let key = V2Crypto.deriveKey(
                from: masterKey,
                salt: object.vaultID.v2Data,
                purpose: "com.crypta.v2.thumbnail"
            )
            return try V2Crypto.seal(
                data,
                using: key,
                authenticating: thumbnailAdditionalData(for: object)
            )
        }
        let encoded = try JSONEncoder().encode(sealed)
        try encoded.write(to: thumbnailURL(for: object), options: [.atomic])
    }

    func loadThumbnail(
        for object: V2ObjectRecord,
        session: V2VaultSession
    ) throws -> Data? {
        guard object.vaultID == session.vaultID else {
            throw V2Error.authenticationFailed
        }
        let url = thumbnailURL(for: object)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let sealed = try JSONDecoder().decode(
            V2SealedData.self,
            from: Data(contentsOf: url)
        )
        return try session.withMasterKey { masterKey in
            let key = V2Crypto.deriveKey(
                from: masterKey,
                salt: object.vaultID.v2Data,
                purpose: "com.crypta.v2.thumbnail"
            )
            return try V2Crypto.open(
                sealed,
                using: key,
                authenticating: thumbnailAdditionalData(for: object)
            )
        }
    }

    private func thumbnailURL(for object: V2ObjectRecord) -> URL {
        locations.thumbnails.appendingPathComponent(
            "\(object.id.uuidString.lowercased()).thumb",
            isDirectory: false
        )
    }

    private func thumbnailAdditionalData(for object: V2ObjectRecord) -> Data {
        Data("com.crypta.v2.thumbnail".utf8)
            + object.vaultID.v2Data
            + object.id.v2Data
            + object.revisionID.v2Data
    }
}

extension InMemoryMediaPlaybackSource {
    func makePlayerItem(for object: V2ObjectRecord) -> AVPlayerItem {
        makePlayerItem(id: object.id, originalExtension: object.originalExtension)
    }
}
