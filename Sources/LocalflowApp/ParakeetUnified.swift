@preconcurrency import CoreML
import CryptoKit
import FluidAudio
import Foundation
import LocalflowEngine
import Synchronization
import os

/// Parakeet Unified 0.6B's offline transcription as FluidAudio's `UnifiedAsrManager` does it (same
/// features, encoder, 15 s windows overlapping by 2 s and window merge) but with the RNNT decoder in
/// LocalflowEngine instead of two CoreML models called once per frame and per token: ~35 ms of a
/// dictation on cold cores became ~3 ms, with the same tokens on 437 of 439 windows of the ASR test
/// set (bench/README.md). Recordings shorter than a window use a shorter copy of the encoder
/// (`ShorterWindows`): its graph masks everything past `mel_length`, the input, each subsampling
/// convolution, attention and the convolution modules, so any window that holds the mel frames gives
/// the same frames up to fp16 rounding.
actor ParakeetUnified {
    enum Failure: LocalizedError {
        case decoder
        case encoder
        var errorDescription: String? {
            switch self {
            case .decoder: "The speech model's decoder failed"
            case .encoder: "The speech model's encoder failed"
            }
        }
    }

    private typealias Token = WindowMerge.Token

    private static let sampleRate = 16_000
    private static let frameSamples = 1280                  // one encoder frame, 80 ms
    private static let windowSamples = 15 * sampleRate      // the encoder's fixed input
    private static let chunkSamples = windowSamples / frameSamples * frameSamples
    private static let overlapSamples = 2 * sampleRate / frameSamples * frameSamples
    private static let hop = 160
    private static let melBins = 128
    private static let melFrames = windowSamples / hop + 1
    private static let log = Logger(subsystem: "io.github.snaeppi.localflow", category: "asr")
    private static let windows = ShorterWindows(
        graph: .unifiedEncoder, source: "parakeet_unified_encoder_int8.mlmodelc",
        all: [
            (frames: 401, sha256: "66229bf3739df78b3cbfee57a5941c2ff29cf87d342da0e5cd9079dae6532c7f"),
            (frames: 1021, sha256: "9c015fb664562f300156628a73142810af91cf995e1692259e9995b3a0596127"),
        ])

    /// By mel frames, ascending: the shorter windows as they finish loading, and the 15 s one, which
    /// fits every window.
    private var encoders: [(frames: Int, model: MLModel)]
    private var loadingWindows: Task<Void, Never>?
    private let decoder: OpaquePointer
    private let vocabulary: [Int: String]   // SentencePiece pieces
    private let merger: WindowMerge
    private let mel = AudioMelSpectrogram(
        sampleRate: sampleRate, nMels: melBins, nFFT: 512, hopLength: hop, winLength: 400, preemph: 0.97, padTo: 0,
        windowPeriodic: false)

    init(directory: URL) async throws {
        let json = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: directory.appending(path: "vocab.json")))
        let vocabulary = Dictionary(
            uniqueKeysWithValues: json.compactMap { key, piece in Int(key).map { ($0, piece) } })
        self.vocabulary = vocabulary
        merger = WindowMerge(vocabulary: vocabulary)
        encoders = [
            (Self.melFrames, try await MLModel.load(
                contentsOf: directory.appending(path: Self.windows.source),
                configuration: MLModelConfigurationUtils.defaultConfiguration()))
        ]
        // Last, so nothing can throw once its threads run.
        guard let decoder = lf_rnnt_load(
            directory.appending(path: "parakeet_unified_decoder.mlmodelc/weights/weight.bin").path,
            directory.appending(path: "parakeet_unified_joint_decision_single_step.mlmodelc/weights/weight.bin").path)
        else { throw Failure.decoder }
        self.decoder = decoder
        // Afterwards, so dictation works meanwhile: the first load of each window compiles it (~8 s).
        loadingWindows = Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = ContinuousClock.now
            for window in Self.windows.all where !Task.isCancelled {
                guard let model = await Self.windows.load(window, in: directory) else { continue }
                guard let self else { return }
                await self.add(window.frames, model)
            }
            let ms = Int((ContinuousClock.now - t0) / .milliseconds(1))
            Self.log.info("Encoder windows ready in \(ms, privacy: .public) ms")
        }
    }

    isolated deinit {
        loadingWindows?.cancel()
        lf_rnnt_free(decoder)
    }

    /// Returns once the shorter windows are loaded (or failed to), for timing them (localflow-bench).
    func windowsLoaded() async {
        await loadingWindows?.value
    }

    private func add(_ frames: Int, _ model: MLModel) {
        encoders.append((frames, model))
        encoders.sort { $0.frames < $1.frames }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        var starts = [0]
        var start = Self.chunkSamples - Self.overlapSamples
        // A window is only needed if it adds samples beyond the previous one.
        while start + Self.overlapSamples < samples.count {
            starts.append(start)
            start += Self.chunkSamples - Self.overlapSamples
        }
        var tokens: [Token] = []
        for start in starts {
            let window = try await decode(samples, from: start)
            tokens = merger.merge(tokens, window)
        }
        tokens.sort { $0.frame < $1.frame }
        // FluidAudio collapses case-only duplicates in single windows too, where they're the speaker's
        // ("Amazing, amazing luck." became "amazing luck.": 3 of 4 such changes in the test set were wrong).
        if starts.count > 1 { tokens = merger.collapseSeamDuplicates(tokens) }
        return tokens.map { vocabulary[$0.id] ?? "" }.joined().replacing("\u{2581}", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// The tokens of the window at `start`, with the frames they were emitted at counted from the
    /// start of the recording.
    private func decode(_ samples: [Float], from start: Int) async throws -> [Token] {
        lf_rnnt_prepare(decoder)
        let valid = min(Self.chunkSamples, samples.count - start)
        var window = [Float](repeating: 0, count: Self.windowSamples)
        window.withUnsafeMutableBufferPointer { w in
            samples.withUnsafeBufferPointer { w.baseAddress!.update(from: $0.baseAddress! + start, count: valid) }
        }
        // The smallest window that holds the valid frames (NeMo's valid length has no +1: the 15 s
        // tensor's last frame is always padding).
        let (total, encoder) = encoders.first { $0.frames >= valid / Self.hop }!
        let (features, length) = try features(window, valid: valid, total: total)
        let output = try await encoder.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["mel": features, "mel_length": length]))
        guard let encoded = output.featureValue(for: "encoder")?.multiArrayValue,
            let encodedLength = output.featureValue(for: "encoder_length")?.multiArrayValue,
            encoded.dataType == .float32, encoded.shape.count == 3, encoded.strides[2].intValue == 1
        else { throw Failure.encoder }
        let frames = min(encodedLength[0].intValue, encoded.shape[2].intValue), stride = encoded.strides[1].intValue
        var ids = [Int32](repeating: 0, count: max(frames, 1) * 10)
        var emitted = ids
        let count = encoded.withUnsafeBufferPointer(ofType: Float.self) { p in
            lf_rnnt_decode(decoder, p.baseAddress, stride, Int32(frames), &ids, &emitted, Int32(ids.count))
        }
        guard count >= 0 else { throw Failure.decoder }
        let offset = start / Self.frameSamples
        return (0..<Int(count)).map { Token(id: Int(ids[$0]), frame: offset + Int(emitted[$0])) }
    }

    /// NeMo's log-mel features for a zero-padded window of `total` frames, normalized per mel bin over
    /// its `valid` samples, as FluidAudio's `UnifiedMelExtractor`.
    private func features(_ window: [Float], valid: Int, total: Int) throws -> (MLMultiArray, MLMultiArray) {
        let bins = Self.melBins
        let frames = min(valid / Self.hop, total)
        // Later frames are zeroed below, so only the audio the valid ones read is transformed: the
        // same values (frames are independent and the center padding is zeros), a third of the work
        // for a 5 s dictation.
        var x = mel.computeFlatTransposed(
            audio: window.prefix(min(window.count, valid + 512)), lastAudioSample: 0, paddingMode: .center,
            expectedFrameCount: max(frames, 1)
        ).mel
        for m in 0..<bins {
            var mean: Float = 0
            for t in 0..<frames { mean += x[t * bins + m] }
            mean /= Float(max(frames, 1))
            var squares: Float = 0
            for t in 0..<frames { squares += (x[t * bins + m] - mean) * (x[t * bins + m] - mean) }
            let std = (squares / Float(frames > 1 ? frames - 1 : 1)).squareRoot() + 1e-5
            for t in 0..<frames { x[t * bins + m] = (x[t * bins + m] - mean) / std }
        }
        let features = try MLMultiArray(shape: [1, NSNumber(value: bins), NSNumber(value: total)], dataType: .float32)
        features.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
            p.initialize(repeating: 0)
            for t in 0..<frames { for m in 0..<bins { p[m * total + t] = x[t * bins + m] } }
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: frames)
        return (features, length)
    }
}
