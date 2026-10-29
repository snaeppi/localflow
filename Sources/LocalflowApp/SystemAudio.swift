import AudioToolbox
import CoreAudio
import Foundation
import os

/// Other apps' audio while recording (Settings › Sound) and the microphone volume boost.
@MainActor final class SystemAudio {
    enum WhileRecording: String, CaseIterable, Codable { case keepPlaying, pause, mute, lower }

    private nonisolated static let log = Logger(subsystem: "io.github.snaeppi.localflow", category: "system-audio")
    /// Mute and Lower wait this long so Localflow's own start sound isn't cut off (Tink.aiff lasts 0.56 s, mostly tail).
    private static let outputDelay = Duration.milliseconds(250)
    /// "Lower" leaves other audio audible but out of the way.
    private static let loweredFraction: Float32 = 0.3
    /// Per-channel microphone controls are looked up for these elements when there is no main one.
    private static let maxInputChannels: UInt32 = 8
    /// What `/usr/bin/perl` runs to call `localflow_now_playing` from the dylib given as its argument.
    private nonisolated static let nowPlayingScript = """
        use DynaLoader;
        my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
        my $sym = DynaLoader::dl_find_symbol($lib, "localflow_now_playing") or die "no symbol";
        DynaLoader::dl_install_xsub("main::now_playing", $sym);
        main::now_playing();
        """

    /// The helper built by scripts/build-app.sh; nil in a bare `swift build` binary, where Pause does nothing.
    private let nowPlayingLibrary: URL?
    private var task: Task<Void, Never>?
    /// True while we hold the other app's playback paused, so `end` sends play only for our own pause.
    private(set) var pausedMedia = false
    private var output: Change?
    private var input: [Change] = []

    init(nowPlayingLibrary: URL? = Bundle.main.url(forResource: "NowPlaying", withExtension: "dylib")) {
        self.nowPlayingLibrary = nowPlayingLibrary
    }

    /// Called when a recording's start feedback appears (after the start sound began playing).
    func begin(_ mode: WhileRecording) {
        end()
        guard mode != .keepPlaying else { return }
        task = Task { [self] in
            if mode == .pause {
                // perl answers in 30–50 ms; `end` cancels this task, so a very short recording never pauses.
                guard let nowPlayingLibrary, let state = await Self.nowPlaying(nowPlayingLibrary),
                    state.playing, !Task.isCancelled
                else { return }
                Self.send(.pause)
                pausedMedia = true
                Self.log.info("paused playback of pid \(state.pid, privacy: .public)")
            } else {
                try? await Task.sleep(for: Self.outputDelay)
                if !Task.isCancelled { changeOutput(mode) }
            }
        }
    }

    /// Called when the recording stops or is cancelled; restores whatever `begin` changed.
    func end() {
        task?.cancel()
        task = nil
        if pausedMedia {
            Self.send(.play)
            pausedMedia = false
        }
        guard let change = output else { return }
        output = nil
        if !change.undo() { Self.log.debug("output was changed meanwhile, left as it is") }
    }

    /// Sets the input device's volume to the maximum; `restoreInput()` puts the previous value back.
    func boostInput(deviceID: AudioDeviceID) {
        restoreInput()
        let main = Control(deviceID, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput)
        let controls =
            main.isSettable
            ? [main]
            : (1...Self.maxInputChannels).map {
                Control(deviceID, kAudioDevicePropertyVolumeScalar, scope: kAudioObjectPropertyScopeInput, element: $0)
            }
        input = controls.compactMap { Change($0) { _ in 1 } }
        Self.log.debug("boosted \(self.input.count, privacy: .public) controls of input \(deviceID, privacy: .public)")
    }

    /// Puts the volume back where `boostInput` found it, unless the user has changed it since.
    func restoreInput() {
        for change in input where !change.undo() { Self.log.debug("input volume was changed meanwhile") }
        input = []
    }

    // MARK: Output

    private func changeOutput(_ mode: WhileRecording) {
        guard let device = Self.defaultOutputDevice() else { return }
        let scope = kAudioObjectPropertyScopeOutput
        let muteSwitch = Control(device, kAudioDevicePropertyMute, scope: scope)
        let volume = Control(device, kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: scope)
        if mode == .mute {
            // Devices without a mute switch get volume 0 instead.
            output = muteSwitch.isSettable ? Change(muteSwitch) { _ in 1 } : Change(volume) { _ in 0 }
        } else {
            output = Change(volume) { $0 * Self.loweredFraction }
        }
        Self.log.debug("output device \(device, privacy: .public): changed \(self.output != nil, privacy: .public)")
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        let system = Control(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
        guard let id = system.read(AudioDeviceID(0)), id != 0 else { return nil }
        return id
    }

    // MARK: Media

    private struct NowPlaying: Decodable {
        let playing: Bool
        let pid: Int
    }

    /// Asks the helper, nil if it fails. Runs off the main actor: starting perl and waiting for it take 30–50 ms.
    @concurrent private static func nowPlaying(_ library: URL) async -> NowPlaying? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        process.arguments = ["-e", nowPlayingScript, library.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        // The helper gives up after 1 s itself; this only covers perl hanging before it gets there.
        let watchdog = Task { try await Task.sleep(for: .seconds(3)); process.terminate() }
        defer { watchdog.cancel() }
        let started = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            process.terminationHandler = { _ in done.resume(returning: true) }
            do { try process.run() } catch { done.resume(returning: false) }
        }
        let data = started ? pipe.fileHandleForReading.availableData : Data()  // A few bytes; perl has exited.
        let state = try? JSONDecoder().decode(NowPlaying.self, from: data)
        if state == nil { log.error("no answer from the now-playing helper (started: \(started, privacy: .public))") }
        return state
    }

    private enum Command: UInt32 { case play = 0, pause = 1 }  // MRMediaRemoteCommand values.
    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool
    /// Sending works from any process; only reading what is playing is restricted. Private framework.
    private static let sendCommand: SendCommand? = {
        guard let framework = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
            let symbol = dlsym(framework, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    private static func send(_ command: Command) {
        let ok = sendCommand?(command.rawValue, nil) ?? false
        log.debug("sent \(String(describing: command), privacy: .public): \(ok, privacy: .public)")
    }
}

// MARK: - CoreAudio properties

/// One CoreAudio property of an object, read and written as a `Float32` (muting is a 0/1 flag).
private struct Control {
    let object: AudioObjectID
    var address: AudioObjectPropertyAddress

    init(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) {
        self.object = object
        address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    var isSettable: Bool {
        var settable: DarwinBoolean = false
        var address = address
        return AudioObjectHasProperty(object, &address)
            && AudioObjectIsPropertySettable(object, &address, &settable) == noErr && settable.boolValue
    }

    var value: Float32? {
        address.mSelector == kAudioDevicePropertyMute ? read(UInt32(0)).map(Float32.init) : read(Float32(0))
    }

    func set(_ value: Float32) -> Bool {
        address.mSelector == kAudioDevicePropertyMute ? write(UInt32(value)) : write(value)
    }

    func read<T: BitwiseCopyable>(_ initial: T) -> T? {
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        var address = address
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private func write<T: BitwiseCopyable>(_ value: T) -> Bool {
        var value = value
        var address = address
        return AudioObjectSetPropertyData(object, &address, 0, nil, UInt32(MemoryLayout<T>.size), &value) == noErr
    }
}

/// A control we moved: `undo` puts `original` back only while it still reads `applied`.
private struct Change {
    /// Finer than the steps of the volume keys (1/64 with Shift-Option), coarser than a device's rounding.
    private static let tolerance: Float32 = 0.005
    let control: Control
    let original: Float32
    let applied: Float32

    /// Nil when the control can't be changed or is at the target already.
    init?(_ control: Control, to target: (Float32) -> Float32) {
        guard control.isSettable, let original = control.value else { return nil }
        let wanted = target(original)
        guard wanted != original, control.set(wanted), let applied = control.value else { return nil }
        (self.control, self.original, self.applied) = (control, original, applied)
    }

    func undo() -> Bool {
        guard let now = control.value, abs(now - applied) <= Self.tolerance else { return false }
        return control.set(original)
    }
}
