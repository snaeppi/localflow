import AVFoundation
import AppKit
import ServiceManagement
import os

/// Localflow's settings. Everything except per-Mac state (the microphone, the walkthrough, launch at login)
/// is kept in `settings.json` in the app folder, so settings and vocabulary can be backed up or moved with
/// the folder. The file is read at launch (or when the folder changes) and written shortly after each change.
@MainActor @Observable
final class AppSettings {
    enum Theme: String, CaseIterable, Codable {
        case auto, light, dark

        var appearance: NSAppearance? {
            switch self {
            case .auto: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    /// What the clipboard holds after a paste.
    enum Clipboard: String, CaseIterable, Codable {
        case keep, replace
    }

    /// The choices for how long the speech model stays loaded, in seconds; 0 keeps it loaded.
    static let activeDurations = [10, 30, 60, 120, 300, 600, 1800, 3600, 0]

    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored var onShortcutsChange: (() -> Void)?
    @ObservationIgnored var onMicrophoneChange: (() -> Void)?
    @ObservationIgnored var onCleanupChange: ((Bool) -> Void)?
    @ObservationIgnored var onRecordingWindowChange: (() -> Void)?
    @ObservationIgnored var onDockChange: (() -> Void)?
    @ObservationIgnored var onSpeechModelChange: (() -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.snaeppi.localflow", category: "settings")

    // MARK: Shortcuts

    /// Starts and stops a hands-free dictation. The same key as `pushToTalkShortcut` (Right ⌘ by default)
    /// does both: hold it to talk, tap it for hands-free.
    var toggleShortcut: Shortcut? {
        didSet { shortcutsChanged() }
    }

    /// Dictates while held.
    var pushToTalkShortcut: Shortcut? {
        didSet { shortcutsChanged() }
    }

    var cancelShortcut: Shortcut {
        didSet { shortcutsChanged() }
    }

    /// Like the key both shortcuts share: hold to talk, click for hands-free.
    var mouseShortcut: MouseButton? {
        didSet { shortcutsChanged() }
    }

    /// CoreAudio device UID; nil follows the system default input. Per Mac, so not in the settings file.
    var microphoneUID: String? {
        didSet {
            defaults.set(microphoneUID, forKey: "microphoneUID")
            onMicrophoneChange?()
        }
    }

    // MARK: Sound

    var soundEffects: Bool {
        didSet { save() }
    }

    /// Scales the start and stop sounds, 0–1.
    var soundVolume: Double {
        didSet { save() }
    }

    var whileRecording: SystemAudio.WhileRecording {
        didSet { save() }
    }

    /// Turn the microphone's input volume all the way up while recording.
    var boostMicrophone: Bool {
        didSet { save() }
    }

    // MARK: Models, cleanup and vocabulary

    /// The speech model to dictate with (`SpeechModels`); it may not be downloaded (yet).
    var speechModel: SpeechModels.Kind {
        didSet {
            save()
            onSpeechModelChange?()
        }
    }

    /// Clean up transcripts with the optional model (RewriteModel) before pasting. Only with the English
    /// speech model: see `cleansUp`.
    var cleanup: Bool {
        didSet {
            save()
            onCleanupChange?(cleanup)
        }
    }

    /// Add words to the vocabulary when the user fixes them right after dictating.
    var learnCorrections: Bool {
        didSet { save() }
    }

    var vocabulary: Vocabulary {
        didSet { save() }
    }

    // MARK: Appearance

    /// Appearance of Localflow's windows and menu; the recording window is always dark glass.
    var theme: Theme {
        didSet {
            save()
            NSApp.appearance = theme.appearance
        }
    }

    /// Show the recording window while recording; when off it shows only notices ("No sound from the
    /// microphone").
    var showRecordingWindow: Bool {
        didSet {
            save()
            onRecordingWindowChange?()
        }
    }

    /// Keep the recording window on screen between dictations, to start them with a click.
    var alwaysShowRecordingWindow: Bool {
        didSet {
            save()
            onRecordingWindowChange?()
        }
    }

    // MARK: Advanced

    /// Otherwise Localflow is in the Dock only while one of its windows is open.
    var showInDock: Bool {
        didSet {
            save()
            onDockChange?()
        }
    }

    /// A left click on the menu bar icon starts or finishes a dictation; the menu opens on a right click.
    var recordOnMenuBarClick: Bool {
        didSet { save() }
    }

    /// Seconds the models stay loaded after a dictation; 0 keeps them loaded.
    var modelActiveDuration: Int {
        didSet { save() }
    }

    var silenceRemoval: Bool {
        didSet { save() }
    }

    var normalization: Bool {
        didSet { save() }
    }

    var clipboard: Clipboard {
        didSet { save() }
    }

    /// Let clipboard managers record dictations (otherwise they're marked transient).
    var clipboardHistory: Bool {
        didSet { save() }
    }

    /// Paste the text; when off it's only put on the clipboard.
    var pasteResult: Bool {
        didSet { save() }
    }

    /// Press Return after pasting when Shift is held as the dictation ends.
    var shiftToSend: Bool {
        didSet { save() }
    }

    /// Type the text instead of pasting it.
    var simulateKeypresses: Bool {
        didSet { save() }
    }

    /// Keep each recording and its transcript in the app folder's `recordings`, to test speech models on
    /// your own voice (bench/README.md).
    var saveRecordings: Bool {
        didSet { save() }
    }

    // MARK: Per Mac

    /// The first-run walkthrough was finished or closed.
    var onboarded: Bool {
        didSet { defaults.set(onboarded, forKey: "onboarded") }
    }

    var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != (SMAppService.mainApp.status == .enabled) else { return }
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                launchAtLogin = SMAppService.mainApp.status == .enabled
            }
        }
    }

    init() {
        let stored = Self.load()
        toggleShortcut = stored.toggleShortcut.map(\.shortcut) ?? .rightCommand
        pushToTalkShortcut = stored.pushToTalkShortcut.map(\.shortcut) ?? .rightCommand
        cancelShortcut = stored.cancelShortcut ?? .escape
        mouseShortcut = stored.mouseShortcut
        microphoneUID = defaults.string(forKey: "microphoneUID")
        soundEffects = stored.soundEffects ?? true
        soundVolume = stored.soundVolume ?? 1
        whileRecording = stored.whileRecording ?? .pause
        boostMicrophone = stored.boostMicrophone ?? true
        speechModel = stored.speechModel ?? SpeechModels.Kind.suggested
        cleanup = stored.cleanup ?? false
        learnCorrections = stored.learnCorrections ?? true
        vocabulary = stored.vocabulary ?? Vocabulary()
        theme = stored.theme ?? .auto
        showRecordingWindow = stored.showRecordingWindow ?? true
        alwaysShowRecordingWindow = stored.alwaysShowRecordingWindow ?? true
        showInDock = stored.showInDock ?? false
        recordOnMenuBarClick = stored.recordOnMenuBarClick ?? false
        modelActiveDuration = stored.modelActiveDuration ?? 60
        // From the benchmark (bench/README.md): normalization helped on every test set; silence removal only
        // speeds up recordings with long pauses and can lose quiet speech.
        silenceRemoval = stored.silenceRemoval ?? false
        normalization = stored.normalization ?? true
        clipboard = stored.clipboard ?? .keep
        clipboardHistory = stored.clipboardHistory ?? false
        pasteResult = stored.pasteResult ?? true
        shiftToSend = stored.shiftToSend ?? false
        simulateKeypresses = stored.simulateKeypresses ?? false
        saveRecordings = stored.saveRecordings ?? false
        onboarded = defaults.bool(forKey: "onboarded")
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Storage

    /// The settings file. Every field is optional, so a file edited by hand loads what it has and the rest
    /// takes its default.
    private struct Stored: Codable {
        var toggleShortcut: StoredShortcut?
        var pushToTalkShortcut: StoredShortcut?
        var cancelShortcut: Shortcut?
        var mouseShortcut: MouseButton?
        var soundEffects: Bool?
        var soundVolume: Double?
        var whileRecording: SystemAudio.WhileRecording?
        var boostMicrophone: Bool?
        var speechModel: SpeechModels.Kind?
        var cleanup: Bool?
        var learnCorrections: Bool?
        var vocabulary: Vocabulary?
        var theme: Theme?
        var showRecordingWindow: Bool?
        var alwaysShowRecordingWindow: Bool?
        var showInDock: Bool?
        var recordOnMenuBarClick: Bool?
        var modelActiveDuration: Int?
        var silenceRemoval: Bool?
        var normalization: Bool?
        var clipboard: Clipboard?
        var clipboardHistory: Bool?
        var pasteResult: Bool?
        var shiftToSend: Bool?
        var simulateKeypresses: Bool?
        var saveRecordings: Bool?
    }

    private var stored: Stored {
        Stored(
            toggleShortcut: StoredShortcut(toggleShortcut), pushToTalkShortcut: StoredShortcut(pushToTalkShortcut),
            cancelShortcut: cancelShortcut, mouseShortcut: mouseShortcut, soundEffects: soundEffects,
            soundVolume: soundVolume, whileRecording: whileRecording, boostMicrophone: boostMicrophone,
            speechModel: speechModel, cleanup: cleanup, learnCorrections: learnCorrections, vocabulary: vocabulary,
            theme: theme, showRecordingWindow: showRecordingWindow,
            alwaysShowRecordingWindow: alwaysShowRecordingWindow, showInDock: showInDock,
            recordOnMenuBarClick: recordOnMenuBarClick, modelActiveDuration: modelActiveDuration,
            silenceRemoval: silenceRemoval, normalization: normalization, clipboard: clipboard,
            clipboardHistory: clipboardHistory, pasteResult: pasteResult, shiftToSend: shiftToSend,
            simulateKeypresses: simulateKeypresses, saveRecordings: saveRecordings)
    }

    /// A shortcut with a default in the settings file: `"none"` once removed, so the default doesn't come back.
    private enum StoredShortcut: Codable {
        case none
        case key(Shortcut)

        init(_ shortcut: Shortcut?) { self = shortcut.map(Self.key) ?? .none }

        var shortcut: Shortcut? {
            if case .key(let shortcut) = self { shortcut } else { nil }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            self = (try? container.decode(String.self)) == "none" ? .none : .key(try container.decode(Shortcut.self))
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .none: try container.encode("none")
            case .key(let shortcut): try container.encode(shortcut)
            }
        }
    }

    /// Cleanup runs: it's on and the English speech model is in use (S1-mini only knows English).
    var cleansUp: Bool { cleanup && speechModel.supportsCleanup }

    /// How to start dictating, for the menu and the recording window: "Hold Right ⌘", "Press ⌥Space".
    var dictationHint: String? {
        if let pushToTalkShortcut { return "Hold \(pushToTalkShortcut.title)" }
        return toggleShortcut.map { "Press \($0.title)" }
    }

    /// The settings file; if it isn't valid JSON (edited by hand?), it's kept aside rather than overwritten.
    private static func load() -> Stored {
        let file = AppFolder.settingsFile
        guard let data = try? Data(contentsOf: file) else { return Stored() }
        if let stored = try? JSONDecoder().decode(Stored.self, from: data) { return stored }
        let aside = file.deletingLastPathComponent()
            .appending(path: "settings (unreadable \(Int(Date.now.timeIntervalSince1970))).json")
        try? FileManager.default.moveItem(at: file, to: aside)
        return Stored()
    }

    private func shortcutsChanged() {
        save()
        onShortcutsChange?()
    }

    /// Writes shortly after the last change, so dragging a slider doesn't write the file at every step.
    private func save() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            write()
        }
    }

    /// Writes any pending change now (at quit).
    func flush() {
        guard let saveTask else { return }
        saveTask.cancel()
        write()
    }

    @discardableResult
    private func write() -> Bool {
        saveTask = nil
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            try FileManager.default.createDirectory(at: AppFolder.url, withIntermediateDirectories: true)
            try encoder.encode(stored).write(to: AppFolder.settingsFile, options: .atomic)
            return true
        } catch {
            log.error("Saving settings failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Takes the settings from the app folder's file, after the folder changed.
    func reload() {
        guard let data = try? Data(contentsOf: AppFolder.settingsFile),
            let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        toggleShortcut = stored.toggleShortcut.map(\.shortcut) ?? .rightCommand
        pushToTalkShortcut = stored.pushToTalkShortcut.map(\.shortcut) ?? .rightCommand
        cancelShortcut = stored.cancelShortcut ?? .escape
        mouseShortcut = stored.mouseShortcut
        soundEffects = stored.soundEffects ?? soundEffects
        soundVolume = stored.soundVolume ?? soundVolume
        whileRecording = stored.whileRecording ?? whileRecording
        boostMicrophone = stored.boostMicrophone ?? boostMicrophone
        speechModel = stored.speechModel ?? speechModel
        cleanup = stored.cleanup ?? cleanup
        learnCorrections = stored.learnCorrections ?? learnCorrections
        vocabulary = stored.vocabulary ?? Vocabulary()
        theme = stored.theme ?? theme
        showRecordingWindow = stored.showRecordingWindow ?? showRecordingWindow
        alwaysShowRecordingWindow = stored.alwaysShowRecordingWindow ?? alwaysShowRecordingWindow
        showInDock = stored.showInDock ?? showInDock
        recordOnMenuBarClick = stored.recordOnMenuBarClick ?? recordOnMenuBarClick
        modelActiveDuration = stored.modelActiveDuration ?? modelActiveDuration
        silenceRemoval = stored.silenceRemoval ?? silenceRemoval
        normalization = stored.normalization ?? normalization
        clipboard = stored.clipboard ?? clipboard
        clipboardHistory = stored.clipboardHistory ?? clipboardHistory
        pasteResult = stored.pasteResult ?? pasteResult
        shiftToSend = stored.shiftToSend ?? shiftToSend
        simulateKeypresses = stored.simulateKeypresses ?? simulateKeypresses
        saveRecordings = stored.saveRecordings ?? saveRecordings
    }
}

/// Localflow's folder (Advanced settings › App folder location): `settings.json` (settings and vocabulary),
/// `models` (the cleanup model) and `recordings` (opt-in diagnostics). Where it is is the one thing kept in
/// UserDefaults.
enum AppFolder {
    private static let key = "appFolder"

    nonisolated static var url: URL {
        UserDefaults.standard.string(forKey: key).map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Localflow", directoryHint: .isDirectory)
    }

    nonisolated static var settingsFile: URL { url.appending(path: "settings.json") }
    nonisolated static var models: URL { url.appending(path: "models", directoryHint: .isDirectory) }
    nonisolated static var recordings: URL { url.appending(path: "recordings", directoryHint: .isDirectory) }

    /// The Localflow folder inside a location the user picked.
    static func folder(in location: URL) -> URL {
        location.appending(path: "Localflow", directoryHint: .isDirectory)
    }

    /// Whether `folder` already holds Localflow's settings (from another Mac, or a backup).
    static func hasSettings(_ folder: URL) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: "settings.json").path)
    }

    /// Moves everything to `folder` (off the main thread: the cleanup model is ~0.9 GB) and switches to
    /// it. With `adopt`, `folder`'s own settings are kept and only what it lacks is moved over.
    static func move(to folder: URL, adopt: Bool) async throws {
        let source = url
        try await Task.detached(priority: .userInitiated) {
            let files = FileManager.default
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            for item in (try? files.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)) ?? [] {
                let target = folder.appending(path: item.lastPathComponent)
                if files.fileExists(atPath: target.path) {
                    if adopt { continue }
                    try files.removeItem(at: target)
                }
                try files.moveItem(at: item, to: target)
            }
            // Leave nothing behind but an empty folder, which goes too.
            if (try? files.contentsOfDirectory(atPath: source.path))?.isEmpty == true {
                try? files.removeItem(at: source)
            }
        }.value
        UserDefaults.standard.set(folder.path, forKey: key)
    }
}

enum Permissions {
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var microphone: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    /// Shows the system prompt that adds the app to the Accessibility list.
    static func requestAccessibility() {
        // The value of kAXTrustedCheckOptionPrompt (a C global Swift 6 won't let us read).
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// macOS 27 renamed the Accessibility list in Privacy & Security.
    static var accessibilityPaneName: String {
        ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0))
            ? "Device Control and Data Access" : "Accessibility"
    }

    static func openAccessibilitySettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    static func openMicrophoneSettings() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private static func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}

/// The start and stop sounds, soft system sounds at levels chosen by ear; Settings › Sound scales them.
@MainActor
enum Sounds {
    static let start = sound("Tink")
    static let stop = sound("Pop")
    private static let startVolume: Float = 0.2
    private static let stopVolume: Float = 0.15

    static func playStart(volume: Double) { play(start, volume: startVolume * Float(volume)) }
    static func playStop(volume: Double) { play(stop, volume: stopVolume * Float(volume)) }

    private static func sound(_ name: String) -> NSSound? {
        NSSound(named: NSSound.Name(name))?.copy() as? NSSound
    }

    private static func play(_ sound: NSSound?, volume: Float) {
        guard let sound else { return }
        sound.stop()
        sound.volume = volume
        sound.play()
    }
}
