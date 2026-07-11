import AVFoundation
import CryptoKit
import Foundation

nonisolated final class CryptaStore: @unchecked Sendable {
    private let keyStore: any CryptaEncryptionKeyStore
    let locations: CryptaStorageLocations
    let indexEncoder = JSONEncoder()
    let indexDecoder = JSONDecoder()
    let indexMutationLock = NSRecursiveLock()

    init(
        locations: CryptaStorageLocations = .live,
        keyStore: any CryptaEncryptionKeyStore = CryptaKeychainKeyStore()
    ) {
        self.locations = locations
        self.keyStore = keyStore
        indexEncoder.outputFormatting = [.sortedKeys]
        indexEncoder.dateEncodingStrategy = .iso8601
        indexDecoder.dateDecodingStrategy = .iso8601
    }

    func importVideo(
        from sourceURL: URL,
        storageState: CryptaVideo.StorageState = .encrypted,
        libraryKind: LibraryKind = .encrypted,
        mediaType: MediaType = .video
    ) async throws -> CryptaVideo {
        try await importMedia(
            from: sourceURL,
            storageState: storageState,
            libraryKind: libraryKind,
            mediaType: mediaType,
            durationSeconds: await Self.videoDuration(for: sourceURL)
        )
    }

    func importImage(from sourceURL: URL, libraryKind: LibraryKind = .encryptedImage) async throws -> CryptaVideo {
        try await importMedia(
            from: sourceURL,
            storageState: .encrypted,
            libraryKind: libraryKind,
            mediaType: .image,
            durationSeconds: nil
        )
    }

    private func importMedia(
        from sourceURL: URL,
        storageState: CryptaVideo.StorageState,
        libraryKind: LibraryKind,
        mediaType: MediaType,
        durationSeconds: Double?
    ) async throws -> CryptaVideo {
        try locations.prepareDirectories()

        let secureURL = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if secureURL {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let id = UUID()
        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey])
        let displayName = sourceURL.deletingPathExtension().lastPathComponent
        let byteCount = Int64(values.fileSize ?? 0)
        let extensionName = sourceURL.pathExtension.lowercased()
        var plainFileName: String?
        var encryptedFileName: String?

        var preEncryptedThumbnailData: Data?
        if mediaType == .video {
            preEncryptedThumbnailData = await VideoThumbnailLoader.thumbnailData(from: sourceURL)
        }

        switch storageState {
        case .plain:
            let destinationFileName = uniquePlainFileName(displayName: displayName, extensionName: extensionName)
            let destinationURL = locations.moviesVault.appendingPathComponent(destinationFileName, isDirectory: false)
            try copyFile(from: sourceURL, to: destinationURL)
            plainFileName = destinationFileName
        case .encrypted:
            let destinationFileName = randomBlobName()
            let destinationURL = locations.moviesVault.appendingPathComponent(destinationFileName, isDirectory: false)
            try encryptFile(from: sourceURL, to: destinationURL)
            encryptedFileName = destinationFileName
        }

        let video = CryptaVideo(
            id: id,
            displayName: displayName,
            originalExtension: extensionName,
            libraryKind: libraryKind,
            mediaType: mediaType,
            storageState: storageState,
            plainFileName: plainFileName,
            encryptedFileName: encryptedFileName,
            importedAt: Date(),
            byteCount: byteCount,
            durationSeconds: durationSeconds
        )
        if let thumbnailData = preEncryptedThumbnailData {
            try? saveThumbnailData(thumbnailData, for: video)
        }
        try withIndexMutation {
            var index = try loadIndex()
            index.videos.append(video)
            try saveIndex(index)
        }
        try? FileManager.default.removeItem(at: sourceURL)
        return video
    }

    func preparePlaybackURL(for video: CryptaVideo) throws -> PlaybackURL {
        try locations.prepareDirectories()
        switch video.storageState {
        case .plain:
            guard let plainFileName = video.plainFileName else { throw CryptaError.missingVideoFile }
            return PlaybackURL(
                url: locations.moviesVault.appendingPathComponent(plainFileName, isDirectory: false),
                cleanupURL: nil
            )
        case .encrypted:
            guard let encryptedFileName = video.encryptedFileName else { throw CryptaError.missingVideoFile }
            let source = locations.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
            let playbackName = "\(UUID().uuidString).\(video.originalExtension.isEmpty ? "mov" : video.originalExtension)"
            let playbackDirectory = locations.playbackCache.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: playbackDirectory, withIntermediateDirectories: true)
            let playbackURL = playbackDirectory.appendingPathComponent(playbackName, isDirectory: false)
            try decryptFile(from: source, to: playbackURL)
            return PlaybackURL(url: playbackURL, cleanupURL: playbackDirectory)
        }
    }

    func materializeMedia(_ video: CryptaVideo, to destinationURL: URL) throws {
        try locations.prepareDirectories()
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let sourceURL: URL
        switch video.storageState {
        case .plain:
            guard let plainFileName = video.plainFileName else { throw CryptaError.missingVideoFile }
            sourceURL = locations.moviesVault.appendingPathComponent(plainFileName, isDirectory: false)
            try copyFile(from: sourceURL, to: destinationURL)
        case .encrypted:
            guard let encryptedFileName = video.encryptedFileName else { throw CryptaError.missingVideoFile }
            sourceURL = locations.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
            try decryptFile(from: sourceURL, to: destinationURL)
        }
    }

    func materializeImageGroup(
        _ videos: [CryptaVideo],
        to directoryURL: URL
    ) throws -> [CryptaVideo.ID: URL] {
        try locations.prepareDirectories()
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var result: [CryptaVideo.ID: URL] = [:]
        for video in videos where video.mediaType == .image {
            do {
                let destinationFileName = uniqueFileName(
                    displayName: video.displayName,
                    extensionName: video.originalExtension,
                    in: directoryURL
                )
                let destinationURL = directoryURL.appendingPathComponent(destinationFileName, isDirectory: false)
                try materializeMedia(video, to: destinationURL)
                result[video.id] = destinationURL
            } catch {
                continue
            }
        }
        return result
    }

    func inMemoryMediaDataSource(for video: CryptaVideo) throws -> EncryptedMediaDataSource {
        try locations.prepareDirectories()
        guard video.storageState == .encrypted,
              let encryptedFileName = video.encryptedFileName else {
            throw CryptaError.missingVideoFile
        }
        let sourceURL = locations.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
        return try EncryptedMediaDataSource(
            sourceURL: sourceURL,
            originalExtension: video.originalExtension,
            key: existingKeyForDecryption()
        )
    }

    func storedPlainMediaURL(for video: CryptaVideo) throws -> URL {
        try locations.prepareDirectories()
        guard video.storageState == .plain,
              let plainFileName = video.plainFileName else {
            throw CryptaError.missingVideoFile
        }
        return locations.moviesVault.appendingPathComponent(plainFileName, isDirectory: false)
    }

    func loadThumbnailData(for video: CryptaVideo) throws -> Data? {
        try locations.prepareDirectories()
        let url = thumbnailURL(for: video, in: locations.thumbnailCache)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let encrypted = try Data(contentsOf: url)
        return try decryptCombined(encrypted)
    }

    func saveThumbnailData(_ data: Data, for video: CryptaVideo) throws {
        try locations.prepareDirectories()
        let encrypted = try encryptCombined(data)
        try encrypted.write(to: thumbnailURL(for: video, in: locations.thumbnailCache), options: [.atomic])
    }

    func commitModifiedVideo(at modifiedVideoURL: URL, for video: CryptaVideo) throws -> CryptaVideo {
        try locations.prepareDirectories()
        return try replaceStoredVideo(
            with: modifiedVideoURL,
            for: video,
            hasEmbeddedSubtitles: true
        )
    }

    private func replaceStoredVideo(
        with newVideoURL: URL,
        for video: CryptaVideo,
        hasEmbeddedSubtitles: Bool
    ) throws -> CryptaVideo {
        try withIndexMutation {
            var index = try loadIndex()
            guard let indexPosition = index.videos.firstIndex(where: { $0.id == video.id }) else {
                throw CryptaError.missingIndexEntry
            }

            let newByteCount = try fileByteCount(at: newVideoURL)
            var updated = index.videos[indexPosition]
            updated.hasEmbeddedSubtitles = hasEmbeddedSubtitles
            updated.byteCount = newByteCount

            switch updated.storageState {
            case .plain:
                guard let plainFileName = updated.plainFileName else { throw CryptaError.missingVideoFile }
                let plainURL = locations.moviesVault.appendingPathComponent(plainFileName, isDirectory: false)
                let replacementURL = plainURL.deletingLastPathComponent()
                    .appendingPathComponent(".crypta-replace-\(UUID().uuidString).\(updated.originalExtension)", isDirectory: false)
                try FileManager.default.copyItem(at: newVideoURL, to: replacementURL)
                _ = try FileManager.default.replaceItemAt(plainURL, withItemAt: replacementURL)
            case .encrypted:
                guard let oldEncryptedFileName = updated.encryptedFileName else { throw CryptaError.missingVideoFile }
                let oldEncryptedURL = locations.moviesVault.appendingPathComponent(oldEncryptedFileName, isDirectory: false)
                let newEncryptedFileName = randomBlobName()
                let newEncryptedURL = locations.moviesVault.appendingPathComponent(newEncryptedFileName, isDirectory: false)
                try encryptFile(from: newVideoURL, to: newEncryptedURL)
                updated.encryptedFileName = newEncryptedFileName
                index.videos[indexPosition] = updated
                try saveIndex(index)
                try? FileManager.default.removeItem(at: oldEncryptedURL)
                return updated
            }

            index.videos[indexPosition] = updated
            try saveIndex(index)
            return updated
        }
    }

    private func fileByteCount(at url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber else {
            throw CryptaError.missingVideoFile
        }
        return size.int64Value
    }

    func deleteThumbnail(for video: CryptaVideo) {
        try? FileManager.default.removeItem(at: thumbnailURL(for: video, in: locations.thumbnailCache))
    }

    func rename(_ video: CryptaVideo, to newName: String) throws -> CryptaVideo {
        try withIndexMutation {
            var index = try loadIndex()
            guard let indexPosition = index.videos.firstIndex(where: { $0.id == video.id }) else {
                throw CryptaError.missingIndexEntry
            }

            var updated = index.videos[indexPosition]
            updated.displayName = newName

            if updated.storageState == .plain, let oldFileName = updated.plainFileName {
                let oldURL = locations.moviesVault.appendingPathComponent(oldFileName, isDirectory: false)
                let newFileName = uniquePlainFileName(displayName: newName, extensionName: updated.originalExtension)
                let newURL = locations.moviesVault.appendingPathComponent(newFileName, isDirectory: false)
                try FileManager.default.moveItem(at: oldURL, to: newURL)
                updated.plainFileName = newFileName
            }

            index.videos[indexPosition] = updated
            try saveIndex(index)
            return updated
        }
    }

    func exportAndRemoveDecryptedVideo(_ video: CryptaVideo, to destinationDirectory: URL) throws -> URL {
        guard !destinationDirectory.isInsideOrEqual(to: locations.vaultPackage) else {
            throw CryptaError.invalidExportDestination
        }

        return try withIndexMutation {
            var index = try loadIndex()
            guard let indexPosition = index.videos.firstIndex(where: { $0.id == video.id }),
                  let encryptedFileName = index.videos[indexPosition].encryptedFileName else {
                throw CryptaError.missingIndexEntry
            }

            let encryptedURL = locations.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
            let plainFileName = uniqueFileName(
                displayName: index.videos[indexPosition].displayName,
                extensionName: index.videos[indexPosition].originalExtension,
                in: destinationDirectory
            )
            let finalURL = destinationDirectory.appendingPathComponent(plainFileName, isDirectory: false)
            let temporaryURL = destinationDirectory.appendingPathComponent(
                ".crypta-export-\(UUID().uuidString).tmp",
                isDirectory: false
            )
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try decryptFile(from: encryptedURL, to: temporaryURL)
            do {
                try FileManager.default.moveItem(at: temporaryURL, to: finalURL)
            } catch {
                try? FileManager.default.removeItem(at: temporaryURL)
                throw error
            }

            index.videos.remove(at: indexPosition)
            try saveIndex(index)
            try? FileManager.default.removeItem(at: encryptedURL)
            deleteThumbnail(for: video)
            return finalURL
        }
    }

    func delete(_ video: CryptaVideo) throws {
        try withIndexMutation {
            var index = try loadIndex()
            index.videos.removeAll { $0.id == video.id }
            try saveIndex(index)

            switch video.storageState {
            case .plain:
                if let plainFileName = video.plainFileName {
                    try? FileManager.default.removeItem(
                        at: locations.moviesVault.appendingPathComponent(plainFileName, isDirectory: false)
                    )
                }
            case .encrypted:
                if let encryptedFileName = video.encryptedFileName {
                    try? FileManager.default.removeItem(
                        at: locations.moviesVault.appendingPathComponent(encryptedFileName, isDirectory: false)
                    )
                }
            }
            deleteThumbnail(for: video)
        }
    }

    func updatePlaybackPosition(videoID: CryptaVideo.ID, seconds: Double?) throws -> CryptaVideo? {
        try withIndexMutation {
            var index = try loadIndex()
            guard let indexPosition = index.videos.firstIndex(where: { $0.id == videoID }) else {
                return nil
            }

            index.videos[indexPosition].playbackPositionSeconds = seconds
            try saveIndex(index)
            return index.videos[indexPosition]
        }
    }

    private func thumbnailURL(for video: CryptaVideo, in directory: URL) -> URL {
        directory.appendingPathComponent("\(video.id.uuidString).v3.thumb", isDirectory: false)
    }

    private func encryptFile(from sourceURL: URL, to destinationURL: URL) throws {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: destinationURL)
        defer { try? output.close() }

        do {
            while true {
                let chunk = try input.read(upToCount: EncryptedMediaFormat.plaintextChunkSize) ?? Data()
                if chunk.isEmpty { break }
                let sealed = try encryptCombined(chunk)
                try output.write(contentsOf: EncryptedMediaFormat.lengthPrefix(for: sealed.count))
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
                let length = EncryptedMediaFormat.length(fromPrefix: prefix)
                guard EncryptedMediaFormat.isValidEncryptedChunkLength(length) else {
                    throw CryptaError.invalidEncryptedFile
                }
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

    private func copyFile(from sourceURL: URL, to destinationURL: URL) throws {
        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    private func uniquePlainFileName(displayName: String, extensionName: String) -> String {
        uniqueFileName(displayName: displayName, extensionName: extensionName, in: locations.moviesVault)
    }

    private func uniqueFileName(displayName: String, extensionName: String, in directory: URL) -> String {
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
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
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

    func encryptCombined(_ plaintext: Data) throws -> Data {
        let key = try keyForEncryption()
        let sealedBox = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealedBox.combined else {
            throw CryptaError.encryptionFailed
        }
        return combined
    }

    func decryptCombined(_ encrypted: Data) throws -> Data {
        let key = try existingKeyForDecryption()
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encrypted)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw CryptaError.decryptionFailed
        }
    }

    private func keyForEncryption() throws -> SymmetricKey {
        if let data = try keyStore.readKeyData() {
            return SymmetricKey(data: data)
        }
        guard !protectedDataExists() else {
            throw CryptaError.protectedDataRequiresExistingKey
        }
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        try keyStore.saveKeyData(data)
        return key
    }

    private func existingKeyForDecryption() throws -> SymmetricKey {
        guard let data = try keyStore.readKeyData() else {
            throw CryptaError.missingEncryptionKey
        }
        return SymmetricKey(data: data)
    }

    private func protectedDataExists() -> Bool {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: locations.encryptedIndex.path) ||
            fileManager.fileExists(atPath: locations.encryptedIndexBackup.path) {
            return true
        }
        if containsProtectedFiles(in: locations.thumbnailCache) {
            return true
        }
        return containsProtectedFiles(in: locations.moviesVault)
    }

    private func containsProtectedFiles(in directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return contents.contains { url in
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey]) else {
                return false
            }
            if values.isDirectory == true {
                return url.lastPathComponent == "Thumbnails" ? false : containsProtectedFiles(in: url)
            }
            return values.isRegularFile == true
        }
    }

    private static func videoDuration(for url: URL) async -> Double? {
        await withTaskGroup(of: Double?.self, returning: Double?.self) { group in
            group.addTask {
                let asset = AVURLAsset(url: url)
                guard let durationTime = try? await asset.load(.duration) else {
                    return nil
                }
                let duration = CMTimeGetSeconds(durationTime)
                return duration.isFinite && duration > 0 ? duration : nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return nil
            }
            let result = await group.next()
            group.cancelAll()
            if let result { return result }
            return VideoThumbnailLoader.duration(from: url)
        }
    }
}

nonisolated private extension String {
    var nonEmptyValue: String? {
        isEmpty ? nil : self
    }
}

nonisolated private extension URL {
    func isInsideOrEqual(to directory: URL) -> Bool {
        let path = standardizedFileURL.path
        let directoryPath = directory.standardizedFileURL.path
        return path == directoryPath || path.hasPrefix(directoryPath + "/")
    }
}
