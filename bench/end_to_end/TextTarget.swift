// Paste target for the end-to-end latency test: one text view that logs when each paste lands.
// usage: TextTarget -log FILE [-stay SECONDS]   (quits after SECONDS, default 1800)
import AppKit

let arguments = CommandLine.arguments
func argument(_ name: String) -> String? {
    guard let i = arguments.firstIndex(of: name), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
}

final class Target: NSObject, NSApplicationDelegate, NSTextViewDelegate {
    var window: NSWindow!
    var textView: NSTextView!
    var log: FileHandle!
    var length = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = argument("-log") ?? "/tmp/texttarget.jsonl"
        FileManager.default.createFile(atPath: path, contents: nil)
        log = FileHandle(forWritingAtPath: path)

        let menu = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit TextTarget", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(appItem)
        let editItem = NSMenuItem()
        editItem.submenu = NSMenu(title: "Edit")
        editItem.submenu?.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu?.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(editItem)
        NSApp.mainMenu = menu

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 420), styleMask: [.titled, .closable, .resizable],
            backing: .buffered, defer: false)
        window.title = "TextTarget (Localflow latency test)"
        let scroll = NSScrollView(frame: window.contentView!.bounds)
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        textView = NSTextView(frame: scroll.bounds)
        textView.autoresizingMask = [.width]
        textView.font = .systemFont(ofSize: 14)
        textView.delegate = self
        scroll.documentView = textView
        window.contentView = scroll
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(textView)
        NSApp.activate()

        let stay = Double(argument("-stay") ?? "1800") ?? 1800
        DispatchQueue.main.asyncAfter(deadline: .now() + stay) { NSApp.terminate(nil) }
    }

    func textDidChange(_ notification: Notification) {
        let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let text = textView.string
        let added = text.count > length ? String(text.suffix(text.count - length)) : ""
        length = text.count
        let record = try! JSONSerialization.data(withJSONObject: ["t": t, "added": added])
        log.write(record + Data("\n".utf8))
    }
}

let app = NSApplication.shared
let target = Target()
app.delegate = target
app.setActivationPolicy(.regular)
app.run()
