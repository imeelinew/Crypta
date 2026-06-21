import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

nonisolated final class EncryptedMediaDataSource: @unchecked Sendable {
    private struct Chunk: Sendable {
        let encryptedOffset: UInt64
        let encryptedLength: Int
        let plaintextOffset: Int64
        let plaintextLength: Int
    }

    let byteCount: Int64
    let contentTypeIdentifier: String

    private let sourceURL: URL
    private let key: SymmetricKey
    private let chunks: [Chunk]
    private let maximumCacheBytes: Int
    private let lock = NSLock()
    private var cachedChunks: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private var cachedByteCount = 0

    init(
        sourceURL: URL,
        originalExtension: String,
        byteCount: Int64,
        key: SymmetricKey,
        maximumCacheBytes: Int = 64 * 1024 * 1024
    ) throws {
        self.sourceURL = sourceURL
        self.byteCount = byteCount
        self.key = key
        self.maximumCacheBytes = maximumCacheBytes
        contentTypeIdentifier = Self.contentTypeIdentifier(for: originalExtension)
        chunks = try Self.scanChunks(in: sourceURL, expectedByteCount: byteCount)
    }

    func data(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0, length >= 0, offset <= byteCount else {
            throw CryptaError.invalidEncryptedFile
        }
        guard length > 0 else { return Data() }

        let endOffset = min(byteCount, offset + Int64(length))
        guard endOffset >= offset else { throw CryptaError.invalidEncryptedFile }

        var result = Data()
        result.reserveCapacity(Int(endOffset - offset))

        for (index, chunk) in chunks.enumerated() {
            let chunkStart = chunk.plaintextOffset
            let chunkEnd = chunk.plaintextOffset + Int64(chunk.plaintextLength)
            guard chunkEnd > offset, chunkStart < endOffset else { continue }

            let plaintext = try decryptedChunk(at: index)
            let sliceStart = Int(max(offset, chunkStart) - chunkStart)
            let sliceEnd = Int(min(endOffset, chunkEnd) - chunkStart)
            result.append(plaintext.subdata(in: sliceStart..<sliceEnd))
        }

        guard result.count == Int(endOffset - offset) else {
            throw CryptaError.invalidEncryptedFile
        }
        return result
    }

    func clearCache() {
        lock.lock()
        defer { lock.unlock() }
        cachedChunks.removeAll()
        cacheOrder.removeAll()
        cachedByteCount = 0
    }

    private func decryptedChunk(at index: Int) throws -> Data {
        lock.lock()
        if let cached = cachedChunks[index] {
            markRecentlyUsed(index)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let chunk = chunks[index]
        let sealed = try readEncryptedChunk(chunk)
        let plaintext = try Self.decryptCombined(sealed, using: key)
        guard plaintext.count == chunk.plaintextLength else {
            throw CryptaError.invalidEncryptedFile
        }

        lock.lock()
        cachedChunks[index] = plaintext
        cachedByteCount += plaintext.count
        markRecentlyUsed(index)
        trimCache()
        lock.unlock()

        return plaintext
    }

    private func readEncryptedChunk(_ chunk: Chunk) throws -> Data {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }
        try input.seek(toOffset: chunk.encryptedOffset)
        let data = try input.read(upToCount: chunk.encryptedLength) ?? Data()
        guard data.count == chunk.encryptedLength else {
            throw CryptaError.invalidEncryptedFile
        }
        return data
    }

    private func markRecentlyUsed(_ index: Int) {
        cacheOrder.removeAll { $0 == index }
        cacheOrder.append(index)
    }

    private func trimCache() {
        while cachedByteCount > maximumCacheBytes, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            if let removed = cachedChunks.removeValue(forKey: oldest) {
                cachedByteCount -= removed.count
            }
        }
    }

    private static func scanChunks(in sourceURL: URL, expectedByteCount: Int64) throws -> [Chunk] {
        let input = try FileHandle(forReadingFrom: sourceURL)
        defer { try? input.close() }

        var chunks: [Chunk] = []
        var plaintextOffset: Int64 = 0
        var encryptedOffset: UInt64 = 0

        while true {
            try input.seek(toOffset: encryptedOffset)
            let prefix = try input.read(upToCount: 4) ?? Data()
            if prefix.isEmpty { break }
            guard prefix.count == 4 else { throw CryptaError.invalidEncryptedFile }

            let encryptedLength = length(fromPrefix: prefix)
            let plaintextLength = encryptedLength - 28
            guard encryptedLength > 28, plaintextLength > 0 else {
                throw CryptaError.invalidEncryptedFile
            }

            chunks.append(
                Chunk(
                    encryptedOffset: encryptedOffset + 4,
                    encryptedLength: encryptedLength,
                    plaintextOffset: plaintextOffset,
                    plaintextLength: plaintextLength
                )
            )
            plaintextOffset += Int64(plaintextLength)
            encryptedOffset += UInt64(4 + encryptedLength)
        }

        guard plaintextOffset == expectedByteCount else {
            throw CryptaError.invalidEncryptedFile
        }
        return chunks
    }

    private static func decryptCombined(_ encrypted: Data, using key: SymmetricKey) throws -> Data {
        do {
            let sealedBox = try AES.GCM.SealedBox(combined: encrypted)
            return try AES.GCM.open(sealedBox, using: key)
        } catch {
            throw CryptaError.decryptionFailed
        }
    }

    private static func length(fromPrefix data: Data) -> Int {
        data.reduce(0) { partial, byte in
            (partial << 8) | Int(byte)
        }
    }

    private static func contentTypeIdentifier(for extensionName: String) -> String {
        let cleanedExtension = extensionName.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let identifier = UTType(filenameExtension: cleanedExtension)?.identifier {
            return identifier
        }
        return UTType.movie.identifier
    }
}

final class InMemoryMediaPlaybackSource: NSObject {
    private static let scheme = "crypta-memory-media"

    private let dataSource: EncryptedMediaDataSource
    private let queue = DispatchQueue(label: "app.crypta.memory-media-loader")
    private var asset: AVURLAsset?

    init(dataSource: EncryptedMediaDataSource) {
        self.dataSource = dataSource
    }

    func makePlayerItem(for video: CryptaVideo) -> AVPlayerItem {
        let extensionName = video.originalExtension.isEmpty ? "bin" : video.originalExtension
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = video.id.uuidString
        components.path = "/media.\(extensionName)"

        let url = components.url ?? URL(string: "\(Self.scheme)://\(video.id.uuidString)/media.\(extensionName)")!
        let asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(self, queue: queue)
        self.asset = asset
        return AVPlayerItem(asset: asset)
    }

    func invalidate() {
        asset?.resourceLoader.setDelegate(nil, queue: nil)
        asset?.cancelLoading()
        asset = nil
        dataSource.clearCache()
    }
}

extension InMemoryMediaPlaybackSource: AVAssetResourceLoaderDelegate {
    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        do {
            if let contentInformationRequest = loadingRequest.contentInformationRequest {
                contentInformationRequest.contentType = dataSource.contentTypeIdentifier
                contentInformationRequest.contentLength = dataSource.byteCount
                contentInformationRequest.isByteRangeAccessSupported = true
            }

            if let dataRequest = loadingRequest.dataRequest {
                let requestedOffset = dataRequest.currentOffset != 0
                    ? dataRequest.currentOffset
                    : dataRequest.requestedOffset
                let availableLength = max(0, dataSource.byteCount - requestedOffset)
                let requestedLength = min(Int64(dataRequest.requestedLength), availableLength)
                if requestedLength > 0 {
                    let data = try dataSource.data(offset: requestedOffset, length: Int(requestedLength))
                    dataRequest.respond(with: data)
                }
            }

            loadingRequest.finishLoading()
        } catch {
            loadingRequest.finishLoading(with: error)
        }
        return true
    }

    nonisolated func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {}
}
