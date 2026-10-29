import Foundation

/// Runs the app's cleanup (`Rewriter`, instrumented by instrument.py) over the cleanup test set and
/// prints latency and per-pass statistics. Build with build.sh.
///
/// usage: harness MODEL CASES OUT [REPS]
///   MODEL  a model file prepared by the app (the engine's format), e.g.
///          ~/Localflow/models/s1-mini-2.gguf
///   CASES  the test set from bench/rewrite_asr.py (cases.jsonl)
///   OUT    outputs as JSON lines (id, output, ms) for bench/rewrite_score.py and for diffing builds
///   REPS   runs per case (default 3); latency is the best run, statistics come from the first
/// HARNESS_IDLE_MS (environment): idle before each case, as between dictations
struct Case: Decodable {
    let id: String
    let asr: String
    let dictionary: [String]?
}

enum Stats {
    nonisolated(unsafe) static var enabled = false
    /// First pass of each piece: tokens evaluated (transcript, template, opening draft) and µs.
    nonisolated(unsafe) static var first: [(tokens: Int, drafted: Int, accepted: Int, us: Int)] = []
    /// Later passes: draft length, tokens accepted, µs.
    nonisolated(unsafe) static var verify: [(drafted: Int, accepted: Int, us: Int)] = []
}

extension Duration {
    var milliseconds: Int { Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15) }
    var microseconds: Int { Int(Double(components.seconds) * 1e6 + Double(components.attoseconds) / 1e12) }
}

@main struct Main {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 4 else {
            print("usage: harness MODEL CASES OUT [REPS]")
            exit(2)
        }
        let model = URL(fileURLWithPath: args[1]), cases = URL(fileURLWithPath: args[2])
        let out = URL(fileURLWithPath: args[3])
        let reps = args.count > 4 ? Int(args[4])! : 3
        let idle = Int(ProcessInfo.processInfo.environment["HARNESS_IDLE_MS"] ?? "0") ?? 0
        let rewriter = Rewriter()
        let t0 = ContinuousClock.now
        try await rewriter.load(model)
        let loadMs = (ContinuousClock.now - t0).milliseconds
        let items = try String(contentsOf: cases, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(Case.self, from: Data($0.utf8)) }
        var inputs: [String] = []
        for item in items {
            inputs.append(await MainActor.run { Vocabulary(words: item.dictionary ?? []).respell(item.asr) })
        }
        _ = try await rewriter.rewrite(inputs[0])  // warm-up
        var best = [Double](repeating: .infinity, count: items.count)
        var outputs = [String](repeating: "", count: items.count)
        for rep in 0..<reps {
            Stats.enabled = rep == 0
            for (i, input) in inputs.enumerated() {
                if idle > 0 { try await Task.sleep(for: .milliseconds(idle)) }
                let start = ContinuousClock.now
                let output = try await rewriter.rewrite(input)
                best[i] = min(best[i], Double((ContinuousClock.now - start).microseconds) / 1000)
                if rep == 0 { outputs[i] = output }
            }
        }
        var lines = ""
        for (i, item) in items.enumerated() {
            let record = try JSONSerialization.data(withJSONObject: ["id": item.id, "output": outputs[i], "ms": best[i]])
            lines += String(decoding: record, as: UTF8.self) + "\n"
        }
        try lines.write(to: out, atomically: true, encoding: .utf8)

        func f(_ x: Double) -> String { String(format: "%.1f", x) }
        let sorted = best.sorted()
        print("load \(loadMs) ms · p50 \(f(sorted[sorted.count / 2])) · p90 \(f(sorted[sorted.count * 9 / 10])) · max \(f(sorted.last!)) · mean \(f(best.reduce(0, +) / Double(best.count))) ms (best of \(reps))")
        let firstMs = Double(Stats.first.map(\.us).reduce(0, +)) / 1000
        let verifyMs = Double(Stats.verify.map(\.us).reduce(0, +)) / 1000
        let firstTokens = Stats.first.map(\.tokens).reduce(0, +)
        print("first passes: \(Stats.first.count), \(firstTokens) tokens, \(f(firstMs)) ms (\(f(firstMs * 1000 / Double(max(1, firstTokens)))) µs/token), opening drafts \(Stats.first.map(\.drafted).reduce(0, +)) drafted / \(Stats.first.map(\.accepted).reduce(0, +)) accepted")
        let drafted = Stats.verify.map(\.drafted).reduce(0, +), accepted = Stats.verify.map(\.accepted).reduce(0, +)
        print("later passes: \(Stats.verify.count), drafted \(drafted), accepted \(accepted), \(f(verifyMs)) ms")
        print("passes per piece: \(f(Double(Stats.first.count + Stats.verify.count) / Double(max(1, Stats.first.count)))) · time in first passes \(f(100 * firstMs / max(1, firstMs + verifyMs)))%")
        var bySize: [Int: (n: Int, us: Int)] = [:]
        for v in Stats.verify {
            bySize[1 + v.drafted, default: (0, 0)].n += 1
            bySize[1 + v.drafted, default: (0, 0)].us += v.us
        }
        print("later pass cost by batch size (tokens: count × mean ms):", bySize.keys.sorted().map {
            "\($0): \(bySize[$0]!.n)×\(f(Double(bySize[$0]!.us) / Double(bySize[$0]!.n) / 1000))"
        }.joined(separator: ", "))
    }
}
