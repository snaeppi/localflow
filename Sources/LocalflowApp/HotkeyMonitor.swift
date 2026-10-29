import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Synchronization

/// A modifier key that can be a dictation shortcut on its own (without being part of a chord).
enum TriggerKey: String, CaseIterable, Identifiable, Codable {
    case rightCommand, rightOption, rightControl, rightShift, fn

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .rightCommand: "Right ⌘"
        case .rightOption: "Right ⌥"
        case .rightControl: "Right ⌃"
        case .rightShift: "Right ⇧"
        case .fn: "Fn"
        }
    }

    var keyCode: Int64 {
        switch self {
        case .rightCommand: 54
        case .rightOption: 61
        case .rightControl: 62
        case .rightShift: 60
        case .fn: 63
        }
    }

    init?(keyCode: Int64) {
        guard let key = Self.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = key
    }

    /// Device-dependent flag bit (IOLLEvent.h `NX_DEVICER*KEYMASK`) that is set only while this
    /// physical key is held, so the left-hand twin of the key never triggers dictation.
    var deviceMask: UInt64 {
        switch self {
        case .rightCommand: 0x10
        case .rightOption: 0x40
        case .rightControl: 0x2000
        case .rightShift: 0x04
        case .fn: CGEventFlags.maskSecondaryFn.rawValue
        }
    }
}

/// A dictation shortcut (Toggle recording, Push to talk): a key with modifiers (⌥ Space), or a right-hand
/// modifier or Fn on its own (`modifierKey`).
struct Shortcut: Hashable, Sendable, Codable {
    let keyCode: Int64
    /// Command, Option, Control and Shift (`CGEventFlags` bits). Fn is left out: the hardware sets it
    /// on arrow and function keys.
    let modifiers: UInt64

    static let escape = Shortcut(keyCode: 53, modifiers: 0)
    static let rightCommand = Shortcut(.rightCommand)

    init(_ key: TriggerKey) {
        self.init(keyCode: key.keyCode, modifiers: 0)
    }

    /// The modifier key this shortcut is, when it's one pressed on its own.
    var modifierKey: TriggerKey? { modifiers == 0 ? TriggerKey(keyCode: keyCode) : nil }

    /// In the order macOS shows them.
    private static let modifierNames: [(name: String, symbol: String, flag: CGEventFlags)] = [
        ("control", "⌃", .maskControl), ("option", "⌥", .maskAlternate), ("shift", "⇧", .maskShift),
        ("command", "⌘", .maskCommand),
    ]
    private static let modifierMask = modifierNames.reduce(0) { $0 | $1.flag.rawValue }

    init(keyCode: Int64, modifiers: UInt64) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.modifierMask
    }

    /// NSEvent's modifier flags use the same bits as CGEventFlags.
    init(_ event: NSEvent) {
        self.init(keyCode: Int64(event.keyCode), modifiers: UInt64(event.modifierFlags.rawValue))
    }

    /// With `extraShift`, also when Shift is held on top (to finish a dictation with "Hold Shift to send").
    func matches(keyCode: Int64, flags: CGEventFlags, extraShift: Bool = false) -> Bool {
        guard keyCode == self.keyCode else { return false }
        let held = flags.rawValue & Self.modifierMask
        return held == modifiers || extraShift && held == modifiers | CGEventFlags.maskShift.rawValue
    }

    /// Keys that make sense without modifiers (they type nothing): F1–F20.
    var isFunctionKey: Bool { Self.functionKeys[keyCode] != nil }

    /// Keycaps to show, modifiers first.
    var keys: [String] {
        if let modifierKey { return [modifierKey.shortTitle] }
        return Self.modifierNames.filter { modifiers & $0.flag.rawValue != 0 }.map(\.symbol) + [Self.name(of: keyCode)]
    }

    var title: String { modifierKey?.shortTitle ?? keys.joined() }

    private static func name(of keyCode: Int64) -> String {
        if let name = specialKeys[keyCode] ?? functionKeys[keyCode] { return name }
        return KeyboardLayout.current?.character(keyCode: Int(keyCode))?.uppercased() ?? "Key \(keyCode)"
    }

    private static let specialKeys: [Int64: String] = [
        49: "Space", 36: "↩", 76: "⌤", 48: "⇥", 51: "⌫", 117: "⌦", 53: "esc", 123: "←", 124: "→", 125: "↓",
        126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟", 114: "Help",
    ]
    private static let functionKeys: [Int64: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
        90: "F20",
    ]

    // Written as names ("option") so settings.json stays readable.
    private enum CodingKeys: String, CodingKey { case keyCode, modifiers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let names = try container.decode([String].self, forKey: .modifiers)
        self.init(
            keyCode: try container.decode(Int64.self, forKey: .keyCode),
            modifiers: Self.modifierNames.filter { names.contains($0.name) }.reduce(0) { $0 | $1.flag.rawValue })
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyCode, forKey: .keyCode)
        try container.encode(Self.modifierNames.filter { modifiers & $0.flag.rawValue != 0 }.map(\.name), forKey: .modifiers)
    }
}

/// A mouse button other than the primary and secondary one, for the mouse shortcut.
struct MouseButton: Hashable, Sendable, Codable {
    /// CGEvent numbering: 2 is the middle button, 3 and 4 the side buttons of most mice.
    let number: Int64

    var title: String { number == 2 ? "Middle button" : "Button \(number + 1)" }
}

/// The current keyboard layout, to name keys and find the key that types a character.
struct KeyboardLayout {
    private let data: Data

    static var current: KeyboardLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        return KeyboardLayout(data: Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data)
    }

    /// What the key types with the given Carbon modifiers (e.g. `cmdKey`), without dead keys.
    func character(keyCode: Int, carbonModifiers: Int = 0) -> String? {
        data.withUnsafeBytes { bytes -> String? in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(
                layout, UInt16(keyCode), UInt16(kUCKeyActionDown), UInt32(carbonModifiers >> 8) & 0xFF,
                UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length,
                &chars)
            guard status == noErr, length > 0 else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }
}

/// Watches the dictation shortcuts system-wide through a session event tap.
///
/// Reports the toggle and push-to-talk shortcuts (when both are the same, one key that does both:
/// `Press.combined`), the mouse button, the cancel shortcut while `capturesCancel` is set, and any other
/// key pressed while a modifier-key shortcut is held (a chord such as Right ⌘ + C, which should not
/// dictate). Matched key combinations are swallowed so they don't also reach the frontmost app.
///
/// The tap runs on its own thread: every keystroke on the system passes through it, so it must
/// never wait for the main thread. Events are delivered to `onEvent` on the main queue.
final class HotkeyMonitor: Sendable {
    /// What a recording is held with: push to talk only holds; the combined key and the mouse button also
    /// switch to hands-free on a tap.
    enum Press: Sendable { case pushToTalk, combined, mouse }
    enum Event: Sendable, Equatable { case down(Press), up(Press), chord, cancel, toggle }

    /// Tag on events we synthesize ourselves (the paste keystroke) so the tap ignores them.
    static let syntheticEventTag: Int64 = 0x4C_46_4C_57  // "LFLW"

    struct Shortcuts: Sendable {
        var toggle: Shortcut? = .rightCommand
        var pushToTalk: Shortcut? = .rightCommand
        var cancel = Shortcut.escape
        var mouse: MouseButton?

        /// What pressing `shortcut` does: hold (push to talk, or both when the toggle is the same) or toggle.
        func press(for shortcut: Shortcut) -> Press? {
            guard shortcut == pushToTalk else { return nil }
            return shortcut == toggle ? .combined : .pushToTalk
        }

        func shortcut(for press: Press) -> Shortcut? {
            press == .mouse ? nil : pushToTalk
        }
    }

    private struct State {
        var shortcuts = Shortcuts()
        var capturesCancel = false
        var paused = false
        /// Modifier-key shortcuts held down, and whether another key was pressed meanwhile.
        var heldModifiers: Set<TriggerKey> = []
        var chorded = false
        var comboDown = false
        var mouseDown = false
        /// A matched key combination's key: its repeats and its release are swallowed too.
        var swallowedKey: Int64?
        var onEvent: @MainActor @Sendable (Event) -> Void = { _ in }

        mutating func reset() {
            heldModifiers = []
            comboDown = false
            mouseDown = false
            swallowedKey = nil
        }
    }

    private let state = Mutex(State())
    /// Written once in `start()` before the tap thread exists; afterwards only read.
    nonisolated(unsafe) private var tap: CFMachPort?

    var shortcuts: Shortcuts {
        get { state.withLock { $0.shortcuts } }
        set {
            state.withLock {
                $0.shortcuts = newValue
                $0.reset()
            }
        }
    }

    var capturesCancel: Bool {
        get { state.withLock { $0.capturesCancel } }
        set { state.withLock { $0.capturesCancel = newValue } }
    }

    /// While Settings records a new shortcut, every key passes through untouched.
    var isPaused: Bool {
        get { state.withLock { $0.paused } }
        set {
            state.withLock {
                $0.paused = newValue
                $0.reset()
            }
        }
    }

    /// Whether the key or button behind a press is physically held right now.
    func isHeld(_ press: Press) -> Bool {
        let shortcuts = self.shortcuts
        if press == .mouse {
            guard let number = shortcuts.mouse?.number, let button = CGMouseButton(rawValue: UInt32(number)) else {
                return false
            }
            return CGEventSource.buttonState(.combinedSessionState, button: button)
        }
        guard let shortcut = shortcuts.shortcut(for: press) else { return false }
        if let key = shortcut.modifierKey {
            return CGEventSource.flagsState(.combinedSessionState).rawValue & key.deviceMask != 0
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(shortcut.keyCode))
    }

    func setHandler(_ handler: @escaping @MainActor @Sendable (Event) -> Void) {
        state.withLock { $0.onEvent = handler }
    }

    /// Installs the tap. Fails until the app has Accessibility permission.
    func start() -> Bool {
        if tap != nil { return true }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp, .otherMouseDragged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: hotkeyTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        self.tap = tap
        nonisolated(unsafe) let port = tap
        let thread = Thread {
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "Localflow hotkey tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// Runs on the tap thread. Returns true when the event should be swallowed.
    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        var emit: [Event] = []
        var swallow = false
        let handler = state.withLock { s -> @MainActor @Sendable (Event) -> Void in
            switch type {
            case .tapDisabledByTimeout, .tapDisabledByUserInput:
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
                emit = Self.missedReleases(&s)
            case _ where s.paused:
                break
            case .flagsChanged:
                emit = Self.modifierChanged(&s, event)
            case .keyDown:
                if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventTag { break }
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                // While recording, Shift on top still matches: it finishes a dictation with "Hold Shift to send".
                let recording = s.capturesCancel
                let combination = { (shortcut: Shortcut) in
                    shortcut.modifierKey == nil
                        && shortcut.matches(keyCode: key, flags: event.flags, extraShift: recording)
                }
                if s.swallowedKey == key {
                    swallow = true
                } else if s.capturesCancel, s.shortcuts.cancel.matches(keyCode: key, flags: event.flags) {
                    emit.append(.cancel)
                    swallow = true
                } else if let pushToTalk = s.shortcuts.pushToTalk, combination(pushToTalk) {
                    if !isRepeat, !s.comboDown, let press = s.shortcuts.press(for: pushToTalk) {
                        s.comboDown = true
                        emit.append(.down(press))
                    }
                    s.swallowedKey = key
                    swallow = true
                } else if let toggle = s.shortcuts.toggle, combination(toggle) {
                    if !isRepeat { emit.append(.toggle) }
                    s.swallowedKey = key
                    swallow = true
                } else if !s.heldModifiers.isEmpty {
                    s.chorded = true
                    // Only a held recording is cancelled; a toggle key just won't toggle on release.
                    if s.heldModifiers.contains(where: { s.shortcuts.press(for: Shortcut($0)) != nil }) {
                        emit.append(.chord)
                    }
                }
            case .keyUp:
                let key = event.getIntegerValueField(.keyboardEventKeycode)
                guard s.swallowedKey == key else { break }
                s.swallowedKey = nil
                swallow = true
                if s.comboDown, let pushToTalk = s.shortcuts.pushToTalk, pushToTalk.keyCode == key,
                    let press = s.shortcuts.press(for: pushToTalk)
                {
                    s.comboDown = false
                    emit.append(.up(press))
                }
            case .otherMouseDown, .otherMouseUp, .otherMouseDragged:
                guard event.getIntegerValueField(.mouseEventButtonNumber) == s.shortcuts.mouse?.number else { break }
                swallow = true
                if type == .otherMouseDown, !s.mouseDown {
                    s.mouseDown = true
                    emit.append(.down(.mouse))
                } else if type == .otherMouseUp, s.mouseDown {
                    s.mouseDown = false
                    emit.append(.up(.mouse))
                }
            default:
                break
            }
            return s.onEvent
        }
        // The main queue keeps events in order (separate Tasks wouldn't guarantee that).
        if !emit.isEmpty {
            let events = emit
            DispatchQueue.main.async { MainActor.assumeIsolated { events.forEach(handler) } }
        }
        return swallow
    }

    /// A modifier-key shortcut went down or up. The hold shortcuts act at once; a toggle on its own acts
    /// when released without another key, so Right ⌥ + C still works as a shortcut.
    private static func modifierChanged(_ s: inout State, _ event: CGEvent) -> [Event] {
        guard let key = TriggerKey(keyCode: event.getIntegerValueField(.keyboardEventKeycode)) else { return [] }
        let shortcut = Shortcut(key)
        let press = s.shortcuts.press(for: shortcut)
        guard press != nil || shortcut == s.shortcuts.toggle else { return [] }
        let down = event.flags.rawValue & key.deviceMask != 0
        guard down != s.heldModifiers.contains(key) else { return [] }
        if down {
            s.heldModifiers.insert(key)
            s.chorded = false
            return press.map { [.down($0)] } ?? []
        }
        s.heldModifiers.remove(key)
        if let press { return [.up(press)] }
        return s.chorded ? [] : [.toggle]
    }

    /// After macOS switched the tap off: releases that went by meanwhile.
    private static func missedReleases(_ s: inout State) -> [Event] {
        var events: [Event] = []
        let flags = CGEventSource.flagsState(.combinedSessionState).rawValue
        for key in s.heldModifiers where flags & key.deviceMask == 0 {
            s.heldModifiers.remove(key)
            if let press = s.shortcuts.press(for: Shortcut(key)) { events.append(.up(press)) }
        }
        if s.comboDown, let pushToTalk = s.shortcuts.pushToTalk,
            !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(pushToTalk.keyCode))
        {
            s.comboDown = false
            s.swallowedKey = nil
            if let press = s.shortcuts.press(for: pushToTalk) { events.append(.up(press)) }
        }
        if s.mouseDown, let number = s.shortcuts.mouse?.number, let button = CGMouseButton(rawValue: UInt32(number)),
            !CGEventSource.buttonState(.combinedSessionState, button: button)
        {
            s.mouseDown = false
            events.append(.up(.mouse))
        }
        return events
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    return monitor.handle(type, event) ? nil : Unmanaged.passUnretained(event)
}
