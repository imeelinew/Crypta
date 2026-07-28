import Foundation

nonisolated extension V2VaultRecord {
    var libraryGroup: LibraryGroup {
        LibraryGroup(
            id: id.uuidString,
            name: name,
            encryptionLevel: encryptionLevel,
            mediaType: mediaType
        )
    }
}

nonisolated extension V2ObjectRecord {
    var libraryVideo: CryptaVideo {
        CryptaVideo(
            id: id,
            displayName: displayName,
            originalExtension: originalExtension,
            libraryKind: LibraryKind(rawValue: vaultID.uuidString),
            mediaType: mediaType,
            storageState: .encrypted,
            plainFileName: nil,
            encryptedFileName: blobName,
            importedAt: importedAt,
            byteCount: byteCount,
            durationSeconds: durationSeconds,
            playbackPositionSeconds: playbackPositionSeconds
        )
    }
}

nonisolated struct RecoveryKeyPresentation: Identifiable, Sendable {
    enum Purpose: Sendable, Equatable {
        case migration
        case vault(UUID)
    }

    let id = UUID()
    let purpose: Purpose
    let recoveryKey: V2RecoveryKey
}

nonisolated enum MigrationPresentationState: Equatable, Sendable {
    case ready
    case running
    case complete
    case failed
}

nonisolated struct RecoveryAccessPresentation: Identifiable, Sendable {
    let id = UUID()
    let expectedVaultID: UUID?
}

nonisolated enum RecoveryAccessAttemptResult: Equatable, Sendable {
    case success
    case invalidKey
    case failure
}
