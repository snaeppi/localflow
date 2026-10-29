@preconcurrency import CoreML
import FluidAudio
import Foundation
import LocalflowEngine
import os

/// Parakeet TDT 0.6B v3's transcription as FluidAudio's `AsrManager` does it with `ASRConfig.default`
/// (the same preprocessor, encoder, retries of windows decoded to nothing and, past 15 s, the same
/// windows, merge and seam repair) but with the decoder in LocalflowEngine instead of two CoreML models
/// called once per step: ~35 ms of a dictation on cold cores became ~3 ms, with the same tokens but
/// at decision ties (bench/README.md). Recordings that leave room in shorter copies of the
/// preprocessor and encoder (`ShorterWindows`) use them: the encoder's layers mask everything past
/// `mel_length` but the subsampling, whose stride-2 convolutions let the last valid frame read 7 mel
/// frames further, so a window needs 6 to spare.
actor ParakeetV3 {
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

    /// How a window's length is declared to the models (FluidAudio's InferenceLengthPolicy). The
    /// flags are its retries for a window of sound decoded to nothing (FluidAudio issue #909: v3 has
    /// cuts on which the joint never beats blank), tried in this order until one is credible.
    private struct LengthPolicy: OptionSet {
        let rawValue: Int
        static let encoderFull = LengthPolicy(rawValue: 1)       // the padding declared valid to the encoder
        static let preprocessorFull = LengthPolicy(rawValue: 2)  // to the preprocessor
        static let trimmedTail = LengthPolicy(rawValue: 4)       // the audio declared 0.2 s shorter, that tail silenced
        static let retries: [LengthPolicy] = [
            .encoderFull, .preprocessorFull, .trimmedTail, [.trimmedTail, .encoderFull], [.trimmedTail, .preprocessorFull],
        ]
    }

    private static let sampleRate = 16_000
    private static let windowSamples = 15 * sampleRate      // the preprocessor's fixed input
    private static let frameSamples = 1280                  // one encoder frame, 80 ms
    private static let frameSeconds = ASRConstants.secondsPerEncoderFrame
    private static let melFrames = windowSamples / 160 + 1
    private static let maxTokens = 160                      // per window: 150, then the end-of-audio flush
    private static let log = Logger(subsystem: "io.github.snaeppi.localflow", category: "asr")
    /// 63 and 127 encoder frames: on the M4 Pro their output was the 15 s window's bit for bit, where
    /// 64 and 128, as fast, differed by fp16 rounding (bench/README.md). They hold up to 4.96 and
    /// 10.08 s; the preprocessor's copies, as long, give the 15 s one's first frames.
    private static let preprocessorWindows = ShorterWindows(
        graph: .v3Preprocessor, source: "Preprocessor.mlmodelc",
        all: [
            (frames: 503, sha256: "04eaec5300ca02e74c25bec5c97034e5d865c0b1a1118ddddf89f2e7993d03fb"),
            (frames: 1015, sha256: "67f44efc55f4f53e5c6267180db3baa2f5699ced3dd32c80f6759be0585d70ed"),
        ])
    private static let encoderWindows = ShorterWindows(
        graph: .v3Encoder, source: "Encoder.mlmodelc",
        all: [
            (frames: 503, sha256: "a67ceea9ceb89bac17e9bfad9a713bcf92de2df42fa535acdbb01d858f85301a"),
            (frames: 1015, sha256: "b185bbc8bdc4191627e1fc9b737f2b5d6f1af721c1fd1c7b81dd03e829e9d51d"),
        ])

    /// By mel frames, ascending: the shorter windows as they finish loading, and the 15 s ones.
    private var preprocessors: [(frames: Int, model: MLModel)]
    private var encoders: [(frames: Int, model: MLModel)]
    private var loadingWindows: Task<Void, Never>?
    private let decoder: OpaquePointer
    private let merger: WindowMerge

    init(directory: URL) async throws {
        let json = try JSONDecoder().decode(
            [String: String].self, from: Data(contentsOf: directory.appending(path: "parakeet_vocab.json")))
        merger = WindowMerge(
            vocabulary: Dictionary(uniqueKeysWithValues: json.compactMap { key, piece in Int(key).map { ($0, piece) } }))
        // As FluidAudio's AsrModels.loadLocal: the preprocessor on the CPU, the encoder on the Neural Engine.
        preprocessors = [
            (Self.melFrames, try await MLModel.load(
                contentsOf: directory.appending(path: Self.preprocessorWindows.source),
                configuration: MLModelConfigurationUtils.defaultConfiguration(computeUnits: .cpuOnly)))
        ]
        encoders = [
            (Self.melFrames, try await MLModel.load(
                contentsOf: directory.appending(path: Self.encoderWindows.source),
                configuration: AsrModels.defaultConfiguration()))
        ]
        // Last, so nothing can throw once its threads run.
        guard let decoder = lf_tdt_load(
            directory.appending(path: "Decoder.mlmodelc/weights/weight.bin").path,
            directory.appending(path: "JointDecisionv3.mlmodelc/weights/weight.bin").path)
        else { throw Failure.decoder }
        self.decoder = decoder
        // Afterwards, so dictation works meanwhile: the first load of each window compiles it (~12 s).
        loadingWindows = Task.detached(priority: .userInitiated) { [weak self] in
            let t0 = ContinuousClock.now
            for (pre, enc) in zip(Self.preprocessorWindows.all, Self.encoderWindows.all) where !Task.isCancelled {
                let preprocessor = await Self.preprocessorWindows.load(pre, in: directory)
                let encoder = await Self.encoderWindows.load(enc, in: directory)
                guard let self else { return }
                await self.add(preprocessor.map { (pre.frames, $0) }, encoder.map { (enc.frames, $0) })
            }
            let ms = Int((ContinuousClock.now - t0) / .milliseconds(1))
            Self.log.info("Windows ready in \(ms, privacy: .public) ms")
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

    private func add(_ preprocessor: (frames: Int, model: MLModel)?, _ encoder: (frames: Int, model: MLModel)?) {
        if let preprocessor {
            preprocessors.append(preprocessor)
            preprocessors.sort { $0.frames < $1.frames }
        }
        if let encoder {
            encoders.append(encoder)
            encoders.sort { $0.frames < $1.frames }
        }
    }

    func transcribe(_ samples: [Float]) async throws -> String {
        let tokens: [Token]
        if samples.count <= Self.windowSamples {
            // Zero-padded to a whole encoder frame, as FluidAudio's frameAlignedAudio.
            let aligned = (samples.count + Self.frameSamples - 1) / Self.frameSamples * Self.frameSamples
            let length = aligned <= Self.windowSamples ? aligned : samples.count
            tokens = try await window(samples, length: length, last: true)
        } else {
            tokens = try await longRecording(samples)
        }
        return tokens.compactMap { merger.vocabulary[$0.id] }.filter { !$0.isEmpty }.joined()
            .replacing("\u{2581}", with: " ").trimmingCharacters(in: .whitespaces)
    }

    // MARK: One window

    /// The tokens of a window of up to 15 s (FluidAudio's executeMLInferenceWithTimings): `length`
    /// samples of `audio` are declared valid; frames count from `offset`, and tokens emitted before
    /// frame `emitFrom` (the part of the window that only warms the decoder up) are dropped.
    private func window(_ audio: [Float], length: Int, offset: Int = 0, emitFrom: Int? = nil, last: Bool)
        async throws -> [Token]
    {
        var padded = audio
        padded += [Float](repeating: 0, count: Self.windowSamples - audio.count)
        // A retry needs 2 s of audio that isn't silence (RMS −50 dBFS).
        let span = min(length, padded.count)
        var energy = 0.0
        for i in 0..<span { energy += Double(padded[i] * padded[i]) }
        let retry = span >= 2 * Self.sampleRate && (energy / Double(span)).squareRoot() >= Double(Float(0.003))
        let first = try await infer(padded, length: length, offset: offset, emitFrom: emitFrom, last: last, policy: [])
        guard first.emitted.isEmpty, first.suppressed == 0, retry else { return first.emitted }
        for policy in LengthPolicy.retries {
            let attempt = try await infer(
                padded, length: length, offset: offset, emitFrom: emitFrom, last: last, policy: policy)
            // Credible: 2 tokens or more with a mean probability of 0.7, which noise doesn't reach.
            guard attempt.emitted.count >= 2,
                attempt.probabilities.reduce(0, +) / Float(attempt.probabilities.count) >= 0.7
            else { continue }
            Self.log.info("Empty window recovered (\(policy.rawValue, privacy: .public))")
            return attempt.emitted
        }
        return first.emitted
    }

    /// One pass of the models over a padded window (FluidAudio's runInference).
    private func infer(
        _ padded: [Float], length: Int, offset: Int, emitFrom: Int?, last: Bool, policy: LengthPolicy
    ) async throws -> (emitted: [Token], probabilities: [Float], suppressed: Int) {
        // .trimmedTail: 0.2 s shorter on a frame boundary, and those samples silenced.
        let trimmed = max(2 * Self.sampleRate, length - Self.sampleRate / 5) / Self.frameSamples * Self.frameSamples
        let effective = policy.contains(.trimmedTail) ? trimmed : length
        var input = padded
        if policy.contains(.trimmedTail), effective < input.count {
            for i in effective..<min(input.count, length) { input[i] = 0 }
        }
        lf_rnnt_prepare(decoder)
        // The smallest window whose subsampling sees the valid frames' whole reach (8 mel frames per
        // encoder frame; the preprocessor makes declared / 160 + 1 frames valid). The padding
        // declared valid needs the 15 s ones.
        let declared = policy.contains(.preprocessorFull) ? Self.windowSamples : effective
        let reach = 8 * ShorterWindows.stages(declared / 160 + 1).2 - 1
        let (frames, encoder) = policy.isDisjoint(with: [.encoderFull, .preprocessorFull])
            ? encoders.first { $0.frames >= reach } ?? encoders[encoders.count - 1] : encoders[encoders.count - 1]
        let (total, preprocessor) = preprocessors.first { $0.frames >= frames } ?? preprocessors[preprocessors.count - 1]
        let samples = ShorterWindows.samples(total)
        let audio = try MLMultiArray(shape: [1, NSNumber(value: samples)], dataType: .float32)
        input.withUnsafeBufferPointer { source in
            audio.withUnsafeMutableBufferPointer(ofType: Float.self) { p, _ in
                p.baseAddress!.update(from: source.baseAddress!, count: samples)
            }
        }
        let length = try MLMultiArray(shape: [1], dataType: .int32)
        length[0] = NSNumber(value: declared)
        let features = try await preprocessor.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["audio_signal": audio, "audio_length": length]))
        guard var mel = features.featureValue(for: "mel")?.multiArrayValue,
            var melLength = features.featureValue(for: "mel_length")?.multiArrayValue,
            mel.dataType == .float32, mel.shape.count == 3, mel.shape[2].intValue == total, mel.strides[2] == 1
        else { throw Failure.encoder }
        if policy.contains(.encoderFull) {
            melLength = try MLMultiArray(shape: [1], dataType: .int32)
            melLength[0] = mel.shape[2]
        }
        if frames < total {
            // The first frames of the longer features: the preprocessor zeroes those past mel_length.
            let window = try MLMultiArray(shape: [1, 128, NSNumber(value: frames)], dataType: .float32)
            let stride = mel.strides[1].intValue
            mel.withUnsafeBufferPointer(ofType: Float.self) { source in
                window.withUnsafeMutableBufferPointer(ofType: Float.self) { p, strides in
                    for m in 0..<128 {
                        p.baseAddress!.advanced(by: m * strides[1]).update(from: source.baseAddress! + m * stride, count: frames)
                    }
                }
            }
            mel = window
        }
        let output = try await encoder.prediction(
            from: MLDictionaryFeatureProvider(dictionary: ["mel": mel, "mel_length": melLength]))
        guard let encoded = output.featureValue(for: "encoder")?.multiArrayValue,
            let encodedLength = output.featureValue(for: "encoder_length")?.multiArrayValue,
            encoded.dataType == .float32, encoded.shape.count == 3, encoded.strides[2].intValue == 1
        else { throw Failure.encoder }
        let valid = (effective + Self.frameSamples - 1) / Self.frameSamples
        var ids = [Int32](repeating: 0, count: Self.maxTokens), emitted = ids, durations = ids
        var probabilities = [Float](repeating: 0, count: Self.maxTokens)
        let count = encoded.withUnsafeBufferPointer(ofType: Float.self) { p in
            lf_tdt_decode(
                decoder, p.baseAddress, encoded.strides[1].intValue,
                Int32(min(encodedLength[0].intValue, encoded.shape[2].intValue)), Int32(valid), last,
                &ids, &emitted, &durations, &probabilities, Int32(Self.maxTokens))
        }
        guard count >= 0 else { throw Failure.decoder }
        var result: (emitted: [Token], probabilities: [Float], suppressed: Int) = ([], [], 0)
        for i in 0..<Int(count) {
            let frame = offset + Int(emitted[i])
            if let emitFrom, frame < emitFrom {
                result.suppressed += 1
                continue
            }
            result.emitted.append(Token(id: Int(ids[i]), frame: frame, duration: Int(durations[i])))
            result.probabilities.append(probabilities[i])
        }
        return result
    }

    // MARK: Longer recordings
    // FluidAudio 0.17.7's ChunkProcessor.process (Apache 2.0) as it runs for v3 with ASRConfig.default:
    // 15 s windows starting near silence, the last one ending at the last speech and filled backwards
    // with audio whose tokens are dropped, the windows merged, and gaps that hold speech decoded again.

    private static let chunkSamples = (windowSamples - 160) / frameSamples * frameSamples
    private static let strideSamples = chunkSamples - 2 * sampleRate / frameSamples * frameSamples
    private static let speechFloor: Float = 0.0005          // RMS below the quietest speech, −66 dBFS

    private func longRecording(_ samples: [Float]) async throws -> [Token] {
        let total = samples.count
        let starts = Self.starts(samples)
        let speechEnd = Self.speechEnd(samples)
        var outputs: [[Token]] = []
        var start = starts[0]
        while start < total {
            // The last window is filled backwards with audio before its start rather than padded.
            var warmup = 0
            let remaining = min(speechEnd, total) - start
            if start + Self.chunkSamples >= total, remaining > 0, start > 0 {
                let fill = (Self.chunkSamples - remaining) / Self.frameSamples * Self.frameSamples
                if fill > 0 { warmup = min(start / Self.frameSamples * Self.frameSamples, fill) }
            }
            let visibleEnd = start + max(Self.frameSamples, Self.chunkSamples - warmup)
            let isLast = visibleEnd >= total
            let end = isLast ? min(total, speechEnd) : visibleEnd
            guard end > start else { break }
            let from = start - warmup
            let audio = Array(samples[from..<end])
            outputs.append(
                try await window(
                    audio, length: audio.count, offset: from / Self.frameSamples,
                    emitFrom: warmup > 0 ? start / Self.frameSamples : nil, last: isLast))
            if isLast { break }
            start = outputs.count < starts.count ? starts[outputs.count] : start + Self.strideSamples
        }
        guard var tokens = outputs.first else { return [] }
        for window in outputs.dropFirst() { tokens = merger.merge(tokens, window) }
        // Timestamps made non-decreasing without reordering: the merge's order is the text's.
        for i in tokens.indices.dropFirst() where tokens[i].frame < tokens[i - 1].frame {
            tokens[i].frame = tokens[i - 1].frame
        }
        guard outputs.count > 1 else { return tokens }
        tokens = merger.collapseSeamDuplicates(tokens)
        return tokens.count > 1 ? try await repairGaps(tokens, in: samples) : tokens
    }

    /// Where the windows start: every 12.96 s (15 s windows overlapping by 2 s), each moved to the
    /// quietest frame boundary within 4 s if that is near silence, else within 0.5 s if it is a clear
    /// valley, keeping at least 0.48 s of overlap (FluidAudio's silenceAlignedChunkStarts).
    private static func starts(_ samples: [Float]) -> [Int] {
        let total = samples.count, frame = frameSamples
        func energy(around center: Int) -> Float {
            let range = max(0, center - frame)..<min(total, center + frame)
            guard !range.isEmpty else { return 0 }
            var sum: Float = 0
            for i in range { sum += samples[i] * samples[i] }
            return sum / Float(range.count)
        }
        var starts = [0], previous = 0, target = strideSamples
        while target < total {
            let targetFrame = target / frame
            let latest = previous + chunkSamples - 6 * frame
            let targetStart = min(max(targetFrame * frame, previous + frame), latest)
            /// The quietest boundary within `radius` frames, and the median of the boundaries' energies.
            func quietest(radius: Int) -> (start: Int, score: Float, median: Float) {
                var best = (start: targetStart, score: Float.greatestFiniteMagnitude)
                var scores: [Float] = []
                let lower = max(1, targetFrame - radius), upper = min((total - 1) / frame, targetFrame + radius)
                if lower <= upper {
                    for candidate in (lower...upper).map({ $0 * frame }) where candidate > previous && candidate <= latest {
                        let score = energy(around: candidate)
                        scores.append(score)
                        if score < best.score { best = (candidate, score) }
                    }
                }
                guard !scores.isEmpty else { return (targetStart, .greatestFiniteMagnitude, 0) }
                return (best.start, best.score, scores.sorted()[scores.count / 2])
            }
            let silence = quietest(radius: 4 * sampleRate / frame)
            var start: Int
            if silence.score <= (silence.median > 0 ? silence.median * 0.05 : 0) {
                start = silence.start
            } else {
                let valley = quietest(radius: sampleRate / 2 / frame)
                start = valley.score <= (valley.median > 0 ? valley.median * 0.35 : 0) ? valley.start : targetStart
            }
            if start <= previous { start = min(previous + strideSamples, total) }
            starts.append(start)
            previous = start
            target += strideSamples
        }
        return starts
    }

    /// The end of the last frame louder than `speechFloor`: a window ending in silence decodes badly.
    private static func speechEnd(_ samples: [Float]) -> Int {
        var end = samples.count
        while end > 0 {
            let start = max(0, end - frameSamples)
            if rms(samples[start..<end]) >= speechFloor { return end }
            end = start
        }
        return samples.count
    }

    private static func rms(_ samples: ArraySlice<Float>) -> Float {
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// Gaps of 1.5 s or more between tokens that hold 0.5 s of speech, decoded again in a window of
    /// their own (starting at the gap, else centred on it), splicing in only the tokens inside the gap
    /// (FluidAudio's repairSeamGaps, issue #758). Three rounds, 32 gaps at most.
    private func repairGaps(_ tokens: [Token], in samples: [Float]) async throws -> [Token] {
        let total = samples.count, frame = Self.frameSamples
        // Speech is judged against the recording's own level: 0.3 of the 75th percentile of the frames'
        // RMS (digital silence left out), between −66 and −42 dBFS.
        var levels: [Float] = []
        for start in stride(from: 0, through: total - frame, by: frame) {
            var sum: Float = 0
            for sample in samples[start..<start + frame] { sum += sample * sample }
            if sum > 0 { levels.append((sum / Float(frame)).squareRoot()) }
        }
        levels.sort()
        let reference = levels.isEmpty ? 0 : levels[min(levels.count - 1, Int(Double(levels.count) * 0.75))]
        let threshold: Float = levels.isEmpty ? 0.008 : min(0.008, max(Self.speechFloor, reference * 0.3))
        let minGap = max(2, Int(1.5 / Self.frameSeconds))
        let vocabulary = merger.vocabulary
        func punctuation(_ id: Int) -> Bool {
            guard let piece = vocabulary[id], !piece.isEmpty else { return false }
            return piece.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
            }
        }
        func samePiece(_ a: Int, _ b: Int) -> Bool {
            if a == b { return true }
            guard let pieceA = vocabulary[a], let pieceB = vocabulary[b] else { return false }
            return pieceA.lowercased() == pieceB.lowercased()
        }
        /// The token of the word next to a gap, past punctuation.
        func neighbour(_ stream: [Token], from index: Int, step: Int) -> Token {
            var i = index
            while i + step >= 0, i + step < stream.count, punctuation(stream[i].id) { i += step }
            return stream[i]
        }

        var working = tokens, probes = 0
        var probed = Set<Int>()
        for _ in 0..<3 {
            var inserts: [Token] = []
            for index in 0..<(working.count - 1) {
                guard probes < 32 else { break }
                let gapStart = working[index].frame + max(1, working[index].duration)
                let gapEnd = working[index + 1].frame
                guard gapEnd - gapStart >= minGap, !probed.contains(gapStart) else { continue }
                let startSample = gapStart * frame, endSample = min(gapEnd * frame, total)
                guard endSample > startSample else { continue }
                let speech = stride(from: startSample, through: endSample - frame, by: frame)
                    .filter { Self.rms(samples[$0..<$0 + frame]) > threshold }.count
                guard Double(speech) * Self.frameSeconds >= 0.5 else { continue }
                probed.insert(gapStart)
                probes += 1
                let lead = neighbour(working, from: index, step: -1)
                let tail = neighbour(working, from: index + 1, step: 1)
                for placement in [startSample, (startSample + endSample) / 2 - Self.chunkSamples / 2] {
                    let from = max(0, min(placement, total - Self.chunkSamples)) / frame * frame
                    let to = min(from + Self.chunkSamples, total)
                    guard to > from else { continue }
                    let decoded = try await window(
                        Array(samples[from..<to]), length: to - from, offset: from / frame, last: to >= total)
                    // Only tokens strictly inside the gap, from a word start, minus border words heard again.
                    var candidate = decoded.filter { $0.frame > gapStart && $0.frame < gapEnd - 1 }
                    while let first = candidate.first, !merger.spliceSafe.contains(first.id) { candidate.removeFirst() }
                    while let first = candidate.first, samePiece(first.id, lead.id), abs(first.frame - lead.frame) <= 6 {
                        candidate.removeFirst()
                    }
                    while let last = candidate.last, samePiece(last.id, tail.id), abs(tail.frame - last.frame) <= 6 {
                        candidate.removeLast()
                    }
                    while let first = candidate.first, !merger.spliceSafe.contains(first.id) || punctuation(first.id) {
                        candidate.removeFirst()
                    }
                    if !candidate.isEmpty {
                        inserts += candidate
                        break
                    }
                }
            }
            guard !inserts.isEmpty else { break }
            working += inserts
            working.sort { $0.frame < $1.frame }
        }
        return working
    }
}
