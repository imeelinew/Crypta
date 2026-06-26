import Foundation
import Security

nonisolated struct SubtitleSettings: Equatable, Sendable {
    static let defaultWhisperModelPath = NSString(string: "~/whisper-models/ggml-large-v3-turbo.bin").expandingTildeInPath
    static let defaultBaseURLString = "https://opencode.ai/zen/go/v1/chat/completions"
    static let defaultModel = "mimo-v2.5"

    var whisperModelPath: String
    var apiKey: String
    var baseURLString: String
    var model: String
    var segmentationEnabled: Bool
    var translationEnabled: Bool

    static var defaults: SubtitleSettings {
        SubtitleSettings(
            whisperModelPath: defaultWhisperModelPath,
            apiKey: "",
            baseURLString: defaultBaseURLString,
            model: defaultModel,
            segmentationEnabled: false,
            translationEnabled: true
        )
    }
}

nonisolated struct SubtitleConfiguration: Sendable {
    let apiKey: String?
    let baseURL: URL
    let model: String
    let whisperModelPath: String
    let segmentationEnabled: Bool
    let translationEnabled: Bool
    let segmentationBatchSize: Int
    let translationBatchCues: Int
    let translationContextCues: Int

    var canUseLLM: Bool {
        guard let apiKey else { return false }
        return !apiKey.isEmpty
    }

    init(settings: SubtitleSettings) {
        let trimmedAPIKey = settings.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = settings.baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModel = settings.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWhisperModelPath = settings.whisperModelPath.trimmingCharacters(in: .whitespacesAndNewlines)

        apiKey = trimmedAPIKey.isEmpty ? nil : trimmedAPIKey
        baseURL = URL(string: trimmedBaseURL) ?? URL(string: SubtitleSettings.defaultBaseURLString)!
        model = trimmedModel.isEmpty ? SubtitleSettings.defaultModel : trimmedModel
        whisperModelPath = trimmedWhisperModelPath.isEmpty ? SubtitleSettings.defaultWhisperModelPath : trimmedWhisperModelPath
        segmentationEnabled = settings.segmentationEnabled
        translationEnabled = settings.translationEnabled
        segmentationBatchSize = 160
        translationBatchCues = 40
        translationContextCues = 8
    }

    static func load(store: SubtitleSettingsStore = .live) -> SubtitleConfiguration {
        SubtitleConfiguration(settings: store.load())
    }
}

nonisolated final class SubtitleSettingsStore: @unchecked Sendable {
    static let live = SubtitleSettingsStore()

    private let userDefaults: UserDefaults
    private let apiKeyStore: any SubtitleAPIKeyStore

    init(
        userDefaults: UserDefaults = .standard,
        apiKeyStore: any SubtitleAPIKeyStore = SubtitleKeychainAPIKeyStore()
    ) {
        self.userDefaults = userDefaults
        self.apiKeyStore = apiKeyStore
    }

    func load() -> SubtitleSettings {
        let defaults = SubtitleSettings.defaults
        return SubtitleSettings(
            whisperModelPath: string(for: Keys.whisperModelPath) ?? defaults.whisperModelPath,
            apiKey: (try? apiKeyStore.loadAPIKey()) ?? "",
            baseURLString: string(for: Keys.baseURLString) ?? defaults.baseURLString,
            model: string(for: Keys.model) ?? defaults.model,
            segmentationEnabled: bool(for: Keys.segmentationEnabled) ?? defaults.segmentationEnabled,
            translationEnabled: bool(for: Keys.translationEnabled) ?? defaults.translationEnabled
        )
    }

    func save(_ settings: SubtitleSettings) throws {
        userDefaults.set(settings.whisperModelPath, forKey: Keys.whisperModelPath)
        userDefaults.set(settings.baseURLString, forKey: Keys.baseURLString)
        userDefaults.set(settings.model, forKey: Keys.model)
        userDefaults.set(settings.segmentationEnabled, forKey: Keys.segmentationEnabled)
        userDefaults.set(settings.translationEnabled, forKey: Keys.translationEnabled)
        try apiKeyStore.saveAPIKey(settings.apiKey)
    }

    private func string(for key: String) -> String? {
        guard let value = userDefaults.string(forKey: key) else { return nil }
        return value.isEmpty ? nil : value
    }

    private func bool(for key: String) -> Bool? {
        userDefaults.object(forKey: key) == nil ? nil : userDefaults.bool(forKey: key)
    }

    private enum Keys {
        static let whisperModelPath = "subtitle.whisperModelPath"
        static let baseURLString = "subtitle.openRouterBaseURL"
        static let model = "subtitle.openRouterModel"
        static let segmentationEnabled = "subtitle.segmentationEnabled"
        static let translationEnabled = "subtitle.translationEnabled"
    }
}

nonisolated protocol SubtitleAPIKeyStore: Sendable {
    func loadAPIKey() throws -> String
    func saveAPIKey(_ apiKey: String) throws
}

nonisolated final class SubtitleKeychainAPIKeyStore: SubtitleAPIKeyStore, @unchecked Sendable {
    private let service = "com.eli.Crypta.subtitle"
    private let account = "openrouter-api-key"

    func loadAPIKey() throws -> String {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return ""
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw CryptaError.keychainReadFailed(status)
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    func saveAPIKey(_ apiKey: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            let status = SecItemDelete(baseQuery() as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CryptaError.keychainWriteFailed(status)
            }
            return
        }

        let data = Data(trimmed.utf8)
        let query = baseQuery()
        let attributes = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ] as [String: Any]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw CryptaError.keychainWriteFailed(updateStatus)
        }

        var addQuery = query
        addQuery.merge(attributes) { _, new in new }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw CryptaError.keychainWriteFailed(addStatus)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}
