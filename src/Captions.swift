// From decoded tokens to readable captions: words, casing, the user's vocabulary, cues, SubRip and word timings.
import Foundation

struct Word {
    var text: String
    var start: Double
    var end: Double
}

struct Cue {
    let start: Double
    let end: Double
    let text: String
    let words: [Word]
}

// Caption shape (same as Whisper Captions): a new caption after a pause, never longer than the character limit or
// maxSeconds on screen.
let maxSeconds = 6.0
let pauseSeconds = 0.6
let minSeconds = 0.7
// Token timestamps are starts only. A word is shown at most this long, so a pause after it stays a gap that
// `phrases` can see.
let maxWordSeconds = 0.5
// The model stamps the first token of a segment at 0 wherever the speech starts, so the first word is placed this long
// before the second.
let firstWordSeconds = 0.3

let vietnamese = Locale(identifier: "vi")

func lowercase(_ text: String) -> String { text.lowercased(with: vietnamese) }

func capitalizeFirst(_ text: String) -> String {
    guard let first = text.first else { return text }
    return String(first).uppercased(with: vietnamese) + text.dropFirst()
}

/// Words from the recognizer's tokens (a token starting with a space, or ▁, starts a word), lowercased, in media seconds: `offset` is where the
/// segment starts and `segmentEnd` where it ends.
func words(from decoded: Decoded, offset: Double, segmentEnd: Double) -> [Word] {
    var pieces: [(text: String, start: Double)] = []
    for (index, token) in decoded.tokens.enumerated() {
        let time = offset + Double(index < decoded.timestamps.count ? decoded.timestamps[index] : 0)
        let startsWord = token.hasPrefix("\u{2581}") || token.hasPrefix(" ")
        if startsWord || pieces.isEmpty {
            pieces.append((String(token.drop { $0 == "\u{2581}" || $0 == " " }), time))
        } else {
            pieces[pieces.count - 1].text += token
        }
    }
    pieces = pieces.filter { !$0.text.isEmpty }
    if pieces.count > 1 { pieces[0].start = max(pieces[0].start, pieces[1].start - firstWordSeconds) }
    return pieces.enumerated().map { index, piece in
        let next = index + 1 < pieces.count ? pieces[index + 1].start : segmentEnd
        let end = max(piece.start, min(next, piece.start + maxWordSeconds, segmentEnd))
        return Word(text: lowercase(piece.text), start: piece.start, end: end)
    }
}

/// Puts the user's spelling and capitals back where a vocabulary entry matches consecutive words.
func restoreVocabulary(_ words: [Word], entries: [String]) -> [Word] {
    var result = words
    for entry in entries {
        let parts = entry.split(separator: " ").map(String.init)
        let wanted = parts.map(lowercase)
        guard !wanted.isEmpty, result.count >= wanted.count else { continue }
        var index = 0
        while index + wanted.count <= result.count {
            if (0..<wanted.count).allSatisfy({ lowercase(result[index + $0].text) == wanted[$0] }) {
                for offset in 0..<wanted.count { result[index + offset].text = parts[offset] }
                index += wanted.count
            } else {
                index += 1
            }
        }
    }
    return result
}

/// Runs of words between pauses.
func phrases(_ words: [Word]) -> [[Word]] {
    var runs: [[Word]] = []
    var current: [Word] = []
    for word in words {
        if let last = current.last, word.start - last.end > pauseSeconds {
            runs.append(current)
            current = []
        }
        current.append(word)
    }
    if !current.isEmpty { runs.append(current) }
    return runs
}

func joined(_ words: [Word]) -> String { words.map(\.text).joined(separator: " ") }

/// A phrase as few captions as fit the limits, about equally long, so no word is left alone on a line.
func splitEvenly(_ words: [Word], maxCharacters: Int) -> [[Word]] {
    let length = joined(words).count
    let seconds = words[words.count - 1].end - words[0].start
    var count = max(Int((Double(length) / Double(maxCharacters)).rounded(.up)), Int((seconds / maxSeconds).rounded(.up)), 1)
    while true {
        let ideal = Double(length) / Double(count)
        var groups: [[Word]] = []
        var current: [Word] = []
        for word in words {
            let line = joined(current + [word]).count
            if !current.isEmpty && (line > maxCharacters || (groups.count < count - 1 && Double(line) > ideal * 1.15)) {
                groups.append(current)
                current = []
            }
            current.append(word)
        }
        groups.append(current)
        if groups.count <= count || count >= words.count { return groups }
        count += 1
    }
}

/// Readable captions from the words of each segment. A segment's end always ends a caption.
func cues(from segments: [[Word]], maxCharacters: Int) -> [Cue] {
    var result: [Cue] = []
    for segment in segments {
        for phrase in phrases(segment) {
            for var group in splitEvenly(phrase, maxCharacters: maxCharacters) {
                group[0].text = capitalizeFirst(group[0].text)
                var start = group[0].start
                var end = max(group[group.count - 1].end, start + minSeconds)
                if let previous = result.last, start < previous.end {
                    start = previous.end
                    end = max(end, start + 0.2)
                }
                result.append(Cue(start: start, end: end, text: joined(group), words: group))
            }
        }
    }
    return result
}

/// Each caption word with its time, kept inside its caption and in order, for BashCut's word-by-word captions.
func wordTimings(_ cues: [Cue]) -> [[String: Any]] {
    var timed: [[String: Any]] = []
    for cue in cues {
        for word in cue.words {
            let begin = min(max(word.start, cue.start), cue.end)
            let finish = min(max(word.end, begin), cue.end)
            timed.append(["text": word.text, "start": (begin * 1000).rounded() / 1000, "end": (finish * 1000).rounded() / 1000])
        }
    }
    return timed
}

/// SubRip time, such as 00:00:02,000.
func timestamp(_ seconds: Double) -> String {
    let millis = Int((seconds * 1000).rounded())
    return String(format: "%02d:%02d:%02d,%03d", millis / 3_600_000, millis / 60_000 % 60, millis / 1000 % 60, millis % 1000)
}

func subRip(_ cues: [Cue]) -> String {
    cues.enumerated().map { index, cue in
        "\(index + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n\(cue.text)\n"
    }.joined(separator: "\n")
}
