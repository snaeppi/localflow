import AVFoundation
import AppKit
import SwiftUI

// Localflow's windows use 13 pt text, a 185 pt sidebar, 28 pt round glass buttons and 18 pt panel corners.

/// Localflow's windows (Settings, the walkthrough): the desktop shows blurred through the background, and the
/// content runs under a transparent title bar.
@MainActor
func makeWindow(title: String, size: NSSize, minSize: NSSize?, content: some View) -> NSWindow {
    var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
    if minSize != nil { style.insert(.resizable) }
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
    window.title = title
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    // An empty compact toolbar puts the traffic lights level with the page titles (22 pt down) and gives the window
    // macOS 26's larger corner radius.
    window.toolbar = NSToolbar()
    window.toolbarStyle = .unifiedCompact
    // No full screen and no zoom button.
    window.collectionBehavior.insert(.fullScreenNone)
    window.standardWindowButton(.zoomButton)?.isHidden = true
    window.isReleasedWhenClosed = false
    if let minSize { window.contentMinSize = minSize }
    let background = NSVisualEffectView()
    background.material = .underWindowBackground
    background.blendingMode = .behindWindow
    background.state = .active  // As translucent in the background as in front.
    window.contentView = background
    let host = NSHostingView(rootView: content)
    host.sizingOptions = []
    // The pages lay out the title bar area themselves. With the title bar as a safe area, scroll views
    // would extend up into it, over the page header.
    host.safeAreaRegions = []
    host.frame = background.bounds
    host.autoresizingMask = [.width, .height]
    background.addSubview(host)
    window.center()
    return window
}

// MARK: Layout

/// A page's title row, level with the window's traffic lights.
struct PageHeader<Trailing: View>: View {
    let title: String
    var info: String?
    /// A subpage's back button, left of the title (Advanced settings).
    var back: (() -> Void)?
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 7) {
            if let back {
                GlassIconButton(symbol: "chevron.left", label: "Back", action: back)
                    .padding(.leading, -6)
                    .padding(.trailing, 5)
            }
            Text(title).font(.system(size: 13, weight: .semibold))
            if let info { InfoButton(info) }
            Spacer()
            trailing
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .frame(height: 48)
        .background { WindowDragArea() }
    }
}

/// Lets the window be dragged by an empty area: the content covers the title bar.
struct WindowDragArea: View {
    var body: some View {
        Color.clear.contentShape(Rectangle()).gesture(WindowDragGesture())
    }
}

// MARK: Scroll edges

extension View {
    /// Lays `bar` over a scroll view's top or bottom edge: content scrolled under it fades toward the page
    /// background and blurs more the closer it gets to the window edge, with no visible boundary. (The
    /// system's soft scroll edge effect blurs an even band with a hard edge.)
    func scrollBar(_ edge: VerticalEdge, @ViewBuilder bar: () -> some View) -> some View {
        modifier(ScrollBar(edge: edge, bar: bar()))
    }
}

/// The blur runs a quarter of the bar's height past it.
private let scrollBarBlurReach: CGFloat = 1.25

private struct ScrollBar<Bar: View>: ViewModifier {
    let edge: VerticalEdge
    let bar: Bar
    // The page header's height, so the first layout pass doesn't jump.
    @State private var height: CGFloat = 48

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(edge == .top ? .top : .bottom, height)
            .scrollEdgeEffectHidden(true, for: edge == .top ? .top : .bottom)
            .overlay(alignment: edge == .top ? .top : .bottom) {
                ProgressiveBlur(edge: edge).frame(height: height * scrollBarBlurReach)
            }
            // Over the blur: blurring the fade would leave content visible at the edge.
            .mask { ScrollEdgeFade(edge: edge, length: height) }
            .overlay(alignment: edge == .top ? .top : .bottom) {
                bar.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            }
    }
}

/// The scroll view's mask: content fades out toward an edge with a bar.
private struct ScrollEdgeFade: View {
    /// Content opacity by distance from the window edge under a 48 pt header (scaled for bars of other
    /// heights).
    private static let curve: [(points: Double, opacity: Double)] = [
        (0, 0.07), (6, 0.15), (12, 0.28), (16, 0.46), (20, 0.63), (24, 0.75), (28, 0.83), (32, 0.88),
        (38, 0.93), (46, 1),
    ]
    let edge: VerticalEdge
    let length: CGFloat

    var body: some View {
        VStack(spacing: 0) {
            if edge == .top { fade.frame(height: length) }
            Color.black
            if edge == .bottom { fade.frame(height: length) }
        }
    }

    private var fade: LinearGradient {
        let stops = Self.curve.map { Gradient.Stop(color: .black.opacity($0.opacity), location: $0.points / 48) }
        return LinearGradient(stops: stops, startPoint: edge == .top ? .top : .bottom, endPoint: edge == .top ? .bottom : .top)
    }
}

/// A progressive blur: a stack of backdrop blurs, each stronger than the one before and masked to fade
/// out further from the edge, all sampling one shared backdrop so they don't blur each other. The
/// backdrop filter is private Core Animation API; where it's missing the bar stays clear.
private struct ProgressiveBlur: NSViewRepresentable {
    let edge: VerticalEdge

    func makeNSView(context: Context) -> ProgressiveBlurView { ProgressiveBlurView(edge: edge) }
    func updateNSView(_ view: ProgressiveBlurView, context: Context) {}
}

private final class ProgressiveBlurView: NSView {
    private static let maxRadius: CGFloat = 8
    private static let layerCount = 8
    /// The backdrop layers appear only once the view is in a window and has been drawn.
    private var retriesLeft = 10
    private let edge: VerticalEdge
    private let group = "Localflow.ProgressiveBlur.\(UUID().uuidString)"
    private var bands: [NSVisualEffectView] = []
    /// From 5% of the maximum radius far from the edge to all of it at the edge.
    private let blurs = (1...layerCount).compactMap { step in
        blur(radius: maxRadius * (0.05 + 0.95 * pow(CGFloat(step) / CGFloat(layerCount), 2.2)))
    }

    init(edge: VerticalEdge) {
        self.edge = edge
        super.init(frame: .zero)
        for _ in 0..<Self.layerCount {
            let band = NSVisualEffectView(frame: bounds)
            band.blendingMode = .withinWindow
            band.state = .active
            band.autoresizingMask = [.width, .height]
            band.alphaValue = 0  // Until its backdrop is a blur: unconfigured, it shows a material.
            addSubview(band)
            bands.append(band)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        configure()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        needsLayout = true
    }

    // NSVisualEffectView rebuilds its layers for a new appearance.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    private func configure() {
        guard window != nil, blurs.count == bands.count else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let count = CGFloat(bands.count)
        for (index, band) in bands.enumerated() {
            guard let layer = band.layer, let backdrop = Self.backdrop(in: layer) else {
                if retriesLeft > 0 {
                    retriesLeft -= 1
                    DispatchQueue.main.async { [weak self] in self?.needsLayout = true }
                }
                return
            }
            if backdrop.filters?.first as AnyObject? !== blurs[index] {
                backdrop.filters = [blurs[index]]
                backdrop.setValue(1.0, forKey: "scale")  // Full resolution; materials sample at a fraction.
                backdrop.setValue(group, forKey: "groupName")
            }
            // The material's tint layers.
            for sibling in backdrop.superlayer?.sublayers ?? [] where sibling !== backdrop { sibling.isHidden = true }
            // Opaque from the edge to this band's step, then fading out over one step.
            let mask = layer.mask as? CAGradientLayer ?? CAGradientLayer()
            mask.frame = layer.bounds
            mask.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            let outer = 1 - CGFloat(index) / count
            mask.locations = [0, max(outer - 1 / count, 0), outer].map { NSNumber(value: Double($0)) }
            // y = 1 is the top of a view's (unflipped) layer.
            mask.startPoint = CGPoint(x: 0.5, y: edge == .top ? 1 : 0)
            mask.endPoint = CGPoint(x: 0.5, y: edge == .top ? 0 : 1)
            layer.mask = mask
            band.alphaValue = 1
        }
    }

    private static func backdrop(in layer: CALayer) -> CALayer? {
        if NSStringFromClass(type(of: layer)).contains("Backdrop") { return layer }
        return layer.sublayers?.lazy.compactMap { backdrop(in: $0) }.first
    }

    private static func blur(radius: CGFloat) -> NSObject? {
        let make = NSSelectorFromString("filterWithType:")
        guard let type = NSClassFromString("CAFilter") as? NSObject.Type, type.responds(to: make),
            let filter = type.perform(make, with: "gaussianBlur")?.takeUnretainedValue() as? NSObject
        else { return nil }
        filter.setValue(radius, forKey: "inputRadius")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        return filter
    }
}

/// Rows on a rounded glass panel; separate rows with `CardDivider`.
struct Card<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

struct CardDivider: View {
    var body: some View {
        Rectangle().fill(.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 16)
    }
}

struct SectionTitle: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 14)
    }
}

/// A title, an optional subtitle and (i) explanation, and a control on the trailing side.
struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var info: String?
    var alignment = VerticalAlignment.center
    @ViewBuilder let control: Control

    var body: some View {
        HStack(alignment: alignment, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 13))
                    if let info { InfoButton(info) }
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, alignment == .top ? 6 : 0)
            Spacer(minLength: 12)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .frame(minHeight: 45)
    }
}

/// A 32 × 14 pt switch, in line with 13 pt text. The smallest system switch is 36 × 16, so it's drawn at 8/9
/// of that.
struct Switch: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn).labelsHidden().toggleStyle(.switch).controlSize(.mini)
            .scaleEffect(32 / 36)
            .frame(width: 32, height: 14)
    }
}

// MARK: Controls

/// An explanation behind an (i), opened by a click rather than on hover and to the right of the
/// icon. Markdown links work.
struct InfoButton: View {
    let text: String
    @State private var shown = false

    init(_ text: String) { self.text = text }

    var body: some View {
        Button {
            shown.toggle()
        } label: {
            Image(systemName: "info.circle").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More information")
        .popover(isPresented: $shown, arrowEdge: .trailing) {
            Text(LocalizedStringKey(text))
                .font(.system(size: 13))
                .frame(width: 240, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
        }
    }
}

struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 6)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5).fill(.primary.opacity(0.1)))
    }
}

/// A shortcut field: its keys as keycaps, or "Record shortcut" when there's none.
/// A click listens for the next key combination (or mouse button); Esc stops listening, ⌫ removes the
/// shortcut (or, where one is required, brings back the default), and the arrow brings back the default.
struct ShortcutField<Value: Equatable>: View {
    @Binding var value: Value?
    var defaultValue: Value?
    let keys: (Value) -> [String]
    /// Besides key presses (which Esc and ⌫ need), e.g. `.otherMouseDown` for a mouse shortcut.
    var events: NSEvent.EventTypeMask = []
    var allowsNone = true
    /// What an event (after the one before it) records, or nil if it can't be a shortcut: then Localflow beeps
    /// and keeps listening, except for modifier changes, which are steps on the way to one.
    let parse: (_ event: NSEvent, _ previous: NSEvent?) -> Value?
    /// Localflow's own shortcuts mustn't act while one is being recorded.
    let onRecording: (Bool) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var previous: NSEvent?

    var body: some View {
        HStack(spacing: 10) {
            if value != defaultValue, !recording {
                Button {
                    value = defaultValue
                } label: {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(defaultValue == nil ? "Remove shortcut" : "Reset to default")
            }
            Button(action: { recording ? stop() : start() }) { label.contentShape(Rectangle()) }
                .buttonStyle(.plain)
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    @ViewBuilder private var label: some View {
        if recording {
            Text(events.contains(.otherMouseDown) ? "Press a mouse button…" : "Press shortcut…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .frame(minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.06)))
        } else if let value {
            HStack(spacing: 4) {
                ForEach(Array(keys(value).enumerated()), id: \.offset) { KeyCap($0.element) }
            }
        } else {
            Text("Record shortcut").font(.system(size: 12)).foregroundStyle(.tertiary)
        }
    }

    private func start() {
        recording = true
        previous = nil
        onRecording(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: events.union(.keyDown)) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil  // Nothing reaches the window while listening.
        }
    }

    private func handle(_ event: NSEvent) {
        defer { previous = event }
        let plain = event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        if event.type == .keyDown, plain, event.keyCode == 53 {  // Esc
            stop()
        } else if event.type == .keyDown, plain, event.keyCode == 51 {  // ⌫
            value = allowsNone ? nil : defaultValue
            stop()
        } else if let recorded = parse(event, previous) {
            value = recorded
            stop()
        } else if event.type != .flagsChanged {
            NSSound.beep()
        }
    }

    private func stop() {
        guard recording else { return }
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        onRecording(false)
    }
}

/// The mark for experimental options.
struct ExperimentalBadge: View {
    var body: some View {
        Image(systemName: "atom").font(.system(size: 13)).foregroundStyle(.secondary).help("Experimental")
    }
}

/// Picture tiles with a caption; each tile draws its own selection ring.
struct ChoiceTiles<Value: Hashable, Tile: View>: View {
    @Binding var selection: Value
    let options: [(value: Value, title: String)]
    var spacing: CGFloat = 18
    @ViewBuilder let tile: (Value, Bool) -> Tile

    var body: some View {
        HStack(alignment: .top, spacing: spacing) {
            ForEach(options, id: \.value) { option in
                let selected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    VStack(spacing: 6) {
                        tile(option.value, selected)
                        Text(option.title)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(selected ? .primary : .secondary)
                            .fixedSize()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(option.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .fixedSize()
    }
}

/// macOS's theme thumbnails as System Settings › Appearance shows them, read from its extension rather
/// than copied into the app; ringed when selected.
struct ThemeTile: View {
    let theme: AppSettings.Theme
    let selected: Bool

    private static let appearanceSettings = Bundle(path: "/System/Library/ExtensionKit/Extensions/Appearance.appex")

    private var imageName: String {
        switch theme {
        case .auto: "AppearanceAuto"
        case .light: "AppearanceLight"
        case .dark: "AppearanceDark"
        }
    }

    var body: some View {
        Image(nsImage: Self.appearanceSettings?.image(forResource: imageName) ?? NSImage())
            .resizable()
            .frame(width: 67, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.black.opacity(0.3), lineWidth: 1))
            .padding(2.5)
            .overlay(RoundedRectangle(cornerRadius: 10.5).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
    }
}

/// The recording window on or off, drawn small on a tile.
struct RecordingWindowTile: View {
    let on: Bool
    let selected: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(selected ? Color.accentColor.opacity(0.12) : Color(nsColor: .textBackgroundColor).opacity(0.45))
            RoundedRectangle(cornerRadius: 10).strokeBorder(.primary.opacity(0.12), lineWidth: 1)
            if on {
                PillIcon(selected: selected)
            } else {
                Image(systemName: "eye.slash").font(.system(size: 15)).foregroundStyle(.secondary)
            }
        }
        .frame(width: 94, height: 44)
        .padding(1)
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
    }
}

/// The recording window's pill in the tile, with resting bars. Selecting it sends a dip through the bars from left to
/// right.
private struct PillIcon: View {
    let selected: Bool
    @State private var waveStart: Date?
    private static let heights: [CGFloat] = [4, 9, 6, 3, 8, 4, 6, 3]
    /// Each bar dips to a third of its height over a quarter second, 45 ms after the one before it.
    private static let dip = (depth: 0.65, duration: 0.25, stagger: 0.045)

    var body: some View {
        TimelineView(.animation(paused: waveStart == nil)) { context in
            let elapsed = waveStart.map { context.date.timeIntervalSince($0) } ?? -1
            HStack(spacing: 1) {
                ForEach(Self.heights.indices, id: \.self) { i in
                    let t = (elapsed - Double(i) * Self.dip.stagger) / Self.dip.duration
                    let scale = (0...1).contains(t) ? 1 - Self.dip.depth * sin(.pi * t) : 1
                    Capsule().fill(.white).frame(width: 2, height: max(2, Self.heights[i] * scale))
                }
            }
        }
        .frame(width: 50, height: 20)
        .background(Capsule().fill(.black))
        .onChange(of: selected) {
            guard selected else { return }
            waveStart = .now
            Task {
                try? await Task.sleep(for: .seconds(Self.dip.duration + Self.dip.stagger * 8 + 0.1))
                waveStart = nil
            }
        }
    }
}

// MARK: Microphone

/// The microphone as a round glass button showing the device's icon, its name on hover, and
/// `deviceMenu` on click.
struct DeviceButton: View {
    @Bindable var settings: AppSettings
    let current: AudioDevices.Device?
    @Binding var menuShown: Bool
    var showsName = false
    @State private var hovering = false

    private var name: String {
        guard let current else { return "No microphone" }
        return settings.microphoneUID == nil ? "\(current.name) (Automatic)" : current.name
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .opacity(hovering || showsName || menuShown ? 1 : 0)
            GlassIconButton(symbol: current?.symbol ?? "mic.slash", label: "Microphone: \(name)") {
                menuShown.toggle()
            } onHover: { hovering in
                withAnimation(.easeOut(duration: 0.15)) { self.hovering = hovering }
            }
            .anchorPreference(key: DeviceButtonBounds.self, value: .bounds) { $0 }
        }
    }
}

private struct DeviceButtonBounds: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

extension View {
    /// The microphone list that `DeviceButton` opens: a glass panel under the button, closed by
    /// choosing, clicking elsewhere or Esc. Apply it to the window's root view.
    func deviceMenu(isPresented: Binding<Bool>, settings: AppSettings, devices: [AudioDevices.Device]) -> some View {
        overlayPreferenceValue(DeviceButtonBounds.self) { anchor in
            if isPresented.wrappedValue, let anchor {
                GeometryReader { proxy in
                    let button = proxy[anchor]
                    ZStack(alignment: .topTrailing) {
                        Color.black.opacity(0.001).onTapGesture { isPresented.wrappedValue = false }
                        DeviceMenu(settings: settings, devices: devices) { isPresented.wrappedValue = false }
                            .padding(.top, button.maxY + 6)
                            .padding(.trailing, max(8, proxy.size.width - button.maxX))
                    }
                }
            }
        }
    }
}

private struct DeviceMenu: View {
    @Bindable var settings: AppSettings
    let devices: [AudioDevices.Device]
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row("Automatic", symbol: "speaker.wave.2", uid: nil)
                .help("Uses the system input, but skips Bluetooth headsets: their microphones are less accurate and slow to start.")
            ForEach(devices) { row($0.name, symbol: $0.symbol, uid: $0.uid) }
        }
        .padding(4)
        .frame(minWidth: 250, alignment: .leading)
        .fixedSize()
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .background {
            Button("Close", action: close).keyboardShortcut(.cancelAction).opacity(0)
        }
    }

    private func row(_ title: String, symbol: String, uid: String?) -> some View {
        DeviceMenuRow(title: title, symbol: symbol, selected: settings.microphoneUID == uid) {
            settings.microphoneUID = uid
            close()
        }
    }
}

private struct DeviceMenuRow: View {
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(selected ? .white : .secondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(selected ? Color.accentColor : .primary.opacity(0.1)))
                Text(title).font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(Rectangle())
            .background {
                if hovering { RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.08)) }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A round glass button with a symbol, as in the page headers.
struct GlassIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var onHover: (Bool) -> Void = { _ in }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(GlassBounce(onHover: onHover))
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Round buttons give under the pointer: they drop most of the way to 90% within ~30 ms of a press and
/// spring back on release, ~2% past full size at ~0.11 s. Plain glass: interactive glass grows under a
/// press instead.
private struct GlassBounce: ButtonStyle {
    let onHover: (Bool) -> Void

    func makeBody(configuration: Configuration) -> some View {
        GlassBounceBody(configuration: configuration, onHover: onHover)
    }
}

private struct GlassBounceBody: View {
    let configuration: ButtonStyle.Configuration
    let onHover: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        let pressed = configuration.isPressed
        configuration.label
            .background(Circle().fill(.primary.opacity(hovering ? 0.08 : 0)))
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) { self.hovering = hovering }
                onHover(hovering)
            }
            .glassEffect(.regular, in: .circle)
            .scaleEffect(pressed ? 0.9 : 1)
            .animation(
                pressed ? .spring(response: 0.15, dampingFraction: 1) : .spring(response: 0.22, dampingFraction: 0.5),
                value: pressed)
    }
}

// MARK: Permissions

/// Microphone and Accessibility, each with what it's for and a button until it's granted.
struct PermissionRows: View {
    let microphone: AVAuthorizationStatus
    let accessibility: Bool

    var body: some View {
        PermissionRow(
            title: "Microphone", detail: "To hear you while you dictate. Audio stays on this Mac and isn’t saved.",
            granted: microphone == .authorized,
            action: microphone == .notDetermined ? "Allow" : "Open Settings"
        ) {
            if microphone == .notDetermined {
                Task { _ = await AVCaptureDevice.requestAccess(for: .audio) }
            } else {
                Permissions.openMicrophoneSettings()
            }
        }
        CardDivider()
        PermissionRow(
            title: "Accessibility",
            detail: "To notice the shortcut and paste into your apps. Turn on Localflow in Privacy & Security › \(Permissions.accessibilityPaneName).",
            granted: accessibility, action: "Open Settings"
        ) {
            Permissions.requestAccessibility()
            Permissions.openAccessibilitySettings()
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: String
    let perform: () -> Void

    var body: some View {
        SettingRow(title: title, subtitle: detail) {
            if granted {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            } else {
                Button(action, action: perform)
            }
        }
    }
}
