import Foundation
import Security

enum LibrarySection: String, CaseIterable, Identifiable, Hashable {
    case plain
    case encrypted

    var id: String { rawValue }

    var title: String {
        switch self {
        case .plain: return "视频"
        case .encrypted: return "加密视频"
        }
    }

    var systemImage: String {
        switch self {
        case .plain: return "video.fill"
        case .encrypted: return "lock.fill"
        }
    }

    var storageState: CryptaVideo.StorageState {
        switch self {
        case .plain: return .plain
        case .encrypted: return .encrypted
        }
    }
}

struct RenameRequest: Identifiable {
    let id = UUID()
    let video: CryptaVideo
    var name: String

    init(video: CryptaVideo) {
        self.video = video
        self.name = video.displayName
    }
}

struct CryptaToast: Equatable, Identifiable {
    enum Kind: Equatable {
        case success
        case error
    }

    let id = UUID()
    let message: String
    let kind: Kind

    var systemImage: String {
        switch kind {
        case .success: return "checkmark.circle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

struct CryptaVideo: Codable, Identifiable, Hashable, Sendable {
    enum StorageState: String, Codable, Sendable {
        case plain
        case encrypted
    }

    let id: UUID
    var displayName: String
    let originalExtension: String
    var storageState: StorageState
    var plainFileName: String?
    var encryptedFileName: String?
    let importedAt: Date
    let byteCount: Int64
    let durationSeconds: Double?

    var detailLine: String {
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        guard let durationSeconds else { return size }
        return "\(Self.formatDuration(durationSeconds)) · \(size)"
    }

    init(
        id: UUID,
        displayName: String,
        originalExtension: String,
        storageState: StorageState,
        plainFileName: String?,
        encryptedFileName: String?,
        importedAt: Date,
        byteCount: Int64,
        durationSeconds: Double?
    ) {
        self.id = id
        self.displayName = displayName
        self.originalExtension = originalExtension
        self.storageState = storageState
        self.plainFileName = plainFileName
        self.encryptedFileName = encryptedFileName
        self.importedAt = importedAt
        self.byteCount = byteCount
        self.durationSeconds = durationSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        originalExtension = try container.decode(String.self, forKey: .originalExtension)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        storageState = try container.decodeIfPresent(StorageState.self, forKey: .storageState) ?? .encrypted
        plainFileName = try container.decodeIfPresent(String.self, forKey: .plainFileName)
        encryptedFileName = try container.decodeIfPresent(String.self, forKey: .encryptedFileName)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case originalExtension
        case storageState
        case plainFileName
        case encryptedFileName
        case importedAt
        case byteCount
        case durationSeconds
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let totalSeconds = max(0, Int(seconds.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct CryptaIndex: Codable, Sendable {
    var videos: [CryptaVideo] = []
}

extension Array where Element == CryptaVideo {
    func sortedForDisplay() -> [CryptaVideo] {
        sorted { $0.importedAt > $1.importedAt }
    }
}

struct PlaybackURL: Sendable {
    let url: URL
    let cleanupURL: URL?
}

enum CryptaError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case invalidEncryptedFile
    case missingIndexEntry
    case missingVideoFile
    case thumbnailFailed
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .encryptionFailed:
            return "加密失败"
        case .decryptionFailed:
            return "解密失败"
        case .invalidEncryptedFile:
            return "加密文件格式无效"
        case .missingIndexEntry:
            return "找不到视频索引"
        case .missingVideoFile:
            return "找不到视频文件"
        case .thumbnailFailed:
            return "无法生成缩略图"
        case .keychainReadFailed(let status):
            return "无法读取钥匙串密钥（\(status)）"
        case .keychainWriteFailed(let status):
            return "无法保存钥匙串密钥（\(status)）"
        }
    }
}
