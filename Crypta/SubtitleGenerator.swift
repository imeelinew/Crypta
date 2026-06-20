import Foundation

nonisolated struct SubtitleGenerator: Sendable {
    private let progress: @MainActor @Sendable (Int, String) -> Void

    init(progress: @escaping @MainActor @Sendable (Int, String) -> Void) {
        self.progress = progress
    }

    func generate(from videoURL: URL, force: Bool) async throws {
        let configuration = SubtitleConfiguration.load()
        let whisperModelPath = configuration.whisperModelPath

        guard SubtitleEmbedder.supportsContainerExtension(videoURL.pathExtension) else {
            throw CryptaError.subtitleGenerationFailed("不支持的容器格式：\(videoURL.pathExtension.lowercased())")
        }
        guard FileManager.default.fileExists(atPath: whisperModelPath) else {
            throw CryptaError.subtitleGenerationFailed(whisperModelPath)
        }
        guard let ffmpegURL = SubtitleProcessRunner.executableURL(named: "ffmpeg") else {
            throw CryptaError.subtitleToolUnavailable("ffmpeg")
        }
        guard let whisperURL = SubtitleProcessRunner.executableURL(named: "whisper-cli") else {
            throw CryptaError.subtitleToolUnavailable("whisper-cli")
        }

        if !force, (try? SubtitleEmbedder.subtitleStreamCount(at: videoURL)) ?? 0 > 0 {
            throw CryptaError.subtitleGenerationFailed("视频已包含内嵌字幕")
        }

        let workDirectory = videoURL.deletingLastPathComponent()
        let baseName = "crypta-subtitle-\(UUID().uuidString)"
        let audioURL = workDirectory.appendingPathComponent("\(baseName).wav", isDirectory: false)
        let srtBaseURL = workDirectory.appendingPathComponent(baseName, isDirectory: false)
        let srtURL = srtBaseURL.appendingPathExtension("srt")
        let whisperLogURL = workDirectory.appendingPathComponent("\(baseName).whisper.log", isDirectory: false)

        defer {
            try? FileManager.default.removeItem(at: audioURL)
            try? FileManager.default.removeItem(at: srtURL)
            try? FileManager.default.removeItem(at: whisperLogURL)
        }

        await progress(5, "抽取音频")
        try Task.checkCancellation()
        try await SubtitleProcessRunner.run(
            executable: ffmpegURL,
            arguments: ["-y", "-i", videoURL.path, "-ar", "16000", "-ac", "1", "-c:a", "pcm_s16le", audioURL.path, "-loglevel", "error"]
        )

        await progress(12, "识别字幕")
        try Task.checkCancellation()
        let logBox = WhisperLogBox()
        try await SubtitleProcessRunner.run(
            executable: whisperURL,
            arguments: [
                "-m", whisperModelPath,
                "-f", audioURL.path,
                "-l", "auto",
                "-ml", "46",
                "-osrt",
                "-of", srtBaseURL.path
            ],
            outputHandler: { chunk in
                let snapshot = logBox.append(chunk)
                try? snapshot.write(to: whisperLogURL, atomically: true, encoding: .utf8)
                let processed = Self.parseWhisperProcessedSeconds(from: snapshot)
                if processed > 0 {
                    Task { @MainActor in
                        progress(min(88, 12 + processed / 4), "识别字幕")
                    }
                }
            }
        )

        let whisperLog = logBox.snapshot()

        guard FileManager.default.fileExists(atPath: srtURL.path) else {
            throw CryptaError.subtitleGenerationFailed("Whisper 没有生成有效字幕")
        }

        let rawSRT = try String(contentsOf: srtURL, encoding: .utf8)
        guard !rawSRT.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CryptaError.subtitleGenerationFailed("Whisper 没有生成有效字幕")
        }

        let detectedLanguage = Self.parseWhisperLanguage(from: whisperLog)
        var cues = SubtitleSRT.parse(rawSRT)

        if detectedLanguage == "en", configuration.canUseLLM, configuration.segmentationEnabled {
            await progress(90, "语义分句")
            cues = try await SubtitleSemanticSegmenter.segment(cues, configuration: configuration)
        }

        await progress(92, "整理字幕")
        cues = SubtitleNormalizer.normalize(cues, sourceLanguage: detectedLanguage)

        if !detectedLanguage.hasPrefix("zh"), configuration.canUseLLM, configuration.translationEnabled {
            await progress(93, "翻译字幕")
            cues = try await SubtitleBilingualTranslator.translate(
                cues,
                sourceLanguage: detectedLanguage,
                configuration: configuration
            )
        }

        let finalSRT = SubtitleSRT.serialize(cues)
        try finalSRT.write(to: srtURL, atomically: true, encoding: .utf8)

        await progress(96, "封装字幕")
        try await SubtitleEmbedder.embedSubtitles(in: videoURL, srtURL: srtURL)
        await progress(100, "字幕已写入视频")
    }

    private static func parseWhisperLanguage(from log: String) -> String {
        let pattern = #"auto-detected language:\s*([A-Za-z_-]+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return "en"
        }
        let range = NSRange(log.startIndex..., in: log)
        guard let match = regex.firstMatch(in: log, range: range),
              let languageRange = Range(match.range(at: 1), in: log) else {
            return "en"
        }
        return String(log[languageRange]).split(separator: "-").first.map { String($0).lowercased() } ?? "en"
    }

    private static func parseWhisperProcessedSeconds(from log: String) -> Int {
        let pattern = #"\[(\d+):(\d{2}):(\d{2})\.(\d{3})\s*-->\s*(\d+):(\d{2}):(\d{2})\.(\d{3})\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 0 }
        let nsLog = log as NSString
        let matches = regex.matches(in: log, range: NSRange(location: 0, length: nsLog.length))
        guard let last = matches.last else { return 0 }
        func component(_ index: Int) -> Int {
            Int(nsLog.substring(with: last.range(at: index))) ?? 0
        }
        let hours = component(5)
        let minutes = component(6)
        let seconds = component(7)
        let millis = component(8)
        return hours * 3600 + minutes * 60 + seconds + millis / 1000
    }
}

nonisolated private final class WhisperLogBox: @unchecked Sendable {
    private var value = ""
    private let lock = NSLock()

    func append(_ chunk: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        value += chunk
        return value
    }

    func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
