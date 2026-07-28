import CryptoKit
import Foundation
import LocalAuthentication
import Security

nonisolated enum V2VaultProtection: String, Codable, Equatable, Sendable {
    case standard
    case userPresence

    init(level: EncryptionLevel) {
        self = level == .standard ? .standard : .userPresence
    }
}

nonisolated struct V2DeviceEnvelope: Codable, Equatable, Sendable {
    let version: UInt8
    let protection: V2VaultProtection
    let sealedMasterKey: V2SealedData
    let ephemeralPublicKey: Data?
    let keyIdentifier: UUID?

    init(
        protection: V2VaultProtection,
        sealedMasterKey: V2SealedData,
        ephemeralPublicKey: Data?,
        keyIdentifier: UUID? = nil
    ) {
        version = 1
        self.protection = protection
        self.sealedMasterKey = sealedMasterKey
        self.ephemeralPublicKey = ephemeralPublicKey
        self.keyIdentifier = keyIdentifier
    }
}

nonisolated protocol V2DeviceKeyProtector: Sendable {
    func wrap(
        masterKey: SymmetricKey,
        vaultID: UUID,
        protection: V2VaultProtection
    ) throws -> V2DeviceEnvelope

    func unwrap(
        envelope: V2DeviceEnvelope,
        vaultID: UUID,
        reason: String
    ) throws -> SymmetricKey

    func removeDeviceKey(envelope: V2DeviceEnvelope, vaultID: UUID) throws
}

nonisolated struct V2VaultKeySetup: Sendable {
    let deviceEnvelope: V2DeviceEnvelope
    let recoveryEnvelope: V2RecoveryEnvelope
    let recoveryKey: V2RecoveryKey
    let session: V2VaultSession
}

nonisolated final class V2VaultSession: @unchecked Sendable {
    let id = UUID()
    let vaultID: UUID
    let createdAt = Date()

    private let lock = NSLock()
    private var masterKey: SymmetricKey?

    init(vaultID: UUID, masterKey: SymmetricKey) {
        self.vaultID = vaultID
        self.masterKey = masterKey
    }

    var isUnlocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return masterKey != nil
    }

    func withMasterKey<T>(_ operation: (SymmetricKey) throws -> T) throws -> T {
        lock.lock()
        guard let masterKey else {
            lock.unlock()
            throw V2Error.sessionLocked
        }
        defer { lock.unlock() }
        return try operation(masterKey)
    }

    func invalidate() {
        lock.lock()
        masterKey = nil
        lock.unlock()
    }
}

nonisolated final class V2KeyManager: @unchecked Sendable {
    private let deviceProtector: any V2DeviceKeyProtector

    init(deviceProtector: any V2DeviceKeyProtector = V2ProductionDeviceKeyProtector()) {
        self.deviceProtector = deviceProtector
    }

    func createVaultKeys(
        vaultID: UUID,
        protection: V2VaultProtection,
        catalogKey: SymmetricKey,
        recoveryKey suppliedRecoveryKey: V2RecoveryKey? = nil
    ) throws -> V2VaultKeySetup {
        let recoveryKey = try suppliedRecoveryKey ?? V2RecoveryKey()
        let masterKey = SymmetricKey(size: .bits256)
        let deviceEnvelope = try deviceProtector.wrap(
            masterKey: masterKey,
            vaultID: vaultID,
            protection: protection
        )
        do {
            let recoveryEnvelope = try V2RecoveryEnvelope(
                vaultID: vaultID,
                masterKey: masterKey,
                catalogKey: catalogKey,
                recoveryKey: recoveryKey
            )
            return V2VaultKeySetup(
                deviceEnvelope: deviceEnvelope,
                recoveryEnvelope: recoveryEnvelope,
                recoveryKey: recoveryKey,
                session: V2VaultSession(vaultID: vaultID, masterKey: masterKey)
            )
        } catch {
            try? deviceProtector.removeDeviceKey(
                envelope: deviceEnvelope,
                vaultID: vaultID
            )
            throw error
        }
    }

    func unlock(
        vaultID: UUID,
        envelope: V2DeviceEnvelope,
        reason: String
    ) throws -> V2VaultSession {
        let key = try deviceProtector.unwrap(
            envelope: envelope,
            vaultID: vaultID,
            reason: reason
        )
        return V2VaultSession(vaultID: vaultID, masterKey: key)
    }

    func recover(
        envelope: V2RecoveryEnvelope,
        recoveryKey: V2RecoveryKey
    ) throws -> (session: V2VaultSession, catalogKey: SymmetricKey) {
        let recovered = try envelope.recover(using: recoveryKey)
        return (
            V2VaultSession(
                vaultID: envelope.vaultID,
                masterKey: recovered.masterKey
            ),
            recovered.catalogKey
        )
    }

    func replaceRecoveryEnvelope(
        session: V2VaultSession,
        catalogKey: SymmetricKey,
        recoveryKey suppliedRecoveryKey: V2RecoveryKey? = nil
    ) throws -> (envelope: V2RecoveryEnvelope, recoveryKey: V2RecoveryKey) {
        let recoveryKey = try suppliedRecoveryKey ?? V2RecoveryKey()
        let envelope = try session.withMasterKey { masterKey in
            try V2RecoveryEnvelope(
                vaultID: session.vaultID,
                masterKey: masterKey,
                catalogKey: catalogKey,
                recoveryKey: recoveryKey
            )
        }
        return (envelope, recoveryKey)
    }

    func reenrollDevice(
        session: V2VaultSession,
        protection: V2VaultProtection
    ) throws -> V2DeviceEnvelope {
        try session.withMasterKey { masterKey in
            try deviceProtector.wrap(
                masterKey: masterKey,
                vaultID: session.vaultID,
                protection: protection
            )
        }
    }

    func removeDeviceKey(envelope: V2DeviceEnvelope, vaultID: UUID) throws {
        try deviceProtector.removeDeviceKey(envelope: envelope, vaultID: vaultID)
    }
}

nonisolated protocol V2KeyRepository: Sendable {
    func catalogKeyData() throws -> Data?
    func saveCatalogKeyData(_ data: Data) throws
    func secureEnclaveKeyData(keyIdentifier: UUID) throws -> Data?
    func saveSecureEnclaveKeyData(_ data: Data, keyIdentifier: UUID) throws
    func removeSecureEnclaveKeyData(keyIdentifier: UUID) throws
}

nonisolated final class V2KeychainRepository: V2KeyRepository, @unchecked Sendable {
    private let catalogService = "com.eli.Crypta.v2.catalog-key"
    private let enclaveService = "com.eli.Crypta.v2.secure-enclave"

    func catalogKeyData() throws -> Data? {
        try read(service: catalogService, account: "default")
    }

    func saveCatalogKeyData(_ data: Data) throws {
        try upsert(
            data,
            service: catalogService,
            account: "default",
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        )
    }

    func secureEnclaveKeyData(keyIdentifier: UUID) throws -> Data? {
        try read(service: enclaveService, account: keyIdentifier.uuidString)
    }

    func saveSecureEnclaveKeyData(_ data: Data, keyIdentifier: UUID) throws {
        try upsert(
            data,
            service: enclaveService,
            account: keyIdentifier.uuidString,
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    func removeSecureEnclaveKeyData(keyIdentifier: UUID) throws {
        let status = SecItemDelete(
            baseQuery(service: enclaveService, account: keyIdentifier.uuidString) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw V2Error.keychainFailure(status)
        }
    }

    private func read(service: String, account: String) throws -> Data? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw V2Error.keychainFailure(status)
        }
        return data
    }

    private func upsert(
        _ data: Data,
        service: String,
        account: String,
        accessibility: CFString
    ) throws {
        let query = baseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw V2Error.keychainFailure(updateStatus)
        }
        var item = query
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = accessibility
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw V2Error.keychainFailure(addStatus)
        }
    }

    private func baseQuery(service: String, account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

nonisolated final class V2ProductionDeviceKeyProtector: V2DeviceKeyProtector, @unchecked Sendable {
    private let repository: any V2KeyRepository
    private let repositoryLock = NSLock()

    init(repository: any V2KeyRepository = V2KeychainRepository()) {
        self.repository = repository
    }

    func wrap(
        masterKey: SymmetricKey,
        vaultID: UUID,
        protection: V2VaultProtection
    ) throws -> V2DeviceEnvelope {
        switch protection {
        case .standard:
            let catalogKey = try getOrCreateCatalogKey()
            let wrappingKey = V2Crypto.deriveKey(
                from: catalogKey,
                salt: vaultID.v2Data,
                purpose: "com.crypta.v2.standard-vault-wrap"
            )
            let sealed = try V2Crypto.seal(
                V2Crypto.keyData(masterKey),
                using: wrappingKey,
                authenticating: deviceAdditionalData(vaultID: vaultID, protection: protection)
            )
            return V2DeviceEnvelope(
                protection: protection,
                sealedMasterKey: sealed,
                ephemeralPublicKey: nil
            )

        case .userPresence:
            #if arch(arm64)
            guard SecureEnclave.isAvailable else {
                throw V2Error.secureEnclaveUnavailable
            }
            var accessControlError: Unmanaged<CFError>?
            guard let accessControl = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage, .userPresence],
                &accessControlError
            ) else {
                throw accessControlError?.takeRetainedValue() ?? V2Error.secureEnclaveUnavailable
            }
            let securePrivateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                accessControl: accessControl
            )
            let keyIdentifier = UUID()
            try repository.saveSecureEnclaveKeyData(
                securePrivateKey.dataRepresentation,
                keyIdentifier: keyIdentifier
            )
            do {
                let ephemeralPrivateKey = P256.KeyAgreement.PrivateKey()
                let secret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(
                    with: securePrivateKey.publicKey
                )
                let wrappingKey = secret.hkdfDerivedSymmetricKey(
                    using: SHA256.self,
                    salt: vaultID.v2Data,
                    sharedInfo: Data("com.crypta.v2.user-presence-wrap".utf8),
                    outputByteCount: V2Crypto.keyByteCount
                )
                let sealed = try V2Crypto.seal(
                    V2Crypto.keyData(masterKey),
                    using: wrappingKey,
                    authenticating: deviceAdditionalData(vaultID: vaultID, protection: protection)
                )
                return V2DeviceEnvelope(
                    protection: protection,
                    sealedMasterKey: sealed,
                    ephemeralPublicKey: ephemeralPrivateKey.publicKey.rawRepresentation,
                    keyIdentifier: keyIdentifier
                )
            } catch {
                try? repository.removeSecureEnclaveKeyData(keyIdentifier: keyIdentifier)
                throw error
            }
            #else
            throw V2Error.secureEnclaveUnavailable
            #endif
        }
    }

    func unwrap(
        envelope: V2DeviceEnvelope,
        vaultID: UUID,
        reason: String
    ) throws -> SymmetricKey {
        guard envelope.version == 1 else {
            throw V2Error.invalidEnvelope
        }
        let wrappingKey: SymmetricKey
        switch envelope.protection {
        case .standard:
            guard let catalogData = try repository.catalogKeyData(),
                  catalogData.count == V2Crypto.keyByteCount,
                  envelope.ephemeralPublicKey == nil,
                  envelope.keyIdentifier == nil else {
                throw V2Error.invalidEnvelope
            }
            wrappingKey = V2Crypto.deriveKey(
                from: SymmetricKey(data: catalogData),
                salt: vaultID.v2Data,
                purpose: "com.crypta.v2.standard-vault-wrap"
            )

        case .userPresence:
            #if arch(arm64)
            guard SecureEnclave.isAvailable,
                  let keyIdentifier = envelope.keyIdentifier,
                  let privateKeyData = try repository.secureEnclaveKeyData(
                    keyIdentifier: keyIdentifier
                  ),
                  let ephemeralPublicKeyData = envelope.ephemeralPublicKey else {
                throw V2Error.invalidEnvelope
            }
            let context = LAContext()
            context.localizedReason = reason
            let securePrivateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                dataRepresentation: privateKeyData,
                authenticationContext: context
            )
            let ephemeralPublicKey = try P256.KeyAgreement.PublicKey(
                rawRepresentation: ephemeralPublicKeyData
            )
            let secret = try securePrivateKey.sharedSecretFromKeyAgreement(
                with: ephemeralPublicKey
            )
            wrappingKey = secret.hkdfDerivedSymmetricKey(
                using: SHA256.self,
                salt: vaultID.v2Data,
                sharedInfo: Data("com.crypta.v2.user-presence-wrap".utf8),
                outputByteCount: V2Crypto.keyByteCount
            )
            #else
            throw V2Error.secureEnclaveUnavailable
            #endif
        }

        let plaintext = try V2Crypto.open(
            envelope.sealedMasterKey,
            using: wrappingKey,
            authenticating: deviceAdditionalData(
                vaultID: vaultID,
                protection: envelope.protection
            )
        )
        guard plaintext.count == V2Crypto.keyByteCount else {
            throw V2Error.invalidEnvelope
        }
        return SymmetricKey(data: plaintext)
    }

    func removeDeviceKey(envelope: V2DeviceEnvelope, vaultID: UUID) throws {
        guard envelope.protection == .userPresence else { return }
        guard let keyIdentifier = envelope.keyIdentifier else {
            throw V2Error.invalidEnvelope
        }
        try repository.removeSecureEnclaveKeyData(keyIdentifier: keyIdentifier)
    }

    private func getOrCreateCatalogKey() throws -> SymmetricKey {
        repositoryLock.lock()
        defer { repositoryLock.unlock() }
        if let existing = try repository.catalogKeyData() {
            guard existing.count == V2Crypto.keyByteCount else {
                throw V2Error.invalidEnvelope
            }
            return SymmetricKey(data: existing)
        }
        let data = try V2Crypto.randomData(count: V2Crypto.keyByteCount)
        try repository.saveCatalogKeyData(data)
        return SymmetricKey(data: data)
    }

    private func deviceAdditionalData(
        vaultID: UUID,
        protection: V2VaultProtection
    ) -> Data {
        Data("com.crypta.v2.device-envelope".utf8)
            + vaultID.v2Data
            + Data(protection.rawValue.utf8)
    }
}
