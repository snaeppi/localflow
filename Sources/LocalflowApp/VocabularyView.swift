import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Words and replacements: one field that adds a word (⏎), opens a hidden "Replace with…" box (⌘⏎) and
/// searches the list as you type, and one alphabetical list whose rows show a delete button on hover.
/// Clicking a replacement edits it.
struct VocabularyPage: View {
    @Bindable var settings: AppSettings
    @State private var entry = ""
    @State private var replacement = ""
    @State private var replacing = false
    /// The replacement the "Replace with…" box is editing; nil when it adds a new one.
    @State private var editing: UUID?
    /// The Import CSV panel is open.
    @State private var importing = false
    @State private var hoveringImport = false
    @FocusState private var focus: Field?

    private enum Field { case entry, replacement }

    fileprivate enum Item: Identifiable {
        case word(String)
        case replacement(Vocabulary.Replacement)

        var id: String {
            switch self {
            case .word(let word): "word " + word
            case .replacement(let item): item.id.uuidString
            }
        }

        var sortKey: String {
            switch self {
            case .word(let word): word
            case .replacement(let item): item.original
            }
        }

        func contains(_ query: String) -> Bool {
            switch self {
            case .word(let word): word.localizedStandardContains(query)
            case .replacement(let item):
                item.original.localizedStandardContains(query) || item.replacement.localizedStandardContains(query)
            }
        }
    }

    private var query: String { trimmed(entry) }

    /// The field searches while it's an entry, not while it's the original of a replacement.
    private var search: String { replacing ? "" : query }

    private var items: [Item] {
        (settings.vocabulary.words.map(Item.word) + settings.vocabulary.replacements.map(Item.replacement))
            .filter { search.isEmpty || $0.contains(search) }
            .sorted { $0.sortKey.localizedStandardCompare($1.sortKey) == .orderedAscending }
    }

    var body: some View {
        // The Import CSV panel slides over the page from the right; the page's content dims and is hidden
        // under it, its background stays.
        page
            .opacity(importing ? 0.6 : 1)
            .mask {
                HStack(spacing: 0) {
                    Color.black
                    Color.clear.frame(width: importing ? ImportPanel.width : 0)
                }
            }
            .overlay {
                if importing {
                    Color.black.opacity(0.001).onTapGesture { importing = false }
                }
            }
            .overlay(alignment: .trailing) {
                if importing {
                    ImportPanel(close: { importing = false }, choose: chooseCSV, drop: dropped, saveExample: saveExample)
                        .transition(.move(edge: .trailing))
                }
            }
            // The panel settles in ~0.2 s without overshoot.
            .animation(.smooth(duration: 0.2), value: importing)
    }

    private var page: some View {
        let items = items
        // The field scrolls with the list, under the page header.
        return ScrollView {
            VStack(spacing: 10) {
                entryBar
                if replacing { replacementBox }
            }
            .padding(.top, 16)
            .padding(.bottom, 8)
            .onExitCommand {
                if importing { importing = false } else if replacing { closeReplacement() } else { entry = "" }
            }
            // Lazy: only the rows on screen are built (200 entries in a Form took ~1 s to show).
            LazyVStack(spacing: 0) {
                if items.isEmpty {
                    Text(search.isEmpty ? "No words or replacements yet" : "Nothing matches “\(search)”")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.top, 24)
                }
                ForEach(items) { item in
                    VocabularyRow(item: item, query: search) {
                        if case .replacement(let entry) = item { edit(entry) }
                    } delete: {
                        delete(item)
                    }
                }
            }
            .padding(.bottom, 12)
        }
        .contentMargins(.horizontal, 24, for: .scrollContent)
        .scrollBar(.top) {
            PageHeader(
                title: "Vocabulary",
                info: "Words help Localflow spell names, acronyms and jargon. Replacements swap a word or phrase for your exact text after every dictation.\n\nType to search the list. ⏎ adds a word, ⌘⏎ a replacement. Import a CSV file with a “word” column and an optional “replacement” column."
            ) {
                // Like the microphone button, it shows its name on hover.
                HStack(spacing: 10) {
                    Text("Import CSV")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .opacity(hoveringImport ? 1 : 0)
                    GlassIconButton(symbol: "arrow.down.document.fill", label: "Import CSV") {
                        importing = true
                    } onHover: { hovering in
                        withAnimation(.easeOut(duration: 0.15)) { hoveringImport = hovering }
                    }
                }
            }
        }
        .scrollBar(.bottom) { learnRow }
        .animation(.easeOut(duration: 0.2), value: replacing)
        .task {
            // Focus set as the page appears doesn't reach the field yet.
            try? await Task.sleep(for: .milliseconds(150))
            focus = .entry
        }
    }

    private var entryBar: some View {
        HStack(spacing: 16) {
            TextField("New word or replacement", text: $entry, prompt: Text("New word or replacement"))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focus, equals: .entry)
                .onSubmit {
                    if replacing { focus = .replacement } else { addWord() }
                }
            if !replacing {
                HintButton(title: "Add word", keys: ["⏎"], action: addWord)
                    .disabled(query.isEmpty)
                HintButton(title: "Replace with…", keys: ["⌘", "⏎"]) {
                    replacing = true
                    focus = .replacement
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(query.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background(FieldBackground())
    }

    private var replacementBox: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: $replacement)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)
                    .focused($focus, equals: .replacement)
                if replacement.isEmpty {
                    Text("Replace with…")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 5)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 60)
            HintButton(title: editing == nil ? "Add replacement" : "Save replacement", keys: ["⌘", "⏎"], action: saveReplacement)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(query.isEmpty || trimmed(replacement).isEmpty)
        }
        .padding(.leading, 11)
        .padding([.trailing, .vertical], 10)
        .background(FieldBackground())
        .transition(.opacity)
    }

    private var learnRow: some View {
        HStack(spacing: 6) {
            Text("Learn from corrections").font(.system(size: 13))
            InfoButton("When you fix a misheard name or term right after dictating, Localflow adds it here. It reads the text field you dictated into for 30 seconds and keeps only the corrected word.")
            Spacer()
            Switch(title: "Learn from corrections", isOn: $settings.learnCorrections)
        }
        .padding(.horizontal, 16)
        .frame(height: 45)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
    }

    private func trimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func addWord() {
        let word = query
        guard !word.isEmpty else { return }
        if !settings.vocabulary.words.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            settings.vocabulary.words.append(word)
        }
        entry = ""
    }

    private func edit(_ item: Vocabulary.Replacement) {
        editing = item.id
        entry = item.original
        replacement = item.replacement
        replacing = true
        focus = .replacement
    }

    private func saveReplacement() {
        let (original, text) = (query, trimmed(replacement))
        guard !original.isEmpty, !text.isEmpty else { return }
        let existing = settings.vocabulary.replacements.firstIndex { entry in
            if let editing { entry.id == editing } else { entry.original.caseInsensitiveCompare(original) == .orderedSame }
        }
        if let existing {
            settings.vocabulary.replacements[existing].original = original
            settings.vocabulary.replacements[existing].replacement = text
        } else {
            settings.vocabulary.replacements.append(.init(original: original, replacement: text))
        }
        entry = ""
        closeReplacement()
    }

    private func closeReplacement() {
        if editing != nil { entry = "" }
        editing = nil
        replacement = ""
        replacing = false
        focus = .entry
    }

    private func delete(_ item: Item) {
        switch item {
        case .word(let word): settings.vocabulary.words.removeAll { $0 == word }
        case .replacement(let entry): settings.vocabulary.replacements.removeAll { $0.id == entry.id }
        }
        if case .replacement(let entry) = item, entry.id == editing { closeReplacement() }
    }

    // MARK: Importing

    private func chooseCSV() {
        importing = false
        let panel = NSOpenPanel()
        panel.title = "Import Vocabulary CSV"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.prompt = "Import"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importFile(url)
    }

    private func dropped(_ urls: [URL]) {
        importing = false
        guard urls.count == 1, let url = urls.first else {
            return ImportResult.failed("Drop a single .csv file to import vocabulary.")
        }
        if url.hasDirectoryPath { return ImportResult.failed("Folders aren’t supported.") }
        guard url.pathExtension.lowercased() == "csv" else {
            return ImportResult.failed("Only .csv files can be imported. Localflow can’t read “\(url.lastPathComponent)”.")
        }
        importFile(url)
    }

    private func importFile(_ url: URL) {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .windowsCP1252))
        else { return ImportResult.failed("Could not read the CSV file.") }
        do {
            let added = try settings.vocabulary.importCSV(text)
            if added == 0 {
                ImportResult.show("Nothing imported", "Everything in the file is already in your vocabulary.", symbol: "info.circle.fill", color: .systemBlue)
            } else {
                ImportResult.show("Import complete", "Imported \(added) item\(added == 1 ? "" : "s")", symbol: "checkmark.circle.fill", color: .systemGreen)
            }
        } catch {
            ImportResult.failed(error.localizedDescription)
        }
    }

    private func saveExample() {
        let panel = NSSavePanel()
        panel.title = "Save Example CSV"
        panel.nameFieldStringValue = "localflow-vocabulary-example.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Vocabulary.exampleCSV.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            ImportResult.show("Could not save example", error.localizedDescription, symbol: "exclamationmark.triangle.fill", color: .systemOrange)
        }
    }
}

/// Import results: an alert on the Settings window with a coloured symbol.
@MainActor
private enum ImportResult {
    static func failed(_ message: String) {
        show("Import failed", message, symbol: "exclamationmark.triangle.fill", color: .systemOrange)
    }

    static func show(_ title: String, _ message: String, symbol: String, color: NSColor) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let configuration = NSImage.SymbolConfiguration(pointSize: 44, weight: .regular)
            .applying(.init(paletteColors: [.black, color]))
        alert.icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        // An (empty) accessory view gives a left-aligned layout, 279 pt wide; without one, a one-line message
        // is centred.
        alert.accessoryView = NSView(frame: NSRect(x: 0, y: 0, width: 247, height: 0))
        // After the drop or the file chooser has finished (a modal alert inside the drop handler holds the
        // drag session open), on the Settings window even when a drop came from Finder.
        DispatchQueue.main.async {
            NSApp.activate()
            if let window = NSApp.orderedWindows.first(where: { $0.isVisible && $0.canBecomeKey }) {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }
}

/// The Import CSV panel: a dashed drop zone that also opens a file chooser, an example file,
/// and the format.
private struct ImportPanel: View {
    /// 345 pt wide, its drop zone 107 pt tall with 16 pt margins.
    static let width: CGFloat = 345
    let close: () -> Void
    let choose: () -> Void
    let drop: ([URL]) -> Void
    let saveExample: () -> Void
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Import vocabulary").font(.system(size: 13, weight: .semibold))
                HStack {
                    Button(action: close) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Back")
                    Spacer()
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 48)
            .background { WindowDragArea() }
            dropZone
                .padding(.horizontal, 16)
                .padding(.top, 20)
            HStack {
                Button(action: saveExample) {
                    Label("Example file", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Spacer()
                Text("\(code("word")) and \(code("replacement")) headers required")
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 16)
            .padding(.top, 10)
            Spacer()
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity)
        .background(Color.primary.opacity(0.03))
        .overlay(alignment: .leading) { Rectangle().fill(.primary.opacity(0.14)).frame(width: 1) }
    }

    private var dropZone: some View {
        Button(action: choose) {
            VStack(spacing: 4) {
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 17))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 4)
                Text("Import CSV").foregroundStyle(.primary.opacity(0.8))
                Text("Drag and drop or select file").foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, minHeight: 107)
            .background(RoundedRectangle(cornerRadius: 12).fill(targeted ? Color.accentColor.opacity(0.12) : .clear))
            .overlay {
                // Dashes of 7 pt with 5 pt gaps.
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(targeted ? Color.accentColor : .primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [7, 5]))
            }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Import CSV, drag and drop or select file")
        .dropDestination(for: URL.self) { urls, _ in
            drop(urls)
            return true
        } isTargeted: { targeted = $0 }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    private func code(_ text: String) -> Text {
        Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(.primary)
    }
}

/// The bordered, lightly filled background of the entry field and the "Replace with…" box.
private struct FieldBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color(nsColor: .textBackgroundColor).opacity(0.45))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.12)))
    }
}

/// An action shown as its name and keyboard shortcut, dimmed until it applies.
private struct HintButton: View {
    let title: String
    let keys: [String]
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13))
                HStack(spacing: 3) {
                    ForEach(keys, id: \.self) { KeyCap($0) }
                }
            }
            .foregroundStyle(.secondary)
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct VocabularyRow: View {
    let item: VocabularyPage.Item
    let query: String
    let edit: () -> Void
    let delete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            switch item {
            case .word(let word):
                highlighted(word)
            case .replacement(let entry):
                highlighted(entry.original).frame(width: 150, alignment: .leading)
                Image(systemName: "arrow.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.08)))
                    .padding(.trailing, 8)
                highlighted(entry.replacement.replacingOccurrences(of: "\n", with: " "))
            }
            Spacer(minLength: 12)
            if hovering {
                Button(action: delete) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete")
            }
        }
        .lineLimit(1)
        .font(.system(size: 13))
        .padding(.horizontal, 16)
        .frame(height: 36)
        .background {
            if hovering { RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.06)) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: edit)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityAction(.default, edit)
        .accessibilityAction(named: "Delete", delete)
    }

    private var label: String {
        switch item {
        case .word(let word): word
        case .replacement(let entry): "\(entry.original), replaced with \(entry.replacement)"
        }
    }

    /// The text with the search match marked. Plain text otherwise: 200 rows of
    /// attributed text took the list a second to show.
    private func highlighted(_ text: String) -> Text {
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        guard !query.isEmpty, text.range(of: query, options: options) != nil else { return Text(text) }
        var result = AttributedString(text)
        if let range = result.range(of: query, options: options) {
            result[range].backgroundColor = Color.accentColor.opacity(0.25)
        }
        return Text(result)
    }
}
