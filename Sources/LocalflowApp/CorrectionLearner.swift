import AppKit
import os

/// Learns vocabulary from the user's own fixes. For 30 s after a paste it reads the text field
/// it pasted into (in memory only, never logged or kept) and, when the user has replaced one word of
/// the dictated text with a word that isn't an ordinary lowercase word — typically a name the speech
/// model misheard — reports that correction so the word joins the vocabulary.
///
/// It polls the field every 0.4 s for 30 s, accepts exactly one changed word (or two merged into one),
/// and ignores case-only and punctuation-only edits and edits to ordinary words.
@MainActor
final class CorrectionLearner {
    struct Correction: Equatable {
        let misheard: String
        let word: String
    }

    var onCorrection: ((Correction) -> Void)?

    private static let pollInterval: Duration = .milliseconds(400)
    private static let window: Duration = .seconds(30)
    /// Whole documents aren't watched: copying and diffing them every 0.4 s would cost the main thread.
    private static let maxFieldLength = 100_000
    /// Accessibility reads time out now and then (busy Electron apps); give up after this many in a row.
    private static let maxFailedReads = 3
    /// How long after the paste to wait for an Electron app's accessibility tree: Slack's appeared
    /// 2.2 s after `exposeFrontmostApp` asked for it (measured), and a short dictation is shorter.
    private static let fieldWait: Duration = .seconds(3)

    private struct Session {
        let id: Int
        let element: AXUIElement
        let inserted: String
        /// The field's text once the paste landed, and where the pasted text sits in it (UTF-16).
        var baseline: (text: String, range: NSRange)?
        var lastText: String?
        var failedReads = 0
        /// The correction in the latest snapshot that still showed the dictated text.
        var correction: Correction?
    }

    private var session: Session?
    private var sessions = 0
    private var polling: Task<Void, Never>?
    /// Apps already asked to expose their text fields, by process.
    private var exposedApps: Set<pid_t> = []
    private let log = Logger(subsystem: "io.github.snaeppi.localflow", category: "learn")

    var isWatching: Bool { polling != nil }

    /// Electron apps (Discord, Slack) build their accessibility tree only for screen readers or when
    /// a client sets `AXManualAccessibility`; until then their text fields
    /// can't be read. Called when a recording starts because the tree takes ~2 s to appear. VS Code
    /// and its forks are left alone: they take the request for a screen reader and switch to their
    /// screen-reader mode, with sounds (microsoft/vscode#282290).
    func exposeFrontmostApp() {
        guard let app = NSWorkspace.shared.frontmostApplication, let bundle = app.bundleURL,
            exposedApps.insert(app.processIdentifier).inserted
        else { return }
        let contains = { (path: String) in FileManager.default.fileExists(atPath: bundle.appending(path: path).path) }
        guard contains("Contents/Frameworks/Electron Framework.framework"), !contains("Contents/Resources/app/out/vs")
        else { return }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.1)
        if AXUIElementSetAttributeValue(element, "AXManualAccessibility" as CFString, kCFBooleanTrue) != .success {
            exposedApps.remove(app.processIdentifier)  // Busy; ask again next time.
        }
    }

    /// Starts watching the focused text field for edits to `inserted`, which was just pasted into it.
    func watch(_ inserted: String) {
        finish()
        sessions += 1
        let id = sessions
        let inserted = inserted.trimmingCharacters(in: .whitespacesAndNewlines)
        polling = Task { [weak self] in
            let start = ContinuousClock.now
            // An Electron app may still be building its accessibility tree (`exposeFrontmostApp`).
            var element = Self.focusedTextField()
            while element == nil, ContinuousClock.now < start + Self.fieldWait {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                element = Self.focusedTextField()
            }
            guard let element, let self else {
                self?.polling = nil
                return
            }
            self.session = Session(id: id, element: element, inserted: inserted)
            while ContinuousClock.now < start + Self.window {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled, self.poll() else { break }
            }
            // A cancelled task belongs to a session that was already finished.
            guard !Task.isCancelled, self.session?.id == id else { return }
            self.end()
        }
    }

    /// Ends the current session (another dictation is starting) after one last look at the field,
    /// and reports what it learned.
    func finish() {
        if session != nil { _ = poll() }
        end()
    }

    private func end() {
        polling?.cancel()
        polling = nil
        guard let session else { return }
        self.session = nil
        if let correction = session.correction {
            log.info("Learned a correction")
            onCorrection?(correction)
        }
    }

    /// Takes one snapshot; false when the session is over: focus moved, the field became unreadable,
    /// or the dictated text was sent, cleared or edited around (keeping what the last snapshot showed).
    private func poll() -> Bool {
        guard var session else { return false }
        defer { self.session = session }
        guard let focused = Self.focusedElement(), let text = Self.value(of: session.element) else {
            session.failedReads += 1
            return session.failedReads < Self.maxFailedReads
        }
        session.failedReads = 0
        guard CFEqual(focused, session.element), (text as NSString).length <= Self.maxFieldLength else { return false }
        guard text != session.lastText else { return true }
        session.lastText = text
        guard let baseline = session.baseline else {
            session.baseline = Self.locate(session.inserted, in: text, element: session.element)
            return true
        }
        let start = baseline.range.location
        let current = text as NSString
        let insertedLength = (session.inserted as NSString).length
        let tail = current.substring(with: NSRange(location: min(start, current.length),
                                                   length: max(0, min(current.length - start, insertedLength + 200))))
        guard text.hasPrefix((baseline.text as NSString).substring(to: start)),
            Self.words(tail).count * 2 >= Self.words(session.inserted).count
        else { return false }
        session.correction = Self.correction(from: baseline.text, to: text, within: baseline.range)
        return true
    }

    // MARK: Diffing

    private struct Word {
        let text: String
        let range: NSRange
    }

    private static func words(_ text: String) -> [Word] {
        let pattern = /[\p{L}\p{N}_'’]+(?:[-.][\p{L}\p{N}_'’]+)*/
        return text.matches(of: pattern).map { Word(text: String($0.output), range: NSRange($0.range, in: text)) }
    }

    /// The single plausible correction between `old` and `new` inside `region` of `old`, if any.
    static func correction(from old: String, to new: String, within region: NSRange) -> Correction? {
        // Edits are local: only the stretch between the common beginning and end, widened to the
        // dictated text and a margin, is split into words and diffed.
        let (oldUnits, newUnits) = (Array(old.utf16), Array(new.utf16))
        var prefix = 0
        while prefix < min(oldUnits.count, newUnits.count), oldUnits[prefix] == newUnits[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(oldUnits.count, newUnits.count) - prefix,
            oldUnits[oldUnits.count - 1 - suffix] == newUnits[newUnits.count - 1 - suffix]
        {
            suffix += 1
        }
        let changed = NSRange(location: prefix, length: oldUnits.count - suffix - prefix)
        guard changed.location <= NSMaxRange(region), NSMaxRange(changed) >= region.location else { return nil }
        let margin = 80
        let start = max(0, min(prefix, region.location) - margin)
        let oldEnd = min(oldUnits.count, max(oldUnits.count - suffix, NSMaxRange(region)) + margin)
        let newEnd = oldEnd - oldUnits.count + newUnits.count
        let a = words((old as NSString).substring(with: NSRange(location: start, length: oldEnd - start)))
        let b = words((new as NSString).substring(with: NSRange(location: start, length: newEnd - start)))
        let region = NSRange(location: region.location - start, length: region.length)

        var head = 0
        while head < min(a.count, b.count), a[head].text == b[head].text { head += 1 }
        var tail = 0
        while tail < min(a.count, b.count) - head, a[a.count - 1 - tail].text == b[b.count - 1 - tail].text {
            tail += 1
        }
        let oldMiddle = Array(a[head..<a.count - tail]), newMiddle = Array(b[head..<b.count - tail])
        guard oldMiddle.count <= 200, newMiddle.count <= 200 else { return nil }
        let hunks = diff(oldMiddle.map(\.text), newMiddle.map(\.text)).filter { hunk in
            // Only edits that touch the dictated text; typing elsewhere is not a correction.
            let touched = hunk.old.map { oldMiddle[$0].range }
            return touched.contains { NSIntersectionRange($0, region).length > 0 }
        }
        guard hunks.count == 1, let hunk = hunks.first,
            hunk.old.allSatisfy({ NSIntersectionRange(oldMiddle[$0].range, region).length == oldMiddle[$0].range.length }),
            (1...2).contains(hunk.old.count), hunk.new.count == 1
        else { return nil }
        let misheard = hunk.old.map { oldMiddle[$0].text }.joined(separator: " ")
        let word = newMiddle[hunk.new.lowerBound].text
        return isPlausible(misheard: misheard, word: word) ? Correction(misheard: misheard, word: word) : nil
    }

    /// The rules, with a similarity check so rewording isn't mistaken for a correction:
    /// the new word must not be an ordinary lowercase word (names and identifiers count even when the
    /// spell checker knows them, as it does Niamh), a single word must change more than case or
    /// punctuation, and the two must look or sound alike ("Nyam" → Niamh, "fluid audio" → FluidAudio).
    static func isPlausible(misheard: String, word: String) -> Bool {
        let (old, new) = (Vocabulary.squashed(misheard), Vocabulary.squashed(word))
        let merged = misheard.contains(" ")
        guard new.contains(where: \.isLetter), merged || old != new,
            !(word == word.lowercased() && Vocabulary.isKnownWord(word)),
            // A typo of the original ("lunch" → "lunchh") is not a correction.
            !Vocabulary.isTypo(word, of: misheard)
        else { return false }
        let distance = Vocabulary.editDistance(old, new)
        let soundDistance = Vocabulary.editDistance(Vocabulary.soundKey(misheard), Vocabulary.soundKey(word))
        return distance <= max(3, max(old.count, new.count) / 2) || soundDistance <= 1
    }

    /// Word-level diff (longest common subsequence) as hunks of old and new word indices.
    private static func diff(_ a: [String], _ b: [String]) -> [(old: Range<Int>, new: Range<Int>)] {
        let n = a.count, m = b.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = a[i] == b[j] ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var hunks: [(old: Range<Int>, new: Range<Int>)] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                i += 1
                j += 1
                continue
            }
            let (oldStart, newStart) = (i, j)
            while i < n || j < m, !(i < n && j < m && a[i] == b[j]) {
                if j < m, i == n || table[i][j + 1] >= table[i + 1][j] { j += 1 } else { i += 1 }
            }
            hunks.append((oldStart..<i, newStart..<j))
        }
        return hunks
    }

    // MARK: Accessibility

    private static func focusedTextField() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
            let focused, CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.1)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subrole as? String != kAXSecureTextFieldSubrole, let value = value(of: element),
            (value as NSString).length <= maxFieldLength
        else { return nil }
        return element
    }

    private static func focusedElement() -> CFTypeRef? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.1)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success
        else { return nil }
        return focused
    }

    private static func value(of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    /// Where the pasted text is: the occurrence ending at the cursor, else the last one.
    private static func locate(_ inserted: String, in text: String, element: AXUIElement) -> (text: String, range: NSRange)? {
        let string = text as NSString
        var cursor: Int?
        var rangeValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
            let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID()
        {
            var range = CFRange()
            if AXValueGetValue(rangeValue as! AXValue, .cfRange, &range) { cursor = range.location }
        }
        if let cursor, cursor >= (inserted as NSString).length {
            let range = NSRange(location: cursor - (inserted as NSString).length, length: (inserted as NSString).length)
            if NSMaxRange(range) <= string.length, string.substring(with: range) == inserted { return (text, range) }
        }
        let range = string.range(of: inserted, options: .backwards)
        return range.location == NSNotFound ? nil : (text, range)
    }
}
