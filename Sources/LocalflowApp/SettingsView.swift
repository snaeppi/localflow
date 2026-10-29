import AVFoundation
import SwiftUI

/// Which Settings page is showing, so other parts of the app can open one.
@MainActor @Observable
final class SettingsNavigation {
    var page = SettingsView.Page.general
    /// General's Advanced settings subpage is showing.
    var advanced = false
}

/// The Settings window: a sidebar of pages on a translucent window, each page with its title level with the
/// traffic lights and the microphone or an action at the right.
struct SettingsView: View {
    enum Page: CaseIterable {
        case general, sound, models, vocabulary, cleanup

        var title: String {
            switch self {
            case .general: "General"
            case .sound: "Sound"
            case .models: "Models"
            case .vocabulary: "Vocabulary"
            case .cleanup: "Cleanup"
            }
        }

        var symbol: String {
            switch self {
            case .general: "gearshape.fill"
            case .sound: "speaker.wave.2.fill"
            case .models: "book.fill"
            case .vocabulary: "character.book.closed.fill"
            case .cleanup: "eraser.fill"
            }
        }

        var tint: Color {
            switch self {
            case .general, .sound, .models: .gray
            case .vocabulary: .blue
            case .cleanup: .purple
            }
        }
    }

    let controller: DictationController
    let navigation: SettingsNavigation
    /// The sidebar folds to its icons with a click on its edge.
    @AppStorage("sidebarCollapsed") private var collapsed = false
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var microphone = Permissions.microphone
    @State private var deviceMenuShown = false

    /// 185 pt open, 60 pt folded, a ~0.27 s spring without bounce either way.
    private static let sidebarWidth: CGFloat = 185
    private static let foldedSidebarWidth: CGFloat = 60
    private static let sidebarAnimation = Animation.spring(response: 0.27, dampingFraction: 1)

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            pages
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // Pages a shade toward the text background (darker in dark mode, lighter in light mode) than
                // the sidebar.
                .background(Color(nsColor: .textBackgroundColor).opacity(0.4))
        }
        // The whole row, so the page moves with the sidebar's edge. Explicit: a change to @AppStorage
        // doesn't carry withAnimation's transaction.
        .animation(Self.sidebarAnimation, value: collapsed)
        .task {
            // Permissions change in System Settings; keep the rows current.
            while !Task.isCancelled {
                accessibility = Permissions.accessibilityGranted
                microphone = Permissions.microphone
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .deviceMenu(isPresented: $deviceMenuShown, settings: controller.settings, devices: controller.microphones)
    }

    private var pages: some View {
        Group {
            switch navigation.page {
            case .general where navigation.advanced:
                // The subpage swaps in without an animation.
                AdvancedPage(controller: controller, deviceButton: deviceButton) { navigation.advanced = false }
            case .general:
                GeneralPage(
                    controller: controller, accessibility: accessibility, microphone: microphone,
                    deviceButton: deviceButton
                ) { navigation.advanced = true }
            case .sound:
                SoundPage(settings: controller.settings, deviceButton: deviceButton)
            case .models:
                ModelsPage(controller: controller, deviceButton: deviceButton)
            case .vocabulary:
                VocabularyPage(settings: controller.settings)
            case .cleanup:
                CleanupPage(settings: controller.settings, model: controller.rewriteModel, deviceButton: deviceButton) {
                    navigation.page = .models
                }
            }
        }
    }

    private var deviceButton: DeviceButton {
        DeviceButton(settings: controller.settings, current: controller.microphone, menuShown: $deviceMenuShown)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Page.allCases, id: \.self) { item in
                SidebarRow(page: item, selected: item == navigation.page, folded: collapsed) {
                    navigation.page = item
                    navigation.advanced = false
                }
            }
            Spacer()
            // One line at the sidebar's width: 128 pt for the text, which every state fits. Folded, a circle
            // with the status dot.
            Circle().fill(statusColor).frame(width: 6, height: 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    Text(statusText).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                        .padding(.leading, 13)
                        .opacity(collapsed ? 0 : 1)
                }
                .padding(.leading, collapsed ? 15 : 10)
                .frame(minHeight: 36)
                .clipShape(.capsule)
                .glassEffect(.regular, in: .capsule)
                .help(controller.statusLine)
        }
        .padding(.top, 52)
        .padding([.horizontal, .bottom], 12)
        .frame(width: collapsed ? Self.foldedSidebarWidth : Self.sidebarWidth, alignment: .leading)
        .clipped()
        .frame(maxHeight: .infinity)
        .background { WindowDragArea() }
        .overlay(alignment: .trailing) { Rectangle().fill(.primary.opacity(0.07)).frame(width: 1) }
        // On the edge, over both sides of it, so it's drawn above the page.
        .overlay(alignment: .trailing) {
            SidebarEdge(folded: collapsed) { collapsed.toggle() }
                .offset(x: SidebarEdge.width / 2)
        }
        .zIndex(1)
        .background { MinimizeButton(hidden: collapsed) }
    }

    private var statusText: String {
        switch controller.status {
        case .ready: controller.statusLine
        case .noSpeechModel: "No speech model"
        case .loadingModel: "Loading speech model…"
        case .needsAccessibility: "Needs Accessibility"
        case .failed: "Speech model failed"
        }
    }

    private var statusColor: Color {
        switch controller.status {
        case .ready: .green
        case .loadingModel: .orange
        case .needsAccessibility, .noSpeechModel, .failed: .red
        }
    }
}

private struct SidebarRow: View {
    let page: SettingsView.Page
    let selected: Bool
    let folded: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: page.symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 19, height: 19)
                .background(RoundedRectangle(cornerRadius: 5).fill(page.tint.gradient))
                .frame(maxWidth: .infinity, alignment: .leading)
                // The label doesn't take part in the layout, so the row can narrow to its icon; it's cut off
                // at the row's edge. Labels fade out at once when folding and back in as it opens; the icons
                // stay put.
                .overlay(alignment: .leading) {
                    Text(page.title).font(.system(size: 13)).fixedSize()
                        .padding(.leading, 26)
                        .opacity(folded ? 0 : 1)
                        .animation(folded ? .easeOut(duration: 0.08) : .easeIn(duration: 0.2), value: folded)
                }
                .padding(.horizontal, 8)
                .frame(height: 35)
                .clipped()
                .contentShape(Rectangle())
            .background {
                if selected {
                    Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 10))
                } else if hovering {
                    RoundedRectangle(cornerRadius: 10).fill(.primary.opacity(0.05))
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(folded ? page.title : "")
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The sidebar's edge: a click anywhere on it folds or opens the sidebar, and under the pointer it shows a
/// round arrow, centred on the edge.
private struct SidebarEdge: View {
    static let width: CGFloat = 16
    let folded: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: Self.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay {
                Image(systemName: folded ? "chevron.right" : "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 25, height: 25)
                    .glassEffect(.regular, in: .circle)
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .onHover { hovering in withAnimation(.easeOut(duration: 0.15)) { self.hovering = hovering } }
            // A pointing hand. Set at every move: `pointerStyle` lost to the page's scroll view,
            // which sets its own cursor under the right half of the edge.
            .onContinuousHover { phase in
                if case .active = phase { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .onTapGesture(perform: toggle)
            .accessibilityElement()
            .accessibilityLabel(folded ? "Show sidebar" : "Hide sidebar")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle() }
    }
}

/// The window's minimize button is hidden while the sidebar is folded, which leaves room for the close
/// button only.
private struct MinimizeButton: NSViewRepresentable {
    let hidden: Bool

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // Not attached to the window yet on the first pass.
        DispatchQueue.main.async { view.window?.standardWindowButton(.miniaturizeButton)?.isHidden = hidden }
    }
}

private struct GeneralPage: View {
    let controller: DictationController
    let accessibility: Bool
    let microphone: AVAuthorizationStatus
    let deviceButton: DeviceButton
    let showAdvanced: () -> Void

    var body: some View {
        @Bindable var settings = controller.settings
        ScrollView {
            VStack(spacing: 10) {
                if !accessibility || microphone != .authorized {
                    Card { PermissionRows(microphone: microphone, accessibility: accessibility) }
                }
                Card {
                    SettingRow(title: "Theme", alignment: .top) {
                        ChoiceTiles(
                            selection: $settings.theme, options: [(.auto, "Auto"), (.light, "Light"), (.dark, "Dark")]
                        ) { ThemeTile(theme: $0, selected: $1) }
                    }
                    CardDivider()
                    SettingRow(title: "Recording window", alignment: .top) {
                        ChoiceTiles(
                            selection: $settings.showRecordingWindow,
                            options: [(true, "On"), (false, "Off")], spacing: 12
                        ) { RecordingWindowTile(on: $0, selected: $1) }
                    }
                    if settings.showRecordingWindow {
                        CardDivider()
                        SettingRow(
                            title: "Always show",
                            info: "Keeps the recording window on screen between dictations, so you can click it to start and finish one. Drag it to any edge or the middle of a screen."
                        ) {
                            Switch(title: "Always show", isOn: $settings.alwaysShowRecordingWindow)
                        }
                    }
                }

                SectionTitle("Keyboard shortcuts")
                Card {
                    SettingRow(
                        title: "Toggle recording",
                        subtitle: fnNote(settings.toggleShortcut) ?? "Starts and stops recordings"
                    ) {
                        keyField($settings.toggleShortcut, default: .rightCommand, others: [settings.cancelShortcut])
                    }
                    CardDivider()
                    SettingRow(title: "Cancel recording", subtitle: "Discards the active recording") {
                        keyField(
                            Binding { settings.cancelShortcut } set: { settings.cancelShortcut = $0 ?? .escape },
                            default: .escape, others: [settings.toggleShortcut, settings.pushToTalkShortcut],
                            allowsNone: false, allowsBareKeys: true, modifierKeys: false)
                    }
                    CardDivider()
                    SettingRow(
                        title: "Push to talk",
                        subtitle: fnNote(settings.pushToTalkShortcut) ?? "Hold to record, release when done",
                        info: "With the same key as Toggle recording, one key does both: hold it to talk, or tap it to start and tap again to finish. A modifier key used on its own still works in shortcuts: Right ⌘ + C copies as usual."
                    ) {
                        keyField($settings.pushToTalkShortcut, default: .rightCommand, others: [settings.cancelShortcut])
                    }
                    CardDivider()
                    SettingRow(title: "Mouse shortcut", subtitle: "Tap to toggle, or hold and release when done") {
                        ShortcutField(
                            value: $settings.mouseShortcut, keys: { [$0.title] }, events: .otherMouseDown,
                            parse: { event, _ in
                                event.type == .otherMouseDown ? MouseButton(number: Int64(event.buttonNumber)) : nil
                            },
                            onRecording: controller.pauseShortcuts)
                    }
                }

                SectionTitle("Application")
                Card {
                    SettingRow(title: "Launch at login") {
                        Switch(title: "Launch at login", isOn: $settings.launchAtLogin)
                    }
                }
                Card {
                    Button(action: showAdvanced) {
                        SettingRow(title: "Advanced settings") {
                            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 14)
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBar(.top) {
            PageHeader(title: "General") { deviceButton }
        }
    }

    /// A keyboard shortcut: a key combination, or (`modifierKeys`) a right-hand modifier or Fn pressed on its
    /// own. Without modifiers only function keys make a combination (anything else would type), except for
    /// Cancel, which acts only while recording. `others` are the shortcuts it mustn't equal.
    private func keyField(
        _ value: Binding<Shortcut?>, default: Shortcut, others: [Shortcut?], allowsNone: Bool = true,
        allowsBareKeys: Bool = false, modifierKeys: Bool = true
    ) -> some View {
        ShortcutField(
            value: value, defaultValue: `default`, keys: \.keys, events: modifierKeys ? .flagsChanged : [],
            allowsNone: allowsNone,
            parse: { event, previous in
                let shortcut: Shortcut
                if event.type == .flagsChanged {
                    // Pressed and released with nothing in between.
                    guard modifierKeys, let key = TriggerKey(keyCode: Int64(event.keyCode)), let previous,
                        previous.type == .flagsChanged, previous.keyCode == event.keyCode,
                        UInt64(previous.modifierFlags.rawValue) & key.deviceMask != 0,
                        UInt64(event.modifierFlags.rawValue) & key.deviceMask == 0
                    else { return nil }
                    shortcut = Shortcut(key)
                } else {
                    guard event.type == .keyDown else { return nil }
                    shortcut = Shortcut(event)
                    guard allowsBareKeys || shortcut.isFunctionKey
                        || shortcut.modifiers & ~CGEventFlags.maskShift.rawValue != 0
                    else { return nil }
                }
                return others.contains(shortcut) ? nil : shortcut
            },
            onRecording: controller.pauseShortcuts)
    }

    /// Fn as a shortcut only works with macOS's own use of the key switched off.
    private func fnNote(_ shortcut: Shortcut?) -> String? {
        shortcut == Shortcut(.fn) ? "Set “Press 🌐 key to” to “Do Nothing” in Keyboard settings" : nil
    }

}

/// Advanced settings: how Localflow sits on the Mac, models, audio processing, its folder, how text gets
/// into apps, and diagnostics.
private struct AdvancedPage: View {
    let controller: DictationController
    let deviceButton: DeviceButton
    let back: () -> Void
    @State private var folder = AppFolder.url
    @State private var moving = false

    var body: some View {
        @Bindable var settings = controller.settings
        ScrollView {
            VStack(spacing: 10) {
                SectionTitle("Application").padding(.top, -14)
                Card {
                    SettingRow(title: "Show in Dock", info: "Keeps Localflow in the Dock. Otherwise it's there only while one of its windows is open.") {
                        Switch(title: "Show in Dock", isOn: $settings.showInDock)
                    }
                    CardDivider()
                    SettingRow(
                        title: "Start recording on menu bar click",
                        info: "A click on Localflow's icon in the menu bar starts a dictation, and another click finishes it. Right-click the icon for its menu."
                    ) {
                        Switch(title: "Start recording on menu bar click", isOn: $settings.recordOnMenuBarClick)
                    }
                }

                SectionTitle("Models")
                Card {
                    SettingRow(
                        title: "Model active duration",
                        info: "How long the speech model, and the cleanup model when it's on, stay loaded after you dictate. When you start dictating again they load while you speak, in a fraction of a second."
                    ) {
                        Picker("Model active duration", selection: $settings.modelActiveDuration) {
                            ForEach(AppSettings.activeDurations, id: \.self) { Text(Self.duration($0)).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }

                SectionTitle("Audio processing")
                Card {
                    SettingRow(
                        title: "Silence removal",
                        info: "Shortens long pauses before a recording is transcribed, so long dictations with many pauses are transcribed faster. Speech much quieter than the rest can be taken for a pause."
                    ) {
                        Switch(title: "Silence removal", isOn: $settings.silenceRemoval)
                    }
                    CardDivider()
                    SettingRow(
                        title: "Dynamic normalization",
                        info: "Evens out the loudness of a recording before it's transcribed. Fewer mistakes with quiet or distant microphones."
                    ) {
                        Switch(title: "Dynamic normalization", isOn: $settings.normalization)
                    }
                }

                SectionTitle("App folder location")
                Card {
                    HStack(spacing: 10) {
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .font(.system(size: 13))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 12)
                        if moving { ProgressView().controlSize(.small) }
                        Button("Change Folder…", action: chooseFolder).disabled(moving)
                        InfoButton(
                            "Where Localflow keeps its settings, vocabulary and the cleanup model. Choose a folder you back up, or one with a Localflow folder from another Mac to use its settings.")
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 45)
                }

                SectionTitle("Text input")
                Card {
                    SettingRow(
                        title: "Clipboard content",
                        info: "To paste a dictation, Localflow puts it on your clipboard. This sets what your clipboard holds afterwards."
                    ) {
                        Picker("Clipboard content", selection: $settings.clipboard) {
                            Text("Keep what I have copied").tag(AppSettings.Clipboard.keep)
                            Text("Replace with dictation").tag(AppSettings.Clipboard.replace)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    CardDivider()
                    SettingRow(
                        title: "Clipboard history",
                        info: "Lets clipboard history apps such as Maccy, Paste or Alfred keep a copy of each dictation. Otherwise dictations are marked so those apps skip them."
                    ) {
                        Switch(title: "Clipboard history", isOn: $settings.clipboardHistory)
                    }
                    CardDivider()
                    SettingRow(
                        title: "Paste result text",
                        info: "Pastes each dictation where you're typing. Turned off, the text is only put on your clipboard."
                    ) {
                        Switch(title: "Paste result text", isOn: $settings.pasteResult)
                    }
                    CardDivider()
                    SettingRow(
                        title: "Hold Shift to send after paste",
                        info: "Hold Shift as you finish a dictation and Localflow presses Return after pasting it, to send a chat message."
                    ) {
                        HStack(spacing: 14) {
                            ExperimentalBadge()
                            Switch(title: "Hold Shift to send after paste", isOn: $settings.shiftToSend)
                        }
                    }
                    CardDivider()
                    SettingRow(
                        title: "Simulate keypresses",
                        info: "Types each dictation character by character instead of pasting it, for apps that don't accept pasting."
                    ) {
                        HStack(spacing: 14) {
                            ExperimentalBadge()
                            Switch(title: "Simulate keypresses", isOn: $settings.simulateKeypresses)
                        }
                    }
                }

                SectionTitle("Diagnostics")
                Card {
                    SettingRow(
                        title: "Save recordings",
                        info: "Keeps each recording and its transcript in the recordings folder inside the app folder, for testing speech models on your own voice. They stay on this Mac; delete the folder to remove them."
                    ) {
                        Switch(title: "Save recordings", isOn: $settings.saveRecordings)
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBar(.top) {
            PageHeader(title: "Advanced settings", back: back) { deviceButton }
        }
    }

    private static func duration(_ seconds: Int) -> String {
        switch seconds {
        case 0: "Always"
        case ..<60: "\(seconds) seconds"
        case 60: "1 minute"
        case ..<3600: "\(seconds / 60) minutes"
        default: seconds == 3600 ? "1 hour" : "\(seconds / 3600) hours"
        }
    }

    /// The folder goes inside the location you pick. Picking a folder that already holds Localflow's settings
    /// (synced from another Mac, or a backup) uses those settings.
    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Location for the Localflow Folder"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = folder.deletingLastPathComponent()
        guard panel.runModal() == .OK, let location = panel.url else { return }
        let target = location.lastPathComponent == "Localflow" && AppFolder.hasSettings(location)
            ? location : AppFolder.folder(in: location)
        guard target.standardizedFileURL != folder.standardizedFileURL else { return }
        let alert = NSAlert()
        guard !target.standardizedFileURL.path.hasPrefix(folder.standardizedFileURL.path + "/") else {
            alert.messageText = "Choose a location outside the Localflow folder"
            alert.runModal()
            return
        }
        let adopt = AppFolder.hasSettings(target)
        let name = (target.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        if adopt {
            alert.messageText = "Use the Localflow folder in “\(name)”?"
            alert.informativeText = "Its settings and vocabulary replace the ones Localflow uses now."
            alert.addButton(withTitle: "Use Folder")
        } else {
            alert.messageText = "Move the Localflow folder to “\(name)”?"
            alert.informativeText = "Your settings, vocabulary and the cleanup model move with it."
            alert.addButton(withTitle: "Move")
        }
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        moving = true
        Task {
            defer { moving = false }
            controller.settings.flush()
            do {
                try await AppFolder.move(to: target, adopt: adopt)
                if adopt { controller.settings.reload() }
                controller.rewriteModel.refresh()
                folder = AppFolder.url
            } catch {
                let failure = NSAlert()
                failure.messageText = "The folder couldn't be moved"
                failure.informativeText = error.localizedDescription
                failure.runModal()
            }
        }
    }
}

/// The Sound page: the start and stop sounds, and what happens to other audio while recording.
private struct SoundPage: View {
    @Bindable var settings: AppSettings
    let deviceButton: DeviceButton

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Card {
                    SettingRow(title: "Sound effects", info: "A soft sound when a recording starts and stops.") {
                        Switch(title: "Sound effects", isOn: $settings.soundEffects)
                    }
                    if settings.soundEffects {
                        CardDivider()
                        SettingRow(title: "Volume") {
                            Slider(value: $settings.soundVolume, in: 0...1, step: 0.1) {
                                Text("Volume")
                            } minimumValueLabel: {
                                Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                            } maximumValueLabel: {
                                Image(systemName: "speaker.wave.2.fill").foregroundStyle(.secondary)
                            } onEditingChanged: { editing in
                                if !editing { Sounds.playStart(volume: settings.soundVolume) }
                            }
                            .labelsHidden()
                            .frame(width: 230)
                        }
                    }
                }

                SectionTitle("Recording")
                Card {
                    SettingRow(title: "Sound while recording") {
                        Picker("Sound while recording", selection: $settings.whileRecording) {
                            Label("Keep Playing", systemImage: "play.circle").tag(SystemAudio.WhileRecording.keepPlaying)
                            Label("Pause", systemImage: "pause.circle").tag(SystemAudio.WhileRecording.pause)
                            Label("Mute", systemImage: "speaker.slash").tag(SystemAudio.WhileRecording.mute)
                            Label("Lower", systemImage: "speaker.wave.1").tag(SystemAudio.WhileRecording.lower)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    CardDivider()
                    SettingRow(
                        title: "Automatically increase microphone volume",
                        info: "Turns the microphone's input volume all the way up while you dictate, and back afterwards."
                    ) {
                        Switch(title: "Automatically increase microphone volume", isOn: $settings.boostMicrophone)
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBar(.top) {
            PageHeader(title: "Sound") { deviceButton }
        }
    }
}

/// The Models page, for the speech models: which one is in use, and downloading and removing them. The
/// cleanup model stays on the Cleanup page.
private struct ModelsPage: View {
    let controller: DictationController
    let deviceButton: DeviceButton

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if controller.activeSpeechModel == nil {
                    Card {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 17))
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No speech model").font(.system(size: 13, weight: .semibold))
                                Text("Download one below to start dictating.").font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .frame(minHeight: 52)
                    }
                }
                SectionTitle("Speech models").padding(.top, controller.activeSpeechModel == nil ? 0 : -14)
                Card {
                    ForEach(SpeechModels.Kind.allCases) { kind in
                        if kind != SpeechModels.Kind.allCases.first { CardDivider() }
                        SpeechModelRow(kind: kind, controller: controller)
                    }
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBar(.top) {
            PageHeader(
                title: "Models",
                info: "Speech is transcribed on this Mac. Each model is downloaded once from Hugging Face; remove the ones you don't use to free space."
            ) { deviceButton }
        }
        .onAppear { controller.reconcileSpeechModel() }
    }
}

private struct SpeechModelRow: View {
    let kind: SpeechModels.Kind
    let controller: DictationController

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(kind.name).font(.system(size: 13))
                    LanguageBadge(text: kind == .english ? "EN" : "25 languages")
                    if kind == .multilingual {
                        InfoButton(
                            SpeechModels.Kind.multilingualLanguages.formatted(.list(type: .and))
                                + ". It recognizes the language as you speak, so you can switch between them.")
                    }
                }
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
    }

    private var subtitle: String {
        switch kind {
        case .english: "\(kind.modelName) · More accurate for English · Works with cleanup"
        case .multilingual: "\(kind.modelName) · 25 European languages · Cleanup isn't available"
        }
    }

    private var size: String { ByteCountFormatter.string(fromByteCount: kind.size, countStyle: .file) }

    @ViewBuilder private var control: some View {
        let models = controller.speechModels
        switch models.state(kind) {
        case .installed:
            HStack(spacing: 10) {
                if controller.activeSpeechModel == kind {
                    Text("In use").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    Button("Use") { controller.settings.speechModel = kind }
                }
                Button(action: remove) {
                    Image(systemName: "trash").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .disabled(models.installed.count == 1)
                .accessibilityLabel("Remove the \(kind.name) model")
                .help(models.installed.count == 1 ? "Localflow needs one speech model" : "Remove (\(size))")
            }
        case .downloading(let fraction):
            HStack(spacing: 10) {
                ProgressView(value: fraction).frame(width: 90)
                Text("\(Int(fraction * 100))%").font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
                Button("Cancel") { models.cancel(kind) }
            }
        case .failed(let message):
            HStack(spacing: 10) {
                Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(2)
                Button("Try Again") { models.install(kind) }
            }
        case .absent:
            HStack(spacing: 10) {
                Text(size).font(.system(size: 12)).foregroundStyle(.secondary)
                Button("Download") { models.install(kind) }
            }
        }
    }

    private func remove() {
        let alert = NSAlert()
        alert.messageText = "Remove the \(kind.name) model?"
        alert.informativeText = controller.activeSpeechModel == kind
            ? "Localflow switches to the other model. You can download this one again (\(size))."
            : "You can download it again (\(size))."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.speechModels.remove(kind)
        controller.reconcileSpeechModel()
    }
}

/// The small language tag after a model's name ("EN").
private struct LanguageBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(.primary.opacity(0.08)))
    }
}

/// The optional cleanup model: off until the user asks for it, then downloaded once.
private struct CleanupPage: View {
    @Bindable var settings: AppSettings
    let model: RewriteModel
    let deviceButton: DeviceButton
    let showModels: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                if !settings.speechModel.supportsCleanup {
                    Card {
                        SettingRow(
                            title: "Cleanup works with the English speech model",
                            subtitle: "Its model was trained on English only. You're dictating with the multilingual model."
                        ) {
                            Button("Models…", action: showModels)
                        }
                    }
                }
                Card {
                    SettingRow(
                        title: "Clean up transcripts",
                        subtitle: "Removes filler words, applies spoken corrections and formats lists"
                    ) {
                        // Off while it can't run; the choice is kept for the English model.
                        Switch(
                            title: "Clean up transcripts",
                            isOn: Binding { settings.cleansUp } set: { settings.cleanup = $0 })
                            .disabled(!settings.speechModel.supportsCleanup)
                    }
                    if settings.cleanup || model.isInstalled {
                        CardDivider()
                        modelRow
                    }
                }

                // Real outputs of the model for these transcripts.
                SectionTitle("Examples")
                Card {
                    ExampleRow(
                        spoken: "Can you send me the the report by, uh, tomorrow morning?",
                        cleaned: "Can you send me the report by tomorrow morning?")
                    CardDivider()
                    ExampleRow(
                        spoken: "Let's meet on Tuesday, no wait, Wednesday.",
                        cleaned: "Let's meet on Wednesday.")
                    CardDivider()
                    ExampleRow(
                        spoken: "For the trip pack three things. First the charger, second the cable, and third the adapter.",
                        cleaned: "For the trip pack, three things:\n1. The charger\n2. The cable\n3. The adapter")
                }
            }
            .frame(maxWidth: 520)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity)
        }
        .scrollBar(.top) {
            PageHeader(
                title: "Cleanup",
                info: "Cleanup uses [\(RewriteModel.name)](\(RewriteModel.licenseURL)), a small language model trained for exactly this. It is downloaded once from Hugging Face (1.5 GB; 0.9 GB on disk), runs on this Mac like transcription, and adds about 25 ms."
            ) { deviceButton }
        }
    }

    @ViewBuilder private var modelRow: some View {
        switch model.state {
        case .downloading(let fraction):
            SettingRow(title: "Downloading \(RewriteModel.name)…", subtitle: "\(Int(fraction * 100))% of 1.5 GB") {
                HStack(spacing: 12) {
                    ProgressView(value: fraction).frame(width: 110)
                    Button("Cancel") { settings.cleanup = false }
                }
            }
        case .preparing:
            SettingRow(title: "Preparing \(RewriteModel.name)…") { ProgressView().controlSize(.small) }
        case .installed:
            SettingRow(
                title: RewriteModel.name,
                subtitle: "Installed · " + ByteCountFormatter.string(fromByteCount: model.installedSize ?? 0, countStyle: .file)
            ) {
                Button("Remove") {
                    settings.cleanup = false
                    model.remove()
                }
            }
        case .failed(let message):
            SettingRow(title: message) { Button("Try Again") { model.install() } }
        case .absent:
            SettingRow(title: RewriteModel.name, subtitle: "1.5 GB download") { Button("Download") { model.install() } }
        }
    }
}

private struct ExampleRow: View {
    let spoken: String
    let cleaned: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(spoken).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(.primary.opacity(0.08)))
            Text(cleaned).frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12.5))
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }
}
