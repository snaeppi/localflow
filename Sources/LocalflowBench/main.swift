// Offline ASR benchmark harness: runs one engine over a manifest of 16 kHz clips and writes
// per-clip hypotheses + latencies (JSONL) and a run summary (JSON). Scoring happens in
// bench/score.py so every engine (Swift or Python) is normalized identically.
//
// usage: localflow-bench <engine> <manifest.jsonl> <out-prefix> [--limit N]
//   engines: parakeet-v2 parakeet-v3 parakeet-v3-localflow parakeet-ultra phonon2 parakeet-unified
//            parakeet-unified-vocab parakeet-unified-localflow cohere apple-speech

@preconcurrency import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Speech

struct Clip: Decodable {
    let id: String
    let audio: String
    let duration: Double
    /// Terms for vocabulary boosting (`parakeet-unified-vocab` only).
    let dictionary: [String]?
}

protocol Engine: AnyObject {
    /// Fetch weights if missing (untimed).
    func prepare() async throws
    /// Load weights into memory / compile (timed).
    func load() async throws
    func transcribe(_ samples: [Float]) async throws -> String
}

final class ParakeetEngine: Engine {
    let version: AsrModelVersion
    var dir: URL?
    var manager: AsrManager?
    var layers = 2

    init(_ version: AsrModelVersion) { self.version = version }

    func prepare() async throws { dir = try await AsrModels.download(version: version) }

    func load() async throws {
        let models = try await AsrModels.load(from: dir!, version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        layers = await manager.decoderLayerCount
        self.manager = manager
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        var state = TdtDecoderState.make(decoderLayers: layers)
        return try await manager!.transcribe(samples, decoderState: &state).text
    }
}

final class UnifiedEngine: Engine {
    let manager = UnifiedAsrManager()
    func prepare() async throws { try await manager.loadModels(to: nil) }
    func load() async throws {
        // prepare() already loaded; reload from cache to time a cold-ish load.
        try await manager.loadModels(to: nil)
    }
    func transcribe(_ samples: [Float]) async throws -> String {
        try await manager.transcribe(samples)
    }
}

/// Parakeet Unified as the app runs it (ParakeetUnified.swift, a symlink to the app's file): FluidAudio's
/// features, encoder and window merge with LocalflowEngine's RNNT decoder.
final class LocalflowUnifiedEngine: Engine {
    var model: ParakeetUnified?
    func prepare() async throws { try await UnifiedAsrManager().loadModels(to: nil) }
    func load() async throws {
        let models = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "FluidAudio/Models")
        model = try await ParakeetUnified(directory: models.appending(path: Repo.parakeetUnified.folderName))
        await model!.windowsLoaded()
    }
    func transcribe(_ samples: [Float]) async throws -> String { try await model!.transcribe(samples) }
}

/// Parakeet v3 as the app runs it (ParakeetV3.swift, a symlink to the app's file): FluidAudio's preprocessor,
/// encoder, windows and merge with LocalflowEngine's TDT decoder, on the app's copy of the model (Settings › Models).
final class LocalflowV3Engine: Engine {
    let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Localflow/models/parakeet-tdt-0.6b-v3")
    var model: ParakeetV3?
    func prepare() async throws {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: directory.path])
        }
    }
    func load() async throws {
        model = try await ParakeetV3(directory: directory)
        await model!.windowsLoaded()
    }
    func transcribe(_ samples: [Float]) async throws -> String { try await model!.transcribe(samples) }
}

/// Parakeet Unified plus FluidAudio's CTC vocabulary boosting (parakeet-ctc-110m keyword
/// spotting + rescoring) with each clip's `dictionary`; clips without one run unboosted.
final class UnifiedVocabEngine: Engine {
    var plain = UnifiedAsrManager()
    var boosted: UnifiedAsrManager?
    var ctc: CtcModels?
    var terms: [String] = []

    func prepare() async throws {
        try await plain.loadModels(to: nil)
        ctc = try await CtcModels.downloadAndLoad(variant: .ctc110m)
    }
    func load() async throws { try await plain.loadModels(to: nil) }

    func use(_ dictionary: [String]?) async throws {
        let dictionary = dictionary ?? []
        guard dictionary != terms else { return }
        terms = dictionary
        guard !dictionary.isEmpty else { boosted = nil; return }
        if boosted == nil {
            boosted = UnifiedAsrManager()
            try await boosted!.loadModels(to: nil)
        }
        let context = CustomVocabularyContext(terms: dictionary.map { CustomVocabularyTerm(text: $0) })
        let t = now()
        try await boosted!.configureVocabularyBoosting(vocabulary: context, ctcModels: ctc!)
        FileHandle.standardError.write(Data(String(format: "configured %d terms in %.0f ms\n", dictionary.count, now() - t).utf8))
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        try await (terms.isEmpty ? plain : boosted!).transcribe(samples)
    }
}

final class CohereEngine: Engine {
    let pipeline = CoherePipeline()
    var models: CoherePipeline.LoadedModels?
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models")

    func prepare() async throws {
        let target = dir.appendingPathComponent("cohere-transcribe/q8")
        if !FileManager.default.fileExists(atPath: target.appendingPathComponent("vocab.json").path) {
            try await ModelHub.download(.cohereTranscribeCoreml, to: dir)
        }
    }

    func load() async throws {
        let target = dir.appendingPathComponent("cohere-transcribe/q8")
        models = try await CoherePipeline.loadModels(encoderDir: target, decoderDir: target, vocabDir: target)
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let r = try await pipeline.transcribe(audio: samples, models: models!, language: .english)
        if ProcessInfo.processInfo.environment["BENCH_BREAKDOWN"] != nil {
            FileHandle.standardError.write(Data(String(format: "enc %.0f ms  dec %.0f ms  tokens %d\n", r.encoderSeconds * 1000, r.decoderSeconds * 1000, r.tokenIds.count).utf8))
        }
        return r.text
    }
}

final class AppleSpeechEngine: Engine {
    let locale = Locale(identifier: "en-US")
    var format: AVAudioFormat?

    func prepare() async throws {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            try await request.downloadAndInstall()
        }
    }

    func load() async throws {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module])
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let module = SpeechTranscriber(locale: locale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [module])
        let buffer = try convert(samples, to: format!)
        let collector = Task {
            var text = ""
            for try await result in module.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        continuation.yield(AnalyzerInput(buffer: buffer))
        continuation.finish()
        try await analyzer.start(inputSequence: stream)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        return try await collector.value.trimmingCharacters(in: .whitespaces)
    }

    private func convert(_ samples: [Float], to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let input = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(samples.count))!
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        if format == src { return input }
        let converter = AVAudioConverter(from: src, to: format)!
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / 16000) + 1024
        let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity)!
        nonisolated(unsafe) var fed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        if let error { throw error }
        return output
    }
}

func readSamples(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    precondition(file.processingFormat.sampleRate == 16000 && file.processingFormat.channelCount == 1)
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

func makeEngine(_ name: String) -> Engine? {
    switch name {
    case "parakeet-v2": ParakeetEngine(.v2)
    case "parakeet-v3": ParakeetEngine(.v3)
    case "parakeet-v3-localflow": LocalflowV3Engine()
    case "parakeet-ultra": ParakeetEngine(.ultra)
    case "phonon2": ParakeetEngine(.phonon2)
    case "parakeet-unified": UnifiedEngine()
    case "parakeet-unified-vocab": UnifiedVocabEngine()
    case "parakeet-unified-localflow": LocalflowUnifiedEngine()
    case "cohere": CohereEngine()
    case "apple-speech": AppleSpeechEngine()
    default: nil
    }
}

// Not @main: with the app's files symlinked next to it (AudioProcessing, ParakeetUnified, ParakeetV3,
// ShorterWindows, WindowMerge), SwiftPM compiles main.swift as top-level code, which can't carry @main.
struct Bench {
    static func main() async throws {
        var args = Array(CommandLine.arguments.dropFirst())
        var limit = Int.max
        if let i = args.firstIndex(of: "--limit") {
            limit = Int(args[i + 1])!
            args.removeSubrange(i...(i + 1))
        }
        guard args.count == 3 else {
            print("usage: localflow-bench <engine> <manifest.jsonl> <out-prefix> [--limit N]")
            exit(2)
        }
        let (name, manifestURL, outPrefix) = (args[0], URL(fileURLWithPath: args[1]), args[2])
        guard let engine = makeEngine(name) else { fatalError("unknown engine \(name)") }

        let base = manifestURL.deletingLastPathComponent()
        let clips = try String(contentsOf: manifestURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
            .prefix(limit)

        try await engine.prepare()
        let mem0 = footprintMB()
        var t = now()
        try await engine.load()
        let loadMs = now() - t

        // First inference pays any remaining compile / ANE residency cost.
        let warm = try readSamples(base.appendingPathComponent(clips.first!.audio))
        t = now()
        _ = try await engine.transcribe(warm)
        let firstMs = now() - t

        FileManager.default.createFile(atPath: outPrefix + ".jsonl", contents: nil)
        let out = try FileHandle(forWritingTo: URL(fileURLWithPath: outPrefix + ".jsonl"))
        var peak = footprintMB()
        var totalAudio = 0.0
        var totalMs = 0.0
        // Dictation cadence: an idle gap before each clip, as between dictations.
        let env = ProcessInfo.processInfo.environment
        let idleMs = Int(env["BENCH_IDLE_MS"] ?? "0") ?? 0
        let padMs = Int(env["BENCH_PAD_MS"] ?? "0") ?? 0  // Trailing silence appended to every clip.
        // Audio processing as in the app (Sources/LocalflowApp/AudioProcessing.swift), timed apart from transcription.
        let silenceRemoval = env["BENCH_SILENCE_REMOVAL"] == "1"
        let normalization = env["BENCH_NORMALIZE"] == "1"
        for clip in clips {
            var samples = try readSamples(base.appendingPathComponent(clip.audio))
            let noise = Float(env["BENCH_PAD_NOISE"] ?? "0") ?? 0  // RMS of the padding (0 = digital silence)
            samples += (0..<(padMs * 16)).map { _ in noise * Float.random(in: -1.732...1.732) }
            t = now()
            if normalization { samples = AudioProcessing.normalize(samples) }
            if silenceRemoval { samples = AudioProcessing.removeSilence(samples) }
            let procMs = now() - t
            if idleMs > 0 { try await Task.sleep(for: .milliseconds(idleMs)) }
            if let engine = engine as? UnifiedVocabEngine { try await engine.use(clip.dictionary) }
            t = now()
            let hyp = try await engine.transcribe(samples)
            let ms = now() - t
            totalAudio += clip.duration
            totalMs += ms
            peak = max(peak, footprintMB())
            let line = try JSONSerialization.data(withJSONObject: [
                "id": clip.id, "hyp": hyp, "ms": ms, "proc_ms": procMs, "audio_s": Double(samples.count) / 16_000,
            ])
            out.write(line + Data("\n".utf8))
        }
        try out.close()
        let summary: [String: Any] = [
            "engine": name, "clips": clips.count, "load_ms": loadMs, "first_ms": firstMs,
            "rtfx": totalAudio / (totalMs / 1000), "footprint_before_mb": mem0, "footprint_peak_mb": peak,
        ]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: outPrefix + ".summary.json"))
        print(String(data: try JSONSerialization.data(withJSONObject: summary, options: .sortedKeys), encoding: .utf8)!)
    }
}

try await Bench.main()
