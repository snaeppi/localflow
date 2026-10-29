/// Qwen2 byte-level BPE, as llama.cpp tokenizes it (LLAMA_VOCAB_PRE_TYPE_QWEN2).
///
/// Mirrors llama.cpp's code, not the reference regex, where the two differ: its hand-written pre-tokenizer,
/// its Unicode 15.1 tables, and which special tokens are cut out of the text. Tokens must be unique, as
/// llama.cpp asserts. Not reproduced: lstrip/rstrip (llama.cpp sets them by model name, never for Qwen),
/// byte-type tokens and the `[UNK_BYTE]` fallback (a byte-level vocabulary has neither).
struct Tokenizer: Sendable {
    /// What `\p{L}`, `\p{N}` and `\s` make of a scalar; `none` is anything outside the fragment being split.
    enum ScalarClass: UInt8, Sendable { case other, letter, number, space, none }
    private enum Kind: Sendable { case normal, userDefined, control, unused }
    private enum Fragment { case text(Range<Int>), token(Int32) }

    /// Names llama.cpp turns into control tokens whatever the file says, from its end-of-generation and FIM
    /// lists: the ones a Qwen vocabulary has. Note `</s>`, a plain token here that becomes a control one.
    private static let controlNames = ["<|im_end|>", "<|endoftext|>", "</s>", "<|fim_prefix|>", "<|fim_middle|>",
                                       "<|fim_suffix|>", "<|fim_pad|>", "<|repo_name|>", "<|file_sep|>"]
    /// GPT-2's bytes_to_unicode: printable bytes stand for themselves, the others take 256 and up in order.
    private static let alphabet: [Unicode.Scalar] = {
        var next: UInt32 = 255
        return (0..<256).map { byte in
            let printable = (0x21...0x7E).contains(byte) || (0xA1...0xAC).contains(byte) || byte >= 0xAE
            if !printable { next += 1 }
            return printable ? Unicode.Scalar(UInt8(byte)) : Unicode.Scalar(next)!
        }
    }()
    private static let byteSymbols = alphabet.map { String($0) }
    private static let byteOfScalar = Dictionary(uniqueKeysWithValues: alphabet.enumerated().map { ($1, UInt8($0)) })

    private let texts: [String]
    private let idOf: [String: Int32]
    private let rankOf: [String: Int32]  // "left right" as in the GGUF -> rank
    private let kinds: [Kind]
    private let specials: [(id: Int32, scalars: [Unicode.Scalar])]  // control and user-defined, longest first

    /// The GGUF `tokenizer.ggml.tokens`, `tokenizer.ggml.token_type` and `tokenizer.ggml.merges`.
    init(tokens: [String], types: [Int32], merges: [String]) {
        // llama.cpp renames empty tokens, and a merge listed twice keeps its first rank.
        let texts = tokens.enumerated().map { $1.isEmpty ? "[EMPTY_\($0)]" : $1 }
        var idOf = [String: Int32](minimumCapacity: texts.count)
        for (i, text) in texts.enumerated() { idOf[text] = Int32(i) }
        precondition(idOf.count == texts.count && types.count == texts.count, "duplicate tokens or missing types")
        var rankOf = [String: Int32](minimumCapacity: merges.count)
        for i in merges.indices.reversed() { rankOf[merges[i]] = Int32(i) }

        var kinds = types.map { type -> Kind in
            switch type {
            case 1: .normal
            case 2, 3: .control  // unknown tokens are hidden like control tokens
            case 4: .userDefined
            default: .unused
            }
        }
        for name in Self.controlNames { if let id = idOf[name] { kinds[Int(id)] = .control } }
        let specials = kinds.indices.filter { kinds[$0] == .control || kinds[$0] == .userDefined }
            .sorted { (texts[$0].utf8.count, $1) > (texts[$1].utf8.count, $0) }  // longest first, as llama.cpp
            .map { (id: Int32($0), scalars: Array(texts[$0].unicodeScalars)) }
        (self.texts, self.idOf, self.rankOf, self.kinds, self.specials) = (texts, idOf, rankOf, kinds, specials)
    }

    /// = `llama_tokenize(vocab, text, len, …, add_special: false, parse_special: special)`.
    func encode(_ text: String, special: Bool) -> [Int32] {
        let scalars = Array(text.unicodeScalars)
        let classes = scalars.map(Self.scalarClass)
        var out: [Int32] = []
        for fragment in partition(scalars, special: special) {
            switch fragment {
            case .token(let id): out.append(id)
            case .text(let range):
                for word in Self.split(scalars, classes, range) { merge(scalars[word], into: &out) }
            }
        }
        return out
    }

    /// = the concatenated `llama_token_to_piece(vocab, t, …, lstrip: 0, special: false)`, bytes decoded as UTF-8.
    func decode(_ ids: [Int32]) -> String {
        var bytes: [UInt8] = []
        for id in ids where texts.indices.contains(Int(id)) {
            switch kinds[Int(id)] {
            case .userDefined: bytes += texts[Int(id)].utf8
            case .normal: bytes += texts[Int(id)].unicodeScalars.compactMap { Self.byteOfScalar[$0] }
            case .control, .unused: break  // control tokens are empty unless asked for, as are unused ones
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    func piece(_ token: Int32) -> String { decode([token]) }

    /// llama.cpp's `tokenizer_st_partition`: user-defined tokens are always cut out of the text, control tokens
    /// only with `special`. Longer tokens go first, and the text one leaves behind is searched by the next.
    private func partition(_ s: [Unicode.Scalar], special: Bool) -> [Fragment] {
        var parts: [Fragment] = [.text(0..<s.count)]
        for (id, pattern) in specials where (special || kinds[Int(id)] == .userDefined) && s.contains(pattern[0]) {
            var next: [Fragment] = []
            for part in parts {
                guard case .text(let range) = part else { next.append(part); continue }
                var from = range.lowerBound, i = from
                while i + pattern.count <= range.upperBound {
                    guard s[i] == pattern[0], s[i..<i + pattern.count].elementsEqual(pattern) else { i += 1; continue }
                    if i > from { next.append(.text(from..<i)) }
                    next.append(.token(id))
                    i += pattern.count
                    from = i
                }
                if from < range.upperBound { next.append(.text(from..<range.upperBound)) }
            }
            parts = next
        }
        return parts
    }

    /// BPE of one pre-token: always the lowest-ranked adjacent pair, the leftmost on ties, which is what
    /// llama.cpp's bigram queue pops. Quadratic in the pre-token's length, which is a word.
    private func merge(_ word: ArraySlice<Unicode.Scalar>, into out: inout [Int32]) {
        func rank(_ a: String, _ b: String) -> Int32 { rankOf[a + " " + b] ?? .max }
        var parts = word.flatMap { $0.utf8 }.map { Self.byteSymbols[Int($0)] }
        var pairs = parts.indices.dropLast().map { rank(parts[$0], parts[$0 + 1]) }
        while let best = pairs.indices.min(by: { pairs[$0] < pairs[$1] || (pairs[$0] == pairs[$1] && $0 < $1) }),
              pairs[best] != .max {
            parts[best] += parts.remove(at: best + 1)
            pairs.remove(at: best)
            if best > 0 { pairs[best - 1] = rank(parts[best - 1], parts[best]) }
            if best < pairs.count { pairs[best] = rank(parts[best], parts[best + 1]) }
        }
        for part in parts {
            if let id = idOf[part] { out.append(id); continue }
            // Not a token: llama.cpp emits a token per byte of the symbol's text, and only ASCII bytes have one.
            out += part.utf8.compactMap { $0 < 0x80 ? idOf[String(Unicode.Scalar($0))] : nil }
        }
    }

    /// \p{L}, \p{N} and \s the way llama.cpp's tables have them. Those are Unicode 15.1, so letters and numbers
    /// Swift knows from later versions count as unassigned.
    private static func scalarClass(_ s: Unicode.Scalar) -> ScalarClass {
        switch s.value {
        case 9...13, 0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000: return .space
        case 0x30...0x39: return .number
        case 0x41...0x5A, 0x61...0x7A: return .letter
        case 0..<0x80: return .other
        default: break
        }
        let result: ScalarClass
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: result = .letter
        case .decimalNumber, .letterNumber, .otherNumber: result = .number
        default: return .other
        }
        guard let age = s.properties.age, age.major < 15 || (age.major == 15 && age.minor <= 1) else { return .other }
        return result
    }

    /// llama.cpp's `unicode_regex_split_custom_qwen2` for one fragment: the pre-tokens of
    /// `'s|'t|'re|'ve|'m|'ll|'d` (any case), `[^\r\n\p{L}\p{N}]?\p{L}+`, `\p{N}`, ` ?[^\s\p{L}\p{N}]+[\r\n]*`,
    /// `\s*[\r\n]+`, `\s+(?!\S)` and `\s+`, tried in that order at each position.
    private static func split(_ s: [Unicode.Scalar], _ cls: [ScalarClass], _ frag: Range<Int>) -> [Range<Int>] {
        func at(_ p: Int) -> ScalarClass { frag.contains(p) ? cls[p] : .none }
        func lower(_ p: Int) -> Unicode.Scalar { ("A"..."Z").contains(s[p]) ? Unicode.Scalar(s[p].value + 32)! : s[p] }
        func isBreak(_ p: Int) -> Bool { s[p] == "\r" || s[p] == "\n" }
        var words: [Range<Int>] = []
        var pos = frag.lowerBound
        while pos < frag.upperBound {
            var end = pos + 1
            if s[pos] == "'", pos + 1 < frag.upperBound {
                let a = lower(pos + 1)
                if "stmd".unicodeScalars.contains(a) {
                    end = pos + 2
                } else if pos + 2 < frag.upperBound, ("rv".unicodeScalars.contains(a) && lower(pos + 2) == "e")
                            || (a == "l" && lower(pos + 2) == "l") {
                    end = pos + 3
                }
            }
            if end != pos + 1 {
                // a contraction
            } else if !isBreak(pos) && at(pos) != .number && (at(pos) == .letter || at(pos + 1) == .letter) {
                while at(end) == .letter { end += 1 }
            } else if at(pos) == .number {
                // one digit
            } else if case let start = pos + (s[pos] == " " ? 1 : 0), at(start) == .other || at(start) == .none {
                end = start
                while at(end) == .other { end += 1 }
                while end < frag.upperBound && isBreak(end) { end += 1 }
            } else {
                var n = 0, lastBreak = 0
                while at(pos + n) == .space {
                    if isBreak(pos + n) { lastBreak = pos + n + 1 }
                    n += 1
                }
                end = lastBreak > 0 ? lastBreak : n > 1 && pos + n < frag.upperBound ? pos + n - 1 : pos + max(n, 1)
            }
            words.append(pos..<end)
            pos = end
        }
        return words
    }
}
