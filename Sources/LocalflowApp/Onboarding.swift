import AVFoundation
import SwiftUI

/// The first-run walkthrough: welcome, the speech model (downloaded while the
/// walkthrough goes on), permissions, a microphone test, the shortcut, a practice dictation into a field
/// here, and a few tips. Shown once; closing it counts.
struct OnboardingView: View {
    let controller: DictationController
    let close: () -> Void
    @State private var step = Step.welcome
    @State private var accessibility = Permissions.accessibilityGranted
    @State private var microphone = Permissions.microphone
    @State private var confirmSkip = false
    @State private var deviceMenuShown = false
    @State private var waveform = WaveformBuffer(barCount: 44)
    @State private var practice = ""
    @State private var practiced = false
    @FocusState private var practiceFocused: Bool

    private enum Step: Int, CaseIterable {
        case welcome, model, permissions, microphone, shortcut, practice, done
    }

    private var settings: AppSettings { controller.settings }
    /// The push-to-talk key (Right ⌘ by default, which also toggles).
    private var key: String { (settings.pushToTalkShortcut ?? settings.toggleShortcut)?.title ?? "your shortcut" }
    private var permitted: Bool { accessibility && microphone == .authorized }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .model: modelStep
                case .permissions: permissions
                case .microphone: microphoneTest
                case .shortcut: shortcut
                case .practice: practiceStep
                case .done: done
                }
            }
            .id(step)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 24)), removal: .opacity))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 36)
            .padding(.horizontal, 56)
            if step.rawValue > Step.model.rawValue { downloadStatus }
            footer
        }
        .background { WindowDragArea() }
        .deviceMenu(isPresented: $deviceMenuShown, settings: settings, devices: controller.microphones)
        .animation(.smooth(duration: 0.3), value: step)
        .task {
            while !Task.isCancelled {
                let wasPermitted = permitted
                accessibility = Permissions.accessibilityGranted
                microphone = Permissions.microphone
                // Granted in System Settings: come back to the walkthrough.
                if !wasPermitted, permitted, step == .permissions { NSApp.activate() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onChange(of: step, initial: true) { test(during: step) }
        .onChange(of: microphone) { test(during: step) }
        .onChange(of: controller.lastTranscript) { if step == .practice { practiced = true } }
        .alert("Localflow can’t dictate without these permissions", isPresented: $confirmSkip) {
            Button("Continue Anyway") { step = .microphone }
            Button("Go Back", role: .cancel) {}
        } message: {
            Text("You can allow them later in Settings.")
        }
    }

    // MARK: Steps

    /// The wordmark (`Resources/Images/Wordmark.svg`), in the text colour.
    private static let wordmark = Bundle.main.url(forResource: "Wordmark", withExtension: "svg")
        .flatMap(NSImage.init(contentsOf:))

    private var welcome: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 112, height: 112)
            Group {
                if let wordmark = Self.wordmark {
                    Image(nsImage: wordmark).renderingMode(.template).resizable().scaledToFit().frame(height: 27)
                        .accessibilityLabel("Localflow")
                } else {
                    Text("Localflow").font(.system(size: 28, weight: .bold))
                }
            }
            .padding(.top, 18)
            Text("Write by speaking.")
                .font(.system(size: 17, weight: .semibold))
                .padding(.top, 22)
            Text("Dictate directly into the apps you use: hold a key, speak, and release to paste. Everything runs on this Mac.")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .padding(.top, 6)
        }
    }

    private var modelStep: some View {
        VStack(spacing: 22) {
            StepTitle(
                title: "Choose a speech model",
                subtitle: Text("Localflow downloads it once while you set up the rest. After that, dictation runs on this Mac.")
            )
            VStack(spacing: 10) {
                ForEach(SpeechModels.Kind.allCases) { kind in
                    ModelChoice(kind: kind, selected: settings.speechModel == kind) { settings.speechModel = kind }
                }
            }
            Text("You can switch or add a model later in Settings › Models.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    /// The chosen model's download, under the steps that follow its choice.
    @ViewBuilder private var downloadStatus: some View {
        let kind = settings.speechModel
        switch controller.speechModels.state(kind) {
        case .downloading(let fraction):
            HStack(spacing: 8) {
                ProgressView(value: fraction).frame(width: 120)
                Text("Downloading the \(kind.name) model… \(Int(fraction * 100))%")
                    .font(.system(size: 12)).foregroundStyle(.secondary).monospacedDigit()
            }
        case .failed(let message):
            HStack(spacing: 8) {
                Text("The speech model didn’t download: \(message)").font(.system(size: 12)).foregroundStyle(.red)
                Button("Try Again") { controller.speechModels.install(kind) }.controlSize(.small)
            }
        case .absent, .installed:
            EmptyView()
        }
    }

    private var permissions: some View {
        VStack(spacing: 22) {
            StepTitle(
                title: "Two permissions",
                subtitle: Text("Localflow needs both to work. Once they’re allowed, you’ll come back here.")
            )
            Card { PermissionRows(microphone: microphone, accessibility: accessibility) }
        }
    }

    private var microphoneTest: some View {
        VStack(spacing: 22) {
            StepTitle(title: "Say a few words", subtitle: Text("The waveform should move as you speak."))
            Card {
                Group {
                    if microphone == .authorized {
                        Waveform(buffer: waveform, shimmer: false, color: .primary).frame(width: 340, height: 64)
                    } else {
                        Text("Allow microphone access to test it.").foregroundStyle(.secondary).frame(height: 64)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            DeviceButton(settings: settings, current: controller.microphone, menuShown: $deviceMenuShown, showsName: true)
        }
    }

    private var shortcut: some View {
        let held = controller.isTriggerHeld
        return VStack(spacing: 22) {
            StepTitle(title: "Your dictation shortcut", subtitle: Text("\(key) is your shortcut. Press and hold it."))
            Text(key)
                .font(.system(size: 26, weight: .semibold))
                .frame(minWidth: 132, minHeight: 72)
                .padding(.horizontal, 16)
                .foregroundStyle(held ? .white : .primary)
                .background(RoundedRectangle(cornerRadius: 16).fill(held ? Color.accentColor : .primary.opacity(0.08)))
                .scaleEffect(held ? 0.96 : 1)
                .animation(.spring(duration: 0.2), value: held)
            Text(
                held
                    ? "That’s it. When you dictate, releasing it pastes your words."
                    : settings.pushToTalkShortcut == Shortcut(.fn)
                        ? "Fn needs “Press 🌐 key to” set to “Do Nothing” in Keyboard settings." : " ")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("Use another key:").font(.system(size: 12.5)).foregroundStyle(.secondary)
                ForEach(TriggerKey.allCases.filter { Shortcut($0) != settings.pushToTalkShortcut }) { other in
                    // One key for both, like Right ⌘; Settings can split them.
                    Button(other.shortTitle) {
                        settings.toggleShortcut = Shortcut(other)
                        settings.pushToTalkShortcut = Shortcut(other)
                    }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            }
        }
    }

    private var practiceStep: some View {
        VStack(spacing: 22) {
            StepTitle(title: "Try it", subtitle: Text("Hold \(key), say something, and release."))
            Card {
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $practice)
                        .font(.system(size: 14))
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .focused($practiceFocused)
                    if practice.isEmpty {
                        Text(practiceHint)
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 96)
                .padding(14)
            }
            Label("Nice, you’ve got it.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.green)
                .opacity(practiced ? 1 : 0)
        }
        .task {
            // After the step's transition: focus set while it runs doesn't reach the text view.
            try? await Task.sleep(for: .milliseconds(400))
            practiceFocused = true
        }
    }

    private var done: some View {
        @Bindable var settings = settings
        let glyph = Image(nsImage: MenuBarGlyph.image(for: .idle))
        return VStack(spacing: 18) {
            StepTitle(
                title: "You’re all set",
                subtitle: Text("Localflow lives in the menu bar \(glyph). Open Settings from there anytime.")
            )
            Card {
                Tip(symbol: "hand.tap", text: handsFreeTip)
                CardDivider()
                Tip(symbol: "escape", text: "Esc cancels a dictation.")
                CardDivider()
                Tip(symbol: "character.book.closed", text: "Fix a misheard name right after dictating, and Localflow learns it.")
            }
            Card {
                SettingRow(
                    title: "Clean up transcripts",
                    subtitle: settings.speechModel.supportsCleanup
                        ? "Removes filler words and applies spoken corrections. Downloads \(RewriteModel.name) (1.5 GB)."
                        : "Works with the English speech model only: its model was trained on English."
                ) {
                    // Off while it can't run; the choice is kept for the English model.
                    Switch(
                        title: "Clean up transcripts", isOn: Binding { settings.cleansUp } set: { settings.cleanup = $0 })
                        .disabled(!settings.speechModel.supportsCleanup)
                }
            }
        }
    }

    /// "Preparing dictation" while the model is still downloading.
    private var practiceHint: String {
        if case .downloading(let fraction) = controller.speechModels.state(settings.speechModel) {
            return "Preparing dictation… \(Int(fraction * 100))%"
        }
        return "Your words appear here."
    }

    private var handsFreeTip: String {
        guard let toggle = settings.toggleShortcut else {
            return "Toggle Recording in the menu bar starts and finishes a hands-free dictation."
        }
        return toggle == settings.pushToTalkShortcut
            ? "Tap \(toggle.title) to dictate hands-free, and press it again to finish."
            : "Press \(toggle.title) to dictate hands-free, and press it again to finish."
    }

    // MARK: Navigation

    private var footer: some View {
        ZStack {
            HStack(spacing: 7) {
                ForEach(Step.allCases, id: \.self) { item in
                    Circle().fill(item == step ? Color.primary : .primary.opacity(0.2)).frame(width: 6, height: 6)
                }
            }
            HStack {
                if step != .welcome {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1)! }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                }
                Spacer()
                Button(step == .welcome ? "Get Started" : step == .done ? "Done" : "Continue", action: next)
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 22)
        .padding(.top, 12)
    }

    private func next() {
        switch step {
        case .model:
            // Only the chosen model: one picked before going back is no longer wanted.
            for kind in SpeechModels.Kind.allCases where kind != settings.speechModel {
                controller.speechModels.cancel(kind)
            }
            controller.speechModels.install(settings.speechModel)
            step = .permissions
        case .permissions where !permitted: confirmSkip = true
        case .done: close()
        default: step = Step(rawValue: step.rawValue + 1)!
        }
    }

    /// The microphone runs only on its test step; on the shortcut step presses don't dictate.
    private func test(during step: Step) {
        switch step {
        case .microphone:
            waveform.meter = controller.meter
            waveform.reset()
            controller.beginTest(listening: true)
        case .shortcut:
            controller.beginTest(listening: false)
        default:
            controller.endTest()
        }
    }
}

/// One speech model to choose, with what it's good for and what it can't do.
private struct ModelChoice: View {
    let kind: SpeechModels.Kind
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(kind.name).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: kind.size, countStyle: .file))
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Text(description).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
            .overlay {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, lineWidth: 2).opacity(selected ? 1 : 0)
            }
        }
        .buttonStyle(.plain)
    }

    private var description: String {
        switch kind {
        case .english: "More accurate for English. Works with cleanup, which removes filler words and applies spoken corrections."
        case .multilingual:
            "25 European languages: \(SpeechModels.Kind.multilingualLanguages.formatted(.list(type: .and))). Cleanup isn’t available: it only knows English."
        }
    }
}

private struct StepTitle: View {
    let title: String
    let subtitle: Text

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.system(size: 24, weight: .bold))
            subtitle.font(.system(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }
}

private struct Tip: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 15)).foregroundStyle(.secondary).frame(width: 24)
            Text(text).font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 46)
    }
}
