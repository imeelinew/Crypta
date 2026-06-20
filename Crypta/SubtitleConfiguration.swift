import Foundation

nonisolated struct SubtitleConfiguration: Sendable {
    static let defaultWhisperModelPath = NSString(string: "~/whisper-models/ggml-large-v3-turbo.bin").expandingTildeInPath
    static let defaultBaseURL = URL(string: "https://opencode.ai/zen/go/v1/chat/completions")!
    static let defaultModel = "mimo-v2.5"

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

    static func load() -> SubtitleConfiguration {
        let contents = (try? loadSecretsContents()) ?? ""
        return load(contents: contents)
    }

    static func load(contents: String) -> SubtitleConfiguration {
        let apiKey = envValue(named: "LLM_OPENROUTER_API_KEY", in: contents)

        let baseURLString = envValue(named: "LLM_OPENROUTER_BASE_URL", in: contents)
            ?? defaultBaseURL.absoluteString
        let model = envValue(named: "LLM_OPENROUTER_MODEL", in: contents) ?? defaultModel
        let whisperModelPath = envValue(named: "WHISPER_MODEL_PATH", in: contents) ?? defaultWhisperModelPath

        return SubtitleConfiguration(
            apiKey: apiKey,
            baseURL: URL(string: baseURLString) ?? defaultBaseURL,
            model: model,
            whisperModelPath: whisperModelPath,
            segmentationEnabled: envBool(named: "LLM_SEGMENTATION_ENABLED", in: contents, default: false),
            translationEnabled: envBool(named: "LLM_TRANSLATION_ENABLED", in: contents, default: true),
            segmentationBatchSize: envInt(named: "LLM_SEGMENTATION_BATCH_SIZE", in: contents, default: 160),
            translationBatchCues: envInt(named: "LLM_TRANSLATION_BATCH_CUES", in: contents, default: 40),
            translationContextCues: envInt(named: "LLM_TRANSLATION_CONTEXT_CUES", in: contents, default: 8)
        )
    }

    private static func loadSecretsContents() throws -> String {
        let candidates = [
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/Crypta/subtitle-secrets.env", isDirectory: false)
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw CryptaError.subtitleConfigurationMissing
    }

    private static func envValue(named key: String, in contents: String) -> String? {
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let assignment = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
            let parts = assignment.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == key else { continue }
            return unquoted(parts[1].trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    private static func unquoted(_ value: String) -> String {
        guard value.count >= 2,
              let first = value.first,
              let last = value.last,
              (first == "\"" && last == "\"") || (first == "'" && last == "'") else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func envBool(named key: String, in contents: String, default defaultValue: Bool) -> Bool {
        guard let value = envValue(named: key, in: contents) else { return defaultValue }
        switch value.lowercased() {
        case "1", "true", "yes", "on": return true
        case "0", "false", "no", "off": return false
        default: return defaultValue
        }
    }

    private static func envInt(named key: String, in contents: String, default defaultValue: Int) -> Int {
        guard let value = envValue(named: key, in: contents), let parsed = Int(value) else {
            return defaultValue
        }
        return parsed
    }
}
