import CryptoKit
import Foundation
import Security

nonisolated enum V2Error: Error, Equatable {
    case randomGenerationFailed(OSStatus)
    case invalidRecoveryKey
    case invalidEnvelope
    case invalidContainer
    case unsupportedContainerVersion
    case authenticationFailed
    case sourceChangedDuringImport
    case rangeOutOfBounds
    case missingVault
    case missingObject
    case duplicateVaultName
    case vaultNotEmpty
    case databaseFailure(String)
    case secureEnclaveUnavailable
    case keychainFailure(OSStatus)
    case sessionLocked
    case unsafePath
    case migrationAlreadyRunning
    case migrationIncomplete
}

nonisolated enum V2Crypto {
    static let keyByteCount = 32

    static func randomData(count: Int) throws -> Data {
        precondition(count > 0)
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw V2Error.randomGenerationFailed(status)
        }
        return data
    }

    static func keyData(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    static func deriveKey(
        from inputKey: SymmetricKey,
        salt: Data,
        purpose: String
    ) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: salt,
            info: Data(purpose.utf8),
            outputByteCount: keyByteCount
        )
    }

    static func seal(
        _ plaintext: Data,
        using key: SymmetricKey,
        authenticating additionalData: Data
    ) throws -> V2SealedData {
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: additionalData)
        guard let combined = sealed.combined else {
            throw V2Error.invalidEnvelope
        }
        return V2SealedData(combined: combined)
    }

    static func open(
        _ sealed: V2SealedData,
        using key: SymmetricKey,
        authenticating additionalData: Data
    ) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed.combined)
            return try AES.GCM.open(box, using: key, authenticating: additionalData)
        } catch {
            throw V2Error.authenticationFailed
        }
    }
}

nonisolated struct V2SealedData: Codable, Equatable, Sendable {
    let version: UInt8
    let combined: Data

    init(combined: Data) {
        self.version = 1
        self.combined = combined
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(UInt8.self, forKey: .version)
        guard version == 1 else {
            throw V2Error.invalidEnvelope
        }
        combined = try container.decode(Data.self, forKey: .combined)
        guard combined.count >= 28 else {
            throw V2Error.invalidEnvelope
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case combined
    }
}

nonisolated struct V2RecoveryKey: Equatable, Sendable, CustomStringConvertible {
    private static let prefix = "CRYPTA-R1"
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
    private static let lookup = Dictionary(
        uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt8($0)) }
    )

    let rawData: Data

    var description: String {
        let checksum = Data(SHA256.hash(data: rawData).prefix(4))
        let encoded = Self.base32Encode(rawData + checksum)
        let groups = stride(from: 0, to: encoded.count, by: 4).map { offset -> String in
            let start = encoded.index(encoded.startIndex, offsetBy: offset)
            let end = encoded.index(start, offsetBy: min(4, encoded.count - offset))
            return String(encoded[start..<end])
        }
        return ([Self.prefix] + groups).joined(separator: "-")
    }

    init() throws {
        rawData = try V2Crypto.randomData(count: V2Crypto.keyByteCount)
    }

    init(rawData: Data) throws {
        guard rawData.count == V2Crypto.keyByteCount else {
            throw V2Error.invalidRecoveryKey
        }
        self.rawData = rawData
    }

    init(phrase: String) throws {
        let normalized = phrase
            .uppercased()
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: " ", with: "")
        let normalizedPrefix = Self.prefix.replacingOccurrences(of: "-", with: "")
        guard normalized.hasPrefix(normalizedPrefix) else {
            throw V2Error.invalidRecoveryKey
        }
        let payload = String(normalized.dropFirst(normalizedPrefix.count))
        let expectedPayloadLength = ((V2Crypto.keyByteCount + 4) * 8 + 4) / 5
        guard payload.count == expectedPayloadLength else {
            throw V2Error.invalidRecoveryKey
        }
        let decoded = try Self.base32Decode(payload)
        guard decoded.count == V2Crypto.keyByteCount + 4 else {
            throw V2Error.invalidRecoveryKey
        }
        let keyData = decoded.prefix(V2Crypto.keyByteCount)
        let checksum = decoded.suffix(4)
        let expected = SHA256.hash(data: keyData).prefix(4)
        guard Data(checksum) == Data(expected) else {
            throw V2Error.invalidRecoveryKey
        }
        rawData = Data(keyData)
    }

    func wrappingKey(vaultID: UUID) -> SymmetricKey {
        V2Crypto.deriveKey(
            from: SymmetricKey(data: rawData),
            salt: vaultID.v2Data,
            purpose: "com.crypta.v2.recovery-wrap"
        )
    }

    private static func base32Encode(_ data: Data) -> String {
        var output = ""
        var buffer: UInt32 = 0
        var bitCount = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bitCount += 8
            while bitCount >= 5 {
                bitCount -= 5
                output.append(alphabet[Int((buffer >> UInt32(bitCount)) & 0x1F)])
            }
            buffer = bitCount == 0 ? 0 : buffer & ((1 << UInt32(bitCount)) - 1)
        }
        if bitCount > 0 {
            output.append(alphabet[Int((buffer << UInt32(5 - bitCount)) & 0x1F)])
        }
        return output
    }

    private static func base32Decode(_ value: String) throws -> Data {
        var output = Data()
        var buffer: UInt32 = 0
        var bitCount = 0
        for character in value {
            guard let decoded = lookup[character] else {
                throw V2Error.invalidRecoveryKey
            }
            buffer = (buffer << 5) | UInt32(decoded)
            bitCount += 5
            if bitCount >= 8 {
                bitCount -= 8
                output.append(UInt8((buffer >> UInt32(bitCount)) & 0xFF))
            }
            buffer = bitCount == 0 ? 0 : buffer & ((1 << UInt32(bitCount)) - 1)
        }
        guard buffer == 0 else {
            throw V2Error.invalidRecoveryKey
        }
        return output
    }
}

nonisolated struct V2RecoveredKeyMaterial: Sendable {
    let masterKey: SymmetricKey
    let catalogKey: SymmetricKey
}

nonisolated struct V2RecoveryEnvelope: Codable, Equatable, Sendable {
    let version: UInt8
    let vaultID: UUID
    let sealedKeyMaterial: V2SealedData

    init(
        vaultID: UUID,
        masterKey: SymmetricKey,
        catalogKey: SymmetricKey,
        recoveryKey: V2RecoveryKey
    ) throws {
        version = 2
        self.vaultID = vaultID
        sealedKeyMaterial = try V2Crypto.seal(
            V2Crypto.keyData(masterKey) + V2Crypto.keyData(catalogKey),
            using: recoveryKey.wrappingKey(vaultID: vaultID),
            authenticating: Self.additionalData(vaultID: vaultID)
        )
    }

    func recover(using recoveryKey: V2RecoveryKey) throws -> V2RecoveredKeyMaterial {
        guard version == 2 else {
            throw V2Error.invalidEnvelope
        }
        let plaintext = try V2Crypto.open(
            sealedKeyMaterial,
            using: recoveryKey.wrappingKey(vaultID: vaultID),
            authenticating: Self.additionalData(vaultID: vaultID)
        )
        guard plaintext.count == V2Crypto.keyByteCount * 2 else {
            throw V2Error.invalidEnvelope
        }
        return V2RecoveredKeyMaterial(
            masterKey: SymmetricKey(data: plaintext.prefix(V2Crypto.keyByteCount)),
            catalogKey: SymmetricKey(data: plaintext.suffix(V2Crypto.keyByteCount))
        )
    }

    private static func additionalData(vaultID: UUID) -> Data {
        Data("com.crypta.v2.recovery-envelope.v2".utf8) + vaultID.v2Data
    }
}

nonisolated extension UUID {
    var v2Data: Data {
        let bytes = uuid
        return withUnsafeBytes(of: bytes) { Data($0) }
    }

    init?(v2Data: Data) {
        guard v2Data.count == 16 else { return nil }
        let bytes = [UInt8](v2Data)
        self.init(
            uuid: (
                bytes[0], bytes[1], bytes[2], bytes[3],
                bytes[4], bytes[5], bytes[6], bytes[7],
                bytes[8], bytes[9], bytes[10], bytes[11],
                bytes[12], bytes[13], bytes[14], bytes[15]
            )
        )
    }
}

nonisolated extension Data {
    mutating func v2Append<T: FixedWidthInteger>(_ value: T) {
        var bigEndianValue = value.bigEndian
        Swift.withUnsafeBytes(of: &bigEndianValue) { append(contentsOf: $0) }
    }

    func v2Integer<T: FixedWidthInteger>(at offset: Int, as type: T.Type = T.self) -> T? {
        let byteCount = MemoryLayout<T>.size
        guard offset >= 0, offset + byteCount <= count else { return nil }
        return self[offset..<(offset + byteCount)].reduce(T.zero) { partial, byte in
            (partial << 8) | T(byte)
        }
    }
}
