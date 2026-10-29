import FluidAudio
import Foundation
import os

/// On-device speech-to-text with NVIDIA Parakeet on the Neural Engine: Unified 0.6B for English
/// (punctuated and capitalized; `ParakeetUnified`) or TDT v3 0.6B for 25 European languages
/// (`ParakeetV3`), both with FluidAudio's models and pipelines and Localflow's own decoders
/// (`SpeechModels`).
///
/// Chosen from benchmarks on an M4 Pro (see bench/README.md): on dictation-style speech Unified matches
/// Cohere Transcribe 2B's accuracy at ~50 ms per utterance, and unlike GPU models its latency doesn't
/// degrade while other GPU work (e.g. training) is running.
///
/// The models are downloaded by `SpeechModels` and FluidAudio's own downloader is switched off, so
/// nothing here touches the network.
actor Transcriber {
    enum Failure: LocalizedError {
        case modelMissing
        case notLoaded
        var errorDescription: String? {
            switch self {
            case .modelMissing: "No speech model"
            case .notLoaded: "Speech model is not loaded"
            }
        }
    }

    private enum Manager {
        case unified(ParakeetUnified)
        case v3(ParakeetV3)
    }

    private var manager: Manager?
    private var kind: SpeechModels.Kind?
    private let log = Logger(subsystem: "io.github.snaeppi.localflow", category: "asr")

    init() {
        ModelHub.offlineMode = true
    }

    /// Loads `kind` unless it's loaded already, replacing another model.
    func load(_ kind: SpeechModels.Kind) async throws {
        if manager != nil, self.kind == kind { return }
        unload()
        let directory = kind.directory
        guard FileManager.default.fileExists(atPath: directory.path) else { throw Failure.modelMissing }
        let t0 = ContinuousClock.now
        let manager: Manager
        switch kind {
        case .english:
            manager = .unified(try await ParakeetUnified(directory: directory))
        case .multilingual:
            manager = .v3(try await ParakeetV3(directory: directory))
        }
        self.manager = manager
        self.kind = kind
        // The first inference places the encoder on the Neural Engine; pay that now rather
        // than on the user's first dictation. (After a download, or after the app folder moved,
        // CoreML also compiles the model once, which takes several seconds.)
        _ = try? await transcribe(Self.warmupAudio)
        log.info("Model \(kind.rawValue, privacy: .public) ready in \((ContinuousClock.now - t0).milliseconds, privacy: .public) ms")
    }

    /// Frees the model (Advanced settings › Model active duration). Loading it again takes ~60 ms plus
    /// the ~60 ms warm-up (measured with localflow-bench on an M4 Pro), done while the user speaks.
    func unload() {
        guard manager != nil else { return }
        manager = nil   // the pipelines' deinits free them
        kind = nil
        log.info("Model unloaded")
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        guard let manager else { throw Failure.notLoaded }
        var audio = samples
        // Very short clips are padded with silence to one second.
        if audio.count < 16_000 { audio += [Float](repeating: 0, count: 16_000 - audio.count) }
        switch manager {
        case .unified(let unified):
            return Self.finalize(try await unified.transcribe(audio))
        case .v3(let v3):
            return Self.finalize(try await v3.transcribe(audio))
        }
    }

    /// Parakeet often omits the closing period when the audio stops right at the last word,
    /// as push-to-talk clips do. Closing multi-word dictations consistently cut formatting
    /// errors by 10–30% in testing (bench/README.md); one- and two-word inputs such as search
    /// terms are left alone.
    static func finalize(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last, last.isLetter || last.isNumber || "%)\"'".contains(last),
            text.split(separator: " ").count >= 3
        else { return text }
        return text + "."
    }

    /// One second of faint noise: enough to exercise the whole pipeline.
    private static let warmupAudio: [Float] = (0..<16_000).map { _ in Float.random(in: -0.001...0.001) }
}
