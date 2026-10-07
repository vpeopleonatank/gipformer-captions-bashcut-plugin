// Decodes the first audio track to 16 kHz mono floats with AVFoundation (any format macOS plays).
import AVFoundation
import Foundation

let sampleRate = 16_000.0

/// Mono samples between `start` and `end` seconds (to the end of the track when `end` is nil), in media time.
func decodeAudio(_ path: String, start: Double, end: Double?) throws -> [Float] {
    let asset = AVURLAsset(url: URL(fileURLWithPath: path))
    guard let track = asset.tracks(withMediaType: .audio).first else {
        throw PluginError("no_audio", "This media has no audio track")
    }
    let reader: AVAssetReader
    do { reader = try AVAssetReader(asset: asset) } catch {
        throw PluginError("cannot_open", "Cannot open media: \(error.localizedDescription)")
    }
    let duration = CMTimeGetSeconds(asset.duration)
    let last = min(end ?? duration, duration)
    guard last - start > 0.1 else { throw PluginError("bad_range", "The range is outside the audio") }
    reader.timeRange = CMTimeRange(
        start: CMTime(seconds: start, preferredTimescale: 48_000), end: CMTime(seconds: last, preferredTimescale: 48_000))
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false,
    ])
    reader.add(output)
    guard reader.startReading() else {
        throw PluginError("cannot_decode", "Cannot decode audio: \(reader.error?.localizedDescription ?? "unknown error")")
    }
    var samples: [Float] = []
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        chunk.withUnsafeMutableBytes { raw in
            _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        samples += chunk
    }
    if reader.status == .failed {
        throw PluginError("cannot_decode", "Cannot decode audio: \(reader.error?.localizedDescription ?? "unknown error")")
    }
    guard samples.count >= Int(sampleRate / 10) else { throw PluginError("bad_range", "The range is outside the audio") }
    return samples
}
