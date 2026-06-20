import Foundation

nonisolated enum SubtitleNormalizer {
    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)?|[\u4e00-\u9fff]"#
    )
    private static let weakEndWords: Set<String> = [
        "a", "an", "the", "to", "for", "of", "in", "on", "at", "with", "from", "by",
        "and", "or", "but", "so", "because", "if", "when", "while", "as", "than",
        "like", "that", "this", "these", "those", "your", "my", "our", "their",
        "i", "you", "we", "they", "he", "she", "it", "do", "does", "did", "is",
        "are", "was", "were", "be", "being", "been", "am", "can", "could", "would",
        "should", "will", "gonna", "going", "just", "really", "very", "kind"
    ]

    static func normalize(_ cues: [SubtitleCue], sourceLanguage: String) -> [SubtitleCue] {
        let englishLike = ["", "auto", "en"].contains(sourceLanguage.lowercased())
        var working = cues

        if englishLike {
            working = working.map { cue in
                SubtitleCue(
                    id: cue.id,
                    startMs: cue.startMs,
                    endMs: cue.endMs,
                    englishLines: [collapseRepeatedPhraseText(cue.englishText)],
                    chineseLines: cue.chineseLines
                )
            }
            working = removeRepeatedPhraseRuns(working)
            working = mergeShortCues(working)
        }

        var output: [SubtitleCue] = []
        for cue in working {
            let chunks = splitText(cue.englishText)
            let duration = cue.endMs - cue.startMs
            let totalWeight = max(chunks.map { max(width($0), 1) }.reduce(0, +), 1)
            var cursor = cue.startMs

            for (index, chunk) in chunks.enumerated() {
                let chunkEnd: Int
                if index == chunks.count - 1 {
                    chunkEnd = cue.endMs
                } else {
                    let share = max(width(chunk), 1) / totalWeight
                    let chunkMs = max(900, min(5_000, Int(Double(duration) * share)))
                    let remaining = chunks.count - index - 1
                    let latestEnd = cue.endMs - remaining * 900
                    chunkEnd = min(cursor + chunkMs, latestEnd)
                }
                let end = max(cursor + 1, chunkEnd)
                output.append(
                    SubtitleCue(
                        id: cue.id,
                        startMs: cursor,
                        endMs: end,
                        englishLines: wrapLines(chunk),
                        chineseLines: []
                    )
                )
                cursor = end
            }
        }

        if englishLike {
            output = mergeWeakOutputCues(output)
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

    private static func tokenize(_ text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return tokenRegex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]).lowercased() }
        }
    }

    private static func width(_ text: String) -> Double {
        text.reduce(0) { partial, ch in
            if ch.isWhitespace { return partial + 0.5 }
            switch ch.unicodeScalars.first?.value ?? 0 {
            case 0x0020...0x024F: return partial + 0.55
            default: return partial + 1
            }
        }
    }

    private static func endsWithWeakWord(_ text: String) -> Bool {
        guard let last = tokenize(text).last else { return false }
        return weakEndWords.contains(last.trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:，。！？；：")))
    }

    private static func collapseRepeatedPhraseText(_ text: String) -> String {
        var result = text
        var changed = true
        while changed {
            changed = false
            let nsText = result as NSString
            let matches = tokenRegex.matches(in: result, range: NSRange(location: 0, length: nsText.length))
            guard matches.count >= 10 else { break }
            let keys = matches.map { normalizeToken(nsText.substring(with: $0.range)) }
            let maxRun = keys.count / 2
            outer: for runLength in stride(from: maxRun, through: 5, by: -1) {
                for start in 0...(keys.count - runLength * 2) {
                    if Array(keys[start..<(start + runLength)]) == Array(keys[(start + runLength)..<(start + runLength * 2)]) {
                        let removeStart = matches[start + runLength].range.location
                        let removeEnd = matches[start + runLength * 2 - 1].range.upperBound
                        result = nsText.substring(to: removeStart) + nsText.substring(from: removeEnd)
                        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                            .trimmingCharacters(in: .whitespaces)
                        changed = true
                        break outer
                    }
                }
            }
        }
        return result
    }

    private static func normalizeToken(_ token: String) -> String {
        token.lowercased().replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".,!?;:，。！？；："))
    }

    private static func repetitionKey(_ text: String) -> String? {
        let tokens = tokenize(text)
        guard tokens.count >= 5 else { return nil }
        return tokens.map(normalizeToken).joined(separator: " ")
    }

    private static func removeRepeatedPhraseRuns(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        guard cues.count >= 3 else { return cues }
        var cleaned: [SubtitleCue] = []
        var index = 0
        while index < cues.count {
            let cue = cues[index]
            guard let key = repetitionKey(cue.englishText) else {
                cleaned.append(cue)
                index += 1
                continue
            }
            var runEnd = index + 1
            while runEnd < cues.count, repetitionKey(cues[runEnd].englishText) == key {
                runEnd += 1
            }
            cleaned.append(cue)
            index = runEnd - index >= 3 ? runEnd : index + 1
        }
        return cleaned
    }

    private static func canJoin(_ left: SubtitleCue, _ right: SubtitleCue) -> Bool {
        guard right.startMs - left.endMs <= 500 else { return false }
        let combined = joinText(left.englishText, right.englishText)
        return right.endMs > left.startMs && width(combined) <= 46 * 1.8
    }

    private static func mergeShortCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        guard cues.count >= 2 else { return cues }
        var out: [SubtitleCue] = []
        var index = 0
        while index < cues.count {
            let current = cues[index]
            if tokenize(current.englishText).count <= 1 {
                if let last = out.last, canJoin(last, current) {
                    out[out.count - 1] = SubtitleCue(
                        id: last.id,
                        startMs: last.startMs,
                        endMs: current.endMs,
                        englishLines: [joinText(last.englishText, current.englishText)],
                        chineseLines: last.chineseLines
                    )
                    index += 1
                    continue
                }
                if index + 1 < cues.count, canJoin(current, cues[index + 1]) {
                    let next = cues[index + 1]
                    out.append(
                        SubtitleCue(
                            id: current.id,
                            startMs: current.startMs,
                            endMs: next.endMs,
                            englishLines: [joinText(current.englishText, next.englishText)],
                            chineseLines: current.chineseLines
                        )
                    )
                    index += 2
                    continue
                }
            }
            out.append(current)
            index += 1
        }
        return out
    }

    private static func mergeWeakOutputCues(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        guard cues.count >= 2 else { return cues }
        var out: [SubtitleCue] = []
        var index = 0
        while index < cues.count {
            let current = cues[index]
            let weak = tokenize(current.englishText).count <= 2 || endsWithWeakWord(current.englishText)
            if weak {
                if let last = out.last, canJoin(last, current) {
                    let merged = joinText(last.englishText, current.englishText)
                    out[out.count - 1] = SubtitleCue(
                        id: last.id,
                        startMs: last.startMs,
                        endMs: current.endMs,
                        englishLines: wrapLines(merged),
                        chineseLines: last.chineseLines
                    )
                    index += 1
                    continue
                }
                if index + 1 < cues.count, canJoin(current, cues[index + 1]) {
                    let next = cues[index + 1]
                    let merged = joinText(current.englishText, next.englishText)
                    out.append(
                        SubtitleCue(
                            id: current.id,
                            startMs: current.startMs,
                            endMs: next.endMs,
                            englishLines: wrapLines(merged),
                            chineseLines: current.chineseLines
                        )
                    )
                    index += 2
                    continue
                }
            }
            out.append(current)
            index += 1
        }
        return out
    }

    private static func joinText(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        if left.last?.isWhitespace == true || right.first?.isWhitespace == true {
            return left + right
        }
        if left.last?.isLetter == true, right.first?.isLetter == true {
            return left + " " + right
        }
        return left + right
    }

    private static func splitByPunctuation(_ text: String) -> [String] {
        let strong: Set<Character> = ["。", "！", "？", "!", "?", "；", ";"]
        let soft: Set<Character> = ["，", ",", "、"]
        var parts: [String] = []
        var buffer: [Character] = []
        for ch in text {
            buffer.append(ch)
            if strong.contains(ch) || (soft.contains(ch) && width(String(buffer)) >= 24 * 0.75) {
                let part = String(buffer).trimmingCharacters(in: .whitespaces)
                if !part.isEmpty { parts.append(part) }
                buffer.removeAll()
            }
        }
        let tail = String(buffer).trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { parts.append(tail) }
        return parts.isEmpty ? [text] : parts
    }

    private static func splitText(_ text: String) -> [String] {
        var pieces: [String] = []
        for part in splitByPunctuation(text) {
            if width(part) <= 46 {
                pieces.append(part)
            } else {
                pieces.append(contentsOf: splitByWidth(part, limit: 24))
            }
        }
        var cues: [String] = []
        var current = ""
        for piece in pieces {
            let candidate = joinText(current, piece)
            if !current.isEmpty, width(candidate) > 46 {
                cues.append(current)
                current = piece
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { cues.append(current) }
        return cues.isEmpty ? [text] : cues
    }

    private static func splitByWidth(_ text: String, limit: Double) -> [String] {
        var chunks: [String] = []
        var current = ""
        for ch in text {
            let candidate = current + String(ch)
            if !current.isEmpty, width(candidate) > limit {
                chunks.append(current.trimmingCharacters(in: .whitespaces))
                current = String(ch)
            } else {
                current = candidate
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty {
            chunks.append(current.trimmingCharacters(in: .whitespaces))
        }
        return chunks
    }

    private static func wrapLines(_ text: String) -> [String] {
        if width(text) <= 24 { return [text] }
        return Array(splitByWidth(text, limit: 24).prefix(2))
    }
}
