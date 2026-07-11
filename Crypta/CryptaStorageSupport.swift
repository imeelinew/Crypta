import Foundation
import Security
import UniformTypeIdentifiers

nonisolated struct CryptaStorageLocations: Sendable {
    let vaultPackage: URL
    let moviesVault: URL
    let playbackCache: URL

    var encryptedIndex: URL { vaultPackage.appendingPathComponent("library.index", isDirectory: false) }
    var encryptedIndexBackup: URL { vaultPackage.appendingPathComponent("library.index.backup", isDirectory: false) }
    var thumbnailCache: URL { vaultPackage.appendingPathComponent("Thumbnails", isDirectory: true) }
    var cacheRoot: URL { playbackCache.deletingLastPathComponent() }

    static var live: CryptaStorageLocations {
        let moviesDirectory = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        let vaultPackage = moviesDirectory.appendingPathComponent("Crypta.vault", isDirectory: true)
        let cachesDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Crypta", isDirectory: true)
        return CryptaStorageLocations(
            vaultPackage: vaultPackage,
            moviesVault: vaultPackage.appendingPathComponent("Objects", isDirectory: true),
            playbackCache: cachesDirectory.appendingPathComponent("Playback", isDirectory: true)
        )
    }

    func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: vaultPackage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: moviesVault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: thumbnailCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: playbackCache, withIntermediateDirectories: true)
    }
}

nonisolated enum CryptaVideoImport {
    static let supportedExtensions: Set<String> = ["mov", "mp4", "m4v", "avi", "mkv", "webm", "hevc"]
    static let supportedImageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "gif", "webp"]

    static func isSupportedVideo(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if supportedExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }

    static func isSupportedImage(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if supportedImageExtensions.contains(url.pathExtension.lowercased()) { return true }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else { return false }
        return type.conforms(to: .image)
    }
}

nonisolated protocol CryptaEncryptionKeyStore: Sendable {
    func readKeyData() throws -> Data?
    func saveKeyData(_ data: Data) throws
}

nonisolated final class CryptaKeychainKeyStore: CryptaEncryptionKeyStore, @unchecked Sendable {
    private let service = "com.eli.Crypta.encryption"
    private let account = "default-v1"

    func readKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CryptaError.keychainReadFailed(status)
        }
        return data
    }

    func saveKeyData(_ data: Data) throws {
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw CryptaError.keychainWriteFailed(status) }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
