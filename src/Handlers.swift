// Gipformer Captions: provides captions.transcribe for Vietnamese speech (Gipformer 1.5 through sherpa-onnx).
//
// `startSeconds`/`endSeconds` transcribe only that stretch; times stay in media seconds.
// GIPFORMER_FAKE=1 skips the model and the voice detector and decodes a fixed transcript per segment (tests and CI).
import Foundation

let fake = ProcessInfo.processInfo.environment["GIPFORMER_FAKE"] == "1"
let recognizer = Recognizer(paths: Paths.current)

/// A fixed uppercase transcript spread over a segment, the way the model returns tokens.
func fakeDecoded(duration: Double) -> Decoded {
    let tokens = [" XIN", " CHÀO", " CÁC", " BẠN", " HÔM", " NAY", " MÌNH", " ĐI", " BUÔN", " ĐÔN", " CHƠI"]
    let step = min(0.3, duration * 0.8 / Double(tokens.count))
    return Decoded(tokens: tokens, timestamps: tokens.indices.map { Float(0.1 + Double($0) * step) })
}

func number(_ value: Any?) -> Double? { (value as? NSNumber)?.doubleValue }

func handle(method: String, params: JSON, host: Host) throws -> Any? {
    guard method == "captions.transcribe" else { throw PluginError("unknown_method", "Gipformer Captions does not handle \(method)") }
    guard let path = params["mediaPath"] as? String, !path.isEmpty,
          let folder = params["outputDirectory"] as? String, !folder.isEmpty
    else { throw PluginError("bad_request", "mediaPath and outputDirectory are required") }
    let language = (params["language"] as? String ?? "").lowercased()
    guard ["", "auto", "und"].contains(language) || language.hasPrefix("vi") else {
        throw PluginError("bad_language", "Gipformer only transcribes Vietnamese")
    }
    let options = params["options"] as? JSON ?? [:]
    let vocabulary = (options["vocabulary"] as? String ?? "").split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    let maxCharacters = Int(number(options["maxCharacters"]) ?? 42)
    let voiceDetection = (options["voiceDetection"] as? NSNumber)?.boolValue ?? true
    let start = number(params["startSeconds"]) ?? 0
    let end = number(params["endSeconds"])
    if start < 0 || (end != nil && end! <= start) { throw PluginError("bad_range", "endSeconds must follow startSeconds") }
    guard FileManager.default.fileExists(atPath: path) else { throw PluginError("not_found", "Media not found: \(path)") }
    let paths = Paths.current
    if !fake { try paths.requireInstalled() }

    host.progress(0.02, "Reading audio")
    let samples = try decodeAudio(path, start: start, end: end)
    let segments: [AudioSegment]
    if fake {
        if voiceDetection {
            // Fixed detections at 0.5–3, 3.4–6 and 9–11.5 s (clamped to the audio) go through the real padding.
            let found = [(0.5, 3.0), (3.4, 6.0), (9.0, 11.5)].map { Int($0 * sampleRate)..<Int($1 * sampleRate) }
                .map { min($0.lowerBound, samples.count)..<min($0.upperBound, samples.count) }.filter { !$0.isEmpty }
            let ranges = padded(found, count: samples.count)
            segments = ranges.map { AudioSegment(start: Double($0.lowerBound) / sampleRate, samples: Array(samples[$0])) }
            let bounds = ranges.map { String(format: "%.2f-%.2f", Double($0.lowerBound) / sampleRate,
                                             Double($0.upperBound) / sampleRate) }.joined(separator: ",")
            host.progress(0.08, "Voice detection on: \(segments.count) speech segments [\(bounds)]")
        } else {
            segments = fixedWindows(samples)
            let cuts = windowCuts(samples).map { String(format: "%.2f", Double($0) / sampleRate) }.joined(separator: ",")
            host.progress(0.08, "Voice detection off: \(segments.count) windows, cuts at [\(cuts)]")
        }
    } else if voiceDetection {
        host.progress(0.05, "Finding speech")
        segments = speechSegments(samples, vadModel: paths.model("silero_vad.onnx"))
        host.progress(0.1, "\(segments.count) speech segments")
    } else {
        segments = fixedWindows(samples)
        host.progress(0.1, "\(segments.count) windows")
    }

    let total = max(segments.reduce(0) { $0 + $1.duration }, 0.001)
    var done = 0.0
    var spoken: [[Word]] = []
    for segment in segments {
        let decoded = fake
            ? fakeDecoded(duration: segment.duration)
            : recognizer.decode(segment.samples, vocabulary: vocabulary.map { $0.uppercased(with: vietnamese) })
        let offset = start + segment.start
        var found = words(from: decoded, offset: offset, segmentEnd: offset + segment.duration)
        // Without voice detection a noise-only window can decode to a stray short word: drop it.
        if !voiceDetection && found.count <= 1 && segment.duration < 0.3 { found = [] }
        if !found.isEmpty { spoken.append(restoreVocabulary(found, entries: vocabulary)) }
        done += segment.duration
        host.progress(0.1 + 0.85 * done / total, "Transcribing")
    }

    let result = cues(from: spoken, maxCharacters: max(16, min(84, maxCharacters)))
    guard !result.isEmpty else { throw PluginError("no_speech", "No speech found in this media") }
    let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    try subRip(result).write(toFile: (folder as NSString).appendingPathComponent(stem + ".srt"), atomically: true, encoding: .utf8)
    let timings = try JSONSerialization.data(withJSONObject: wordTimings(result), options: [.withoutEscapingSlashes])
    try timings.write(to: URL(fileURLWithPath: (folder as NSString).appendingPathComponent(stem + ".words.json")))
    host.progress(1, "\(result.count) captions")
    return ["srtPath": stem + ".srt", "wordsPath": stem + ".words.json"]
}
