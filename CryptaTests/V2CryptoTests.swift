import CryptoKit
import Darwin.Mach
import Foundation
import Testing
@testable import Crypta

struct V2CryptoTests {
    @Test func recoveryKeyRoundTripsAndDetectsCorruption() throws {
        let key = try V2RecoveryKey()
        let decoded = try V2RecoveryKey(phrase: key.description.lowercased())
        #expect(decoded == key)

        var corrupted = key.description
        let last = corrupted.removeLast()
        corrupted.append(last == "A" ? "B" : "A")
        #expect(throws: V2Error.invalidRecoveryKey) {
            _ = try V2RecoveryKey(phrase: corrupted)
        }

        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        let finalCharacter = try #require(key.description.last)
        let finalIndex = try #require(alphabet.firstIndex(of: finalCharacter))
        let nonCanonical = String(key.description.dropLast())
            + String(alphabet[finalIndex + 1])
        #expect(throws: V2Error.invalidRecoveryKey) {
            _ = try V2RecoveryKey(phrase: nonCanonical)
        }
        #expect(throws: V2Error.invalidRecoveryKey) {
            _ = try V2RecoveryKey(phrase: key.description + "A")
        }
    }

    @Test func recoveryEnvelopeIsBoundToVaultAndKey() throws {
        let vaultID = UUID()
        let masterKey = SymmetricKey(size: .bits256)
        let catalogKey = SymmetricKey(size: .bits256)
        let recoveryKey = try V2RecoveryKey()
        let envelope = try V2RecoveryEnvelope(
            vaultID: vaultID,
            masterKey: masterKey,
            catalogKey: catalogKey,
            recoveryKey: recoveryKey
        )
        let recovered = try envelope.recover(using: recoveryKey)
        #expect(V2Crypto.keyData(recovered.masterKey) == V2Crypto.keyData(masterKey))
        #expect(V2Crypto.keyData(recovered.catalogKey) == V2Crypto.keyData(catalogKey))

        #expect(throws: V2Error.authenticationFailed) {
            _ = try envelope.recover(using: V2RecoveryKey())
        }
    }

    @Test func keyManagerSupportsUnlockRecoveryAndRevocation() throws {
        let protector = TestDeviceKeyProtector()
        let manager = V2KeyManager(deviceProtector: protector)
        let vaultID = UUID()
        let setup = try manager.createVaultKeys(
            vaultID: vaultID,
            protection: .userPresence,
            catalogKey: SymmetricKey(size: .bits256)
        )
        let firstKeyData = try setup.session.withMasterKey(V2Crypto.keyData)

        let unlocked = try manager.unlock(
            vaultID: vaultID,
            envelope: setup.deviceEnvelope,
            reason: "test"
        )
        #expect(try unlocked.withMasterKey(V2Crypto.keyData) == firstKeyData)

        unlocked.invalidate()
        #expect(throws: V2Error.sessionLocked) {
            _ = try unlocked.withMasterKey(V2Crypto.keyData)
        }

        let recovered = try manager.recover(
            envelope: setup.recoveryEnvelope,
            recoveryKey: setup.recoveryKey
        )
        #expect(try recovered.session.withMasterKey(V2Crypto.keyData) == firstKeyData)
    }

    @Test func recoveryKeyFileWriteIsAtomicAndOwnerOnly() throws {
        try withTemporaryDirectory { directory in
            let destination = directory.appendingPathComponent("Recovery.txt")
            try Data("obsolete".utf8).write(to: destination)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: destination.path
            )

            let expected = Data("CRYPTA-R1-SYNTHETIC\n".utf8)
            try V2SecureFileWriter.write(expected, to: destination)

            #expect(try Data(contentsOf: destination) == expected)
            let attributes = try FileManager.default.attributesOfItem(
                atPath: destination.path
            )
            let permissions = try #require(
                attributes[.posixPermissions] as? NSNumber
            )
            #expect(permissions.intValue & 0o777 == 0o600)
            #expect(
                try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                ).map(\.lastPathComponent) == ["Recovery.txt"]
            )
        }
    }

    @Test func mediaContainerRoundTripsAndSupportsRandomAccess() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("source.bin")
            let container = directory.appendingPathComponent("object.c2")
            let output = directory.appendingPathComponent("output.bin")
            let plaintext = deterministicData(count: 3 * 64 * 1024 + 731)
            try plaintext.write(to: source)

            let vaultID = UUID()
            let masterKey = SymmetricKey(size: .bits256)
            let descriptor = try V2MediaContainer.encryptFile(
                from: source,
                to: container,
                vaultID: vaultID,
                masterKey: masterKey,
                chunkSize: 64 * 1024
            )
            #expect(descriptor.plaintextLength == Int64(plaintext.count))
            #expect(descriptor.chunkCount == 4)

            let reader = try V2MediaReader(
                sourceURL: container,
                expectedVaultID: vaultID,
                masterKey: masterKey
            )
            let rangeStart = 64 * 1024 - 127
            let rangeLength = 64 * 1024 + 811
            #expect(
                try reader.data(offset: Int64(rangeStart), length: rangeLength)
                    == plaintext.subdata(in: rangeStart..<(rangeStart + rangeLength))
            )
            #expect(
                Data(try reader.verifyAllChunks())
                    == Data(SHA256.hash(data: plaintext))
            )
            _ = try reader.decrypt(to: output)
            #expect(try Data(contentsOf: output) == plaintext)
        }
    }

    @Test func mediaContainerAuthenticatesHeaderOrderAndCompleteness() throws {
        try withTemporaryDirectory { directory in
            let source = directory.appendingPathComponent("source.bin")
            let base = directory.appendingPathComponent("base.c2")
            let plaintext = deterministicData(count: 2 * 64 * 1024)
            try plaintext.write(to: source)
            let vaultID = UUID()
            let masterKey = SymmetricKey(size: .bits256)
            _ = try V2MediaContainer.encryptFile(
                from: source,
                to: base,
                vaultID: vaultID,
                masterKey: masterKey,
                chunkSize: 64 * 1024
            )

            let wrongVault = UUID()
            #expect(throws: V2Error.authenticationFailed) {
                _ = try V2MediaReader(
                    sourceURL: base,
                    expectedVaultID: wrongVault,
                    masterKey: masterKey
                )
            }

            let mutatedHeader = directory.appendingPathComponent("mutated-header.c2")
            try FileManager.default.copyItem(at: base, to: mutatedHeader)
            try overwriteByte(in: mutatedHeader, offset: 156, xor: 0x01)
            #expect(throws: V2Error.authenticationFailed) {
                _ = try V2MediaReader(
                    sourceURL: mutatedHeader,
                    expectedVaultID: vaultID,
                    masterKey: masterKey
                )
            }

            let truncated = directory.appendingPathComponent("truncated.c2")
            try FileManager.default.copyItem(at: base, to: truncated)
            let truncatedHandle = try FileHandle(forWritingTo: truncated)
            try truncatedHandle.truncate(atOffset: UInt64(V2MediaContainer.headerSize + 100))
            try truncatedHandle.close()
            #expect(throws: V2Error.invalidContainer) {
                _ = try V2MediaReader(
                    sourceURL: truncated,
                    expectedVaultID: vaultID,
                    masterKey: masterKey
                )
            }

            let reordered = directory.appendingPathComponent("reordered.c2")
            try FileManager.default.copyItem(at: base, to: reordered)
            try swapFullChunks(in: reordered, chunkSize: 64 * 1024)
            let reorderedReader = try V2MediaReader(
                sourceURL: reordered,
                expectedVaultID: vaultID,
                masterKey: masterKey
            )
            #expect(throws: V2Error.authenticationFailed) {
                _ = try reorderedReader.data(offset: 0, length: 1)
            }
        }
    }

    @Test func mediaContainerRejectsCrossObjectSplicing() throws {
        try withTemporaryDirectory { directory in
            let sourceA = directory.appendingPathComponent("a.bin")
            let sourceB = directory.appendingPathComponent("b.bin")
            let objectA = directory.appendingPathComponent("a.c2")
            let objectB = directory.appendingPathComponent("b.c2")
            try deterministicData(count: 64 * 1024).write(to: sourceA)
            try Data(repeating: 0xA5, count: 64 * 1024).write(to: sourceB)

            let vaultID = UUID()
            let masterKey = SymmetricKey(size: .bits256)
            _ = try V2MediaContainer.encryptFile(
                from: sourceA,
                to: objectA,
                vaultID: vaultID,
                masterKey: masterKey,
                chunkSize: 64 * 1024
            )
            _ = try V2MediaContainer.encryptFile(
                from: sourceB,
                to: objectB,
                vaultID: vaultID,
                masterKey: masterKey,
                chunkSize: 64 * 1024
            )
            let secondObjectData = try Data(contentsOf: objectB)
            let foreignChunk = secondObjectData.suffix(from: V2MediaContainer.headerSize)
            let handle = try FileHandle(forWritingTo: objectA)
            try handle.seek(toOffset: UInt64(V2MediaContainer.headerSize))
            try handle.write(contentsOf: foreignChunk)
            try handle.close()

            let reader = try V2MediaReader(
                sourceURL: objectA,
                expectedVaultID: vaultID,
                masterKey: masterKey
            )
            #expect(throws: V2Error.authenticationFailed) {
                _ = try reader.verifyAllChunks()
            }
        }
    }

    @Test func largeLegacyTranscodeKeepsResidentMemoryBounded() throws {
        try withTemporaryDirectory { directory in
            let legacyURL = directory.appendingPathComponent("synthetic-v1.enc")
            let containerURL = directory.appendingPathComponent("synthetic-v2.c2")
            let legacyKey = SymmetricKey(size: .bits256)
            let chunkCount = 64
            let plaintextByteCount = chunkCount * EncryptedMediaFormat.plaintextChunkSize

            guard FileManager.default.createFile(
                atPath: legacyURL.path,
                contents: nil
            ) else {
                throw V2Error.unsafePath
            }
            let legacyOutput = try FileHandle(forWritingTo: legacyURL)
            do {
                for index in 0..<chunkCount {
                    try autoreleasepool {
                        let plaintext = Data(
                            repeating: UInt8(truncatingIfNeeded: index),
                            count: EncryptedMediaFormat.plaintextChunkSize
                        )
                        let sealed = try AES.GCM.seal(plaintext, using: legacyKey)
                        let combined = try #require(sealed.combined)
                        try legacyOutput.write(
                            contentsOf: EncryptedMediaFormat.lengthPrefix(
                                for: combined.count
                            )
                        )
                        try legacyOutput.write(contentsOf: combined)
                    }
                }
                try legacyOutput.synchronize()
                try legacyOutput.close()
            } catch {
                try? legacyOutput.close()
                throw error
            }

            let baseline = try currentResidentMemory()
            let sampler = ResidentMemorySampler()
            sampler.start()
            defer { sampler.stop() }

            let input = try V1EncryptedPlaintextInput(
                sourceURL: legacyURL,
                key: legacyKey
            )
            #expect(input.byteCount == Int64(plaintextByteCount))
            let vaultID = UUID()
            let masterKey = SymmetricKey(size: .bits256)
            let descriptor = try V2MediaContainer.encrypt(
                input: input,
                to: containerURL,
                vaultID: vaultID,
                masterKey: masterKey
            )
            #expect(descriptor.plaintextLength == Int64(plaintextByteCount))

            let reader = try V2MediaReader(
                sourceURL: containerURL,
                expectedVaultID: vaultID,
                masterKey: masterKey,
                maximumCacheBytes: 0
            )
            _ = try reader.verifyAllChunks()
            sampler.stop()

            let residentGrowth = sampler.maximumResidentMemory - baseline
            #expect(
                residentGrowth < 256 * 1024 * 1024,
                "A 256 MiB transcode grew resident memory by \(residentGrowth) bytes"
            )
        }
    }

    private func withTemporaryDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Crypta-V2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }

    private func deterministicData(count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: ($0 &* 31) &+ ($0 / 251)) })
    }

    private func overwriteByte(in url: URL, offset: UInt64, xor: UInt8) throws {
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: offset)
        guard let byte = try handle.read(upToCount: 1)?.first else {
            try handle.close()
            throw V2Error.invalidContainer
        }
        try handle.seek(toOffset: offset)
        try handle.write(contentsOf: Data([byte ^ xor]))
        try handle.close()
    }

    private func swapFullChunks(in url: URL, chunkSize: Int) throws {
        let recordSize = chunkSize + V2MediaContainer.chunkTagSize
        let handle = try FileHandle(forUpdating: url)
        try handle.seek(toOffset: UInt64(V2MediaContainer.headerSize))
        let first = try handle.read(upToCount: recordSize) ?? Data()
        let second = try handle.read(upToCount: recordSize) ?? Data()
        guard first.count == recordSize, second.count == recordSize else {
            try handle.close()
            throw V2Error.invalidContainer
        }
        try handle.seek(toOffset: UInt64(V2MediaContainer.headerSize))
        try handle.write(contentsOf: second)
        try handle.write(contentsOf: first)
        try handle.close()
    }
}

private nonisolated func currentResidentMemory() throws -> UInt64 {
    var info = mach_task_basic_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout.size(ofValue: info) / MemoryLayout<natural_t>.size
    )
    let status = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(
            to: integer_t.self,
            capacity: Int(count)
        ) {
            task_info(
                mach_task_self_,
                task_flavor_t(MACH_TASK_BASIC_INFO),
                $0,
                &count
            )
        }
    }
    guard status == KERN_SUCCESS else {
        throw V2Error.databaseFailure("resident-memory")
    }
    return info.resident_size
}

private nonisolated final class ResidentMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let finished = DispatchSemaphore(value: 0)
    private var running = false
    private var maximum: UInt64 = 0

    var maximumResidentMemory: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }

    func start() {
        lock.lock()
        guard !running else {
            lock.unlock()
            return
        }
        running = true
        maximum = (try? currentResidentMemory()) ?? 0
        lock.unlock()

        Thread.detachNewThread { [self] in
            while true {
                lock.lock()
                let shouldContinue = running
                if let sample = try? currentResidentMemory() {
                    maximum = max(maximum, sample)
                }
                lock.unlock()
                guard shouldContinue else { break }
                usleep(10_000)
            }
            finished.signal()
        }
    }

    func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        lock.unlock()
        finished.wait()
    }
}

private nonisolated final class TestDeviceKeyProtector: V2DeviceKeyProtector, @unchecked Sendable {
    private let deviceKey = SymmetricKey(size: .bits256)

    func wrap(
        masterKey: SymmetricKey,
        vaultID: UUID,
        protection: V2VaultProtection
    ) throws -> V2DeviceEnvelope {
        V2DeviceEnvelope(
            protection: protection,
            sealedMasterKey: try V2Crypto.seal(
                V2Crypto.keyData(masterKey),
                using: wrappingKey(vaultID: vaultID),
                authenticating: additionalData(vaultID: vaultID, protection: protection)
            ),
            ephemeralPublicKey: protection == .userPresence ? Data([1]) : nil
        )
    }

    func unwrap(
        envelope: V2DeviceEnvelope,
        vaultID: UUID,
        reason: String
    ) throws -> SymmetricKey {
        let plaintext = try V2Crypto.open(
            envelope.sealedMasterKey,
            using: wrappingKey(vaultID: vaultID),
            authenticating: additionalData(vaultID: vaultID, protection: envelope.protection)
        )
        return SymmetricKey(data: plaintext)
    }

    func removeDeviceKey(envelope: V2DeviceEnvelope, vaultID: UUID) throws {}

    private func wrappingKey(vaultID: UUID) -> SymmetricKey {
        V2Crypto.deriveKey(
            from: deviceKey,
            salt: vaultID.v2Data,
            purpose: "test-device-key"
        )
    }

    private func additionalData(
        vaultID: UUID,
        protection: V2VaultProtection
    ) -> Data {
        vaultID.v2Data + Data(protection.rawValue.utf8)
    }
}
