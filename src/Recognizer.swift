// The sherpa-onnx recognizer for the Gipformer transducer, created on first use and kept for the session.
import Foundation

struct Decoded {
    let tokens: [String]
    let timestamps: [Float]
}

/// Where the model and the plugin's resources are.
struct Paths {
    let models: String
    let resources: String

    static let modelFiles = ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "encoder.onnx", "decoder.onnx",
                             "joiner.onnx", "tokens.txt", "bpe.model", "silero_vad.onnx"]

    static var current: Paths {
        let env = ProcessInfo.processInfo.environment
        let cache = env["BASHCUT_PLUGIN_CACHE"]
            ?? NSHomeDirectory() + "/Library/Caches/BashCut/PluginData/bashcut.gipformer-captions"
        let plugin = env["BASHCUT_PLUGIN_DIR"]
            ?? (Bundle.main.executableURL?.deletingLastPathComponent().deletingLastPathComponent().path ?? ".")
        return Paths(models: cache + "/models", resources: plugin + "/resources")
    }

    func model(_ name: String) -> String { models + "/" + name }

    func requireInstalled() throws {
        for name in Paths.modelFiles where !FileManager.default.fileExists(atPath: model(name)) {
            throw PluginError("model_missing", "Gipformer is not installed yet: open Plugins and install the Gipformer model")
        }
    }
}

/// Which model files to use: int8 (quantized, faster) or fp32 (full precision, a little more accurate on hard audio
/// such as singing).
enum Precision: String {
    case int8
    case fp32

    var suffix: String { self == .int8 ? ".int8.onnx" : ".onnx" }
}

final class Recognizer {
    private let paths: Paths
    /// Recognizers by decoding method and precision, created on first use and kept for the session.
    private var recognizers: [String: OpaquePointer] = [:]

    init(paths: Paths) { self.paths = paths }

    private func make(method: String, precision: Precision) -> OpaquePointer {
        let transducer = sherpaOnnxOfflineTransducerModelConfig(
            encoder: paths.model("encoder" + precision.suffix), decoder: paths.model("decoder" + precision.suffix),
            joiner: paths.model("joiner" + precision.suffix))
        let model = sherpaOnnxOfflineModelConfig(
            tokens: paths.model("tokens.txt"), transducer: transducer,
            numThreads: min(4, ProcessInfo.processInfo.activeProcessorCount), modelType: "transducer",
            modelingUnit: "bpe", bpeVocab: paths.resources + "/bpe.vocab")
        var config = sherpaOnnxOfflineRecognizerConfig(
            featConfig: sherpaOnnxFeatureConfig(sampleRate: 16000, featureDim: 80), modelConfig: model,
            decodingMethod: method, hotwordsScore: 1.5)
        guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
            FileHandle.standardError.write(Data("could not create the recognizer\n".utf8))
            exit(3)
        }
        return recognizer
    }

    /// Decodes one segment. A vocabulary (uppercase entries) switches to beam search with those hotwords.
    func decode(_ samples: [Float], vocabulary: [String], precision: Precision) -> Decoded {
        let method = vocabulary.isEmpty ? "greedy_search" : "modified_beam_search"
        let key = method + "|" + precision.rawValue
        let recognizer = recognizers[key] ?? make(method: method, precision: precision)
        recognizers[key] = recognizer
        let created = vocabulary.isEmpty
            ? SherpaOnnxCreateOfflineStream(recognizer)
            : SherpaOnnxCreateOfflineStreamWithHotwords(recognizer, vocabulary.joined(separator: "/"))
        guard let raw = created else { return Decoded(tokens: [], timestamps: []) }
        let stream = SherpaOnnxOfflineStreamWrapper(stream: raw)
        stream.acceptWaveform(samples: samples)
        SherpaOnnxDecodeOfflineStream(recognizer, raw)
        guard let pointer = SherpaOnnxGetOfflineStreamResult(raw) else { return Decoded(tokens: [], timestamps: []) }
        let result = SherpaOnnxOfflineRecognitionResult(result: pointer)
        let count = Int(pointer.pointee.count)
        guard count > 0, let array = pointer.pointee.tokens_arr else { return Decoded(tokens: [], timestamps: []) }
        let tokens = (0..<count).map { array[$0].map { String(cString: $0) } ?? "" }
        return Decoded(tokens: tokens, timestamps: result.timestamps)
    }
}
