import FluidAudio
import Foundation

/// The merge of overlapping windows' tokens for recordings longer than the encoder's 15 s window:
/// FluidAudio 0.17.7's ChunkProcessor.mergeChunks and collapseSeamWordDuplicates (Apache 2.0),
/// which match the windows' tokens on the 2 s they share and splice them at word boundaries. Both
/// speech models' pipelines use it (`ParakeetUnified`, `ParakeetV3`).
struct WindowMerge {
    struct Token {
        let id: Int
        /// The encoder frame it was emitted at, counted from the start of the recording.
        var frame: Int
        /// Frames it advanced (TDT only).
        var duration = 0
    }

    private static let frameSeconds = ASRConstants.secondsPerEncoderFrame
    private static let overlapSeconds = 2.0

    let vocabulary: [Int: String]   // SentencePiece pieces
    let spliceSafe: Set<Int>
    private let caseVariants: [Int: Int]

    init(vocabulary: [Int: String]) {
        self.vocabulary = vocabulary
        spliceSafe = Set(vocabulary.compactMap { Self.isSpliceSafe($0.value) ? $0.key : nil })
        var variants: [Int: Int] = [:]
        let groups = Dictionary(grouping: vocabulary.keys) { vocabulary[$0]!.lowercased() }
        for ids in groups.values where ids.count > 1 {
            // The lowercase piece is canonical, so the collapse knows which copy of a duplicate to keep.
            let canonical = ids.first { vocabulary[$0] == vocabulary[$0]!.lowercased() } ?? ids.min()!
            for id in ids { variants[id] = canonical }
        }
        caseVariants = variants
    }

    /// The tokens of a window merged into those of the windows before it.
    func merge(_ left: [Token], _ right: [Token]) -> [Token] {
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        let frame = Self.frameSeconds, overlap = Self.overlapSeconds
        func start(_ token: Token) -> Double { Double(token.frame) * frame }
        let leftEnd = start(left.last!) + frame, rightStart = start(right.first!)
        if leftEnd <= rightStart { return left + right }
        let overlapLeft = left.indices.filter { start(left[$0]) + frame > rightStart - overlap }
        let overlapRight = right.indices.filter { start(right[$0]) < leftEnd + overlap }
        guard overlapLeft.count >= 2, overlapRight.count >= 2 else {
            return mergeAtMidpoint(left, right, cutoff: (leftEnd + rightStart) / 2)
        }
        func matches(_ i: Int, _ j: Int) -> Bool {
            let a = left[overlapLeft[i]], b = right[overlapRight[j]]
            let same = a.id == b.id || caseVariants[a.id].map { $0 == caseVariants[b.id] } == true
            return same && abs(start(a) - start(b)) < overlap / 2
        }
        // The longest run of matching tokens, else the longest common subsequence.
        var pairs: [(Int, Int)] = []
        for i in overlapLeft.indices {
            for j in overlapRight.indices where matches(i, j) {
                var run: [(Int, Int)] = []
                var (k, l) = (i, j)
                while k < overlapLeft.count, l < overlapRight.count, matches(k, l) {
                    run.append((k, l))
                    (k, l) = (k + 1, l + 1)
                }
                if run.count > pairs.count { pairs = run }
            }
        }
        if pairs.count < max(overlapLeft.count / 2, 1) {
            let (n, m) = (overlapLeft.count, overlapRight.count)
            var lengths = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
            for i in 1...n {
                for j in 1...m {
                    lengths[i][j] = matches(i - 1, j - 1)
                        ? lengths[i - 1][j - 1] + 1 : max(lengths[i - 1][j], lengths[i][j - 1])
                }
            }
            pairs = []
            var (i, j) = (n, m)
            while i > 0, j > 0 {
                if matches(i - 1, j - 1) {
                    pairs.append((i - 1, j - 1))
                    (i, j) = (i - 1, j - 1)
                } else if lengths[i - 1][j] > lengths[i][j - 1] {
                    i -= 1
                } else {
                    j -= 1
                }
            }
            pairs.reverse()
            if pairs.isEmpty { return mergeAtMidpoint(left, right, cutoff: (leftEnd + rightStart) / 2) }
        }
        return mergeAtMatches(left, right, pairs.map { (overlapLeft[$0.0], overlapRight[$0.1]) })
    }

    /// Left up to the first match, the matched tokens, between matches the longer of the two
    /// windows' gaps, then right after the last match, spliced at a word boundary.
    private func mergeAtMatches(_ left: [Token], _ right: [Token], _ matches: [(left: Int, right: Int)]) -> [Token] {
        var result = Array(left[..<matches[0].left])
        for (index, match) in matches.enumerated() {
            result.append(left[match.left])
            guard index < matches.count - 1 else { continue }
            let next = matches[index + 1]
            let gapLeft = left[(match.left + 1)..<max(next.left, match.left + 1)]
            let gapRight = right[(match.right + 1)..<max(next.right, match.right + 1)]
            result += gapRight.count > gapLeft.count ? Array(gapRight) : Array(gapLeft)
        }
        let last = matches[matches.count - 1]
        guard last.right + 1 < right.count else { return result }
        let tail = right[(last.right + 1)...]
        guard !spliceSafe.contains(tail.first!.id) else { return result + tail }
        // The splice lands mid-word. If right has the seam word from its start, take right's
        // segmentation of it; else left keeps the word and right resumes at its next word.
        if let wordStart = (0...last.right).reversed().first(where: { spliceSafe.contains(right[$0].id) }),
            let cut = result.lastIndex(where: { spliceSafe.contains($0.id) })
        {
            return Array(result[..<cut]) + right[wordStart...]
        }
        var cursor = last.left + 1
        while cursor < left.count, !spliceSafe.contains(left[cursor].id) {
            result.append(left[cursor])
            cursor += 1
        }
        guard let resume = tail.firstIndex(where: { spliceSafe.contains($0.id) }) else { return result + tail }
        return result + right[resume...]
    }

    /// Left before the time halfway between the windows' edges, right after it, at word boundaries.
    private func mergeAtMidpoint(_ left: [Token], _ right: [Token], cutoff: Double) -> [Token] {
        var leftEnd = left.firstIndex { Double($0.frame) * Self.frameSeconds >= cutoff } ?? left.count
        var rightStart = right.firstIndex { Double($0.frame) * Self.frameSeconds >= cutoff } ?? right.count
        if leftEnd > 0 {
            while leftEnd < left.count, !spliceSafe.contains(left[leftEnd].id) { leftEnd += 1 }
        }
        if let next = right[rightStart...].firstIndex(where: { spliceSafe.contains($0.id) }) { rightStart = next }
        return Array(left[..<leftEnd]) + right[rightStart...]
    }

    /// Drops a word repeated across a seam with different case ("…have Have a…"), keeping the
    /// lowercase copy, or else the earlier one.
    func collapseSeamDuplicates(_ tokens: [Token]) -> [Token] {
        let overlapFrames = Int((Self.overlapSeconds / Self.frameSeconds).rounded())
        var words: [[Token]] = []
        for token in tokens {
            if words.isEmpty || isWordBoundary(vocabulary[token.id] ?? "") {
                words.append([token])
            } else {
                words[words.count - 1].append(token)
            }
        }
        let strippable = CharacterSet.punctuationCharacters.union(.whitespaces)
        let texts = words.map { $0.map { stripWordBoundaryPrefix(vocabulary[$0.id] ?? "") }.joined() }
        let cores = texts.map { $0.trimmingCharacters(in: strippable) }
        var keep = [Bool](repeating: true, count: words.count)
        var lastKept = 0
        for index in words.indices.dropFirst() {
            let previous = cores[lastKept], current = cores[index]
            let duplicate = !previous.isEmpty && previous != current && previous.lowercased() == current.lowercased()
                && current.first?.isLetter == true && !(texts[lastKept].last.map { ".?!:".contains($0) } ?? false)
                && words[index][0].frame - words[lastKept][0].frame <= overlapFrames
            guard duplicate else {
                lastKept = index
                continue
            }
            if current == current.lowercased(), previous != previous.lowercased() {
                keep[lastKept] = false
                lastKept = index
            } else {
                keep[index] = false
            }
        }
        return words.indices.filter { keep[$0] }.flatMap { words[$0] }
    }

    /// Splicing before this piece doesn't glue two words: it starts a word or is punctuation.
    static func isSpliceSafe(_ piece: String) -> Bool {
        guard !piece.isEmpty else { return false }
        return isWordBoundary(piece)
            || piece.unicodeScalars.allSatisfy {
                CharacterSet.punctuationCharacters.contains($0) || CharacterSet.symbols.contains($0)
            }
    }
}
