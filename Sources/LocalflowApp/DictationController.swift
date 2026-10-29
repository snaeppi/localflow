import AVFoundation
import AppKit
import os

/// Owns the dictation loop: shortcut → record → transcribe → paste.
///
/// Interaction: hold the push-to-talk key and speak, release to insert. The toggle shortcut starts
/// hands-free recording that ends with the next press; when it's the same key as push to talk (Right ⌘
/// by default), a quick tap does that, and so does a click of the mouse shortcut. The cancel shortcut
/// (Esc) cancels; pressing another key while holding a modifier-key shortcut (a normal shortcut such
/// as ⌘C) passes the shortcut through and silently discards the recording.
@MainActor @Observable
final class DictationController {
    enum Status: Equatable {
        case noSpeechModel
        case loadingModel
        case ready
        case needsAccessibility
        case failed(String)
    }

    private enum ModelState: Equatable {
        case loading, ready
        case failed(String)
    }

    private enum Phase {
        case idle
        case recording(handsFree: Bool, since: ContinuousClock.Instant)
        case finishing
        /// The walkthrough is testing the microphone or the shortcut; presses don't dictate.
        case testing(listening: Bool, since: ContinuousClock.Instant)

        var isBusy: Bool {
            switch self {
            case .recording, .finishing: true
            case .idle, .testing: false
            }
        }
    }

    private var modelState = ModelState.loading
    private var hotkeyActive = false
    private(set) var isRecording = false
    private(set) var lastTranscript: String?
    /// Whether the push-to-talk key is down, for the walkthrough's shortcut step.
    private(set) var isTriggerHeld = false
    /// Connected microphones, and the one a recording would use.
    private(set) var microphones: [AudioDevices.Device] = []
    private(set) var microphone: AudioDevices.Device?

    let settings = AppSettings()
    let rewriteModel = RewriteModel()
    let speechModels = SpeechModels()
    @ObservationIgnored private let hotkey = HotkeyMonitor()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let transcriber = Transcriber()
    @ObservationIgnored private let inserter = TextInserter()
    @ObservationIgnored private let recordingWindow = RecordingWindow()
    @ObservationIgnored private let rewriter = Rewriter()
    @ObservationIgnored private let learner = CorrectionLearner()
    @ObservationIgnored private let systemAudio = SystemAudio()
    @ObservationIgnored private var rewriterUnload: Task<Void, Never>?
    @ObservationIgnored private var transcriberUnload: Task<Void, Never>?
    /// What started the current recording, to tell its release from other presses.
    @ObservationIgnored private var press = HotkeyMonitor.Press.combined
    @ObservationIgnored private var phase = Phase.idle {
        didSet {
            if case .recording = phase { isRecording = true } else { isRecording = false }
        }
    }
    @ObservationIgnored private var modelLoad: Task<Void, Error>?
    @ObservationIgnored private var recorderStart: Task<Int, Error>?
    /// A press that came while the previous dictation was still being transcribed.
    @ObservationIgnored private var pendingPress: HotkeyMonitor.Press?
    @ObservationIgnored private var permissionPoll: Timer?
    /// Shows the Settings window, at a page if given; set by the app delegate.
    @ObservationIgnored var openSettings: ((SettingsView.Page?) -> Void)?
    @ObservationIgnored private let log = Logger(subsystem: "io.github.snaeppi.localflow", category: "dictation")

    /// Quick taps shorter than this switch to hands-free mode instead of push-to-talk.
    private static let tapThreshold: Duration = .milliseconds(300)
    /// Keep listening briefly after release so the last syllable isn't clipped.
    private static let releaseTail: Duration = .milliseconds(150)
    /// Delay before the recording window and start sound appear (see `beginRecording`): long enough
    /// for the second key of a typical shortcut to arrive.
    private static let feedbackDelay: Duration = .milliseconds(200)
    /// Hands-free recordings that are forgotten end on their own.
    private static let maxRecording: Duration = .seconds(15 * 60)
    /// Before "Hold Shift to send" presses Return, so the target has taken the paste.
    private static let sendDelay: Duration = .milliseconds(80)
    /// A walkthrough test left open (window behind others, user away) stops the microphone after this.
    private static let maxTest: Duration = .seconds(5 * 60)

    /// Live microphone levels while recording or testing.
    var meter: LevelMeter { recorder.meter }

    var status: Status {
        if !hotkeyActive { return .needsAccessibility }
        if activeSpeechModel == nil { return .noSpeechModel }
        switch modelState {
        case .loading: return .loadingModel
        case .ready: return .ready
        case .failed(let message): return .failed(message)
        }
    }

    func start() {
        recordingWindow.attach(recorder.meter)
        recordingWindow.actions = RecordingWindow.Actions(
            record: { [weak self] in self?.toggleRecording() },
            toggleCleanup: { [weak self] in self?.toggleCleanup() },
            openSettings: { [weak self] in self?.openSettings?(nil) },
            copyLastTranscript: { [weak self] in self?.copyLastTranscript() })
        updateRecordingWindow()
        settings.onRecordingWindowChange = { [weak self] in self?.updateRecordingWindow() }
        updateShortcuts()
        hotkey.setHandler { [weak self] event in self?.handle(event) }
        settings.onShortcutsChange = { [weak self] in
            self?.updateShortcuts()
            self?.updateRecordingWindow()
        }
        refreshMicrophones()
        AudioDevices.observe { [weak self] in self?.refreshMicrophones() }
        settings.onMicrophoneChange = { [weak self] in
            guard let self else { return }
            refreshMicrophones()
            if case .testing(true, _) = phase {
                beginTest(listening: true)  // On the newly chosen microphone.
            } else {
                Task { await self.recorder.prewarm(deviceUID: self.inputDeviceUID) }
            }
        }
        settings.onCleanupChange = { [weak self] enabled in
            guard let self else { return }
            updateRecordingWindow()
            if enabled {
                rewriteModel.install()
            } else {
                rewriteModel.cancel()
                Task { await self.rewriter.unload() }
            }
        }
        learner.onCorrection = { [weak self] correction in self?.learn(correction) }
        if Permissions.microphone == .authorized {
            let deviceUID = inputDeviceUID
            Task { [recorder] in await recorder.prewarm(deviceUID: deviceUID) }
        }

        speechModels.onInstalled = { [weak self] kind in self?.settings.speechModel = kind }
        settings.onSpeechModelChange = { [weak self] in
            guard let self else { return }
            updateRecordingWindow()
            reloadSpeechModel()
        }
        reconcileSpeechModel()
        reloadSpeechModel()
        installHotkey()
    }

    /// The chosen speech model, if it's on disk.
    var activeSpeechModel: SpeechModels.Kind? {
        speechModels.isInstalled(settings.speechModel) ? settings.speechModel : nil
    }

    /// Re-checks the model files (they can be deleted from the app folder by hand) and falls back to
    /// another installed model when the chosen one is gone, unless it's being downloaded.
    func reconcileSpeechModel() {
        speechModels.refresh()
        let chosen = settings.speechModel
        if case .downloading = speechModels.state(chosen) { return }
        guard !speechModels.isInstalled(chosen), let other = speechModels.installed.first else { return }
        settings.speechModel = other
    }

    /// Loads the chosen model now (switching models, or at launch), so CoreML compiles it before the
    /// first dictation; it unloads again after the active duration.
    private func reloadSpeechModel() {
        modelLoad = nil
        modelState = .loading
        Task {
            await transcriber.unload()
            guard activeSpeechModel != nil else { return }
            do {
                try await loadTranscriber()
                modelState = .ready
            } catch {
                log.error("Model load failed: \(error.localizedDescription, privacy: .public)")
                modelState = .failed(error.localizedDescription)
            }
        }
    }

    /// The chosen microphone, or for "Automatic" the system default unless that's a Bluetooth
    /// headset (see `AudioDevices.automaticInputUID`).
    private var inputDeviceUID: String? {
        settings.microphoneUID ?? AudioDevices.automaticInputUID()
    }

    /// The event tap needs Accessibility permission; poll until it's granted.
    private func installHotkey() {
        if Permissions.accessibilityGranted, hotkey.start() {
            permissionPoll?.invalidate()
            permissionPoll = nil
            hotkeyActive = true
            return
        }
        guard permissionPoll == nil else { return }
        permissionPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installHotkey() }
        }
    }

    // MARK: Trigger handling

    private func handle(_ event: HotkeyMonitor.Event) {
        log.debug("trigger \(String(describing: event), privacy: .public) in \(String(describing: self.phase), privacy: .public)")
        switch event {
        case .down(.pushToTalk), .down(.combined): isTriggerHeld = true
        case .up(.pushToTalk), .up(.combined): isTriggerHeld = false
        default: break
        }
        switch (phase, event) {
        case (.idle, .down(let source)):
            press = source
            beginRecording()
        case (.idle, .toggle):
            toggleRecording()
        case (.recording(false, let since), .up(let source)) where source == press:
            // Push to talk only holds; the shared key and the mouse button also switch to hands-free on a tap.
            if source != .pushToTalk, ContinuousClock.now - since < Self.tapThreshold {
                phase = .recording(handsFree: true, since: since)
                recordingWindow.show(.listening(handsFree: true))
            } else {
                finishRecording()
            }
        case (.recording(true, _), .down), (.recording, .toggle):
            finishRecording()
        case (.recording, .chord):
            // A shortcut such as Right ⌘ + C: the key goes to the app, the dictation is dropped.
            cancelRecording(reason: "shortcut")
        case (.recording, .cancel):
            cancelRecording(reason: "cancel shortcut")
        case (.finishing, .down(let source)):
            pendingPress = source  // Started once the previous text is in; see `resumePendingPress`.
        default:
            break
        }
    }

    private func updateShortcuts() {
        hotkey.shortcuts = HotkeyMonitor.Shortcuts(
            toggle: settings.toggleShortcut, pushToTalk: settings.pushToTalkShortcut, cancel: settings.cancelShortcut,
            mouse: settings.mouseShortcut)
    }

    /// While Settings records a shortcut, the current ones don't act (and aren't swallowed).
    func pauseShortcuts(_ paused: Bool) {
        hotkey.isPaused = paused
    }

    private func beginRecording() {
        reconcileSpeechModel()
        guard activeSpeechModel != nil else {
            if case .downloading(let fraction) = speechModels.state(settings.speechModel) {
                recordingWindow.show(
                    .notice("Downloading the speech model… \(Int(fraction * 100))%", symbol: "arrow.down.circle"))
            } else {
                recordingWindow.show(.notice("Download a speech model in Settings", symbol: "arrow.down.circle"))
                openSettings?(.models)
            }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            Task {
                if await AVCaptureDevice.requestAccess(for: .audio) {
                    recordingWindow.show(.notice("Microphone ready — try again", symbol: "checkmark.circle"))
                }
            }
            return
        default:
            recordingWindow.show(.notice("Allow microphone access in Settings", symbol: "mic.slash"))
            Permissions.openMicrophoneSettings()
            return
        }

        let since = ContinuousClock.now
        phase = .recording(handsFree: false, since: since)
        hotkey.capturesCancel = true
        learner.finish()
        Task {
            try? await Task.sleep(for: Self.maxRecording)
            if case .recording(_, since) = phase { finishRecording() }
        }
        // Recording starts at once, but the recording window and sound wait a moment so a shortcut
        // like Right ⌘ + C doesn't flash the dictation UI.
        Task {
            try? await Task.sleep(for: Self.feedbackDelay)
            guard case .recording(let handsFree, since) = phase else { return }
            recordingWindow.show(.listening(handsFree: handsFree))
            if settings.soundEffects { Sounds.playStart(volume: settings.soundVolume) }
            systemAudio.begin(settings.whileRecording)
            // Here rather than on key-down: a shortcut shouldn't load models.
            Task { try? await loadTranscriber() }
            prepareRewriter()
            if settings.learnCorrections, !NSApp.isActive { learner.exposeFrontmostApp() }
        }
        let deviceUID = inputDeviceUID
        if settings.boostMicrophone, let device = deviceUID.flatMap(AudioDevices.deviceID(forUID:)) {
            systemAudio.boostInput(deviceID: device)
        }
        recorderStart = Task { [recorder] in try await recorder.start(deviceUID: deviceUID) }
        Task {
            do {
                _ = try await recorderStart?.value
            } catch {
                log.error("Recording failed to start: \(error.localizedDescription, privacy: .public)")
                guard case .recording = phase else { return }  // finishRecording reports it.
                cancelRecording(reason: "microphone failed")
                recordingWindow.show(.notice("Microphone unavailable", symbol: "mic.slash"))
            }
        }
    }

    private func finishRecording() {
        guard case .recording(_, let since) = phase else { return }
        phase = .finishing
        hotkey.capturesCancel = false
        recordingWindow.show(.transcribing)
        let send = settings.shiftToSend && isShiftHeld
        if send { log.debug("Shift held: Return follows the paste") }
        let started = recorderStart
        let released = ContinuousClock.now
        Task {
            defer {
                phase = .idle
                resumePendingPress()
            }
            guard let session = try? await started?.value else {
                restoreSystemAudio()
                recordingWindow.show(.notice("Microphone unavailable", symbol: "mic.slash"))
                return
            }
            // Only wait for a tail when the key came up mid-word; usually speech has ended.
            if await recorder.isSpeechTrailing() { try? await Task.sleep(for: Self.releaseTail) }
            let recording = await recorder.stop(session: session)
            let captured = ContinuousClock.now
            restoreSystemAudio()
            let recorded = recording.samples
            guard recorded.count > Int(AudioRecorder.sampleRate * 0.3) else {
                playStopSound()
                recordingWindow.show(.hidden)
                return
            }
            // Bluetooth headsets in particular can deliver pure digital silence while they
            // switch to their call profile; say so instead of failing silently.
            guard recorded.contains(where: { abs($0) > 1e-4 }) else {
                playStopSound()
                recordingWindow.show(.notice("No sound from the microphone", symbol: "mic.slash"))
                return
            }
            do {
                let t0 = ContinuousClock.now
                let samples = await Self.processed(
                    recorded, silenceRemoval: settings.silenceRemoval, normalization: settings.normalization)
                let processed = ContinuousClock.now
                do { try await loadTranscriber() } catch { playStopSound(); throw error }
                // Starting the sound holds the main thread ~30 ms while the output device starts, a quarter to
                // a third of release to paste if it came before the transcription, so it plays while the model
                // runs.
                async let transcription = transcriber.transcribe(samples)
                playStopSound()
                let transcript = try await transcription.trimmingCharacters(in: .whitespacesAndNewlines)
                let transcribed = ContinuousClock.now
                let text = await process(transcript)
                if !text.isEmpty {
                    lastTranscript = text
                    await insert(text, send: send)
                } else {
                    recordingWindow.show(.hidden)
                }
                // Timings only; transcripts are never logged.
                let micStart = recording.firstAudio.map { "\(($0 - since).milliseconds)" } ?? "–"
                log.info(
                    "audio \(Double(samples.count) / AudioRecorder.sampleRate, format: .fixed(precision: 1), privacy: .public)s · mic start \(micStart, privacy: .public) ms · release→captured \((captured - released).milliseconds, privacy: .public) ms · processing \((processed - t0).milliseconds, privacy: .public) ms · asr \((transcribed - processed).milliseconds, privacy: .public) ms · text \((ContinuousClock.now - transcribed).milliseconds, privacy: .public) ms · release→paste \((ContinuousClock.now - released).milliseconds, privacy: .public) ms")
                if settings.saveRecordings { Self.save(samples, transcript: transcript) }
            } catch {
                log.error("Transcription failed: \(error.localizedDescription, privacy: .public)")
                recordingWindow.show(.notice("Transcription failed", symbol: "exclamationmark.triangle"))
            }
        }
    }

    /// Vocabulary spellings, the optional cleanup, then replacements — last, so they always win.
    private func process(_ transcript: String) async -> String {
        var text = settings.vocabulary.respell(transcript)
        if settings.cleansUp, rewriteModel.isInstalled, !text.isEmpty {
            do {
                try await loadRewriter()
                text = try await rewriter.rewrite(text)
            } catch {
                log.error("Cleanup failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return settings.vocabulary.applyReplacements(to: text)
    }

    /// Loads the cleanup model while the user is still speaking.
    private func prepareRewriter() {
        guard settings.cleansUp, rewriteModel.isInstalled else { return }
        Task { try? await loadRewriter() }
    }

    /// Loads the model if needed and restarts the idle countdown that unloads it again.
    private func loadRewriter() async throws {
        rewriterUnload?.cancel()
        rewriterUnload = unloadLater { [rewriter] in await rewriter.unload() }
        do {
            try await rewriter.load(RewriteModel.file)
        } catch Rewriter.Failure.loadFailed {
            log.error("Cleanup model failed to load")
            rewriteModel.reportUnusable()
            throw Rewriter.Failure.loadFailed
        }
    }

    /// Loads the speech model if it was unloaded (sharing a load under way) and restarts the countdown
    /// that unloads it again.
    private func loadTranscriber() async throws {
        transcriberUnload?.cancel()
        transcriberUnload = unloadLater { [weak self, transcriber] in
            self?.modelLoad = nil
            await transcriber.unload()
        }
        guard let kind = activeSpeechModel else { throw Transcriber.Failure.modelMissing }
        if modelLoad == nil { modelLoad = Task { [transcriber] in try await transcriber.load(kind) } }
        do {
            try await modelLoad?.value
        } catch {
            modelLoad = nil  // Try again next time.
            reconcileSpeechModel()  // Its files may have gone.
            throw error
        }
    }

    /// Runs `unload` once the models have been idle for the chosen duration (Advanced settings);
    /// they load again in a fraction of a second, while the next recording is still running.
    private func unloadLater(_ unload: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard settings.modelActiveDuration > 0 else { return nil }
        let idle = Duration.seconds(settings.modelActiveDuration)
        return Task {
            // Not while a dictation that uses the model is still under way.
            repeat {
                try? await Task.sleep(for: idle)
            } while !Task.isCancelled && phase.isBusy
            guard !Task.isCancelled else { return }
            await unload()
        }
    }

    /// Normalization and silence removal (Advanced settings › Audio processing), off the main thread.
    /// Normalizing first keeps silence removal from taking a much quieter stretch of speech for a pause
    /// (bench/README.md).
    private nonisolated static func processed(
        _ samples: [Float], silenceRemoval: Bool, normalization: Bool
    ) async -> [Float] {
        guard silenceRemoval || normalization else { return samples }
        return await Task.detached(priority: .userInitiated) {
            var samples = samples
            if normalization { samples = AudioProcessing.normalize(samples) }
            if silenceRemoval { samples = AudioProcessing.removeSilence(samples) }
            return samples
        }.value
    }

    /// Pastes or types the text (or only copies it, with Paste result text off), then presses Return
    /// for "Hold Shift to send" and starts watching for corrections.
    private func insert(_ text: String, send: Bool) async {
        guard settings.pasteResult else {
            inserter.copy(text, transient: !settings.clipboardHistory)
            recordingWindow.show(.notice("Copied to the clipboard", symbol: "doc.on.clipboard"))
            return
        }
        recordingWindow.show(.hidden)
        await inserter.insert(
            text,
            options: TextInserter.Options(
                restoreClipboard: settings.clipboard == .keep, transient: !settings.clipboardHistory,
                typing: settings.simulateKeypresses))
        if send {
            try? await Task.sleep(for: Self.sendDelay)
            TextInserter.pressReturn()
        }
        // After this dictation has finished (and a queued press has started). Not in Localflow's own
        // windows, which Accessibility would have to query from this thread.
        if settings.learnCorrections, !NSApp.isActive { Task { learner.watch(text) } }
    }

    /// Shift held as the dictation ends ("Hold Shift to send"); with Right ⇧ as a shortcut, only the left one.
    private var isShiftHeld: Bool {
        let flags = CGEventSource.flagsState(.combinedSessionState)
        let rightShift = Shortcut(.rightShift)
        guard settings.toggleShortcut == rightShift || settings.pushToTalkShortcut == rightShift else {
            return flags.contains(.maskShift)
        }
        return flags.rawValue & 0x02 != 0  // NX_DEVICELSHIFTKEYMASK
    }

    private func restoreSystemAudio() {
        systemAudio.end()
        systemAudio.restoreInput()
    }

    private func playStopSound() {
        if settings.soundEffects { Sounds.playStop(volume: settings.soundVolume) }
    }

    private func learn(_ correction: CorrectionLearner.Correction) {
        guard settings.vocabulary.learn(correction.word, misheard: correction.misheard) else { return }
        // Sessions also end when the next dictation starts; don't flash a notice over its recording window.
        guard case .idle = phase else { return }
        recordingWindow.show(.notice("Added “\(correction.word)” to Vocabulary", symbol: "text.badge.plus"))
    }

    /// Advanced settings › Save recordings, off by default: keeps each recording and its transcript in the
    /// app folder's `recordings` for evaluating models on your own voice. Nothing ever leaves the Mac.
    private static func save(_ samples: [Float], transcript: String) {
        let directory = AppFolder.recordings
        let name = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let format = AVAudioFormat(standardFormatWithSampleRate: AudioRecorder.sampleRate, channels: 1)!
            let file = try AVAudioFile(
                forWriting: directory.appendingPathComponent("\(name).wav"),
                settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: AudioRecorder.sampleRate,
                           AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
            try file.write(from: buffer)
            try transcript.write(to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        } catch {
            Logger(subsystem: "io.github.snaeppi.localflow", category: "dictation").error("Saving recording failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func cancelRecording(reason: String) {
        log.info("Dictation cancelled (\(reason, privacy: .public))")
        phase = .idle
        hotkey.capturesCancel = false
        recordingWindow.show(.hidden)
        restoreSystemAudio()
        let started = recorderStart
        Task {
            if let session = try? await started?.value { _ = await recorder.stop(session: session) }
        }
    }

    private func updateRecordingWindow() {
        recordingWindow.configure(
            enabled: settings.showRecordingWindow, alwaysShow: settings.alwaysShowRecordingWindow,
            shortcut: (settings.toggleShortcut ?? settings.pushToTalkShortcut)?.title ?? "", cleanup: settings.cleansUp)
    }

    /// The recording window's cleanup button. Without the model, or with the multilingual speech model, it
    /// opens Settings › Cleanup, which explains the 1.5 GB download or that cleanup is English-only.
    private func toggleCleanup() {
        if settings.speechModel.supportsCleanup, settings.cleanup || rewriteModel.isInstalled {
            settings.cleanup.toggle()
        } else {
            openSettings?(.cleanup)
        }
    }

    private func refreshMicrophones() {
        microphones = AudioDevices.inputDevices()
        microphone = AudioDevices.input(selection: settings.microphoneUID)
    }

    /// The recording window's record button and the menu's Toggle Recording: start hands-free dictation,
    /// or finish it.
    func toggleRecording() {
        switch phase {
        case .idle:
            press = .combined
            beginRecording()
            if case .recording(_, let since) = phase { phase = .recording(handsFree: true, since: since) }
        case .recording:
            finishRecording()
        default:
            break
        }
    }

    /// The walkthrough's tests: until `endTest`, trigger presses only update `isTriggerHeld`, and with
    /// `listening` the microphone runs so `meter` shows levels. Starts only when nothing is recording.
    func beginTest(listening: Bool) {
        switch phase {
        case .idle: break
        case .testing: endTest()
        default: return
        }
        let since = ContinuousClock.now
        phase = .testing(listening: listening, since: since)
        Task {
            try? await Task.sleep(for: Self.maxTest)
            if case .testing(_, since) = phase { endTest() }
        }
        guard listening, Permissions.microphone == .authorized else { return }
        let deviceUID = inputDeviceUID
        recorderStart = Task { [recorder] in try await recorder.start(deviceUID: deviceUID) }
    }

    func endTest() {
        guard case .testing(let listening, _) = phase else { return }
        phase = .idle
        guard listening else { return }
        let started = recorderStart
        Task {
            if let session = try? await started?.value { _ = await recorder.stop(session: session) }
        }
    }

    /// A press that arrived while the last dictation was finishing starts now: as push-to-talk
    /// if the key is still held, otherwise (it was a tap) hands-free.
    private func resumePendingPress() {
        guard let pending = pendingPress else { return }
        pendingPress = nil
        press = pending
        beginRecording()
        if !hotkey.isHeld(pending), case .recording(_, let since) = phase {
            phase = .recording(handsFree: true, since: since)
            recordingWindow.show(.listening(handsFree: true))
        }
    }

    /// `Localflow --selftest`: records 3 s from the configured microphone through the real
    /// capture and model path, and prints stats (never the transcript).
    func selfTest() async -> String {
        do {
            try await loadTranscriber()
            let device = inputDeviceUID ?? "system default"
            let t0 = ContinuousClock.now
            recordingWindow.show(.listening(handsFree: false))
            let session = try await recorder.start(deviceUID: inputDeviceUID)
            try await Task.sleep(for: .milliseconds(3000))
            recordingWindow.show(.transcribing)
            let recording = await recorder.stop(session: session)
            defer { recordingWindow.show(.hidden) }
            let samples = recording.samples
            let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
            let firstSound = samples.firstIndex { abs($0) > 1e-4 }.map { "\($0 * 1000 / 16_000) ms" } ?? "never"
            let t1 = ContinuousClock.now
            let text = try await transcriber.transcribe(samples)
            let micStart = recording.firstAudio.map { "\(($0 - t0).milliseconds) ms" } ?? "no audio"
            return "device \(device) · mic start \(micStart) · \(samples.count) samples @16k · rms \(String(format: "%.4f", rms)) · first non-silent sample \(firstSound) · asr \((ContinuousClock.now - t1).milliseconds) ms · \(text.count) chars"
        } catch {
            return "FAILED: \(error.localizedDescription)"
        }
    }

    /// `Localflow --selftest-keys`: replays Right ⌘ + F18 (no default action anywhere) through
    /// the event system and reports how the dictation state reacted.
    func selfTestChord() async -> String {
        guard settings.pushToTalkShortcut == .rightCommand else { return "skipped: push to talk isn't Right ⌘" }
        let source = CGEventSource(stateID: .privateState)
        func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, type: CGEventType? = nil) {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
            if let type { event.type = type }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
        post(54, down: true, flags: command, type: .flagsChanged)
        try? await Task.sleep(for: .milliseconds(250))
        let recordingAfterPress = isRecording
        post(79, down: true, flags: command)
        post(79, down: false, flags: command)
        try? await Task.sleep(for: .milliseconds(150))
        let recordingAfterChord = isRecording
        post(54, down: false, flags: [], type: .flagsChanged)
        try? await Task.sleep(for: .milliseconds(300))
        return "recording after press: \(recordingAfterPress) · after chord: \(recordingAfterChord) (expected true, false) · after release: \(isRecording)"
    }

    /// `Localflow --selftest-rewrite CASES OUT`: runs vocabulary spelling and cleanup over JSONL cases
    /// (`id`, `asr`, optional `dictionary`, as in bench/rewrite_cases.jsonl after rewrite_asr.py) and
    /// writes outputs and latencies for bench/rewrite_score.py. Installs the model first if needed,
    /// through the same download as Settings. The cases are synthetic, so printing them is fine.
    func selfTestRewrite(cases: URL, output: URL) async -> String {
        struct Case: Decodable {
            let id: String
            let asr: String
            let dictionary: [String]?
        }
        do {
            if !rewriteModel.isInstalled {
                rewriteModel.install()
                var reported = -1
                while !rewriteModel.isInstalled {
                    switch rewriteModel.state {
                    case .failed(let message): return "FAILED: \(message)"
                    case .absent: return "FAILED: install was cancelled"
                    case .downloading(let fraction) where Int(fraction * 10) != reported:
                        reported = Int(fraction * 10)
                        print("downloading \(reported * 10)%")
                    default: break
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                print("installed \(rewriteModel.installedSize ?? 0) bytes")
            }
            let t0 = ContinuousClock.now
            try await rewriter.load(RewriteModel.file)
            let loadMs = (ContinuousClock.now - t0).milliseconds
            let lines = try String(contentsOf: cases, encoding: .utf8).split(separator: "\n")
            var results = ""
            var latencies: [Int] = []
            for line in lines {
                let item = try JSONDecoder().decode(Case.self, from: Data(line.utf8))
                let start = ContinuousClock.now
                let text = try await rewriter.rewrite(Vocabulary(words: item.dictionary ?? []).respell(item.asr))
                let ms = (ContinuousClock.now - start).milliseconds
                latencies.append(Int(ms))
                let record = try JSONSerialization.data(withJSONObject: ["id": item.id, "output": text, "ms": ms])
                results += String(decoding: record, as: UTF8.self) + "\n"
            }
            try results.write(to: output, atomically: true, encoding: .utf8)
            guard !latencies.isEmpty else { return "FAILED: no cases" }
            latencies.sort()
            return "load \(loadMs) ms · \(latencies.count) cases · p50 \(latencies[latencies.count / 2]) ms · p90 \(latencies[latencies.count * 9 / 10]) ms · max \(latencies.last ?? 0) ms"
        } catch {
            return "FAILED: \(error.localizedDescription)"
        }
    }

    /// `Localflow --selftest-learn SENTENCE`: pastes SENTENCE into the frontmost app, watches the field
    /// like after a dictation and reports the correction it would learn (without saving it).
    func selfTestLearn(_ sentence: String) async -> String {
        var learned: CorrectionLearner.Correction?
        learner.onCorrection = { learned = $0 }
        defer { learner.onCorrection = { [weak self] correction in self?.learn(correction) } }
        learner.exposeFrontmostApp()
        await inserter.insert(sentence, options: TextInserter.Options())
        learner.watch(sentence)
        let start = ContinuousClock.now
        while learner.isWatching, ContinuousClock.now - start < .seconds(35) {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let seconds = (ContinuousClock.now - start).milliseconds / 1000
        guard let learned else { return "learned nothing (session ended after \(seconds) s)" }
        return "learned \(learned.misheard) → \(learned.word) (session ended after \(seconds) s)"
    }

    func copyLastTranscript() {
        guard let lastTranscript else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }
}
