import AppKit
import SwiftUI

@main
struct Localflow: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        // The menu bar item is AppKit's (`StatusItem`): SwiftUI's MenuBarExtra can't tell a left click from a
        // right one, which "Start recording on menu bar click" needs. This scene never shows; with Show in
        // Dock its menu command opens Localflow's own Settings window.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {
                    Button("Settings…") { app.showSettings() }.keyboardShortcut(",")
                }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let controller = DictationController()
    private var settingsWindow: NSWindow?
    private let settingsNavigation = SettingsNavigation()
    private var onboardingWindow: NSWindow?
    private var statusItem: StatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.appearance = controller.settings.theme.appearance
        controller.openSettings = { [weak self] page in self?.showSettings(page: page) }
        controller.start()
        statusItem = StatusItem(controller: controller) { [weak self] in self?.showSettings() }
        controller.settings.onDockChange = { [weak self] in self?.updateDockIcon() }
        updateDockIcon()
        if CommandLine.arguments.contains("--selftest-keys") {
            Task {
                try? await Task.sleep(for: .seconds(1))  // Let the event tap come up.
                print(await controller.selfTestChord())
                exit(0)
            }
            return
        }
        let arguments = CommandLine.arguments
        if let i = arguments.firstIndex(of: "--selftest-rewrite"), arguments.count > i + 2 {
            Task {
                let (cases, output) = (URL(fileURLWithPath: arguments[i + 1]), URL(fileURLWithPath: arguments[i + 2]))
                print(await controller.selfTestRewrite(cases: cases, output: output))
                exit(0)
            }
            return
        }
        if let i = arguments.firstIndex(of: "--selftest-learn"), arguments.count > i + 1 {
            Task {
                try? await Task.sleep(for: .seconds(1))  // Let the paste target settle.
                print(await controller.selfTestLearn(arguments[i + 1]))
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--selftest") {
            Task {
                print("listen-event access \(CGPreflightListenEventAccess()) · post-event access \(CGPreflightPostEventAccess()) · AX trusted \(Permissions.accessibilityGranted)")
                for _ in 0..<2 { print(await controller.selfTest()) }
                exit(0)
            }
            return
        }
        if !controller.settings.onboarded {
            showOnboarding()
        } else if controller.activeSpeechModel == nil {
            showSettings(page: .models)
        } else if !Permissions.accessibilityGranted || Permissions.microphone != .authorized {
            showSettings()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.settings.flush()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Launching the app again (Spotlight, Finder) opens Settings, or the walkthrough if it's open.
        if onboardingWindow != nil { showOnboarding() } else { showSettings() }
        return false
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = makeWindow(
                title: "Welcome to Localflow", size: NSSize(width: 640, height: 520), minSize: nil,
                content: OnboardingView(controller: controller) { [weak self] in self?.onboardingWindow?.close() })
            window.delegate = self
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        updateDockIcon()
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        updateDockIcon(closing: window)
        guard window == onboardingWindow else { return }
        controller.endTest()
        controller.settings.onboarded = true
        Task { self.onboardingWindow = nil }  // Not while AppKit is still closing it.
    }

    /// In the Dock with Show in Dock, otherwise only while one of Localflow's windows is open (so it can be
    /// found with ⌘-Tab).
    private func updateDockIcon(closing: NSWindow? = nil) {
        let windowOpen = [settingsWindow, onboardingWindow].contains {
            $0 != nil && $0 != closing && $0?.isVisible == true
        }
        let policy: NSApplication.ActivationPolicy = controller.settings.showInDock || windowOpen ? .regular : .accessory
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    func showSettings() {
        showSettings(page: nil)
    }

    func showSettings(page: SettingsView.Page?) {
        if let page { settingsNavigation.page = page }
        if settingsWindow == nil {
            settingsWindow = makeWindow(
                title: "Localflow", size: NSSize(width: 780, height: 560), minSize: NSSize(width: 750, height: 422),
                content: SettingsView(controller: controller, navigation: settingsNavigation))
            settingsWindow?.delegate = self
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        updateDockIcon()
        NSApp.activate()
    }
}

/// The menu bar item: the mark, and a menu of actions, then the microphone and cleanup as submenus showing
/// the current choice, then the version and Quit. With "Start recording on menu bar click" a left click
/// starts or finishes a dictation and the menu opens on a right click.
@MainActor
private final class StatusItem: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let controller: DictationController
    private let openSettings: () -> Void

    init(controller: DictationController, openSettings: @escaping () -> Void) {
        self.controller = controller
        self.openSettings = openSettings
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        update()
    }

    /// Follows the recording state and the click setting.
    private func update() {
        withObservationTracking {
            item.button?.image = MenuBarGlyph.image(for: controller.menuBarState)
            // Attached, the menu opens on mouse down like any menu bar menu; detached, clicks come to `clicked`.
            item.menu = controller.settings.recordOnMenuBarClick ? nil : menu
        } onChange: {
            Task { @MainActor [weak self] in self?.update() }
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            guard let button = item.button else { return }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 6), in: button)
        } else {
            controller.toggleRecording()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        let settings = controller.settings
        menu.removeAllItems()
        if controller.status != .ready {
            menu.addItem(Action(controller.statusLine, enabled: false))
            menu.addItem(.separator())
        }
        menu.addItem(Action("Toggle Recording") { [controller] in controller.toggleRecording() })
        menu.addItem(Action("Copy Last Transcript", enabled: controller.lastTranscript != nil) { [controller] in
            controller.copyLastTranscript()
        })
        menu.addItem(Action("Settings…", key: ",", perform: openSettings))
        menu.addItem(.separator())
        let microphones = NSMenu()
        microphones.addItem(Action("Automatic", checked: settings.microphoneUID == nil) { settings.microphoneUID = nil })
        microphones.addItem(.separator())
        for device in controller.microphones {
            microphones.addItem(Action(device.name, checked: settings.microphoneUID == device.uid) {
                settings.microphoneUID = device.uid
            })
        }
        menu.addItem(Action(microphoneTitle, submenu: microphones))
        let cleanup = NSMenu()
        if settings.speechModel.supportsCleanup {
            cleanup.addItem(Action("On", checked: settings.cleanup) { settings.cleanup = true })
            cleanup.addItem(Action("Off", checked: !settings.cleanup) { settings.cleanup = false })
        } else {
            cleanup.addItem(Action("Needs the English speech model", enabled: false))
        }
        menu.addItem(Action(settings.cleansUp ? "Cleanup On" : "Cleanup Off", submenu: cleanup))
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        menu.addItem(Action("Version \(version)", enabled: false))
        menu.addItem(Action("Quit", key: "q") { NSApp.terminate(nil) })
    }

    private var microphoneTitle: String {
        guard let microphone = controller.microphone else { return "No Microphone" }
        return controller.settings.microphoneUID == nil ? "\(microphone.name) (Automatic)" : microphone.name
    }

    /// A menu item that runs a closure.
    private final class Action: NSMenuItem {
        private var perform: (() -> Void)?

        init(
            _ title: String, key: String = "", enabled: Bool = true, checked: Bool = false, submenu: NSMenu? = nil,
            perform: (() -> Void)? = nil
        ) {
            self.perform = perform
            super.init(title: title, action: perform == nil ? nil : #selector(run), keyEquivalent: key)
            target = self
            isEnabled = enabled
            state = checked ? .on : .off
            self.submenu = submenu
        }

        required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

        @objc private func run() { perform?() }
    }
}

extension DictationController {
    var menuBarState: MenuBarGlyph.State {
        if isRecording { return .recording }
        switch status {
        case .ready, .loadingModel: return .idle
        case .needsAccessibility, .noSpeechModel, .failed: return .attention
        }
    }

    var statusLine: String {
        switch status {
        case .noSpeechModel: "No speech model: download one in Settings"
        case .loadingModel: "Loading speech model…"
        case .ready: settings.dictationHint.map { "\($0) to dictate" } ?? "No dictation shortcut"
        case .needsAccessibility: "Needs Accessibility permission"
        case .failed(let message): message
        }
    }
}

/// The menu bar glyph: Localflow's mark (`Resources/Images/Mark.svg`), drawn as a template image so it
/// follows the menu bar's appearance.
enum MenuBarGlyph {
    enum State { case idle, recording, attention }

    private static let size = NSSize(width: 22, height: 18)

    @MainActor static func image(for state: State) -> NSImage {
        if let cached = cache[state] { return cached }
        let mark = Bundle.main.url(forResource: "Mark", withExtension: "svg").flatMap(NSImage.init(contentsOf:))
        let image = NSImage(size: size, flipped: false) { rect in
            guard let mark else { return false }
            // `y` puts the top edge of the mark's flat ends (41.3% of its height up) on a pixel row at 2x.
            func frame(width: CGFloat, x: CGFloat, y: CGFloat) -> NSRect {
                NSRect(x: x, y: y, width: width, height: width * mark.size.height / mark.size.width)
            }
            switch state {
            case .idle:
                mark.draw(in: frame(width: 22, x: 0, y: 2.8))
            case .recording:
                // Filled tile with the mark knocked out, like SF Symbols' ".fill" variants.
                NSColor.black.setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4.5, yRadius: 4.5).fill()
                mark.draw(in: frame(width: 16, x: 3, y: 4.22), from: .zero, operation: .destinationOut, fraction: 1)
            case .attention:
                mark.draw(in: frame(width: 22, x: 0, y: 2.8), from: .zero, operation: .sourceOver, fraction: 0.45)
                let slash = NSBezierPath()
                slash.lineWidth = 1.8
                slash.lineCapStyle = .round
                slash.move(to: NSPoint(x: 3, y: 16.5))
                slash.line(to: NSPoint(x: 19, y: 1.5))
                NSColor.black.setStroke()
                slash.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Localflow"
        cache[state] = image
        return image
    }

    @MainActor private static var cache: [State: NSImage] = [:]
}
