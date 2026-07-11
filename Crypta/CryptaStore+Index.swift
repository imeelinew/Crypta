import Foundation

nonisolated extension CryptaStore {
    func withIndexMutation<T>(_ operation: () throws -> T) rethrows -> T {
        indexMutationLock.lock()
        defer { indexMutationLock.unlock() }
        return try operation()
    }

    func loadIndex() throws -> CryptaIndex {
        try locations.prepareDirectories()
        guard FileManager.default.fileExists(atPath: locations.encryptedIndex.path) else {
            return CryptaIndex()
        }
        let encrypted = try Data(contentsOf: locations.encryptedIndex)
        do {
            return try decodeIndex(from: encrypted)
        } catch CryptaError.missingEncryptionKey {
            throw CryptaError.missingEncryptionKey
        } catch CryptaError.protectedDataRequiresExistingKey {
            throw CryptaError.protectedDataRequiresExistingKey
        } catch {
            guard let recovery = try loadBackupIndex() else {
                throw error
            }
            try? recovery.encryptedData.write(to: locations.encryptedIndex, options: [.atomic])
            return recovery.index
        }
    }

    func createGroup(_ group: LibraryGroup) throws {
        try withIndexMutation {
            var index = try loadIndex()
            guard !index.groups.contains(where: { $0.name == group.name }) else {
                throw CryptaError.duplicateGroupName
            }
            index.groups.append(group)
            try saveIndex(index)
        }
    }

    func renameGroup(id: String, to newName: String) throws {
        try withIndexMutation {
            var index = try loadIndex()
            let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            guard let position = index.groups.firstIndex(where: { $0.id == id }) else {
                throw CryptaError.groupNotFound
            }
            guard !index.groups.contains(where: { $0.id != id && $0.name == trimmed }) else {
                throw CryptaError.duplicateGroupName
            }
            index.groups[position].name = trimmed
            try saveIndex(index)
        }
    }

    func deleteGroup(id: String) throws {
        try withIndexMutation {
            var index = try loadIndex()
            guard !index.videos.contains(where: { $0.libraryKind.rawValue == id }) else {
                throw CryptaError.groupNotEmpty
            }
            index.groups.removeAll { $0.id == id }
            try saveIndex(index)
        }
    }

    func saveGroupOrder(_ groups: [LibraryGroup]) throws {
        try withIndexMutation {
            var index = try loadIndex()
            let groupIDs = Set(groups.map(\.id))
            guard groupIDs.count == groups.count,
                  groupIDs == Set(index.groups.map(\.id)) else {
                throw CryptaError.groupNotFound
            }
            index.groups = groups
            try saveIndex(index)
        }
    }

    func saveIndex(_ index: CryptaIndex) throws {
        try withIndexMutation {
            try locations.prepareDirectories()
            let plaintext = try indexEncoder.encode(index)
            let encrypted = try encryptCombined(plaintext)
            try preserveCurrentIndexBackup()
            try encrypted.write(to: locations.encryptedIndex, options: [.atomic])
        }
    }

    private func decodeIndex(from encrypted: Data) throws -> CryptaIndex {
        let plaintext = try decryptCombined(encrypted)
        return try indexDecoder.decode(CryptaIndex.self, from: plaintext)
    }

    private func loadBackupIndex() throws -> (index: CryptaIndex, encryptedData: Data)? {
        guard FileManager.default.fileExists(atPath: locations.encryptedIndexBackup.path) else {
            return nil
        }
        do {
            let backup = try Data(contentsOf: locations.encryptedIndexBackup)
            return (try decodeIndex(from: backup), backup)
        } catch CryptaError.missingEncryptionKey {
            throw CryptaError.missingEncryptionKey
        } catch CryptaError.protectedDataRequiresExistingKey {
            throw CryptaError.protectedDataRequiresExistingKey
        } catch {
            throw CryptaError.indexRecoveryFailed
        }
    }

    private func preserveCurrentIndexBackup() throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: locations.encryptedIndex.path) else { return }
        let currentData = try Data(contentsOf: locations.encryptedIndex)
        guard (try? decodeIndex(from: currentData)) != nil else { return }
        let temporaryBackup = locations.encryptedIndexBackup
            .deletingLastPathComponent()
            .appendingPathComponent("library.index.backup.tmp", isDirectory: false)
        if fileManager.fileExists(atPath: temporaryBackup.path) {
            try fileManager.removeItem(at: temporaryBackup)
        }
        try currentData.write(to: temporaryBackup, options: [.atomic])
        if fileManager.fileExists(atPath: locations.encryptedIndexBackup.path) {
            _ = try fileManager.replaceItemAt(locations.encryptedIndexBackup, withItemAt: temporaryBackup)
        } else {
            try fileManager.moveItem(at: temporaryBackup, to: locations.encryptedIndexBackup)
        }
    }
}
