// Dictates test clips into Localflow the way a user does: holds Right ⌘, plays the clip on the
// speakers (Localflow listens on the built-in microphone), releases GAP seconds after it ends.
// Built as an app with Localflow's bundle ID and signature, so it shares its permission to post
// key events. Pastes must land in TextTarget: before each release the frontmost app is checked,
// and anything else cancels the dictation (Esc) and stops the run.
// usage: LFDriver -manifest FILE -out FILE [-gap 0.3] [-pause 2.5] [-limit N] [-warmup 1]
import AppKit
import AVFoundation

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

struct Clip: Decodable {
    let id: String
    let audio: String
    let duration: Double
}

let target = "io.github.snaeppi.localflow.texttarget"
let rightCommand = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x10)
let source = CGEventSource(stateID: .privateState)

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
func front() -> String { NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none" }

func post(_ key: CGKeyCode, down: Bool, flags: CGEventFlags, flagsChanged: Bool = false) {
    guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { return }
    if flagsChanged { event.type = .flagsChanged }
    event.flags = flags
    event.post(tap: .cghidEventTap)
}

@MainActor
func run() async -> Int32 {
    guard CGPreflightPostEventAccess() else { print("no permission to post events"); return 1 }
    let manifest = URL(fileURLWithPath: argument("-manifest")!)
    let gap = Double(argument("-gap") ?? "0.3")!
    let pause = Double(argument("-pause") ?? "2.5")!
    let warmup = Int(argument("-warmup") ?? "1")!
    var clips = try! String(contentsOf: manifest, encoding: .utf8).split(separator: "\n")
        .map { try! JSONDecoder().decode(Clip.self, from: Data($0.utf8)) }
    if let limit = argument("-limit").flatMap(Int.init), limit > 0 { clips = Array(clips.prefix(limit)) }
    clips = Array(clips.prefix(warmup)) + clips
    FileManager.default.createFile(atPath: argument("-out")!, contents: nil)
    let out = FileHandle(forWritingAtPath: argument("-out")!)!

    for (n, clip) in clips.enumerated() {
        var waited = 0
        while front() != target {
            if waited == 0 { print("waiting: \(front()) is frontmost") }
            if waited >= 120 { print("stopped: TextTarget isn't frontmost"); return 2 }
            try? await Task.sleep(for: .milliseconds(250))
            waited += 1
        }
        let url = manifest.deletingLastPathComponent().appendingPathComponent(clip.audio)
        let player = try! AVAudioPlayer(contentsOf: url)
        player.prepareToPlay()
        post(54, down: true, flags: rightCommand, flagsChanged: true)
        let pressed = now()
        // Past the start sound (200 ms after the press), as a user starts speaking a moment in.
        try? await Task.sleep(for: .milliseconds(350))
        player.play()
        try? await Task.sleep(for: .seconds(player.duration - 0.05))
        while player.isPlaying { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .seconds(gap))
        guard front() == target else {
            post(53, down: true, flags: rightCommand)
            post(53, down: false, flags: rightCommand)
            post(54, down: false, flags: [], flagsChanged: true)
            print("stopped: \(front()) became frontmost; dictation cancelled")
            return 3
        }
        let released = now()
        post(54, down: false, flags: [], flagsChanged: true)
        let record: [String: Any] = [
            "id": clip.id, "duration": clip.duration, "warmup": n < warmup, "pressed": pressed, "released": released,
        ]
        out.write(try! JSONSerialization.data(withJSONObject: record) + Data("\n".utf8))
        print("\(n + 1)/\(clips.count) \(clip.id)")
        try? await Task.sleep(for: .seconds(n < warmup ? 15 : pause))
    }
    return 0
}

setvbuf(stdout, nil, _IOLBF, 0)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in exit(await run()) }
app.run()
