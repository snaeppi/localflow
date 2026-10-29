import Accelerate
import Foundation

/// Optional processing of a finished recording before transcription (Advanced settings › Audio processing).
///
/// Both functions take and return 16 kHz mono samples and are pure. A 15-minute recording takes about 5 ms
/// (silence removal) and 17 ms (normalization) on an M4 Pro.
enum AudioProcessing {
    // MARK: Silence removal

    /// Analysis frame. Short enough to follow word onsets, long enough for a steady RMS.
    private static let silenceFrame = 0.02
    /// Noise floor and speech level are taken as percentiles of the frame levels, so no voice-activity model
    /// is needed and the gate adapts to each room and microphone.
    private static let floorPercentile = 0.10
    private static let speechPercentile = 0.95
    /// Less contrast than this between speech and floor means the gate can't tell them apart (continuous
    /// speech, a noisy room): leave the recording alone.
    private static let minimumContrastDB: Float = 12
    /// The threshold sits above the floor by the larger of a fixed margin and a share of the contrast.
    private static let minimumMarginDB: Float = 6
    private static let marginShare: Float = 0.3
    /// Soft onsets (f, th, h) and trailing-off endings sit below the threshold; keeping this much on both
    /// sides of every speech run keeps them.
    private static let speechPadding = 0.2
    /// Pauses longer than this are cut down to it (half from each end); the edges of the recording to `keptEdge`.
    private static let keptPause = 0.5
    private static let keptEdge = 0.25
    /// Linear crossfade at every cut, so the join doesn't click.
    private static let crossfade = 0.005
    private static let minimumFrames = 10

    /// Shortens long pauses and trims silence at both ends, without touching speech. Returns the input
    /// unchanged when there's nothing to cut or speech and background don't differ clearly.
    ///
    /// Levels are judged against the whole recording, so speech 20 dB or more below the rest of it can be mistaken
    /// for a pause. Run `normalize` first when both are on: that evens the levels out.
    static func removeSilence(_ samples: [Float], sampleRate: Double = 16_000) -> [Float] {
        let frameLength = Int(silenceFrame * sampleRate)
        let frameCount = samples.count / frameLength
        guard frameCount >= minimumFrames else { return samples }

        let levels = frameLevels(samples, frameLength: frameLength, frameCount: frameCount)
        let sorted = levels.sorted()
        let floor = sorted[Int(Double(frameCount - 1) * floorPercentile)]
        let speech = sorted[Int(Double(frameCount - 1) * speechPercentile)]
        let contrast = speech - floor
        guard contrast >= minimumContrastDB else { return samples }

        let threshold = floor + max(minimumMarginDB, marginShare * contrast)
        let reach = Int((speechPadding / silenceFrame).rounded())
        let voiced = voicedFrames(levels, above: threshold, reach: reach)
        guard voiced.contains(true) else { return samples }
        let edge = Int(keptEdge * sampleRate)
        let half = Int(keptPause / 2 * sampleRate)
        var cuts: [Range<Int>] = []
        var i = 0
        while i < frameCount {
            guard !voiced[i] else { i += 1; continue }
            var j = i
            while j < frameCount, !voiced[j] { j += 1 }
            // The last frame takes the remainder, so a trailing run ends at the end of the recording.
            let start = i * frameLength
            let end = j == frameCount ? samples.count : j * frameLength
            // Keep the part of the run next to speech: `edge` at the recording's ends, `half` inside.
            let keepBefore = i == 0 ? 0 : (j == frameCount ? edge : half)
            let keepAfter = j == frameCount ? 0 : (i == 0 ? edge : half)
            if start + keepBefore < end - keepAfter { cuts.append((start + keepBefore)..<(end - keepAfter)) }
            i = j
        }
        guard !cuts.isEmpty else { return samples }
        return splice(samples, removing: cuts, crossfade: Int(crossfade * sampleRate))
    }

    /// RMS of each frame in dBFS. The last frame takes the remainder.
    private static func frameLevels(_ samples: [Float], frameLength: Int, frameCount: Int) -> [Float] {
        var levels = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { samples in
            for i in 0..<frameCount {
                let start = i * frameLength
                let length = i == frameCount - 1 ? samples.count - start : frameLength
                var meanSquare: Float = 0
                vDSP_measqv(samples.baseAddress! + start, 1, &meanSquare, vDSP_Length(length))
                // Digital silence reads -120 dBFS instead of -inf.
                levels[i] = 10 * log10(meanSquare + 1e-12)
            }
        }
        return levels
    }

    /// Frames above the threshold plus `reach` frames on both sides.
    private static func voicedFrames(_ levels: [Float], above threshold: Float, reach: Int) -> [Bool] {
        var voiced = [Bool](repeating: false, count: levels.count)
        var forwardUntil = -1
        for i in levels.indices {
            if levels[i] > threshold { forwardUntil = i + reach }
            voiced[i] = i <= forwardUntil
        }
        var backwardFrom = Int.max
        for i in levels.indices.reversed() {
            if levels[i] > threshold { backwardFrom = i - reach }
            if i >= backwardFrom { voiced[i] = true }
        }
        return voiced
    }

    /// `samples` without the (sorted, disjoint) `cuts`; the pieces on either side of a cut overlap by
    /// `crossfade` samples and are blended linearly.
    private static func splice(_ samples: [Float], removing cuts: [Range<Int>], crossfade: Int) -> [Float] {
        var output: [Float] = []
        output.reserveCapacity(samples.count - cuts.reduce(0) { $0 + $1.count })
        func append(_ piece: ArraySlice<Float>) {
            guard !piece.isEmpty else { return }
            let overlap = min(crossfade, piece.count, output.count)
            let base = output.count - overlap
            for t in 0..<overlap {
                let weight = (Float(t) + 0.5) / Float(overlap)
                output[base + t] += (piece[piece.startIndex + t] - output[base + t]) * weight
            }
            output.append(contentsOf: piece.dropFirst(overlap))
        }
        var position = 0
        for cut in cuts {
            append(samples[position..<cut.lowerBound])
            position = cut.upperBound
        }
        append(samples[position...])
        return output
    }

    // MARK: Dynamic normalization

    /// Rumble and DC offset sit below speech; 80 Hz leaves the fundamental of low male voices (~85 Hz) alone.
    private static let highPassHz = 80.0
    /// Gain is decided per frame, in the spirit of ffmpeg's dynaudnorm (500 ms frames, peak and RMS limits).
    private static let gainFrame = 0.5
    private static let targetRMS: Float = 0.1  // -20 dBFS
    /// +30 dB, for a microphone left at a low input level. On benchmark clips attenuated by 35 dB it beat +20 dB by
    /// 0.3 points of WER (+40 dB gained 0.3 more, not worth amplifying noise floors that much); normal clips never
    /// reach the cap, and recordings of pure noise (-80 to -45 dBFS) still produced no words at +40 dB.
    private static let maximumGain: Float = 31.6
    private static let minimumGain: Float = 1 / 3
    private static let peakLimit: Float = 0.95
    private static let outputLimit: Float = 0.99
    /// A minimum filter over this many frames each side lets quiet gaps take their louder neighbours' smaller
    /// gain, so noise between words isn't pumped up (±1 frame cost 2 points of WER on recordings with 3 s pauses,
    /// ±3 and ±14 matched ±7); a Gaussian then removes the steps.
    private static let minimumFilterRadius = 7
    private static let gaussianSigma = 3.0

    /// Removes rumble, then evens out loudness: quiet speech is raised towards -20 dBFS RMS and loud speech
    /// lowered, without clipping, with the gain changing smoothly over a few seconds.
    static func normalize(_ samples: [Float], sampleRate: Double = 16_000) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var output = highPass(samples, sampleRate: sampleRate)
        let frameLength = max(1, Int(gainFrame * sampleRate))
        // The last frame takes the remainder, so every frame is at least `frameLength` long.
        let frameCount = max(1, output.count / frameLength)
        var gains = [Float](repeating: 1, count: frameCount)
        output.withUnsafeBufferPointer { samples in
            for i in 0..<frameCount {
                let start = i * frameLength
                let length = i == frameCount - 1 ? samples.count - start : frameLength
                var rms: Float = 0
                var peak: Float = 0
                vDSP_rmsqv(samples.baseAddress! + start, 1, &rms, vDSP_Length(length))
                vDSP_maxmgv(samples.baseAddress! + start, 1, &peak, vDSP_Length(length))
                let wanted = rms > 1e-9 ? targetRMS / rms : maximumGain
                let allowed = min(maximumGain, peakLimit / max(peak, 1e-9))
                gains[i] = max(minimumGain, min(wanted, allowed))
            }
        }
        gains = gaussianSmooth(minimumFilter(gains, radius: minimumFilterRadius), sigma: gaussianSigma)

        output.withUnsafeMutableBufferPointer { buffer in
            let base = buffer.baseAddress!
            // Gain ramps linearly between frame centres and is constant before the first and after the last.
            func centre(_ i: Int) -> Int {
                i * frameLength + (i == frameCount - 1 ? buffer.count - i * frameLength : frameLength) / 2
            }
            func ramp(_ range: Range<Int>, from start: Float, to end: Float) {
                guard !range.isEmpty else { return }
                var initial = start
                var step = (end - start) / Float(range.count)
                vDSP_vrampmul(base + range.lowerBound, 1, &initial, &step, base + range.lowerBound, 1,
                    vDSP_Length(range.count))
            }
            ramp(0..<centre(0), from: gains[0], to: gains[0])
            for i in 0..<(frameCount - 1) {
                ramp(centre(i)..<centre(i + 1), from: gains[i], to: gains[i + 1])
            }
            ramp(centre(frameCount - 1)..<buffer.count, from: gains[frameCount - 1], to: gains[frameCount - 1])
            var low = -outputLimit
            var high = outputLimit
            vDSP_vclip(base, 1, &low, &high, base, 1, vDSP_Length(buffer.count))
        }
        return output
    }

    /// Second-order Butterworth high-pass (bilinear transform).
    private static func highPass(_ samples: [Float], sampleRate: Double) -> [Float] {
        let k = tan(Double.pi * highPassHz / sampleRate)
        let q = 1 / 2.0.squareRoot()
        let norm = 1 / (1 + k / q + k * k)
        let coefficients = [norm, -2 * norm, norm, 2 * (k * k - 1) * norm, (1 - k / q + k * k) * norm]
        guard var filter = vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 1, ofType: Float.self)
        else { return samples }
        return filter.apply(input: samples)
    }

    /// Sliding minimum over `radius` values on each side; the ends repeat their edge value.
    private static func minimumFilter(_ values: [Float], radius: Int) -> [Float] {
        values.indices.map { i in
            var smallest = Float.greatestFiniteMagnitude
            for k in (i - radius)...(i + radius) { smallest = min(smallest, values[min(max(k, 0), values.count - 1)]) }
            return smallest
        }
    }

    /// Gaussian smoothing over ±3σ; the ends repeat their edge value.
    private static func gaussianSmooth(_ values: [Float], sigma: Double) -> [Float] {
        let radius = Int((3 * sigma).rounded(.up))
        var kernel = (-radius...radius).map { Float(exp(-Double($0 * $0) / (2 * sigma * sigma))) }
        let total = kernel.reduce(0, +)
        kernel = kernel.map { $0 / total }
        return values.indices.map { i in
            var sum: Float = 0
            for (offset, weight) in kernel.enumerated() {
                sum += weight * values[min(max(i + offset - radius, 0), values.count - 1)]
            }
            return sum
        }
    }
}
