import Foundation

nonisolated enum SubtitleLLMClient {
    struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
                let reasoningContent: String?

                enum CodingKeys: String, CodingKey {
                    case content
                    case reasoningContent = "reasoning_content"
                }
            }

            let message: Message
        }

        let choices: [Choice]
    }

    static func requestJSON(
        configuration: SubtitleConfiguration,
        systemPrompt: String,
        userPayload: [String: Any],
        maxTokens: Int,
        title: String
    ) async throws -> [String: Any] {
        guard let apiKey = configuration.apiKey, !apiKey.isEmpty else {
            throw CryptaError.subtitleTranslationFailed("未启用外部 LLM")
        }

        let body: [String: Any] = [
            "model": configuration.model,
            "temperature": 0,
            "max_tokens": maxTokens,
            "response_format": ["type": "json_object"],
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": String(data: try JSONSerialization.data(withJSONObject: userPayload), encoding: .utf8) ?? "{}"]
            ]
        ]

        var request = URLRequest(url: configuration.baseURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Crypta/1.0 (macOS) OpenAI-compatible client", forHTTPHeaderField: "User-Agent")
        request.setValue("https://crypta.local", forHTTPHeaderField: "HTTP-Referer")
        request.setValue(title, forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CryptaError.subtitleTranslationFailed("LLM 没有返回 HTTP 响应")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CryptaError.subtitleTranslationFailed(
                "LLM HTTP \(http.statusCode)：\(responseExcerpt(from: data))"
            )
        }

        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let message = decoded.choices.first?.message else {
            throw CryptaError.subtitleTranslationFailed("LLM 响应缺少 choices.message")
        }
        let content = (message.content ?? message.reasoningContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw CryptaError.subtitleTranslationFailed("LLM 响应缺少 content")
        }
        guard let json = try parseJSONObject(from: content) as? [String: Any] else {
            throw CryptaError.subtitleTranslationFailed("LLM 响应不是 JSON 对象")
        }
        return json
    }

    private static func parseJSONObject(from content: String) throws -> Any {
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("```") {
            trimmed = trimmed.replacingOccurrences(of: #"^```(?:json)?\s*"#, with: "", options: .regularExpression)
            trimmed = trimmed.replacingOccurrences(of: #"\s*```$"#, with: "", options: .regularExpression)
        }
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) {
            return object
        }

        if let start = trimmed.firstIndex(of: "{"),
           let end = trimmed.lastIndex(of: "}") {
            let candidate = String(trimmed[start...end])
            if let data = candidate.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) {
                return object
            }
        }
        throw CryptaError.subtitleTranslationFailed("LLM 响应缺少有效 JSON")
    }

    private static func responseExcerpt(from data: Data) -> String {
        let text = String(data: data.prefix(240), encoding: .utf8) ?? ""
        return text.replacingOccurrences(of: "\n", with: " ")
    }
}

nonisolated enum SubtitleSemanticSegmenter {
    static func segment(_ cues: [SubtitleCue], configuration: SubtitleConfiguration) async throws -> [SubtitleCue] {
        guard cues.count >= 2 else { return cues }

        var output: [SubtitleCue] = []
        for batch in batches(from: cues, targetTokens: configuration.segmentationBatchSize) {
            let tokens = tokenEntries(from: batch)
            guard tokens.count >= 4 else {
                output.append(contentsOf: batch)
                continue
            }
            do {
                let payload = try await SubtitleLLMClient.requestJSON(
                    configuration: configuration,
                    systemPrompt: """
                    Return only JSON: {"breaks":[number]}. Tokens are indexed from 1. \
                    Choose natural subtitle segment end indexes. The final number must equal the token count. \
                    Do not output subtitle text.
                    """,
                    userPayload: [
                        "token_count": tokens.count,
                        "tokens": tokens.enumerated().map { [$0.offset + 1, $0.element.text] }
                    ],
                    maxTokens: min(1200, max(600, tokens.count * 4)),
                    title: "Crypta Subtitle Semantic Segmentation"
                )
                let breaks = try validatedBreaks(payload["breaks"], tokenCount: tokens.count)
                output.append(contentsOf: timedEntries(breaks: breaks, tokens: tokens))
            } catch {
                output.append(contentsOf: batch)
            }
        }
        return output.enumerated().map { index, cue in
            SubtitleCue(
                id: index + 1,
                startMs: cue.startMs,
                endMs: cue.endMs,
                englishLines: cue.englishLines,
                chineseLines: cue.chineseLines
            )
        }
    }

    private struct TokenEntry {
        let text: String
        let startMs: Int
        let endMs: Int
    }

    private static func batches(from cues: [SubtitleCue], targetTokens: Int) -> [[SubtitleCue]] {
        var batches: [[SubtitleCue]] = []
        var current: [SubtitleCue] = []
        var currentCount = 0
        for cue in cues {
            let count = max(1, cue.englishText.split(separator: " ").count)
            if !current.isEmpty, currentCount + count > targetTokens {
                batches.append(current)
                current = []
                currentCount = 0
            }
            current.append(cue)
            currentCount += count
        }
        if !current.isEmpty { batches.append(current) }
        return batches
    }

    private static func tokenEntries(from cues: [SubtitleCue]) -> [TokenEntry] {
        var entries: [TokenEntry] = []
        for cue in cues {
            let words = cue.englishText.split(separator: " ").map(String.init).filter { !$0.isEmpty }
            guard !words.isEmpty else { continue }
            let duration = max(cue.endMs - cue.startMs, words.count)
            for (index, word) in words.enumerated() {
                let start = cue.startMs + duration * index / words.count
                let end = cue.startMs + duration * (index + 1) / words.count
                entries.append(TokenEntry(text: word, startMs: start, endMs: max(start + 1, end)))
            }
        }
        return entries
    }

    private static func validatedBreaks(_ value: Any?, tokenCount: Int) throws -> [Int] {
        guard let breaks = value as? [Any] else {
            throw CryptaError.subtitleTranslationFailed("missing breaks")
        }
        var cleaned: [Int] = []
        var previous = 0
        for item in breaks {
            guard let number = item as? Int, number > previous, number <= tokenCount else {
                throw CryptaError.subtitleTranslationFailed("invalid breaks")
            }
            cleaned.append(number)
            previous = number
        }
        guard cleaned.last == tokenCount else {
            throw CryptaError.subtitleTranslationFailed("breaks incomplete")
        }
        return cleaned
    }

    private static func timedEntries(breaks: [Int], tokens: [TokenEntry]) -> [SubtitleCue] {
        var output: [SubtitleCue] = []
        var start = 0
        for end in breaks {
            let slice = tokens[start..<end]
            guard !slice.isEmpty else { continue }
            let text = slice.map(\.text).joined(separator: " ")
            output.append(
                SubtitleCue(
                    id: output.count + 1,
                    startMs: slice.first!.startMs,
                    endMs: slice.last!.endMs,
                    englishLines: [text],
                    chineseLines: []
                )
            )
            start = end
        }
        return output
    }
}

nonisolated enum SubtitleBilingualTranslator {
    typealias JSONRequester = (
        _ configuration: SubtitleConfiguration,
        _ systemPrompt: String,
        _ userPayload: [String: Any],
        _ maxTokens: Int,
        _ title: String
    ) async throws -> [String: Any]

    static func translate(
        _ cues: [SubtitleCue],
        sourceLanguage: String,
        configuration: SubtitleConfiguration,
        requestJSON: JSONRequester? = nil
    ) async throws -> [SubtitleCue] {
        guard configuration.translationEnabled, !cues.isEmpty else { return cues }
        if sourceLanguage.lowercased().hasPrefix("zh") { return cues }

        var translated = cues
        let batchSize = max(10, configuration.translationBatchCues)
        let contextSize = max(0, configuration.translationContextCues)
        let requester = requestJSON ?? defaultRequester

        for start in stride(from: 0, to: cues.count, by: batchSize) {
            let end = min(cues.count, start + batchSize)
            let mapping = try await translateBatch(
                cues: cues,
                start: start,
                end: end,
                contextSize: contextSize,
                sourceLanguage: sourceLanguage,
                configuration: configuration,
                requestJSON: requester
            )
            for index in start..<end {
                let cue = translated[index]
                let zh = mapping[cue.id] ?? ""
                translated[index] = SubtitleCue(
                    id: cue.id,
                    startMs: cue.startMs,
                    endMs: cue.endMs,
                    englishLines: cue.englishLines,
                    chineseLines: wrapChinese(zh)
                )
            }
        }
        return translated
    }

    private static func defaultRequester(
        configuration: SubtitleConfiguration,
        systemPrompt: String,
        userPayload: [String: Any],
        maxTokens: Int,
        title: String
    ) async throws -> [String: Any] {
        try await SubtitleLLMClient.requestJSON(
            configuration: configuration,
            systemPrompt: systemPrompt,
            userPayload: userPayload,
            maxTokens: maxTokens,
            title: title
        )
    }

    private static func translateBatch(
        cues: [SubtitleCue],
        start: Int,
        end: Int,
        contextSize: Int,
        sourceLanguage: String,
        configuration: SubtitleConfiguration,
        requestJSON: JSONRequester
    ) async throws -> [Int: String] {
        let contextStart = max(0, start - contextSize)
        let contextEnd = min(cues.count, end + contextSize)
        let targetIDs = cues[start..<end].map(\.id)
        let context = cues[contextStart..<contextEnd].map { ["id": $0.id, "en": $0.englishText] as [String: Any] }
        var pendingIDs = Set(targetIDs)
        var byID: [Int: String] = [:]
        var lastError: Error?

        for attempt in 1...4 {
            try Task.checkCancellation()

            let targets = cues[start..<end]
                .filter { pendingIDs.contains($0.id) }
                .map { ["id": $0.id, "en": $0.englishText] as [String: Any] }
            guard !targets.isEmpty else { break }

            do {
                let payload = try await requestJSON(
                    configuration,
                    systemPrompt(for: sourceLanguage, isRepair: attempt > 1),
                    [
                        "target_ids": targetIDs.filter { pendingIDs.contains($0) },
                        "context": context,
                        "targets": targets
                    ],
                    maxTokens(forContext: context, targets: targets),
                    attempt > 1 ? "Crypta Bilingual Subtitle Translation Repair" : "Crypta Bilingual Subtitle Translation"
                )
                byID.merge(try translations(from: payload, targetIDs: pendingIDs)) { current, _ in current }
                pendingIDs.subtract(byID.keys)
                if pendingIDs.isEmpty { return byID }
            } catch {
                lastError = error
            }

            if attempt < 4 {
                try await Task.sleep(for: .milliseconds(250 * attempt))
            }
        }

        if let lastError, byID.isEmpty {
            throw lastError
        }
        throw CryptaError.subtitleTranslationFailed("translation ids incomplete: missing \(pendingIDs.sorted())")
    }

    private static func translations(from payload: [String: Any], targetIDs: Set<Int>) throws -> [Int: String] {
        guard let translations = payload["translations"] as? [[String: Any]] else {
            throw CryptaError.subtitleTranslationFailed("missing translations")
        }

        var byID: [Int: String] = [:]
        for item in translations {
            guard let id = item["id"] as? Int else {
                continue
            }
            guard targetIDs.contains(id),
                  let zh = cleaned(item["zh"] as? String),
                  !zh.isEmpty else {
                continue
            }
            byID[id] = zh
        }
        return byID
    }

    private static func maxTokens(forContext context: [[String: Any]], targets: [[String: Any]]) -> Int {
        let contextCount = context.compactMap { ($0["en"] as? String)?.count }.reduce(0, +)
        let targetCount = targets.compactMap { ($0["en"] as? String)?.count }.reduce(0, +)
        return min(8000, max(1200, Int(Double(contextCount + targetCount) * 1.4) + 800))
    }

    private static func systemPrompt(for sourceLanguage: String, isRepair: Bool) -> String {
        let name: String
        switch sourceLanguage.lowercased() {
        case "ja": name = "Japanese"
        case "ko": name = "Korean"
        case "fr": name = "French"
        case "de": name = "German"
        case "es": name = "Spanish"
        default: name = "English"
        }
        return """
        Return only JSON: {"translations":[{"id":number,"zh":"..."}]}. \
        Translate the target \(name) subtitle cues into natural Simplified Chinese. \
        Use surrounding context to keep names, terms, pronouns, style, and repeated concepts consistent. \
        Return translations only for target ids. Preserve item count and ids. \
        \(isRepair ? "This is a retry for missing ids; translate every supplied target id." : "")
        """
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func wrapChinese(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        if text.count <= 28 { return [text] }
        var lines: [String] = []
        var buffer = ""
        for ch in text {
            let candidate = buffer + String(ch)
            if !buffer.isEmpty, candidate.count > 28 {
                lines.append(buffer)
                buffer = String(ch)
            } else {
                buffer = candidate
            }
        }
        if !buffer.isEmpty { lines.append(buffer) }
        return Array(lines.prefix(2))
    }
}
