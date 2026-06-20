import Foundation

nonisolated enum SubtitleEmbedder {
    static func supportsContainerExtension(_ extensionName: String) -> Bool {
        codec(for: extensionName) != nil
    }

    static func embedSubtitles(in videoURL: URL, srtURL: URL) async throws {
        guard let ffmpegURL = SubtitleProcessRunner.executableURL(named: "ffmpeg") else {
            throw CryptaError.subtitleToolUnavailable("ffmpeg")
        }

        let ext = videoURL.pathExtension.lowercased()
        guard let codec = codec(for: ext) else {
            throw CryptaError.subtitleGenerationFailed("不支持的容器格式：\(ext)")
        }

        let directory = videoURL.deletingLastPathComponent()
        let stem = videoURL.deletingPathExtension().lastPathComponent
        let tmpVideo = directory.appendingPathComponent(".\(stem).crypta-subtitled.\(UUID().uuidString).\(ext)", isDirectory: false)

        // 只保留音视频，丢弃容器内已有字幕轨，再内嵌一条双语 SRT。
        let arguments = [
            "-y",
            "-loglevel", "error",
            "-i", videoURL.path,
            "-i", srtURL.path,
            "-map", "0:v",
            "-map", "0:a?",
            "-map", "1",
            "-map_metadata", "0",
            "-map_chapters", "0",
            "-c", "copy",
            "-c:s", codec,
            "-metadata:s:s:0", "title=Crypta Subtitles",
            "-metadata:s:s:0", "handler_name=Crypta Subtitles",
            "-disposition:s:0", "default",
            tmpVideo.path
        ]

        try await SubtitleProcessRunner.run(executable: ffmpegURL, arguments: arguments)
        _ = try FileManager.default.replaceItemAt(videoURL, withItemAt: tmpVideo)
    }

    static func subtitleStreamCount(at videoURL: URL) throws -> Int {
        guard let ffprobeURL = SubtitleProcessRunner.executableURL(named: "ffprobe") else {
            throw CryptaError.subtitleToolUnavailable("ffprobe")
        }
        let output = try SubtitleProcessRunner.runCapture(
            executable: ffprobeURL,
            arguments: [
                "-v", "error",
                "-select_streams", "s",
                "-show_entries", "stream=index",
                "-of", "csv=p=0",
                videoURL.path
            ]
        )
        return output
            .split(whereSeparator: \.isNewline)
            .filter { !$0.isEmpty }
            .count
    }

    private static func codec(for extensionName: String) -> String? {
        switch extensionName.lowercased() {
        case "mp4", "m4v", "mov":
            return "mov_text"
        case "mkv":
            return "copy"
        default:
            return nil
        }
    }
}
