import CoreAudio

/// Minimal CoreAudio device enumeration for the microphone picker.
enum AudioDevices {
    struct Device: Identifiable, Hashable {
        let uid: String
        let name: String
        /// An SF Symbol for the kind of device, guessed from its name.
        let symbol: String
        var id: String { uid }
    }

    static func inputDevices() -> [Device] {
        allDeviceIDs().compactMap(device)
    }

    /// The microphone a recording uses for the chosen UID (nil: "Automatic"), falling back to the
    /// system default as `AudioRecorder` does when the device is gone.
    static func input(selection uid: String?) -> Device? {
        ((uid ?? automaticInputUID()).flatMap(deviceID(forUID:)) ?? defaultInputID()).flatMap(device)
    }

    private static func device(_ id: AudioDeviceID) -> Device? {
        guard hasInput(id), let uid = string(id, kAudioDevicePropertyDeviceUID),
            let name = string(id, kAudioObjectPropertyName)
        else { return nil }
        return Device(uid: uid, name: name, symbol: symbol(name: name.lowercased(), transport: transport(id)))
    }

    private static func symbol(name: String, transport: UInt32) -> String {
        let byName = [
            ("airpods pro", "airpods.pro"), ("airpods max", "airpods.max"), ("airpods", "airpods"),
            ("beats", "beats.headphones"), ("earpods", "earpods"), ("iphone", "iphone"),
            ("macbook", "laptopcomputer"), ("imac", "desktopcomputer"), ("mac mini", "macmini"),
            ("mac studio", "macstudio"), ("display", "display"),
        ]
        if let match = byName.first(where: { name.contains($0.0) }) { return match.1 }
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "headphones"
        default: return "mic"
        }
    }

    /// Calls `changed` on the main queue whenever a device comes or goes or the default input changes.
    static func observe(_ changed: @escaping @MainActor @Sendable () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                MainActor.assumeIsolated { changed() }
            }
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        allDeviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    /// The input "Automatic" resolves to: the system default, except that a Bluetooth headset
    /// is skipped in favour of the Mac's own microphone. Headset mics use a narrow-band call
    /// codec that costs accuracy, take up to seconds to switch profiles (clipping the first
    /// words), and drop the headphones' playback to call quality while recording.
    static func automaticInputUID() -> String? {
        guard let current = defaultInputID(), isBluetooth(current),
            let builtIn = allDeviceIDs().first(where: { hasInput($0) && transport($0) == kAudioDeviceTransportTypeBuiltIn })
        else { return nil }
        return string(builtIn, kAudioDevicePropertyDeviceUID)
    }

    static func defaultInputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
            id != 0
        else { return nil }
        return id
    }

    private static func isBluetooth(_ id: AudioDeviceID) -> Bool {
        let type = transport(id)
        return type == kAudioDeviceTransportTypeBluetooth || type == kAudioDeviceTransportTypeBluetoothLE
    }

    private static func transport(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr ? type : 0
    }

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
