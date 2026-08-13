import CryptoKit
import Foundation
import SQLite3

nonisolated struct V2VaultRecord: Equatable, Sendable {
    let id: UUID
    var name: String
    var encryptionLevel: EncryptionLevel
    var mediaType: MediaType
    var position: Int
    let protection: V2VaultProtection
    var deviceEnvelope: V2DeviceEnvelope
    var recoveryEnvelope: V2RecoveryEnvelope
    var recoveryConfirmed: Bool
    let createdAt: Date
}

nonisolated struct V2ObjectRecord: Equatable, Sendable {
    let id: UUID
    let vaultID: UUID
    let revisionID: UUID
    let blobName: String
    var displayName: String
    let originalExtension: String
    let mediaType: MediaType
    let importedAt: Date
    let byteCount: Int64
    let durationSeconds: Double?
    var playbackPositionSeconds: Double?
}

nonisolated struct V2ObjectLocator: Equatable, Sendable {
    let id: UUID
    let vaultID: UUID
    let revisionID: UUID
    let blobName: String
}

nonisolated final class V2MetadataStore: @unchecked Sendable {
    private static let schemaVersion: Int32 = 3
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let databaseURL: URL
    private let catalogKey: SymmetricKey
    private let lock = NSRecursiveLock()
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(databaseURL: URL, catalogKey: SymmetricKey) throws {
        self.databaseURL = databaseURL
        self.catalogKey = catalogKey
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        decoder.dateDecodingStrategy = .millisecondsSince1970

        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var openedDatabase: OpaquePointer?
        let status = sqlite3_open_v2(
            databaseURL.path,
            &openedDatabase,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard status == SQLITE_OK, let openedDatabase else {
            if let openedDatabase {
                sqlite3_close_v2(openedDatabase)
            }
            throw V2Error.databaseFailure("open:\(status)")
        }
        database = openedDatabase
        do {
            sqlite3_busy_timeout(openedDatabase, 5_000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA trusted_schema = OFF")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try prepareSchema()
        } catch {
            sqlite3_close_v2(openedDatabase)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func catalogKeyForRecovery() -> SymmetricKey {
        catalogKey
    }

    func createVault(_ vault: V2VaultRecord) throws {
        try withLock {
            let existing = try loadVaultsUnlocked()
            guard !existing.contains(where: {
                $0.name.compare(vault.name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else {
                throw V2Error.duplicateVaultName
            }
            try insertVaultUnlocked(vault)
        }
    }

    func loadVaults() throws -> [V2VaultRecord] {
        try withLock {
            try loadVaultsUnlocked()
        }
    }

    func vault(id: UUID) throws -> V2VaultRecord {
        guard let result = try loadVaults().first(where: { $0.id == id }) else {
            throw V2Error.missingVault
        }
        return result
    }

    func renameVault(id: UUID, to name: String) throws {
        try withLock {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw V2Error.invalidEnvelope
            }
            let vaults = try loadVaultsUnlocked()
            guard let vault = vaults.first(where: { $0.id == id }) else {
                throw V2Error.missingVault
            }
            guard !vaults.contains(where: {
                $0.id != id &&
                $0.name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) else {
                throw V2Error.duplicateVaultName
            }
            let encrypted = try encryptVaultName(
                trimmed,
                id: id,
                protection: vault.protection,
                level: vault.encryptionLevel,
                mediaType: vault.mediaType
            )
            try executePrepared("UPDATE vaults SET encrypted_name = ? WHERE id = ?") { statement in
                try bind(encrypted, to: 1, in: statement)
                try bind(id.uuidString, to: 2, in: statement)
            }
            guard sqlite3_changes(try requireDatabase()) == 1 else {
                throw V2Error.missingVault
            }
        }
    }

    func saveVaultOrder(_ ids: [UUID]) throws {
        try withTransaction {
            let existing = try loadVaultsUnlocked().map(\.id)
            guard Set(existing) == Set(ids), existing.count == ids.count else {
                throw V2Error.missingVault
            }
            for (position, id) in ids.enumerated() {
                try executePrepared("UPDATE vaults SET position = ? WHERE id = ?") { statement in
                    try bind(Int64(position), to: 1, in: statement)
                    try bind(id.uuidString, to: 2, in: statement)
                }
            }
        }
    }

    func deleteVault(id: UUID) throws {
        try withTransaction {
            let objectCount = try scalarInt(
                "SELECT COUNT(*) FROM objects WHERE vault_id = ?",
                bind: { statement in try bind(id.uuidString, to: 1, in: statement) }
            )
            guard objectCount == 0 else {
                throw V2Error.vaultNotEmpty
            }
            try executePrepared("DELETE FROM vaults WHERE id = ?") { statement in
                try bind(id.uuidString, to: 1, in: statement)
            }
            guard sqlite3_changes(try requireDatabase()) == 1 else {
                throw V2Error.missingVault
            }
        }
    }

    func updateDeviceEnvelope(vaultID: UUID, envelope: V2DeviceEnvelope) throws {
        try withLock {
            let encoded = try encoder.encode(envelope)
            try executePrepared("UPDATE vaults SET device_envelope = ? WHERE id = ?") { statement in
                try bind(encoded, to: 1, in: statement)
                try bind(vaultID.uuidString, to: 2, in: statement)
            }
            guard sqlite3_changes(try requireDatabase()) == 1 else {
                throw V2Error.missingVault
            }
        }
    }

    func updateRecoveryEnvelope(
        vaultID: UUID,
        envelope: V2RecoveryEnvelope,
        confirmed: Bool
    ) throws {
        try withLock {
            guard envelope.vaultID == vaultID else {
                throw V2Error.invalidEnvelope
            }
            let encoded = try encoder.encode(envelope)
            try executePrepared(
                """
                UPDATE vaults
                SET recovery_envelope = ?, recovery_confirmed = ?
                WHERE id = ?
                """
            ) { statement in
                try bind(encoded, to: 1, in: statement)
                try bind(confirmed ? Int64(1) : Int64(0), to: 2, in: statement)
                try bind(vaultID.uuidString, to: 3, in: statement)
            }
            guard sqlite3_changes(try requireDatabase()) == 1 else {
                throw V2Error.missingVault
            }
        }
    }

    func markRecoveryConfirmed(vaultID: UUID) throws {
        try withLock {
            try executePrepared(
                "UPDATE vaults SET recovery_confirmed = 1 WHERE id = ?"
            ) { statement in
                try bind(vaultID.uuidString, to: 1, in: statement)
            }
            guard sqlite3_changes(try requireDatabase()) == 1 else {
                throw V2Error.missingVault
            }
        }
    }

    func insertObject(_ object: V2ObjectRecord, session: V2VaultSession) throws {
        guard object.vaultID == session.vaultID,
              Self.isSafeBlobName(object.blobName) else {
            throw V2Error.unsafePath
        }
        let encryptedPayload = try encryptObjectPayload(object, session: session)
        try withLock {
            try executePrepared(
                """
                INSERT INTO objects (
                    id, vault_id, revision_id, blob_name, encrypted_payload, created_at
                ) VALUES (?, ?, ?, ?, ?, ?)
                """
            ) { statement in
                try bind(object.id.uuidString, to: 1, in: statement)
                try bind(object.vaultID.uuidString, to: 2, in: statement)
                try bind(object.revisionID.uuidString, to: 3, in: statement)
                try bind(object.blobName, to: 4, in: statement)
                try bind(encryptedPayload, to: 5, in: statement)
                try bind(object.importedAt.timeIntervalSince1970, to: 6, in: statement)
            }
        }
    }

    func loadObjects(vaultID: UUID, session: V2VaultSession) throws -> [V2ObjectRecord] {
        guard vaultID == session.vaultID else {
            throw V2Error.authenticationFailed
        }
        return try withLock {
            var results: [V2ObjectRecord] = []
            try query(
                """
                SELECT id, revision_id, blob_name, encrypted_payload
                FROM objects
                WHERE vault_id = ?
                ORDER BY created_at DESC, id ASC
                """,
                bind: { statement in try bind(vaultID.uuidString, to: 1, in: statement) }
            ) { statement in
                let id = try columnUUID(statement, index: 0)
                let revisionID = try columnUUID(statement, index: 1)
                let blobName = try columnString(statement, index: 2)
                let encrypted = try columnData(statement, index: 3)
                results.append(
                    try decryptObjectPayload(
                        encrypted,
                        id: id,
                        vaultID: vaultID,
                        revisionID: revisionID,
                        blobName: blobName,
                        session: session
                    )
                )
            }
            return results
        }
    }

    func object(
        id: UUID,
        vaultID: UUID,
        session: V2VaultSession
    ) throws -> V2ObjectRecord {
        guard let object = try loadObjects(vaultID: vaultID, session: session)
            .first(where: { $0.id == id }) else {
            throw V2Error.missingObject
        }
        return object
    }

    func updateObject(_ object: V2ObjectRecord, session: V2VaultSession) throws {
        guard object.vaultID == session.vaultID else {
            throw V2Error.authenticationFailed
        }
        let encrypted = try encryptObjectPayload(object, session: session)
        try withLock {
            try executePrepared(
                """
                UPDATE objects
                SET encrypted_payload = ?
                WHERE id = ? AND vault_id = ? AND revision_id = ? AND blob_name = ?
                """
            ) { statement in
                try bind(encrypted, to: 1, in: statement)
                try bind(object.id.uuidString, to: 2, in: statement)
                try bind(object.vaultID.uuidString, to: 3, in: statement)
                try bind(object.revisionID.uuidString, to: 4, in: statement)
                try bind(object.blobName, to: 5, in: statement)
            }
            guard sqlite3_changes(try requireDatabase()) == 1 else {
                throw V2Error.missingObject
            }
        }
    }

    func deleteObject(id: UUID, vaultID: UUID) throws -> V2ObjectLocator {
        try withTransaction {
            var locator: V2ObjectLocator?
            try query(
                "SELECT revision_id, blob_name FROM objects WHERE id = ? AND vault_id = ?",
                bind: { statement in
                    try bind(id.uuidString, to: 1, in: statement)
                    try bind(vaultID.uuidString, to: 2, in: statement)
                }
            ) { statement in
                locator = V2ObjectLocator(
                    id: id,
                    vaultID: vaultID,
                    revisionID: try columnUUID(statement, index: 0),
                    blobName: try columnString(statement, index: 1)
                )
            }
            guard let locator else {
                throw V2Error.missingObject
            }
            try executePrepared("DELETE FROM objects WHERE id = ? AND vault_id = ?") { statement in
                try bind(id.uuidString, to: 1, in: statement)
                try bind(vaultID.uuidString, to: 2, in: statement)
            }
            return locator
        }
    }

    func referencedBlobNames() throws -> Set<String> {
        try withLock {
            var names = Set<String>()
            try query("SELECT blob_name FROM objects") { statement in
                names.insert(try columnString(statement, index: 0))
            }
            return names
        }
    }

    func objectCountsByVault() throws -> [UUID: Int] {
        try withLock {
            var counts: [UUID: Int] = [:]
            try query(
                "SELECT vault_id, COUNT(*) FROM objects GROUP BY vault_id"
            ) { statement in
                counts[try columnUUID(statement, index: 0)] = Int(
                    sqlite3_column_int64(statement, 1)
                )
            }
            return counts
        }
    }

    func integrityCheck() throws {
        try withLock {
            var result = ""
            try query("PRAGMA integrity_check") { statement in
                result = try columnString(statement, index: 0)
            }
            guard result == "ok" else {
                throw V2Error.databaseFailure("integrity")
            }
        }
    }

    static func recoveryEnvelopes(databaseURL: URL) throws -> [V2RecoveryEnvelope] {
        var database: OpaquePointer?
        let openStatus = sqlite3_open_v2(
            databaseURL.path,
            &database,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openStatus == SQLITE_OK, let database else {
            if let database {
                sqlite3_close_v2(database)
            }
            throw V2Error.databaseFailure("recovery-open:\(openStatus)")
        }
        defer { sqlite3_close_v2(database) }

        var statement: OpaquePointer?
        let prepareStatus = sqlite3_prepare_v2(
            database,
            "SELECT recovery_envelope FROM vaults ORDER BY position ASC, id ASC",
            -1,
            &statement,
            nil
        )
        guard prepareStatus == SQLITE_OK, let statement else {
            if let statement {
                sqlite3_finalize(statement)
            }
            throw V2Error.databaseFailure("recovery-prepare:\(prepareStatus)")
        }
        defer { sqlite3_finalize(statement) }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var envelopes: [V2RecoveryEnvelope] = []
        while true {
            let stepStatus = sqlite3_step(statement)
            if stepStatus == SQLITE_DONE {
                return envelopes
            }
            guard stepStatus == SQLITE_ROW,
                  sqlite3_column_type(statement, 0) == SQLITE_BLOB,
                  let bytes = sqlite3_column_blob(statement, 0) else {
                throw V2Error.databaseFailure("recovery-step:\(stepStatus)")
            }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0 else {
                throw V2Error.invalidEnvelope
            }
            let data = Data(bytes: bytes, count: count)
            envelopes.append(try decoder.decode(V2RecoveryEnvelope.self, from: data))
        }
    }

    private func prepareSchema() throws {
        let currentVersion = try scalarInt("PRAGMA user_version")
        guard currentVersion == 0 || currentVersion == Int(Self.schemaVersion) else {
            throw V2Error.databaseFailure("schema-version")
        }
        if currentVersion == 0 {
            try withTransaction {
                try execute(
                    """
                    CREATE TABLE vaults (
                        id TEXT PRIMARY KEY NOT NULL,
                        position INTEGER NOT NULL,
                        protection TEXT NOT NULL,
                        encryption_level TEXT NOT NULL,
                        media_type TEXT NOT NULL,
                        encrypted_name BLOB NOT NULL,
                        device_envelope BLOB NOT NULL,
                        recovery_envelope BLOB NOT NULL,
                        recovery_confirmed INTEGER NOT NULL CHECK (
                            recovery_confirmed IN (0, 1)
                        ),
                        created_at REAL NOT NULL
                    )
                    """
                )
                try execute(
                    """
                    CREATE TABLE objects (
                        id TEXT PRIMARY KEY NOT NULL,
                        vault_id TEXT NOT NULL REFERENCES vaults(id) ON DELETE RESTRICT,
                        revision_id TEXT NOT NULL,
                        blob_name TEXT NOT NULL UNIQUE,
                        encrypted_payload BLOB NOT NULL,
                        created_at REAL NOT NULL
                    )
                    """
                )
                try execute(
                    "CREATE INDEX objects_vault_created ON objects(vault_id, created_at DESC)"
                )
                try execute(
                    """
                    CREATE TABLE migration_state (
                        id INTEGER PRIMARY KEY CHECK (id = 1),
                        phase TEXT NOT NULL,
                        total_count INTEGER NOT NULL,
                        committed_count INTEGER NOT NULL,
                        started_at REAL NOT NULL,
                        updated_at REAL NOT NULL
                    )
                    """
                )
                try execute("PRAGMA user_version = \(Self.schemaVersion)")
            }
        }
    }

    private func loadVaultsUnlocked() throws -> [V2VaultRecord] {
        var results: [V2VaultRecord] = []
        try query(
            """
            SELECT id, position, protection, encryption_level, media_type,
                   encrypted_name, device_envelope, recovery_envelope,
                   recovery_confirmed, created_at
            FROM vaults
            ORDER BY position ASC, created_at ASC, id ASC
            """
        ) { statement in
            let id = try columnUUID(statement, index: 0)
            let protectionValue = try columnString(statement, index: 2)
            let levelValue = try columnString(statement, index: 3)
            let mediaTypeValue = try columnString(statement, index: 4)
            guard let protection = V2VaultProtection(rawValue: protectionValue),
                  let level = EncryptionLevel(rawValue: levelValue),
                  let mediaType = MediaType(rawValue: mediaTypeValue) else {
                throw V2Error.databaseFailure("vault-enum")
            }
            let name = try decryptVaultName(
                try columnData(statement, index: 5),
                id: id,
                protection: protection,
                level: level,
                mediaType: mediaType
            )
            results.append(
                V2VaultRecord(
                    id: id,
                    name: name,
                    encryptionLevel: level,
                    mediaType: mediaType,
                    position: Int(sqlite3_column_int64(statement, 1)),
                    protection: protection,
                    deviceEnvelope: try decoder.decode(
                        V2DeviceEnvelope.self,
                        from: columnData(statement, index: 6)
                    ),
                    recoveryEnvelope: try decoder.decode(
                        V2RecoveryEnvelope.self,
                        from: columnData(statement, index: 7)
                    ),
                    recoveryConfirmed: sqlite3_column_int64(statement, 8) == 1,
                    createdAt: Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 9)
                    )
                )
            )
        }
        return results
    }

    private func encryptVaultName(
        _ name: String,
        id: UUID,
        protection: V2VaultProtection,
        level: EncryptionLevel,
        mediaType: MediaType
    ) throws -> Data {
        let sealed = try V2Crypto.seal(
            Data(name.utf8),
            using: catalogKey,
            authenticating: vaultAdditionalData(
                id: id,
                protection: protection,
                level: level,
                mediaType: mediaType
            )
        )
        return try encoder.encode(sealed)
    }

    private func insertVaultUnlocked(_ vault: V2VaultRecord) throws {
        let encryptedName = try encryptVaultName(
            vault.name,
            id: vault.id,
            protection: vault.protection,
            level: vault.encryptionLevel,
            mediaType: vault.mediaType
        )
        let deviceEnvelope = try encoder.encode(vault.deviceEnvelope)
        let recoveryEnvelope = try encoder.encode(vault.recoveryEnvelope)
        try executePrepared(
            """
            INSERT INTO vaults (
                id, position, protection, encryption_level, media_type,
                encrypted_name, device_envelope, recovery_envelope,
                recovery_confirmed, created_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        ) { statement in
            try bind(vault.id.uuidString, to: 1, in: statement)
            try bind(Int64(vault.position), to: 2, in: statement)
            try bind(vault.protection.rawValue, to: 3, in: statement)
            try bind(vault.encryptionLevel.rawValue, to: 4, in: statement)
            try bind(vault.mediaType.rawValue, to: 5, in: statement)
            try bind(encryptedName, to: 6, in: statement)
            try bind(deviceEnvelope, to: 7, in: statement)
            try bind(recoveryEnvelope, to: 8, in: statement)
            try bind(vault.recoveryConfirmed ? Int64(1) : Int64(0), to: 9, in: statement)
            try bind(vault.createdAt.timeIntervalSince1970, to: 10, in: statement)
        }
    }

    private func decryptVaultName(
        _ encrypted: Data,
        id: UUID,
        protection: V2VaultProtection,
        level: EncryptionLevel,
        mediaType: MediaType
    ) throws -> String {
        let sealed = try decoder.decode(V2SealedData.self, from: encrypted)
        let plaintext = try V2Crypto.open(
            sealed,
            using: catalogKey,
            authenticating: vaultAdditionalData(
                id: id,
                protection: protection,
                level: level,
                mediaType: mediaType
            )
        )
        guard let name = String(data: plaintext, encoding: .utf8) else {
            throw V2Error.invalidEnvelope
        }
        return name
    }

    private func vaultAdditionalData(
        id: UUID,
        protection: V2VaultProtection,
        level: EncryptionLevel,
        mediaType: MediaType
    ) -> Data {
        Data("com.crypta.v2.vault-name".utf8)
            + id.v2Data
            + Data(protection.rawValue.utf8)
            + Data([0])
            + Data(level.rawValue.utf8)
            + Data([0])
            + Data(mediaType.rawValue.utf8)
    }

    private func encryptObjectPayload(
        _ object: V2ObjectRecord,
        session: V2VaultSession
    ) throws -> Data {
        let payload = V2ObjectPayload(
            displayName: object.displayName,
            originalExtension: object.originalExtension,
            mediaType: object.mediaType,
            importedAt: object.importedAt,
            byteCount: object.byteCount,
            durationSeconds: object.durationSeconds,
            playbackPositionSeconds: object.playbackPositionSeconds
        )
        return try session.withMasterKey { masterKey in
            let metadataKey = V2Crypto.deriveKey(
                from: masterKey,
                salt: object.vaultID.v2Data,
                purpose: "com.crypta.v2.metadata"
            )
            let sealed = try V2Crypto.seal(
                try encoder.encode(payload),
                using: metadataKey,
                authenticating: objectAdditionalData(
                    id: object.id,
                    vaultID: object.vaultID,
                    revisionID: object.revisionID,
                    blobName: object.blobName
                )
            )
            return try encoder.encode(sealed)
        }
    }

    private func decryptObjectPayload(
        _ encrypted: Data,
        id: UUID,
        vaultID: UUID,
        revisionID: UUID,
        blobName: String,
        session: V2VaultSession
    ) throws -> V2ObjectRecord {
        guard Self.isSafeBlobName(blobName) else {
            throw V2Error.unsafePath
        }
        return try session.withMasterKey { masterKey in
            let metadataKey = V2Crypto.deriveKey(
                from: masterKey,
                salt: vaultID.v2Data,
                purpose: "com.crypta.v2.metadata"
            )
            let sealed = try decoder.decode(V2SealedData.self, from: encrypted)
            let plaintext = try V2Crypto.open(
                sealed,
                using: metadataKey,
                authenticating: objectAdditionalData(
                    id: id,
                    vaultID: vaultID,
                    revisionID: revisionID,
                    blobName: blobName
                )
            )
            let payload = try decoder.decode(V2ObjectPayload.self, from: plaintext)
            return V2ObjectRecord(
                id: id,
                vaultID: vaultID,
                revisionID: revisionID,
                blobName: blobName,
                displayName: payload.displayName,
                originalExtension: payload.originalExtension,
                mediaType: payload.mediaType,
                importedAt: payload.importedAt,
                byteCount: payload.byteCount,
                durationSeconds: payload.durationSeconds,
                playbackPositionSeconds: payload.playbackPositionSeconds
            )
        }
    }

    private func objectAdditionalData(
        id: UUID,
        vaultID: UUID,
        revisionID: UUID,
        blobName: String
    ) -> Data {
        var data = Data("com.crypta.v2.object-metadata".utf8)
        data.append(id.v2Data)
        data.append(vaultID.v2Data)
        data.append(revisionID.v2Data)
        let nameData = Data(blobName.utf8)
        data.v2Append(UInt16(nameData.count))
        data.append(nameData)
        return data
    }

    private static func isSafeBlobName(_ value: String) -> Bool {
        value.count == 32 &&
        value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }

    private func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    private func withTransaction<T>(_ operation: () throws -> T) throws -> T {
        try withLock {
            try execute("BEGIN IMMEDIATE")
            do {
                let result = try operation()
                try execute("COMMIT")
                return result
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        }
    }

    private func execute(_ sql: String) throws {
        let database = try requireDatabase()
        var errorMessage: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        if let errorMessage {
            sqlite3_free(errorMessage)
        }
        guard status == SQLITE_OK else {
            throw databaseError(status)
        }
    }

    private func executePrepared(
        _ sql: String,
        bind binder: (OpaquePointer) throws -> Void = { _ in }
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try binder(statement)
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE else {
            throw databaseError(status)
        }
    }

    private func query(
        _ sql: String,
        bind binder: (OpaquePointer) throws -> Void = { _ in },
        row: (OpaquePointer) throws -> Void
    ) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try binder(statement)
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return }
            guard status == SQLITE_ROW else {
                throw databaseError(status)
            }
            try row(statement)
        }
    }

    private func scalarInt(
        _ sql: String,
        bind binder: (OpaquePointer) throws -> Void = { _ in }
    ) throws -> Int {
        var result: Int?
        try query(sql, bind: binder) { statement in
            result = Int(sqlite3_column_int64(statement, 0))
        }
        guard let result else {
            throw V2Error.databaseFailure("missing-scalar")
        }
        return result
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let database = try requireDatabase()
        var statement: OpaquePointer?
        let status = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard status == SQLITE_OK, let statement else {
            throw databaseError(status)
        }
        return statement
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) throws {
        let status = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, Self.sqliteTransient)
        }
        guard status == SQLITE_OK else {
            throw databaseError(status)
        }
    }

    private func bind(_ value: Data, to index: Int32, in statement: OpaquePointer) throws {
        let status = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(
                statement,
                index,
                bytes.baseAddress,
                Int32(bytes.count),
                Self.sqliteTransient
            )
        }
        guard status == SQLITE_OK else {
            throw databaseError(status)
        }
    }

    private func bind(_ value: Int64, to index: Int32, in statement: OpaquePointer) throws {
        let status = sqlite3_bind_int64(statement, index, value)
        guard status == SQLITE_OK else {
            throw databaseError(status)
        }
    }

    private func bind(_ value: Double, to index: Int32, in statement: OpaquePointer) throws {
        let status = sqlite3_bind_double(statement, index, value)
        guard status == SQLITE_OK else {
            throw databaseError(status)
        }
    }

    private func columnString(_ statement: OpaquePointer, index: Int32) throws -> String {
        guard sqlite3_column_type(statement, index) == SQLITE_TEXT,
              let value = sqlite3_column_text(statement, index) else {
            throw V2Error.databaseFailure("column-text")
        }
        return String(cString: value)
    }

    private func columnData(_ statement: OpaquePointer, index: Int32) throws -> Data {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB else {
            throw V2Error.databaseFailure("column-blob")
        }
        let byteCount = Int(sqlite3_column_bytes(statement, index))
        guard byteCount >= 0 else {
            throw V2Error.databaseFailure("column-size")
        }
        if byteCount == 0 { return Data() }
        guard let bytes = sqlite3_column_blob(statement, index) else {
            throw V2Error.databaseFailure("column-bytes")
        }
        return Data(bytes: bytes, count: byteCount)
    }

    private func columnUUID(_ statement: OpaquePointer, index: Int32) throws -> UUID {
        let value = try columnString(statement, index: index)
        guard let id = UUID(uuidString: value) else {
            throw V2Error.databaseFailure("column-uuid")
        }
        return id
    }

    private func requireDatabase() throws -> OpaquePointer {
        guard let database else {
            throw V2Error.databaseFailure("closed")
        }
        return database
    }

    private func databaseError(_ status: Int32) -> V2Error {
        let code = database.map(sqlite3_extended_errcode) ?? status
        return .databaseFailure("sqlite:\(code)")
    }
}

nonisolated private struct V2ObjectPayload: Codable {
    let displayName: String
    let originalExtension: String
    let mediaType: MediaType
    let importedAt: Date
    let byteCount: Int64
    let durationSeconds: Double?
    let playbackPositionSeconds: Double?
}
