@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Synchronization
import os

/// Captures microphone audio and returns it as 16 kHz mono Float32, the format the ASR model
/// expects.
///
/// Uses CoreAudio's HAL input unit directly rather than AVAudioEngine: it binds to an explicit
/// device and always reports that device's real format (AVAudioEngine keeps a stale format
/// after switching away from the default device, which crashes tap installation). The unit is
/// kept initialized between recordings so a key press only has to start I/O.
actor AudioRecorder {
    static let sampleRate = 16_000.0

    struct Recording {
        var samples: [Float]
        /// When the first audio arrived, to measure how long the microphone took to start.
        var firstAudio: ContinuousClock.Instant?
    }

    /// Live input levels for the recording window.
    nonisolated let meter = LevelMeter()
    private let buffer: CaptureBuffer
    private var input: HALInput?
    /// Identifies the current recording, so a late stop from a cancelled one can't end the next.
    private var session = 0
    private let log = Logger(subsystem: "io.github.snaeppi.localflow", category: "audio")

    init() {
        buffer = CaptureBuffer(meter: meter)
    }

    /// Opens the device ahead of the first key press. `deviceUID` nil means the system default.
    func prewarm(deviceUID: String?) {
        _ = try? prepareInput(deviceUID: deviceUID)
    }

    /// Starts capturing and returns a session token for `stop`.
    func start(deviceUID: String?) throws -> Int {
        let t0 = ContinuousClock.now
        session += 1
        do {
            let input = try prepareInput(deviceUID: deviceUID)
            buffer.begin(sampleRate: input.sampleRate)
            try input.start()
        } catch {
            // The device may have vanished or been reconfigured; retry once with a fresh unit.
            log.error("Microphone start failed (\(error.localizedDescription, privacy: .public)); retrying")
            input = nil
            let input = try prepareInput(deviceUID: deviceUID)
            buffer.begin(sampleRate: input.sampleRate)
            try input.start()
        }
        log.info("Microphone started in \((ContinuousClock.now - t0).milliseconds, privacy: .public) ms")
        return session
    }

    /// Stops capturing and returns everything recorded since `start`, resampled to 16 kHz.
    func stop(session: Int) -> Recording {
        guard session == self.session, buffer.isCapturing else { return Recording(samples: []) }
        let raw = buffer.end()
        if let errors = input?.takeRenderErrors(), errors > 0 {
            log.error("Microphone delivered \(errors, privacy: .public) failed buffers")
        }
        // Stopping the hardware takes tens of milliseconds; hand the audio over first.
        Task { stopIfIdle() }
        return Recording(samples: Self.resample(raw.samples, from: raw.sampleRate), firstAudio: raw.firstAudio)
    }

    /// Whether the last moments of audio still contain speech, i.e. the key was released
    /// mid-word and a short tail is worth recording.
    func isSpeechTrailing() -> Bool {
        buffer.isSpeechTrailing
    }

    private func stopIfIdle() {
        if !buffer.isCapturing { input?.stop() }
    }

    private func prepareInput(deviceUID: String?) throws -> HALInput {
        guard let device = deviceUID.flatMap(AudioDevices.deviceID(forUID:)) ?? AudioDevices.defaultInputID() else {
            throw RecorderError.noInputDevice
        }
        if let input, input.deviceID == device, input.isCurrent { return input }
        input = nil
        let fresh = try HALInput(deviceID: device, buffer: buffer)
        input = fresh
        return fresh
    }

    /// One-shot high-quality conversion to 16 kHz (milliseconds even for long recordings).
    private static func resample(_ samples: [Float], from rate: Double) -> [Float] {
        guard rate != sampleRate, !samples.isEmpty,
            let source = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
            let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let converter = AVAudioConverter(from: source, to: target),
            let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(samples.count)),
            let output = AVAudioPCMBuffer(
                pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(samples.count) * sampleRate / rate) + 1024)
        else { return samples }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        input.frameLength = input.frameCapacity
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        // The input block runs synchronously inside convert(to:error:withInputFrom:).
        nonisolated(unsafe) var supplied = false
        let status = converter.convert(to: output, error: nil) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .endOfStream
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error else { return samples }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

enum RecorderError: LocalizedError {
    case noInputDevice
    case coreAudio(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone available"
        case .coreAudio(let call, let status): "\(call) failed (\(status))"
        }
    }
}

/// A CoreAudio AUHAL unit capturing the first channel of one input device at its native rate.
private final class HALInput: @unchecked Sendable {
    // Mutated only from the AudioRecorder actor; the render callback reads `unit`, `bufferList`
    // and `buffer`, which never change after init.
    let deviceID: AudioDeviceID
    private(set) var sampleRate: Double = 0
    private let unit: AudioUnit
    private let buffer: CaptureBuffer
    private let bufferList: UnsafeMutableAudioBufferListPointer
    private static let maxFrames: UInt32 = 8192
    private var running = false
    private let renderErrors = Atomic<Int>(0)

    /// Failed render calls since the last check; e.g. a device that changed format mid-stream.
    func takeRenderErrors() -> Int { renderErrors.exchange(0, ordering: .relaxed) }

    init(deviceID: AudioDeviceID, buffer: CaptureBuffer) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        var unit: AudioUnit?
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RecorderError.coreAudio("AudioComponentFindNext", -1)
        }
        try Self.check("AudioComponentInstanceNew", AudioComponentInstanceNew(component, &unit))
        self.unit = unit!
        self.deviceID = deviceID
        self.buffer = buffer
        bufferList = AudioBufferList.allocate(maximumBuffers: 1)
        bufferList[0] = AudioBuffer(
            mNumberChannels: 1, mDataByteSize: Self.maxFrames * 4,
            mData: UnsafeMutableRawPointer.allocate(byteCount: Int(Self.maxFrames) * 4, alignment: 16))
        try configure()  // On failure deinit disposes the unit.
    }

    deinit { dispose() }

    /// False once the device's sample rate changed (e.g. in Audio MIDI Setup).
    var isCurrent: Bool { (try? hardwareFormat().mSampleRate) == sampleRate }

    func start() throws {
        guard !running else { return }
        try Self.check("AudioOutputUnitStart", AudioOutputUnitStart(unit))
        running = true
    }

    func stop() {
        guard running else { return }
        AudioOutputUnitStop(unit)
        running = false
    }

    private func configure() throws {
        var on: UInt32 = 1
        var off: UInt32 = 0
        let size32 = UInt32(MemoryLayout<UInt32>.size)
        try Self.check(
            "EnableIO input", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, size32))
        try Self.check(
            "EnableIO output", AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, size32))
        var device = deviceID
        try Self.check(
            "CurrentDevice",
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device,
                UInt32(MemoryLayout<AudioDeviceID>.size)))
        let hardware = try hardwareFormat()
        guard hardware.mSampleRate > 0 else { throw RecorderError.noInputDevice }
        sampleRate = hardware.mSampleRate
        // Mono float at the device rate: the HAL can't resample input, but it does pick channel 1.
        var client = AudioStreamBasicDescription(
            mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32,
            mReserved: 0)
        try Self.check(
            "StreamFormat",
            AudioUnitSetProperty(
                unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)))
        var maxFrames = Self.maxFrames
        AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maxFrames, size32)
        var callback = AURenderCallbackStruct(
            inputProc: halInputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(
            "SetInputCallback",
            AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &callback,
                UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
        try Self.check("AudioUnitInitialize", AudioUnitInitialize(unit))
    }

    private func hardwareFormat() throws -> AudioStreamBasicDescription {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try Self.check(
            "hardware format", AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &format, &size))
        return format
    }

    /// Realtime audio thread: pull the new frames and copy them out; heavier work (resampling)
    /// happens once at stop.
    fileprivate func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, _ time: UnsafePointer<AudioTimeStamp>, _ frames: UInt32
    ) -> OSStatus {
        let frames = min(frames, Self.maxFrames)
        bufferList[0].mDataByteSize = frames * 4
        let status = AudioUnitRender(unit, flags, time, 1, frames, bufferList.unsafeMutablePointer)
        guard status == noErr, let data = bufferList[0].mData else {
            renderErrors.add(1, ordering: .relaxed)
            return status
        }
        buffer.append(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(frames)))
        return noErr
    }

    private func dispose() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        bufferList[0].mData?.deallocate()
        free(bufferList.unsafeMutablePointer)
    }

    private static func check(_ call: String, _ status: OSStatus) throws {
        if status != noErr { throw RecorderError.coreAudio(call, status) }
    }
}

private func halInputCallback(
    refCon: UnsafeMutableRawPointer, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    time: UnsafePointer<AudioTimeStamp>, bus: UInt32, frames: UInt32, data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    Unmanaged<HALInput>.fromOpaque(refCon).takeUnretainedValue().render(flags, time, frames)
}

/// Accumulates captured samples (at the device rate) and derives input levels.
private final class CaptureBuffer: Sendable {
    private struct State {
        var samples: [Float] = []
        var sampleRate = 48_000.0
        var capturing = false
        var firstAudio: ContinuousClock.Instant?
        var energy: Float = 0
        var energyCount = 0
        var levels: [Float] = []
    }

    private let state = Mutex(State())
    private let meter: LevelMeter

    /// 160 ms of 20 ms levels; speech anywhere in it means the speaker hadn't finished.
    private static let trailingLevels = 8

    init(meter: LevelMeter) {
        self.meter = meter
    }

    var isCapturing: Bool { state.withLock { $0.capturing } }

    /// Speech means clearly above this recording's own noise floor (~9 dB over its quietest
    /// fifth), so a noisy room or a hissy mic doesn't count as talking.
    var isSpeechTrailing: Bool {
        let levels = state.withLock { $0.levels }  // Copy out; don't hold up the audio thread.
        guard levels.count > Self.trailingLevels else { return true }
        let floor = levels.sorted()[levels.count / 5]
        let threshold = max(floor + 0.2, 0.3)
        return levels.suffix(Self.trailingLevels).contains { $0 > threshold }
    }

    func begin(sampleRate: Double) {
        state.withLock { s in
            s = State()
            s.sampleRate = sampleRate
            // Ten minutes of headroom so the audio thread never has to grow the buffer in
            // practice; untouched pages of the reservation cost no memory.
            s.samples.reserveCapacity(Int(sampleRate * 600))
            s.levels.reserveCapacity(30_000)
            s.capturing = true
        }
    }

    func end() -> (samples: [Float], sampleRate: Double, firstAudio: ContinuousClock.Instant?) {
        state.withLock { s in
            s.capturing = false
            defer { s.samples = [] }
            return (s.samples, s.sampleRate, s.firstAudio)
        }
    }

    func append(_ frames: UnsafeBufferPointer<Float>) {
        state.withLock { s in
            guard s.capturing else { return }
            if s.firstAudio == nil { s.firstAudio = .now }
            s.samples.append(contentsOf: frames)
            let window = Int(s.sampleRate * 0.02)
            for x in frames {
                s.energy += x * x
                s.energyCount += 1
                if s.energyCount == window {
                    let db = 10 * log10(max(s.energy / Float(window), 1e-10))
                    let level = min(1, max(0, (db + 55) / 45))  // −55 dBFS → 0, −10 dBFS → 1
                    s.levels.append(level)
                    meter.push(level)
                    s.energy = 0
                    s.energyCount = 0
                }
            }
        }
    }
}

/// Input levels (one per 20 ms, 0…1) handed from the audio thread to the UI, which pulls
/// them each frame.
final class LevelMeter: Sendable {
    private let pending = Mutex<[Float]>([])

    fileprivate func push(_ level: Float) {
        pending.withLock { levels in
            if levels.count >= 64 { levels.removeFirst() }
            levels.append(level)
        }
    }

    func drain() -> [Float] {
        pending.withLock { levels in
            defer { levels.removeAll(keepingCapacity: true) }
            return levels
        }
    }
}

extension Duration {
    var milliseconds: Int { Int(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15) }
}
