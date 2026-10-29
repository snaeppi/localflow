import AppKit

/// The user's vocabulary: words the speech model gets wrong (names, products,
/// jargon) and replacements that swap a word or phrase for exact text, every time. Edited in
/// Settings and, when the user fixes a misheard word right after dictating, by CorrectionLearner.
struct Vocabulary: Codable, Equatable {
    struct Replacement: Codable, Equatable, Identifiable {
        var id = UUID()
        var original: String
        var replacement: String
    }

    var words: [String] = []
    var replacements: [Replacement] = []

    /// Adds a word the user typed over a misheard one, plus a replacement for the misheard form when
    /// that form isn't a real word, so it can be swapped every time without touching ordinary text.
    @MainActor mutating func learn(_ word: String, misheard: String) -> Bool {
        var changed = false
        if !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            words.append(word)
            changed = true
        }
        if !misheard.split(separator: " ").allSatisfy({ Self.isKnownWord(String($0)) }),
            !replacements.contains(where: { $0.original.caseInsensitiveCompare(misheard) == .orderedSame })
        {
            replacements.append(Replacement(original: misheard, replacement: word))
            changed = true
        }
        return changed
    }

    // MARK: Importing

    /// Why a CSV file couldn't be imported.
    enum ImportError: LocalizedError {
        case empty, missingWordColumn, extraColumns, noRows

        var errorDescription: String? {
            switch self {
            case .empty: "The CSV file is empty."
            case .missingWordColumn: "The CSV must include a “word” column."
            case .extraColumns: "The CSV can only have “word” and “replacement” columns."
            case .noRows: "The CSV had no valid rows."
            }
        }
    }

    /// Adds the entries of a CSV file: a header with a `word` column and an optional `replacement` column,
    /// where rows with a replacement become replacements. Entries already in the vocabulary are skipped.
    /// Returns how many entries were added.
    mutating func importCSV(_ text: String) throws(ImportError) -> Int {
        var rows = Self.csvRows(text).filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard !rows.isEmpty else { throw .empty }
        let header = rows.removeFirst().map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let wordColumn = header.firstIndex(of: "word") else { throw .missingWordColumn }
        guard header.allSatisfy({ ["word", "replacement", ""].contains($0) }) else { throw .extraColumns }
        let replacementColumn = header.firstIndex(of: "replacement")
        var valid = 0, added = 0
        for row in rows {
            let field = { (i: Int?) in
                i.map { row.indices.contains($0) ? row[$0].trimmingCharacters(in: .whitespacesAndNewlines) : "" } ?? ""
            }
            let (word, replacement) = (field(wordColumn), field(replacementColumn))
            if word.isEmpty { continue }
            valid += 1
            if replacement.isEmpty {
                guard !words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) else { continue }
                words.append(word)
            } else {
                guard !replacements.contains(where: { $0.original.caseInsensitiveCompare(word) == .orderedSame })
                else { continue }
                replacements.append(Replacement(original: word, replacement: replacement))
            }
            added += 1
        }
        guard valid > 0 else { throw .noRows }
        return added
    }

    /// The file Settings › Vocabulary offers as an example of the format.
    static let exampleCSV = "word,replacement\nKubernetes,\nNiamh,\nmy email,me@example.com\n"

    /// RFC 4180 fields: quotes, doubled quotes and line breaks inside quotes. Spreadsheets in regions
    /// that write decimal commas separate fields with semicolons, so the first lines pick the separator
    /// (a list of words alone may start with a one-column line).
    private static func csvRows(_ text: String) -> [[String]] {
        let characters = Array(text.hasPrefix("\u{FEFF}") ? text.dropFirst() : Substring(text))
        let opening = characters.prefix(2000)
        let separator: Character = opening.contains(",") ? "," : opening.contains(";") ? ";" : "\t"
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var i = 0
        while i < characters.count {
            let c = characters[i]
            if quoted {
                if c != "\"" {
                    field.append(c)
                } else if i + 1 < characters.count, characters[i + 1] == "\"" {
                    field.append(c)
                    i += 1
                } else {
                    quoted = false
                }
            } else if c == "\"", field.isEmpty {
                quoted = true
            } else if c == separator {
                row.append(field)
                field = ""
            } else if c.isNewline {
                row.append(field)
                rows.append(row)
                (row, field) = ([], "")
            } else {
                field.append(c)
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { rows.append(row + [field]) }
        return rows
    }

    // MARK: Applying

    /// Replacements, in order, wherever the original appears as whole words (case-insensitive).
    func applyReplacements(to text: String) -> String {
        replacements.reduce(text) { text, entry in
            let original = entry.original.trimmingCharacters(in: .whitespaces)
            // Compiling the pattern costs ~0.3 ms, 31 ms for 100 replacements; most aren't in the text.
            guard !original.isEmpty, text.range(of: original, options: .caseInsensitive) != nil,
                let regex = try? NSRegularExpression(
                    pattern: "(?<![\\p{L}\\p{N}_])" + NSRegularExpression.escapedPattern(for: original) + "(?![\\p{L}\\p{N}_])",
                    options: .caseInsensitive)
            else { return text }
            return regex.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text),
                withTemplate: NSRegularExpression.escapedTemplate(for: entry.replacement))
        }
    }

    /// Writes vocabulary words the way they are spelled in the list where the transcript has a
    /// variant of them: split or joined differently ("fluid audio" → FluidAudio, "max retries" →
    /// max_retries), cased differently ("KPIS" → KPIs), or misspelled in a way that sounds the same
    /// ("Versal" → Vercel). Sound-alikes only replace words the spell checker doesn't know, so
    /// ordinary words stay ("cloud" never becomes Claude); in the benchmark this raised the dictionary
    /// cases' checks from 48% to 71% with no false replacements.
    @MainActor func respell(_ text: String) -> String {
        // Longer terms first, so "Supa Base Cloud" wins over "Supabase".
        let terms = words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map(Term.init).sorted { ($0.words, $0.text.count) > ($1.words, $1.text.count) }
        guard !terms.isEmpty else { return text }
        let tokens = text.ranges(of: /[\p{L}\p{N}_'’]+/)
        let longest = terms.map(\.words).max()! + 2
        var keys = Keys()
        var edits: [(Range<String.Index>, String)] = []
        var i = 0
        tokenLoop: while i < tokens.count {
            // The spans of 1, 2, … words starting here; nil where punctuation interrupts them.
            let spans: [Span?] = (1...min(longest, tokens.count - i)).map { k in
                let range = tokens[i].lowerBound..<tokens[i + k - 1].upperBound
                let text = String(text[range])
                guard text.allSatisfy({ $0.isLetter || $0.isNumber || "_'’ -".contains($0) }) else { return nil }
                return Span(range: range, text: text, lowercased: text.lowercased())
            }
            for term in terms {
                for k in stride(from: min(term.words + 2, spans.count), through: 1, by: -1) {
                    guard let span = spans[k - 1] else { continue }
                    let (core, ending) = term.splitEnding(span)
                    guard core != term.text else { continue }
                    if term.matches(core, words: k, keys: &keys) {
                        edits.append((span.range, term.text + ending))
                        i += k
                        continue tokenLoop
                    }
                }
            }
            i += 1
        }
        var result = text
        for (range, replacement) in edits.reversed() { result.replaceSubrange(range, with: replacement) }
        return result
    }

    private struct Span {
        let range: Range<String.Index>
        let text: String
        let lowercased: String
    }

    /// A vocabulary word with its comparison keys, computed once per `respell`.
    private struct Term {
        let text: String
        let lowercased: String
        let words: Int
        let squashed: String
        let soundKey: String

        init(_ text: String) {
            self.text = text
            lowercased = text.lowercased()
            words = text.split(separator: " ").count
            squashed = Vocabulary.squashed(text)
            soundKey = Vocabulary.soundKey(text)
        }

        /// A possessive or plural ending that the term itself doesn't have ("Vercel's", "Vercels"),
        /// kept when the rest of the span is respelled. The "s" of "ss" is part of the word: "gress"
        /// is not the plural of a "gres" that sounds like Graz.
        func splitEnding(_ span: Span) -> (core: String, ending: String) {
            for ending in ["'s", "’s", "'", "’", "s"]
            where span.lowercased.hasSuffix(ending) && !lowercased.hasSuffix(ending) && span.text.count > ending.count + 2
                && !(ending == "s" && span.lowercased.hasSuffix("ss"))
            {
                return (String(span.text.dropLast(ending.count)), String(span.text.suffix(ending.count)))
            }
            return (span.text, "")
        }

        @MainActor func matches(_ span: String, words count: Int, keys: inout Keys) -> Bool {
            let spanSquashed = keys.squashed(span)
            if spanSquashed == squashed {
                // A lone ordinary word that differs only in case ("linear" vs Linear) is ambiguous.
                return !(count == 1 && span.lowercased() == lowercased && span == span.lowercased() && keys.isKnown(span))
            }
            // Cheapest tests first; the spell checker (~0.1 ms a word) last.
            let tolerance = max(2, squashed.count / 3)
            guard count == words, soundKey.count >= 3, abs(spanSquashed.count - squashed.count) <= tolerance,
                Vocabulary.editDistance(keys.soundKey(span), soundKey) <= max(1, soundKey.count / 4),
                Vocabulary.editDistance(spanSquashed, squashed) <= tolerance
            else { return false }
            let spanWords = span.split(separator: " ").map(String.init)
            // CamelCase means the speech model already wrote a deliberate name, e.g. GitHub.
            return !spanWords.contains(where: { $0.contains(/\p{Ll}\p{Lu}/) }) && !spanWords.allSatisfy { keys.isKnown($0) }
        }
    }

    /// Keys and spell-checker answers for the spans of one `respell`, each computed once.
    private struct Keys {
        private var squashed: [String: String] = [:]
        private var sound: [String: String] = [:]
        private var known: [String: Bool] = [:]

        mutating func squashed(_ text: String) -> String {
            if let key = squashed[text] { return key }
            let key = Vocabulary.squashed(text)
            squashed[text] = key
            return key
        }

        mutating func soundKey(_ text: String) -> String {
            if let key = sound[text] { return key }
            let key = Vocabulary.soundKey(text)
            sound[text] = key
            return key
        }

        @MainActor mutating func isKnown(_ word: String) -> Bool {
            if let answer = known[word] { return answer }
            let answer = Vocabulary.isKnownWord(word)
            known[word] = answer
            return answer
        }
    }

    // MARK: Word helpers (shared with CorrectionLearner)

    /// Whether the system spell checker (including words the user taught it) knows `word`.
    @MainActor static func isKnownWord(_ word: String) -> Bool {
        NSSpellChecker.shared.checkSpelling(
            of: word, startingAt: 0, language: "en", wrap: false, inSpellDocumentWithTag: 0, wordCount: nil
        ).location == NSNotFound
    }

    /// Whether the system spell checker would fix `word` back to `original`: its autocorrection, or
    /// for a lowercase word any of its guesses ("lanch" autocorrects to lunch but lists launch).
    /// Capitalized words only get the autocorrection, since a name one letter off a known name
    /// (Kristen → Kirsten) is a real correction.
    @MainActor static func isTypo(_ word: String, of original: String) -> Bool {
        let checker = NSSpellChecker.shared
        let range = NSRange(location: 0, length: (word as NSString).length)
        var fixes = [checker.correction(forWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0)]
            .compactMap(\.self)
        if word == word.lowercased(), !original.contains(" ") {
            fixes += checker.guesses(forWordRange: range, in: word, language: "en", inSpellDocumentWithTag: 0) ?? []
        }
        return fixes.contains { $0.caseInsensitiveCompare(original) == .orderedSame }
    }

    /// Lowercase letters and digits only.
    static func squashed(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// A crude English sound key: the consonant skeleton with common spellings of a sound merged,
    /// so "Versal" and "Vercel" or "Joquin" and "Joaquin" compare equal.
    static func soundKey(_ text: String) -> String {
        var s = squashed(text)
        for (from, to) in [
            ("ph", "f"), ("ck", "k"), ("qu", "kw"), ("x", "ks"), ("wh", "w"), ("sch", "sk"), ("tch", "ch"),
            ("dge", "j"), ("gh", "g"), ("kn", "n"), ("wr", "r"), ("mb", "m"),
        ] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = s.replacing(/c(?=[eiy])/, with: "s")
        for (from, to) in [("c", "k"), ("z", "s"), ("v", "f"), ("q", "k"), ("j", "g"), ("d", "t"), ("b", "p")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        guard let head = s.first else { return "" }
        let vowels = "aeiouy"
        let body = s.dropFirst().filter { !"aeiouyhw".contains($0) }
        var key = vowels.contains(head) ? String(head) : ""
        for character in (vowels.contains(head) ? "" : String(head)) + body where key.last != character {
            key.append(character)
        }
        return key
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, previous + (a[i - 1] == b[j - 1] ? 0 : 1))
                previous = current
            }
        }
        return row[b.count]
    }
}
