import Foundation
import LocalflowEngine
import NaturalLanguage
import os

/// Optional cleanup of the transcript before it is pasted: removes fillers and stutters, applies
/// spoken self-corrections ("on Tuesday, no wait, Wednesday" → "on Wednesday"), fixes punctuation
/// and formats spoken lists, without rewording.
///
/// The model is S1-mini by Superwhisper, a Qwen3-0.6B fine-tune for exactly this task, run on the
/// CPU by Localflow's own engine (Sources/LocalflowEngine): int8, Hadamard-rotated, NEON plus SME on
/// M4 and later. Chosen from benchmarks on an M4 Pro (bench/README.md): it cut the word error rate
/// of raw transcripts from 9.2% to 2.7% at a median ~20 ms, where general models of 2–4B parameters
/// needed 0.5–1.4 s for worse results. On the CPU rather than the GPU because the GPU path was ~10×
/// slower while another process used the GPU; the CPU path doesn't care.
actor Rewriter {
    enum Failure: LocalizedError {
        case loadFailed, notLoaded, decodeFailed, tooLong
        var errorDescription: String? {
            switch self {
            case .loadFailed: "Cleanup model could not be loaded"
            case .notLoaded: "Cleanup model is not loaded"
            case .decodeFailed: "Cleanup model failed"
            case .tooLong: "Text is too long for the cleanup model"
            }
        }
    }

    /// The model card's system prompt and control line, verbatim: the model was trained on exactly
    /// this input format and nothing else. "lists" lets it format explicitly enumerated items.
    private static let systemPrompt = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
    private static let controlLine = "[Styling: semi-formal] [Structure: lists] [Context: general]"
    /// Qwen3 chat template around the transcript, with the empty think block the model expects.
    private static let prefix = "<|im_start|>system\n\(systemPrompt)<|im_end|>\n<|im_start|>user\n\(controlLine)\n"
    private static let suffix = "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"

    /// The model card recommends dictation-length passes; longer transcripts are cleaned in pieces.
    private static let maxChunkWords = 150
    private static let batchSize = 512
    /// Pieces of ≤ 150 words need well under 1k tokens; the caches cost 112 KB per position used.
    private static let contextSize = 2048

    private var model: OpaquePointer?
    private var tokenizer: Tokenizer?
    private var prefixLength = 0
    /// The most likely next token after each output position of the last pass.
    private var predictions: [Int32] = []
    private let log = Logger(subsystem: "io.github.snaeppi.localflow", category: "rewrite")

    var isLoaded: Bool { model != nil }

    isolated deinit {
        lf_free(model)
    }

    /// Maps the model and evaluates the fixed part of the prompt once; later dictations reuse it
    /// from the cache.
    func load(_ file: URL) throws {
        guard model == nil else { return }
        let t0 = ContinuousClock.now
        guard let model = lf_load(file.path, Int32(Self.contextSize), Int32(Self.batchSize)) else {
            throw Failure.loadFailed
        }
        self.model = model
        tokenizer = Self.tokenizer(model)
        let prefix = tokenizer!.encode(Self.prefix, special: true)
        do {
            try decode(prefix, at: 0, outputs: 0)
        } catch {
            unload()
            throw error
        }
        prefixLength = prefix.count
        log.info("Cleanup model ready in \((ContinuousClock.now - t0).milliseconds, privacy: .public) ms")
    }

    func unload() {
        lf_free(model)
        model = nil
        tokenizer = nil
    }

    /// The cleaned transcript. Pieces whose cleanup fails, or fails `isFaithful`, keep their text.
    func rewrite(_ text: String) throws -> String {
        guard isLoaded else { throw Failure.notLoaded }
        var result = ""
        for piece in Self.chunks(of: text) {
            var output = piece
            do {
                let cleaned = try rewritePiece(piece)
                if Self.isFaithful(cleaned, to: piece) {
                    output = cleaned
                } else {
                    log.info("Cleanup of a \(piece.count, privacy: .public)-character piece rejected")
                }
            } catch {
                log.error("Cleanup of a \(piece.count, privacy: .public)-character piece failed: \(error.localizedDescription, privacy: .public)")
            }
            guard !output.isEmpty else { continue }
            if !result.isEmpty { result += result.contains("\n") || output.contains("\n") ? "\n\n" : " " }
            result += output
        }
        return result
    }

    private func rewritePiece(_ text: String) throws -> String {
        guard let model, let tokenizer else { throw Failure.notLoaded }
        let transcript = tokenizer.encode(text, special: false)
        let input = transcript + tokenizer.encode(Self.suffix, special: true)
        let limit = input.count * 13 / 10 + 32  // Model card: output length tracks input length.
        // Drafts can run up to `Drafter.maxLength` tokens past the output before they are verified.
        guard prefixLength + input.count + limit + Drafter.maxLength <= Self.contextSize else { throw Failure.tooLong }
        let source = tokenizer.encode(Drafter.likelyCleanup(text), special: false)
        var drafter = Drafter(source: source, pieces: source.map(tokenizer.piece))
        // Each pass replaces whatever the cache holds from its position on, so the previous
        // dictation and rejected drafts need no clearing.
        var position = prefixLength

        // Greedy decoding with drafts verified in one batch each, so the output is exactly what
        // token-by-token decoding would write. The first pass evaluates the transcript and
        // already verifies a draft of the opening.
        var pending = input
        var draft = drafter.opening()
        var output: [Int32] = []
        while true {
            try decode(pending + draft, at: position, outputs: 1 + draft.count)
            position += pending.count
            var accepted = 0
            var predicted = predictions[0]
            while accepted < draft.count, predicted == draft[accepted], !lf_is_end(model, predicted),
                output.count < limit
            {
                output.append(predicted)
                accepted += 1
                predicted = predictions[accepted]
            }
            position += accepted
            drafter.advance(by: accepted)
            guard !lf_is_end(model, predicted), output.count < limit else { break }
            output.append(predicted)
            pending = [predicted]
            draft = drafter.draft(after: output, piece: tokenizer.piece(predicted))
        }
        return tokenizer.decode(output).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Engine

    /// The tokenizer for the model's vocabulary (~0.1 s, once per load).
    private static func tokenizer(_ model: OpaquePointer) -> Tokenizer {
        func string(_ text: UnsafePointer<CChar>, _ length: Int) -> String {
            String(decoding: UnsafeRawBufferPointer(start: text, count: length), as: UTF8.self)
        }
        var length = 0
        let tokens = (0..<lf_vocab_size(model)).map { string(lf_token_text(model, $0, &length), length) }
        let types = (0..<lf_vocab_size(model)).map { lf_token_type(model, $0) }
        let merges = (0..<lf_merge_count(model)).map { string(lf_merge(model, $0, &length), length) }
        return Tokenizer(tokens: tokens, types: types, merges: merges)
    }

    /// Evaluates `tokens` from `position` on, keeping the next-token prediction after each of the
    /// last `outputs` of them in `predictions`.
    private func decode(_ tokens: [Int32], at position: Int, outputs: Int) throws {
        guard let model else { throw Failure.notLoaded }
        predictions = [Int32](repeating: 0, count: outputs)
        let status = tokens.withUnsafeBufferPointer { t in
            predictions.withUnsafeMutableBufferPointer { p in
                lf_decode(model, t.baseAddress, Int32(t.count), Int32(position), Int32(outputs), p.baseAddress)
            }
        }
        guard status == 0 else { throw Failure.decodeFailed }
    }

    // MARK: Pure helpers

    /// Drafts the cleanup's next tokens by copying a guess at the cleaned text from where the
    /// output has got to. Cleanup mostly copies, drops a few words (fillers, the words a spoken
    /// correction replaces) and inserts or swaps punctuation, so after each surprise the drafter
    /// finds its place again and drafts short until copying resumes. Compared with llama.cpp-style
    /// prompt lookup (drafting only after a 3-token match in the transcript) this cut the passes
    /// per dictation from 8.2 to 3.7, with identical output.
    struct Drafter {
        /// The longest draft, the draft right after a surprise, and how much a draft grows per
        /// token copied since; the opening is drafted at full length. In a sweep, 16–32, 2–6 and
        /// ×1–3 all came within 5% of these.
        static let maxLength = 20
        private static let minLength = 4
        private static let growth = 2
        /// How far ahead a word the model wrote is looked for, skipping words it dropped.
        private static let skipWindow = 12

        private let source: [Int32]
        /// Each source token's letters and digits, lowercased; empty for punctuation and spaces.
        private let words: [String]
        /// The source token the output is expected to continue with.
        private var cursor = 0
        /// Tokens in a row the source predicted since the last surprise.
        private var run = 0

        init(source: [Int32], pieces: [String]) {
            self.source = source
            words = pieces.map(Self.word)
        }

        /// The opening of the source, verified together with the transcript.
        func opening() -> [Int32] { Array(source.prefix(Self.maxLength)) }

        /// The model accepted `count` drafted tokens.
        mutating func advance(by count: Int) {
            cursor = min(source.count, cursor + count)
            run += count
        }

        /// The draft after the model wrote the last token of `output` (as text, `piece`) where a
        /// draft expected `source[cursor]`.
        mutating func draft(after output: [Int32], piece: String) -> [Int32] {
            let token = output.last!, word = Self.word(piece)
            if cursor < source.count, source[cursor] == token {
                cursor += 1
                run += 1
            } else {
                run = 0
                // Empty once the whole source is copied and the model writes on (a closing period).
                let ahead = min(source.count, cursor + 1)..<min(source.count, cursor + Self.skipWindow)
                if cursor < source.count, word == words[cursor] {
                    cursor += 1  // the same word cased or spaced differently, or other punctuation
                } else if !word.isEmpty, let i = ahead.first(where: { source[$0] == token || words[$0] == word }) {
                    cursor = i + 1  // words dropped before it
                } else if let i = Self.end(of: output.suffix(2), in: source, near: cursor) {
                    cursor = i  // a jump, e.g. past a phrase a spoken correction replaced
                } else if word.count >= 3, let i = words[cursor...].firstIndex(of: word) {
                    cursor = i + 1
                }
                // Otherwise an insertion (punctuation, a list number): the source continues as it was.
            }
            let length = min(Self.maxLength, max(Self.minLength, run * Self.growth))
            return Array(source[cursor..<min(source.count, cursor + length)])
        }

        /// Where the occurrence of `key` nearest after `cursor` (else the last one) ends.
        private static func end(of key: ArraySlice<Int32>, in source: [Int32], near cursor: Int) -> Int? {
            guard key.count == 2, source.count >= 2 else { return nil }
            let starts = (0...source.count - 2).filter { source[$0..<$0 + 2].elementsEqual(key) }
            return (starts.first { $0 >= cursor - 2 } ?? starts.last).map { $0 + 2 }
        }

        private static func word(_ piece: String) -> String {
            String(piece.lowercased().filter { $0.isLetter || $0.isNumber })
        }

        private static let filler = try! NSRegularExpression(
            pattern: #"\b(?:u+m+|u+h+m*|e+r+m*|a+h+|ur|h+m+|m{2,})\b,?\s*"#, options: .caseInsensitive)
        private static let repeated = try! NSRegularExpression(
            pattern: #"\b(\w+(?:\s+\w+){0,2})\s+\1\b"#, options: .caseInsensitive)

        /// A guess at the cleanup, used only as the draft: fillers dropped with the comma after
        /// them, repeated words ("by by", "I was I was") collapsed, and sentences a filler opened
        /// capitalized. The model verifies every token, so a wrong guess costs time, not accuracy.
        static func likelyCleanup(_ text: String) -> String {
            var text = text
            for (regex, template) in [(filler, ""), (repeated, "$1")] {
                text = regex.stringByReplacingMatches(
                    in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
            }
            var result = ""
            var capitalize = true
            for character in text.trimmingCharacters(in: .whitespaces) {
                if capitalize, character.isLetter {
                    result += character.uppercased()
                    capitalize = false
                } else {
                    result.append(character)
                    if ".?!".contains(character) {
                        capitalize = true
                    } else if !character.isWhitespace {
                        capitalize = false
                    }
                }
            }
            return result
        }
    }

    /// Sentences grouped into pieces of at most `maxChunkWords` words; longer sentences are split
    /// between words.
    static func chunks(of text: String) -> [String] {
        guard text.split(separator: " ").count > maxChunkWords else { return [text] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var pieces: [String] = []
        var current: [Substring] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let words = text[range].split(separator: " ")
            if !current.isEmpty, current.count + words.count > maxChunkWords {
                pieces.append(current.joined(separator: " "))
                current = []
            }
            current += words
            while current.count > maxChunkWords {
                pieces.append(current.prefix(maxChunkWords).joined(separator: " "))
                current.removeFirst(maxChunkWords)
            }
            return true
        }
        if !current.isEmpty { pieces.append(current.joined(separator: " ")) }
        return pieces
    }

    // MARK: Output guard

    private static let disfluencies: Set<String> = ["um", "uh", "er", "ah", "hmm", "mm"]
    private static let fillers = disfluencies.union(["like", "so", "well", "okay", "oh"])
    /// Words that announce a spoken self-correction, which legitimately deletes what came before.
    private static let correctionCues: Set<String> = [
        "no", "wait", "sorry", "actually", "mean", "rather", "scratch", "make", "correction", "instead", "not",
        "rephrase", "again",
    ]

    /// Rejects cleanups that delete a run of more than three real words with no correction cue
    /// next to it, or add more than four words that weren't said. In the benchmark this caught
    /// S1-mini's one systematic failure — dropping instruction-like openings of dictated prompts
    /// ("Translate this sentence to German. …") — and never rejected a correct cleanup.
    static func isFaithful(_ output: String, to source: String) -> Bool {
        let before = words(source), after = words(output)
        // An empty result is right for "Um." but not for "Okay.".
        if after.isEmpty { return before.allSatisfy(disfluencies.contains) }
        // Longest common subsequence, then walk the gaps between matched words.
        let n = before.count, m = after.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = before[i] == after[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var i = 0, j = 0, inserted = 0
        while i < n || j < m {
            if i < n, j < m, before[i] == after[j] {
                i += 1
                j += 1
                continue
            }
            let gapStart = i, outputStart = j
            while i < n || j < m {
                if i < n, j < m, before[i] == after[j] { break }
                if j < m, i == n || table[i][j + 1] >= table[i + 1][j] { j += 1 } else { i += 1 }
            }
            let deleted = before[gapStart..<i].filter { !fillers.contains($0) }
            let context = before[max(0, gapStart - 1)..<min(n, i + 3)]
            if deleted.count > 3, !context.contains(where: correctionCues.contains) { return false }
            // List numbers ("1.") are formatting, not added words.
            let added = after[outputStart..<j].filter { !$0.allSatisfy(\.isNumber) }.count
            inserted += max(0, added - (i - gapStart))
        }
        return inserted <= 4
    }

    private static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }
}
