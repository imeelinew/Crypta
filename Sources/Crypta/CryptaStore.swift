import AVFoundation
import CryptoKit
import Foundation
import Security
import UniformTypeIdentifiers

enum CryptaPaths {
    static let appName = "Crypta"

    static var moviesVault: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }

    static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
    }

    static var encryptedIndex: URL {
        applicationSupport.appendingPathComponent("library.index", isDirectory: false)
    }

    static var playbackCache: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(appName, isDirectory: true)
            .appendingPathComponent("Playback", isDirectory: true)
    }

    static func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: moviesVault, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: playbackCache, withIntermediateDirectories: true)
    }

    static func cleanPlaybackCache() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: playbackCache.path) else { return }
        for url in try fileManager.contentsOfDirectory(at: playbackCache, includingPropertiesForKeys: nil) {
            try? fileManager.removeItem(at: url)
        }
    }
}

enum CryptaVideoImport {
    static let supportedExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "webm", "hevc"
    ]

    static func isSupportedVideo(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        if supportedExtensions.contains(url.pathExtension.lowercased()) {
            return true
        }
        guard let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType else {
            return false
        }
        return type.conforms(to: .movie) || type.conforms(to: .video)
    }
}

final class CryptaStore: @unchecked Sendable {
    private let keyStore = CryptaKeychainKeyStore()
    private let indexEncoder = JSONEncoder()
    private let indexDecoder = JSONDecoder()
    private let chunkSize = 4 * 1024 * 1024

    init() {
        indexEncoder.outputFormatting = [.sortedKeys]
        indexEncoder.dateEncodingStrategy = .iso8601
        indexDecoder.dateDecodingStrategy = .iso8601
    }

    func loadIndex() throws -> CryptaIndex {
        try CryptaPaths.prepareDirectories()
        guard FileManager.default.fileExists(atPath: CryptaPaths.encryptedIndex.path) else {
            return CryptaIndex()
        }
        let encrypted = try Data(contentsOf: CryptaPaths.encryptedIndex)
        let plaintext = try decryptCombined(encrypted)
        return try indexDecoder.decode(CryptaIndex.self, from: plaintext)
    }

    func saveIndex(_ index: CryptaIndex) throws {
        try CryptaPaths.prepareDirectories()
        let plaintext = try indexEncoder.encode(index)
        let encrypted = try encryptCombined(plaintext)
        try encrypted.write(to: CryptaPaths.encryptedIndex, options: [.atomic])
    }

    func importVideo(from sourceURL: URL, storageState: CryptaVideo.StorageState) async throws -> CryptaVideo {
        try CryptaPaths.prepareDirectories()

        let secureURL = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if secureURL {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let id = UUID()
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .localizedNameKey])
        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        let byteCount = Int64(values.fileSize ?? 0)
        let extensionName = sourceURL.pathExtension.lowercased()
        let duration = await Self.videoDuration(for: sourceURL)
        var plainFileName: String?
        var encryptedFileName: String?

        switch storageState {
        case .plain:
            let destinationFileName = uniquePlainFileName(displayName: displayName, extensionName: extensionName)
            let destinationURL = CryptaPaths.moviesVault.appendingPathComponent(destinationFileName, isDirectory: false)
            try moveOrCopyFile(from: sourceURL, to: destinationURL)
            plainFileName = destinationFileName
        case .encrypted:
            let destinationFileName = randomBlobName()
            let destinationURL = CryptaPaths.moviesVault.appendingPathComponent(destinationFileName, isDirectory: false)
            try encryptFile(from: sourceURL, to: destinationURL)
            try? FileManager.default.removeItem(at: sourceURL)
            encryptedFileName = destinationFileName
        }

        var index = try loadIndex()
        let video = CryptaVideo(
            id: id,
            displayName: displayName,
            originalExtension: extensionName,
            storageState: storageState,
            plainFileName: plainFileName,
            encryptedFileName: encryptedFileName,
            importedAt: Date(),
            byteCount: byteCount,
            durationSeconds: duration
        )
        index.videos.append(video)
        try saveIndex(index)
        return video
    }

    func preparePlaybackURL(for video: CryptaVideo) throws -> PlaybackURL {
        try CryptaPaths.prepareDirectories()
        switch video.storageState {
        case .plain:
            guard let plainFileName = video.plainFileName else { throw CryptaError.missingVideoFile }
            return PlaybackURL(
                url: CryptaPaths.moviesVault.appendingPathComponent(plainFileName, isDirectory: false),
                cleanupURL: nil
            )
        case .encrypted:
            guard let encryptedFileName = video.encryptedFileName else { throw CryptaError.missingVideoFile }
            let source = CryptaPaths.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
            let playbackName = "\(UUID().uuidString).\(video.originalExtension.isEmpty ? "mov" : video.originalExtension)"
            let playbackDirectory = CryptaPaths.playbackCache.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: playbackDirectory, withIntermediateDirectories: true)
            let playbackURL = playbackDirectory.appendingPathComponent(playbackName, isDirectory: false)
            try decryptFile(from: source, to: playbackURL)
            return PlaybackURL(url: playbackURL, cleanupURL: playbackDirectory)
        }
    }

    func rename(_ video: CryptaVideo, to newName: String) throws -> CryptaVideo {
        var index = try loadIndex()
        guard let indexPosition = index.videos.firstIndex(where: { $0.id == video.id }) else {
            throw CryptaError.missingIndexEntry
        }

        var updated = index.videos[indexPosition]
        updated.displayName = newName

        if updated.storageState == .plain, let oldFileName = updated.plainFileName {
            let oldURL = CryptaPaths.moviesVault.appendingPathComponent(oldFileName, isDirectory: false)
            let newFileName = uniquePlainFileName(displayName: newName, extensionName: updated.originalExtension)
            let newURL = CryptaPaths.moviesVault.appendingPathComponent(newFileName, isDirectory: false)
            try FileManager.default.moveItem(at: oldURL, to: newURL)
            updated.plainFileName = newFileName
        }

        index.videos[indexPosition] = updated
        try saveIndex(index)
        return updated
    }

    func encryptPlainVideo(_ video: CryptaVideo) throws -> CryptaVideo {
        var index = try loadIndex()
        guard let indexPosition = index.videos.firstIndex(where: { $0.id == video.id }),
              let plainFileName = index.videos[indexPosition].plainFileName else {
            throw CryptaError.missingIndexEntry
        }

        let plainURL = CryptaPaths.moviesVault.appendingPathComponent(plainFileName, isDirectory: false)
        let encryptedFileName = randomBlobName()
        let encryptedURL = CryptaPaths.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
        try encryptFile(from: plainURL, to: encryptedURL)

        var updated = index.videos[indexPosition]
        updated.storageState = .encrypted
        updated.plainFileName = nil
        updated.encryptedFileName = encryptedFileName
        index.videos[indexPosition] = updated
        try saveIndex(index)
        try? FileManager.default.removeItem(at: plainURL)
        return updated
    }

    func decryptEncryptedVideo(_ video: CryptaVideo) throws -> CryptaVideo {
        var index = try loadIndex()
        guard let indexPosition = index.videos.firstIndex(where: { $0.id == video.id }),
              let encryptedFileName = index.videos[indexPosition].encryptedFileName else {
            throw CryptaError.missingIndexEntry
        }

        let encryptedURL = CryptaPaths.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
        let plainFileName = uniquePlainFileName(
            displayName: index.videos[indexPosition].displayName,
            extensionName: index.videos[indexPosition].originalExtension
        )
        let plainURL = CryptaPaths.moviesVault.appendingPathComponent(plainFileName, isDirectory: false)
        try decryptFile(from: encryptedURL, to: plainURL)

        var updated = index.videos[indexPosition]
        updated.storageState = .plain
        updated.plainFileName = plainFileName
        updated.encryptedFileName = nil
        index.videos[indexPosition] = updated
        try saveIndex(index)
        try? FileManager.default.removeItem(at: encryptedURL)
        return updated
    }

    func delete(_ video: CryptaVideo) throws {
        switch video.storageState {
        case .plain:
            if let plainFileName = video.plainFileName {
                try? FileManager.default.removeItem(
                    at: CryptaPaths.moviesVault.appendingPathComponent(plainFileName, isDirectory: false)
                )
            }
        case .encrypted:
            if let encryptedFileName = video.encryptedFileName {
                try? FileManager.default.removeItem(
                    at: CryptaPaths.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
                )
            }
        }

        var index = try loadIndex()
        index.videos.removeAll { $0.id == video.id }
        try saveIndex(index)
    }

    private func encryptFile(from sourceURL: URL, to destinationURL: URL) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        do {
            while true {
                let chunk = try input.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                let sealed = try encryptCombined(chunk)
                try output.write(contentsOf: Self.lengthPrefix(for: sealed.count))
                try output.write(contentsOf: sealed)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func decryptFile(from sourceURL: URL, to destinationURL: URL) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        do {
            while true {
                let prefix = try input.read(upToCount: 4) ?? Data()
                if prefix.isEmpty { break }
                guard prefix.count == 4 else { throw CryptaError.invalidEncryptedFile }
                let length = Self.length(fromPrefix: prefix)
                guard length > 0 && length < chunkSize + 1024 else { throw CryptaError.invalidEncryptedFile }
                let sealed = try input.read(upToCount: length) ?? Data()
                guard sealed.count == length else { throw CryptaError.invalidEncryptedFile }
                let chunk = try decryptCombined(sealed)
                try output.write(contentsOf: chunk)
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func randomBlobName() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func moveOrCopyFile(from sourceURL: URL, to destinationURL: URL) throws {
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
            try? FileManager.default.removeItem(at: sourceURL)
        }
    }

    private func uniquePlainFileName(displayName: String, extensionName: String) -> String {
        let cleanedExtension = extensionName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let extensionSuffix = cleanedExtension.isEmpty ? "" : ".\(cleanedExtension)"
        var base = sanitizedFileName(displayName).nonEmptyValue ?? "Video"
        if !extensionSuffix.isEmpty, base.lowercased().hasSuffix(extensionSuffix.lowercased()) {
            base.removeLast(extensionSuffix.count)
        }
        let cleanedBase = base.nonEmptyValue ?? "Video"
        let suffix = cleanedExtension.isEmpty ? "" : ".\(cleanedExtension)"
        var candidate = "\(cleanedBase)\(suffix)"
        var counter = 2
        while FileManager.default.fileExists(atPath: CryptaPaths.moviesVault.appendingPathComponent(candidate).path) {
            candidate = "\(cleanedBase) \(counter)\(suffix)"
            counter += 1
        }
        return candidate
    }

    private func sanitizedFileName(_ value: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:")
        return value
            .components(separatedBy: illegal)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func encryptCombined(_ plaintext: Data) throws -> Data {
        let key = try keyStore.getOrCreateKey()
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptaError.encryptionFailed
        }
        return combined
    }

    private func decryptCombined(_ encrypted: Data) throws -> Data {
        let key = try keyStore.getOrCreateKey()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encrypted)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw CryptaError.decryptionFailed
        }
    }

    private static func lengthPrefix(for length: Int) -> Data {
        var value = UInt32(length).bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }

    private static func length(fromPrefix data: Data) -> Int {
        data.reduce(0) { partial, byte in
            (partial << 8) | Int(byte)
        }
    }

    private static func videoDuration(for url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard let durationTime = try? await asset.load(.duration) else {
            return nil
        }
        let duration = CMTimeGetSeconds(durationTime)
        return duration.isFinite && duration > 0 ? duration : nil
    }
}

private extension String {
    var nonEmptyValue: String? {
        isEmpty ? nil : self
    }
}

final class CryptaKeychainKeyStore: @unchecked Sendable {
    private let service = "local.elidev.Crypta.encryption"
    private let account = "default-v1"

    func getOrCreateKey() throws -> SymmetricKey {
        if let data = try readKeyData() {
            return SymmetricKey(data: data)
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try saveKeyData(data)
        return key
    }

    private func readKeyData() throws -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CryptaError.keychainReadFailed(status)
        }
        return data
    }

    private func saveKeyData(_ data: Data) throws {
        var query = baseQuery()
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw CryptaError.keychainWriteFailed(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
