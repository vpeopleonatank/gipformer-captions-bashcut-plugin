// Cuts audio into pieces the recognizer decodes one at a time: Silero VAD speech segments, or fixed windows.
import Foundation

struct AudioSegment {
    let start: Double  // seconds from the start of the decoded audio
    let samples: [Float]
    var speech: [Range<Int>] = []  // voice-detected speech inside, in samples of the decoded audio
    var duration: Double { Double(samples.count) / sampleRate }
}

let windowSeconds = 20.0
let cutReachSeconds = 3.0
let frameSamples = Int(sampleRate * 0.01)

/// Sample offsets where the audio is cut into windows of about `windowSeconds`: each boundary moves to the quietest
/// 10 ms within `cutReachSeconds` of it, so a cut rarely lands inside a word. The last window takes what is left.
func windowCuts(_ samples: [Float]) -> [Int] {
    let window = Int(windowSeconds * sampleRate)
    let reach = Int(cutReachSeconds * sampleRate)
    var cuts: [Int] = []
    var from = 0
    while samples.count - from > window + reach {
        let ideal = from + window
        var best = ideal
        var bestLevel = Float.infinity
        var frame = ideal - reach
        while frame + frameSamples <= ideal + reach {
            var sum: Float = 0
            for index in frame..<(frame + frameSamples) { sum += samples[index] * samples[index] }
            if sum < bestLevel {
                bestLevel = sum
                best = frame
            }
            frame += frameSamples
        }
        cuts.append(best)
        from = best
    }
    return cuts
}

func fixedWindows(_ samples: [Float]) -> [AudioSegment] {
    let bounds = [0] + windowCuts(samples) + [samples.count]
    return zip(bounds, bounds.dropFirst()).map {
        AudioSegment(start: Double($0) / sampleRate, samples: Array(samples[$0..<$1]))
    }
}

/// Silero marks speech a little late and can drop quiet syllables, so each segment is widened by `speechPad` on both
/// sides. Padded segments less than `mergeGap` apart are decoded together (up to `mergedLimit`), so a short pause never
/// splits a sentence and the recognizer keeps the words around it in context. Each segment keeps the speech found in
/// it (`speech`), so speech its decode left without words can be decoded again on its own.
let speechPad = 1.0
let mergeGap = 1.0
let mergedLimit = 30.0

/// How readily Silero calls a frame speech: `high` also catches quiet or distant voices, `low` skips more noise.
enum Sensitivity: String {
    case low
    case normal
    case high

    var threshold: Float { [.low: 0.5, .normal: 0.3, .high: 0.2][self]! }
}

/// Speech segments found by Silero VAD, padded and merged (up to `mergedLimit` each).
func speechSegments(_ samples: [Float], vadModel: String, sensitivity: Sensitivity) -> [AudioSegment] {
    var config = sherpaOnnxVadModelConfig(
        sileroVad: sherpaOnnxSileroVadModelConfig(
            model: vadModel, threshold: sensitivity.threshold, minSilenceDuration: 0.5, minSpeechDuration: 0.25,
            windowSize: 512, maxSpeechDuration: 20),
        sampleRate: 16000, numThreads: 1)
    let vad = SherpaOnnxVoiceActivityDetectorWrapper(config: &config, buffer_size_in_seconds: 60)
    var found: [Range<Int>] = []
    func drain() {
        while !vad.isEmpty() {
            let segment = vad.front()
            let start = Int(segment.start)
            found.append(start..<(start + segment.samples.count))
            vad.pop()
        }
    }
    var offset = 0
    while offset + 512 <= samples.count {
        vad.acceptWaveform(samples: Array(samples[offset..<(offset + 512)]))
        drain()
        offset += 512
    }
    vad.flush()
    drain()
    return detected(found, samples: samples)
}

/// Segments for detected speech ranges: padded and merged, each keeping the detections it holds.
func detected(_ found: [Range<Int>], samples: [Float]) -> [AudioSegment] {
    padded(found, count: samples.count).map { range in
        AudioSegment(start: Double(range.lowerBound) / sampleRate, samples: Array(samples[range]),
                     speech: found.filter { range.contains($0.lowerBound) })
    }
}

/// Widens each range by `speechPad`, clamped to the audio, and merges ranges less than `mergeGap` apart while the
/// result stays within `mergedLimit`.
func padded(_ ranges: [Range<Int>], count: Int) -> [Range<Int>] {
    let pad = Int(speechPad * sampleRate), gap = Int(mergeGap * sampleRate), limit = Int(mergedLimit * sampleRate)
    var merged: [Range<Int>] = []
    for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
        let wide = max(0, range.lowerBound - pad)..<min(count, range.upperBound + pad)
        if let last = merged.last, wide.lowerBound - last.upperBound < gap,
           max(last.upperBound, wide.upperBound) - last.lowerBound <= limit {
            merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, wide.upperBound)
        } else {
            // Never decode the same audio twice: an overlap left over by the length limit goes to the earlier segment.
            merged.append(max(wide.lowerBound, merged.last?.upperBound ?? 0)..<wide.upperBound)
        }
    }
    return merged.filter { !$0.isEmpty }
}
