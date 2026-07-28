import CryptoKit
import Foundation

nonisolated struct V2MediaDescriptor: Equatable, Sendable {
    let vaultID: UUID
    let objectID: UUID
    let revisionID: UUID
    let plaintextLength: Int64
    let chunkSize: Int
    let chunkCount: Int
}

nonisolated protocol V2PlaintextInput: AnyObject {
    var byteCount: Int64 { get }
    func read(upToCount count: Int) throws -> Data
}

nonisolated final class V2FilePlaintextInput: V2PlaintextInput {
    let byteCount: Int64
    private let handle: FileHandle

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true, let fileSize = values.fileSize else {
            throw V2Error.unsafePath
        }
        byteCount = Int64(fileSize)
        handle = try FileHandle(forReadingFrom: url)
    }

    deinit {
        try? handle.close()
    }

    func read(upToCount count: Int) throws -> Data {
        try handle.read(upToCount: count) ?? Data()
    }
}

nonisolated enum V2MediaContainer {
    static let headerSize = 256
    static let authenticatedHeaderSize = 240
    static let defaultChunkSize = 4 * 1024 * 1024
    static let chunkTagSize = 16

    private static let magic = Data([0x43, 0x52, 0x59, 0x50, 0x54, 0x41, 0x30, 0x32]) // CRYPTA02
    private static let formatVersion: UInt16 = 2
    private static let algorithmAES256GCM: UInt16 = 1
    private static let wrappedKeyCapacity = 64
    private static let wrappedKeyOffset = 92
    private static let headerTagOffset = authenticatedHeaderSize

    static func encryptFile(
        from sourceURL: URL,
        to destinationURL: URL,
        vaultID: UUID,
        masterKey: SymmetricKey,
        objectID: UUID = UUID(),
        revisionID: UUID = UUID(),
        chunkSize: Int = defaultChunkSize
    ) throws -> V2MediaDescriptor {
        let input = try V2FilePlaintextInput(url: sourceURL)
        return try encrypt(
            input: input,
            to: destinationURL,
            vaultID: vaultID,
            masterKey: masterKey,
            objectID: objectID,
            revisionID: revisionID,
            chunkSize: chunkSize
        )
    }

    static func encrypt(
        input: V2PlaintextInput,
        to destinationURL: URL,
        vaultID: UUID,
        masterKey: SymmetricKey,
        objectID: UUID = UUID(),
        revisionID: UUID = UUID(),
        chunkSize: Int = defaultChunkSize
    ) throws -> V2MediaDescriptor {
        guard chunkSize >= 64 * 1024, chunkSize <= 16 * 1024 * 1024 else {
            throw V2Error.invalidContainer
        }
        guard input.byteCount >= 0 else {
            throw V2Error.invalidContainer
        }

        let chunkCount64 = input.byteCount == 0
            ? 0
            : (UInt64(input.byteCount) + UInt64(chunkSize) - 1) / UInt64(chunkSize)
        guard chunkCount64 < UInt64(UInt32.max) else {
            throw V2Error.invalidContainer
        }
        let chunkCount = Int(chunkCount64)
        let dataKey = SymmetricKey(size: .bits256)
        let noncePrefix = try V2Crypto.randomData(count: 8)
        let wrappedKey = try wrapDataKey(
            dataKey,
            masterKey: masterKey,
            vaultID: vaultID,
            objectID: objectID,
            revisionID: revisionID
        )
        let headerPrefix = try makeHeaderPrefix(
            vaultID: vaultID,
            objectID: objectID,
            revisionID: revisionID,
            plaintextLength: input.byteCount,
            chunkSize: chunkSize,
            chunkCount: chunkCount,
            noncePrefix: noncePrefix,
            wrappedKey: wrappedKey
        )
        let headerTag = try authenticationTag(
            plaintext: Data(),
            key: dataKey,
            nonce: nonce(prefix: noncePrefix, index: UInt32.max),
            additionalData: headerPrefix
        )
        let header = headerPrefix + headerTag
        guard header.count == headerSize else {
            throw V2Error.invalidContainer
        }

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw V2Error.unsafePath
        }
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw V2Error.unsafePath
        }

        let output = try FileHandle(forWritingTo: destinationURL)
        do {
            try output.write(contentsOf: header)
            var bytesRead: Int64 = 0
            for index in 0..<chunkCount {
                let chunkLength = try autoreleasepool {
                    let expectedLength = min(chunkSize, Int(input.byteCount - bytesRead))
                    let plaintext = try input.read(upToCount: expectedLength)
                    guard plaintext.count == expectedLength else {
                        throw V2Error.sourceChangedDuringImport
                    }
                    let additionalData = chunkAdditionalData(
                        headerPrefix: headerPrefix,
                        index: UInt32(index),
                        plaintextLength: plaintext.count
                    )
                    let sealed = try AES.GCM.seal(
                        plaintext,
                        using: dataKey,
                        nonce: nonce(prefix: noncePrefix, index: UInt32(index)),
                        authenticating: additionalData
                    )
                    try output.write(contentsOf: sealed.ciphertext)
                    try output.write(contentsOf: sealed.tag)
                    return plaintext.count
                }
                bytesRead += Int64(chunkLength)
            }
            guard bytesRead == input.byteCount,
                  try input.read(upToCount: 1).isEmpty else {
                throw V2Error.sourceChangedDuringImport
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }

        return V2MediaDescriptor(
            vaultID: vaultID,
            objectID: objectID,
            revisionID: revisionID,
            plaintextLength: input.byteCount,
            chunkSize: chunkSize,
            chunkCount: chunkCount
        )
    }

    fileprivate static func parseHeader(
        _ header: Data,
        expectedVaultID: UUID,
        masterKey: SymmetricKey
    ) throws -> V2ParsedMediaHeader {
        guard header.count == headerSize,
              header.prefix(magic.count) == magic,
              header.v2Integer(at: 8, as: UInt16.self) == formatVersion,
              header.v2Integer(at: 10, as: UInt16.self) == UInt16(headerSize),
              header.v2Integer(at: 12, as: UInt16.self) == algorithmAES256GCM,
              header.v2Integer(at: 14, as: UInt16.self) == 0,
              let chunkSizeValue = header.v2Integer(at: 16, as: UInt32.self),
              let chunkCountValue = header.v2Integer(at: 20, as: UInt32.self),
              let plaintextLengthValue = header.v2Integer(at: 24, as: UInt64.self),
              let vaultID = UUID(v2Data: header.subdata(in: 32..<48)),
              let objectID = UUID(v2Data: header.subdata(in: 48..<64)),
              let revisionID = UUID(v2Data: header.subdata(in: 64..<80)),
              let wrappedKeyLengthValue = header.v2Integer(at: 88, as: UInt16.self),
              header.v2Integer(at: 90, as: UInt16.self) == 0 else {
            throw V2Error.invalidContainer
        }
        guard vaultID == expectedVaultID else {
            throw V2Error.authenticationFailed
        }

        let chunkSize = Int(chunkSizeValue)
        let chunkCount = Int(chunkCountValue)
        let plaintextLength = Int64(bitPattern: plaintextLengthValue)
        let wrappedKeyLength = Int(wrappedKeyLengthValue)
        guard plaintextLength >= 0,
              chunkSize >= 64 * 1024,
              chunkSize <= 16 * 1024 * 1024,
              wrappedKeyLength >= 28,
              wrappedKeyLength <= wrappedKeyCapacity else {
            throw V2Error.invalidContainer
        }
        let expectedChunkCount = plaintextLength == 0
            ? 0
            : (UInt64(plaintextLength) + UInt64(chunkSize) - 1) / UInt64(chunkSize)
        guard expectedChunkCount == UInt64(chunkCount) else {
            throw V2Error.invalidContainer
        }

        let noncePrefix = header.subdata(in: 80..<88)
        let wrappedKey = header.subdata(
            in: wrappedKeyOffset..<(wrappedKeyOffset + wrappedKeyLength)
        )
        let dataKey = try unwrapDataKey(
            wrappedKey,
            masterKey: masterKey,
            vaultID: vaultID,
            objectID: objectID,
            revisionID: revisionID
        )
        let headerPrefix = header.prefix(authenticatedHeaderSize)
        let expectedTag = try authenticationTag(
            plaintext: Data(),
            key: dataKey,
            nonce: nonce(prefix: noncePrefix, index: UInt32.max),
            additionalData: Data(headerPrefix)
        )
        guard expectedTag == header.subdata(in: headerTagOffset..<headerSize) else {
            throw V2Error.authenticationFailed
        }

        return V2ParsedMediaHeader(
            descriptor: V2MediaDescriptor(
                vaultID: vaultID,
                objectID: objectID,
                revisionID: revisionID,
                plaintextLength: plaintextLength,
                chunkSize: chunkSize,
                chunkCount: chunkCount
            ),
            headerPrefix: Data(headerPrefix),
            noncePrefix: noncePrefix,
            dataKey: dataKey
        )
    }

    fileprivate static func nonce(prefix: Data, index: UInt32) throws -> AES.GCM.Nonce {
        guard prefix.count == 8 else {
            throw V2Error.invalidContainer
        }
        var data = prefix
        data.v2Append(index)
        return try AES.GCM.Nonce(data: data)
    }

    fileprivate static func chunkAdditionalData(
        headerPrefix: Data,
        index: UInt32,
        plaintextLength: Int
    ) -> Data {
        var data = headerPrefix
        data.v2Append(index)
        data.v2Append(UInt32(plaintextLength))
        return data
    }

    private static func makeHeaderPrefix(
        vaultID: UUID,
        objectID: UUID,
        revisionID: UUID,
        plaintextLength: Int64,
        chunkSize: Int,
        chunkCount: Int,
        noncePrefix: Data,
        wrappedKey: Data
    ) throws -> Data {
        guard wrappedKey.count <= wrappedKeyCapacity,
              noncePrefix.count == 8 else {
            throw V2Error.invalidContainer
        }
        var header = Data()
        header.append(magic)
        header.v2Append(formatVersion)
        header.v2Append(UInt16(headerSize))
        header.v2Append(algorithmAES256GCM)
        header.v2Append(UInt16(0))
        header.v2Append(UInt32(chunkSize))
        header.v2Append(UInt32(chunkCount))
        header.v2Append(UInt64(plaintextLength))
        header.append(vaultID.v2Data)
        header.append(objectID.v2Data)
        header.append(revisionID.v2Data)
        header.append(noncePrefix)
        header.v2Append(UInt16(wrappedKey.count))
        header.v2Append(UInt16(0))
        header.append(wrappedKey)
        header.append(Data(count: wrappedKeyCapacity - wrappedKey.count))
        header.append(Data(count: authenticatedHeaderSize - header.count))
        guard header.count == authenticatedHeaderSize else {
            throw V2Error.invalidContainer
        }
        return header
    }

    private static func wrapDataKey(
        _ dataKey: SymmetricKey,
        masterKey: SymmetricKey,
        vaultID: UUID,
        objectID: UUID,
        revisionID: UUID
    ) throws -> Data {
        let salt = vaultID.v2Data + objectID.v2Data + revisionID.v2Data
        let wrappingKey = V2Crypto.deriveKey(
            from: masterKey,
            salt: salt,
            purpose: "com.crypta.v2.object-key-wrap"
        )
        let sealed = try V2Crypto.seal(
            V2Crypto.keyData(dataKey),
            using: wrappingKey,
            authenticating: objectKeyAdditionalData(
                vaultID: vaultID,
                objectID: objectID,
                revisionID: revisionID
            )
        )
        return sealed.combined
    }

    private static func unwrapDataKey(
        _ wrappedKey: Data,
        masterKey: SymmetricKey,
        vaultID: UUID,
        objectID: UUID,
        revisionID: UUID
    ) throws -> SymmetricKey {
        let salt = vaultID.v2Data + objectID.v2Data + revisionID.v2Data
        let wrappingKey = V2Crypto.deriveKey(
            from: masterKey,
            salt: salt,
            purpose: "com.crypta.v2.object-key-wrap"
        )
        let plaintext = try V2Crypto.open(
            V2SealedData(combined: wrappedKey),
            using: wrappingKey,
            authenticating: objectKeyAdditionalData(
                vaultID: vaultID,
                objectID: objectID,
                revisionID: revisionID
            )
        )
        guard plaintext.count == V2Crypto.keyByteCount else {
            throw V2Error.invalidContainer
        }
        return SymmetricKey(data: plaintext)
    }

    private static func objectKeyAdditionalData(
        vaultID: UUID,
        objectID: UUID,
        revisionID: UUID
    ) -> Data {
        Data("com.crypta.v2.object-key".utf8)
            + vaultID.v2Data
            + objectID.v2Data
            + revisionID.v2Data
    }

    private static func authenticationTag(
        plaintext: Data,
        key: SymmetricKey,
        nonce: AES.GCM.Nonce,
        additionalData: Data
    ) throws -> Data {
        try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: additionalData
        ).tag
    }
}

nonisolated fileprivate struct V2ParsedMediaHeader {
    let descriptor: V2MediaDescriptor
    let headerPrefix: Data
    let noncePrefix: Data
    let dataKey: SymmetricKey
}

nonisolated final class V2MediaReader: @unchecked Sendable {
    let descriptor: V2MediaDescriptor

    private let sourceURL: URL
    private let header: V2ParsedMediaHeader
    private let maximumCacheBytes: Int
    private let lock = NSLock()
    private var cachedChunks: [Int: Data] = [:]
    private var cacheOrder: [Int] = []
    private var cachedByteCount = 0

    init(
        sourceURL: URL,
        expectedVaultID: UUID,
        masterKey: SymmetricKey,
        maximumCacheBytes: Int = 64 * 1024 * 1024
    ) throws {
        self.sourceURL = sourceURL
        self.maximumCacheBytes = max(0, maximumCacheBytes)

        let input = try FileHandle(forReadingFrom: sourceURL)
        let headerData: Data
        do {
            headerData = try input.read(upToCount: V2MediaContainer.headerSize) ?? Data()
            try input.close()
        } catch {
            try? input.close()
            throw error
        }
        header = try V2MediaContainer.parseHeader(
            headerData,
            expectedVaultID: expectedVaultID,
            masterKey: masterKey
        )
        descriptor = header.descriptor

        let values = try sourceURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw V2Error.invalidContainer
        }
        let expectedFileSize = try Self.expectedFileSize(for: descriptor)
        guard UInt64(fileSize) == expectedFileSize else {
            throw V2Error.invalidContainer
        }
    }

    func data(offset: Int64, length: Int) throws -> Data {
        guard offset >= 0,
              length >= 0,
              offset <= descriptor.plaintextLength else {
            throw V2Error.rangeOutOfBounds
        }
        guard length > 0, offset < descriptor.plaintextLength else {
            return Data()
        }
        let requestedEnd = offset.addingReportingOverflow(Int64(length))
        guard !requestedEnd.overflow else {
            throw V2Error.rangeOutOfBounds
        }
        let endOffset = min(descriptor.plaintextLength, requestedEnd.partialValue)
        let firstChunk = Int(offset / Int64(descriptor.chunkSize))
        let lastChunk = Int((endOffset - 1) / Int64(descriptor.chunkSize))

        var result = Data()
        result.reserveCapacity(Int(endOffset - offset))
        for chunkIndex in firstChunk...lastChunk {
            try autoreleasepool {
                let chunk = try decryptedChunk(at: chunkIndex)
                let chunkStart = Int64(chunkIndex) * Int64(descriptor.chunkSize)
                let localStart = Int(max(offset, chunkStart) - chunkStart)
                let localEnd = Int(min(endOffset, chunkStart + Int64(chunk.count)) - chunkStart)
                guard localStart >= 0,
                      localEnd >= localStart,
                      localEnd <= chunk.count else {
                    throw V2Error.invalidContainer
                }
                result.append(chunk.subdata(in: localStart..<localEnd))
            }
        }
        guard result.count == Int(endOffset - offset) else {
            throw V2Error.invalidContainer
        }
        return result
    }

    func verifyAllChunks() throws -> SHA256.Digest {
        var hasher = SHA256()
        for index in 0..<descriptor.chunkCount {
            try autoreleasepool {
                hasher.update(data: try decryptedChunk(at: index))
            }
        }
        return hasher.finalize()
    }

    func decrypt(to destinationURL: URL) throws -> SHA256.Digest {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw V2Error.unsafePath
        }
        try fileManager.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard fileManager.createFile(atPath: destinationURL.path, contents: nil) else {
            throw V2Error.unsafePath
        }
        let output = try FileHandle(forWritingTo: destinationURL)
        var hasher = SHA256()
        do {
            for index in 0..<descriptor.chunkCount {
                try autoreleasepool {
                    let plaintext = try decryptedChunk(at: index)
                    hasher.update(data: plaintext)
                    try output.write(contentsOf: plaintext)
                }
            }
            try output.synchronize()
            try output.close()
        } catch {
            try? output.close()
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
        return hasher.finalize()
    }

    func clearCache() {
        lock.lock()
        cachedChunks.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        cachedByteCount = 0
        lock.unlock()
    }

    private func decryptedChunk(at index: Int) throws -> Data {
        guard index >= 0, index < descriptor.chunkCount else {
            throw V2Error.rangeOutOfBounds
        }
        lock.lock()
        if let cached = cachedChunks[index] {
            markRecentlyUsed(index)
            lock.unlock()
            return cached
        }
        lock.unlock()

        let plaintextLength = chunkPlaintextLength(at: index)
        let encryptedOffset = UInt64(V2MediaContainer.headerSize)
            + UInt64(index) * UInt64(descriptor.chunkSize + V2MediaContainer.chunkTagSize)
        let encryptedLength = plaintextLength + V2MediaContainer.chunkTagSize
        let input = try FileHandle(forReadingFrom: sourceURL)
        let encrypted: Data
        do {
            try input.seek(toOffset: encryptedOffset)
            encrypted = try input.read(upToCount: encryptedLength) ?? Data()
            try input.close()
        } catch {
            try? input.close()
            throw error
        }
        guard encrypted.count == encryptedLength else {
            throw V2Error.invalidContainer
        }

        let ciphertext = encrypted.prefix(plaintextLength)
        let tag = encrypted.suffix(V2MediaContainer.chunkTagSize)
        let nonce = try V2MediaContainer.nonce(
            prefix: header.noncePrefix,
            index: UInt32(index)
        )
        let additionalData = V2MediaContainer.chunkAdditionalData(
            headerPrefix: header.headerPrefix,
            index: UInt32(index),
            plaintextLength: plaintextLength
        )
        let plaintext: Data
        do {
            let sealed = try AES.GCM.SealedBox(
                nonce: nonce,
                ciphertext: ciphertext,
                tag: tag
            )
            plaintext = try AES.GCM.open(
                sealed,
                using: header.dataKey,
                authenticating: additionalData
            )
        } catch {
            throw V2Error.authenticationFailed
        }
        guard plaintext.count == plaintextLength else {
            throw V2Error.invalidContainer
        }

        lock.lock()
        if maximumCacheBytes > 0, plaintext.count <= maximumCacheBytes {
            cachedChunks[index] = plaintext
            cachedByteCount += plaintext.count
            markRecentlyUsed(index)
            trimCache()
        }
        lock.unlock()
        return plaintext
    }

    private func chunkPlaintextLength(at index: Int) -> Int {
        guard index == descriptor.chunkCount - 1 else {
            return descriptor.chunkSize
        }
        let bytesBefore = Int64(index) * Int64(descriptor.chunkSize)
        return Int(descriptor.plaintextLength - bytesBefore)
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

    private static func expectedFileSize(for descriptor: V2MediaDescriptor) throws -> UInt64 {
        let plaintextLength = UInt64(descriptor.plaintextLength)
        let tags = UInt64(descriptor.chunkCount).multipliedReportingOverflow(
            by: UInt64(V2MediaContainer.chunkTagSize)
        )
        guard !tags.overflow else {
            throw V2Error.invalidContainer
        }
        let payload = plaintextLength.addingReportingOverflow(tags.partialValue)
        guard !payload.overflow else {
            throw V2Error.invalidContainer
        }
        let total = UInt64(V2MediaContainer.headerSize).addingReportingOverflow(payload.partialValue)
        guard !total.overflow else {
            throw V2Error.invalidContainer
        }
        return total.partialValue
    }
}
