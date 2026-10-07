// Cuts audio into pieces the recognizer decodes one at a time: Silero VAD speech segments, or fixed windows.
import Foundation

struct AudioSegment {
    let start: Double  // seconds from the start of the decoded audio
    let samples: [Float]
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

/// Speech segments found by Silero VAD (up to 20 s each).
func speechSegments(_ samples: [Float], vadModel: String) -> [AudioSegment] {
    var config = sherpaOnnxVadModelConfig(
        sileroVad: sherpaOnnxSileroVadModelConfig(
            model: vadModel, threshold: 0.5, minSilenceDuration: 0.5, minSpeechDuration: 0.25, windowSize: 512,
            maxSpeechDuration: 20),
        sampleRate: 16000, numThreads: 1)
    let vad = SherpaOnnxVoiceActivityDetectorWrapper(config: &config, buffer_size_in_seconds: 60)
    var found: [AudioSegment] = []
    func drain() {
        while !vad.isEmpty() {
            let segment = vad.front()
            found.append(AudioSegment(start: Double(segment.start) / sampleRate, samples: segment.samples))
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
    return found
}
