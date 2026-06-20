import Foundation

nonisolated struct SubtitleCue: Sendable, Equatable {
    let id: Int
    let startMs: Int
    let endMs: Int
    let englishLines: [String]
    let chineseLines: [String]

    var englishText: String {
        Self.joinLines(englishLines)
    }

    var chineseText: String {
        Self.joinLines(chineseLines)
    }

    var timingLine: String {
        "\(Self.formatTimeMs(startMs)) --> \(Self.formatTimeMs(endMs))"
    }

    static func joinLines(_ lines: [String]) -> String {
        lines
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    static func formatTimeMs(_ ms: Int) -> String {
        let clamped = max(0, ms)
        let hours = clamped / 3_600_000
        let minutes = (clamped % 3_600_000) / 60_000
        let seconds = (clamped % 60_000) / 1_000
        let millis = clamped % 1_000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }

    static func parseTimeMs(_ value: String) throws -> Int {
        let pattern = #"(\d+):(\d{2}):(\d{2}),(\d{3})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges == 5 else {
            throw CryptaError.subtitleGenerationFailed("bad srt timestamp: \(value)")
        }
        func component(_ index: Int) -> Int {
            let range = Range(match.range(at: index), in: value)!
            return Int(value[range]) ?? 0
        }
        let hours = component(1)
        let minutes = component(2)
        let seconds = component(3)
        let millis = component(4)
        return ((hours * 60 + minutes) * 60 + seconds) * 1_000 + millis
    }
}

nonisolated enum SubtitleSRT {
    static func parse(_ raw: String) -> [SubtitleCue] {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        let blocks = normalized
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var cues: [SubtitleCue] = []
        cues.reserveCapacity(blocks.count)

        for (fallbackIndex, block) in blocks.enumerated() {
            let lines = block
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .newlines) }
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { continue }

            guard let timingIndex = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let timingParts = lines[timingIndex].components(separatedBy: "-->")
            guard timingParts.count == 2 else { continue }

            guard let startMs = try? SubtitleCue.parseTimeMs(timingParts[0].trimmingCharacters(in: .whitespaces)),
                  let endMs = try? SubtitleCue.parseTimeMs(
                    timingParts[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? timingParts[1]
                  ),
                  endMs > startMs else { continue }

            let id = Int(lines[0]) ?? fallbackIndex + 1
            let textLines = Array(lines[(timingIndex + 1)...])
            guard !textLines.isEmpty else { continue }

            cues.append(
                SubtitleCue(
                    id: id,
                    startMs: startMs,
                    endMs: endMs,
                    englishLines: textLines,
                    chineseLines: []
                )
            )
        }

        return cues
    }

    static func serialize(_ cues: [SubtitleCue]) -> String {
        var chunks: [String] = []
        chunks.reserveCapacity(cues.count)
        for (index, cue) in cues.enumerated() {
            var displayLines = cue.englishLines
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !cue.chineseLines.isEmpty {
                displayLines.append(
                    contentsOf: cue.chineseLines
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
            }
            guard !displayLines.isEmpty else { continue }
            chunks.append(
                "\(index + 1)\n\(cue.timingLine)\n\(displayLines.joined(separator: "\n"))"
            )
        }
        return chunks.joined(separator: "\n\n") + (chunks.isEmpty ? "" : "\n")
    }
}
