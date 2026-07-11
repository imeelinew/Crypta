import Foundation

nonisolated enum EncryptedMediaFormat {
    static let plaintextChunkSize = 4 * 1024 * 1024
    static let sealedBoxOverhead = 28
    static let maximumEncryptedChunkLength = plaintextChunkSize + 1024

    static func isValidEncryptedChunkLength(_ length: Int) -> Bool {
        length > sealedBoxOverhead && length < maximumEncryptedChunkLength
    }

    static func lengthPrefix(for length: Int) -> Data {
        var value = UInt32(length).bigEndian
        return Data(bytes: &value, count: MemoryLayout<UInt32>.size)
    }

    static func length(fromPrefix data: Data) -> Int {
        data.reduce(0) { partial, byte in
            (partial << 8) | Int(byte)
        }
    }
}
