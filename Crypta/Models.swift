import Foundation
import Security
import UniformTypeIdentifiers

nonisolated struct LibraryKind: RawRepresentable, Codable, Hashable, Sendable, Equatable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }

    static let video = LibraryKind(rawValue: "video")
    static let encrypted = LibraryKind(rawValue: "encrypted")
    static let encryptedImage = LibraryKind(rawValue: "encryptedImage")
}

nonisolated enum EncryptionLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case standard
    case extended

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "标准加密"
        case .extended: return "扩展加密"
        }
    }
}

nonisolated enum MediaType: String, Codable, Sendable, CaseIterable, Identifiable {
    case video
    case image

    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "视频"
        case .image: return "图片"
        }
    }

    var itemNoun: String {
        switch self {
        case .video: return "视频"
        case .image: return "图片"
        }
    }

    var systemImage: String {
        switch self {
        case .video: return "video.fill"
        case .image: return "photo.fill"
        }
    }

    var allowedImportTypes: [UTType] {
        switch self {
        case .video: return [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        case .image: return [.image]
        }
    }
}

nonisolated struct LibraryGroup: Codable, Identifiable, Sendable {
    var id: String
    var name: String
    var encryptionLevel: EncryptionLevel
    var mediaType: MediaType

    var requiresAuthentication: Bool { encryptionLevel == .extended }
    var systemImage: String { mediaType.systemImage }
    var itemNoun: String { mediaType.itemNoun }

    init(id: String = UUID().uuidString, name: String, encryptionLevel: EncryptionLevel, mediaType: MediaType) {
        self.id = id
        self.name = name
        self.encryptionLevel = encryptionLevel
        self.mediaType = mediaType
    }
}

nonisolated struct RenameRequest: Identifiable {
    let id = UUID()
    let video: CryptaVideo
    var name: String

    init(video: CryptaVideo) {
        self.video = video
        self.name = video.displayName
    }
}

nonisolated struct DeleteRequest: Identifiable {
    let id = UUID()
    let videos: [CryptaVideo]

    var primaryVideo: CryptaVideo? {
        videos.first
    }
}

nonisolated struct EditGroupRequest: Identifiable {
    let id = UUID()
    let group: LibraryGroup
    var name: String

    init(group: LibraryGroup) {
        self.group = group
        self.name = group.name
    }
}

nonisolated enum VideoSortMode: String, CaseIterable, Identifiable, Sendable {
    case recentlyAdded
    case name

    static let storageKey = "videoListSortMode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyAdded: return "按最近添加"
        case .name: return "按名称"
        }
    }

    static var stored: VideoSortMode {
        VideoSortMode(rawValue: UserDefaults.standard.string(forKey: storageKey) ?? "") ?? .recentlyAdded
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: Self.storageKey)
    }

    func sorted(_ videos: [CryptaVideo]) -> [CryptaVideo] {
        switch self {
        case .recentlyAdded:
            return videos.sorted { lhs, rhs in
                if lhs.importedAt != rhs.importedAt {
                    return lhs.importedAt > rhs.importedAt
                }
                return Self.isOrderedByName(lhs, before: rhs)
            }
        case .name:
            return videos.sorted { lhs, rhs in
                Self.isOrderedByName(lhs, before: rhs)
            }
        }
    }

    private static func isOrderedByName(_ lhs: CryptaVideo, before rhs: CryptaVideo) -> Bool {
        let nameComparison = lhs.displayName.localizedStandardCompare(rhs.displayName)
        if nameComparison != .orderedSame {
            return nameComparison == .orderedAscending
        }
        let extensionComparison = lhs.originalExtension.localizedStandardCompare(rhs.originalExtension)
        if extensionComparison != .orderedSame {
            return extensionComparison == .orderedAscending
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

nonisolated struct CryptaToast: Equatable, Identifiable {
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

nonisolated struct CryptaVideo: Codable, Identifiable, Hashable, Sendable {
    enum StorageState: String, Codable, Sendable {
        case plain
        case encrypted
    }

    let id: UUID
    var displayName: String
    let originalExtension: String
    var libraryKind: LibraryKind
    var mediaType: MediaType
    var storageState: StorageState
    var plainFileName: String?
    var encryptedFileName: String?
    let importedAt: Date
    let byteCount: Int64
    let durationSeconds: Double?
    var playbackPositionSeconds: Double?

    var isImage: Bool {
        mediaType == .image
    }

    var detailLine: String {
        let size = ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
        guard let durationSeconds else { return size }
        return "\(Self.formatDuration(durationSeconds)) · \(size)"
    }

    init(
        id: UUID,
        displayName: String,
        originalExtension: String,
        libraryKind: LibraryKind = .encrypted,
        mediaType: MediaType = .video,
        storageState: StorageState,
        plainFileName: String?,
        encryptedFileName: String?,
        importedAt: Date,
        byteCount: Int64,
        durationSeconds: Double?,
        playbackPositionSeconds: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.originalExtension = originalExtension
        self.libraryKind = libraryKind
        self.mediaType = mediaType
        self.storageState = storageState
        self.plainFileName = plainFileName
        self.encryptedFileName = encryptedFileName
        self.importedAt = importedAt
        self.byteCount = byteCount
        self.durationSeconds = durationSeconds
        self.playbackPositionSeconds = playbackPositionSeconds
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        displayName = try container.decode(String.self, forKey: .displayName)
        originalExtension = try container.decode(String.self, forKey: .originalExtension)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        durationSeconds = try container.decodeIfPresent(Double.self, forKey: .durationSeconds)
        playbackPositionSeconds = try container.decodeIfPresent(Double.self, forKey: .playbackPositionSeconds)
        storageState = try container.decodeIfPresent(StorageState.self, forKey: .storageState) ?? .encrypted
        libraryKind = try container.decodeIfPresent(LibraryKind.self, forKey: .libraryKind) ?? .encrypted
        mediaType = try container.decodeIfPresent(MediaType.self, forKey: .mediaType) ?? .video
        plainFileName = try container.decodeIfPresent(String.self, forKey: .plainFileName)
        encryptedFileName = try container.decodeIfPresent(String.self, forKey: .encryptedFileName)
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case displayName
        case originalExtension
        case libraryKind
        case mediaType
        case storageState
        case plainFileName
        case encryptedFileName
        case importedAt
        case byteCount
        case durationSeconds
        case playbackPositionSeconds
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

nonisolated struct CryptaIndex: Codable, Sendable {
    var groups: [LibraryGroup] = []
    var videos: [CryptaVideo] = []

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.groups = try container.decodeIfPresent([LibraryGroup].self, forKey: .groups) ?? []
        self.videos = try container.decodeIfPresent([CryptaVideo].self, forKey: .videos) ?? []
    }

    init(groups: [LibraryGroup] = [], videos: [CryptaVideo] = []) {
        self.groups = groups
        self.videos = videos
    }

    private enum CodingKeys: String, CodingKey {
        case groups
        case videos
    }
}

nonisolated extension Array where Element == CryptaVideo {
    func sortedForDisplay() -> [CryptaVideo] {
        sorted { $0.importedAt > $1.importedAt }
    }
}

nonisolated struct PlaybackURL: Sendable {
    let url: URL
    let cleanupURL: URL?
}

nonisolated enum CryptaError: LocalizedError {
    case encryptionFailed
    case decryptionFailed
    case invalidEncryptedFile
    case missingIndexEntry
    case missingVideoFile
    case thumbnailFailed
    case missingEncryptionKey
    case protectedDataRequiresExistingKey
    case indexRecoveryFailed
    case invalidExportDestination
    case externalPlayerUnavailable
    case externalPlayerOpenFailed
    case keychainReadFailed(OSStatus)
    case keychainWriteFailed(OSStatus)
    case groupNotEmpty
    case groupNotFound
    case duplicateGroupName

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
        case .missingEncryptionKey:
            return "加密密钥缺失，无法访问已加密数据"
        case .protectedDataRequiresExistingKey:
            return "检测到已有加密数据，拒绝创建新密钥"
        case .indexRecoveryFailed:
            return "视频索引损坏，且备份索引无法恢复"
        case .invalidExportDestination:
            return "不能解密到 Crypta Vault 内部"
        case .externalPlayerUnavailable:
            return "找不到 IINA"
        case .externalPlayerOpenFailed:
            return "无法使用 IINA 播放"
        case .keychainReadFailed(let status):
            return "无法读取钥匙串密钥（\(status)）"
        case .keychainWriteFailed(let status):
            return "无法保存钥匙串密钥（\(status)）"
        case .groupNotEmpty:
            return "保险箱内仍有文件，无法删除"
        case .groupNotFound:
            return "找不到指定的保险箱"
        case .duplicateGroupName:
            return "已存在同名保险箱"
        }
    }
}
