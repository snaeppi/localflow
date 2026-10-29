import AppKit
import SwiftUI

/// The recording window: a black pill that shows
/// the live waveform while recording. With "Always show" it stays on screen between dictations as a
/// sliver that opens under the pointer into three buttons — cleanup on or off, start dictating, open
/// Settings — and while recording it opens into a stop button. It can be dragged to any of 17 places
/// per screen.
///
/// It lives in a non-activating panel that never becomes key, so it can never take focus away from
/// the text field the transcript is going into. The panel takes the mouse only while the pointer is
/// on the pill; polling the pointer (`trackPointer`) notices it arriving.
@MainActor
final class RecordingWindow {
    enum Mode: Equatable {
        case hidden
        case listening(handsFree: Bool)
        case transcribing
        case notice(String, symbol: String)
    }

    /// What the pill's buttons and context menu do.
    struct Actions {
        var record: () -> Void = {}
        var toggleCleanup: () -> Void = {}
        var openSettings: () -> Void = {}
        var copyLastTranscript: () -> Void = {}
    }

    /// Hovering this long opens the pill, so passing over it doesn't.
    private static let openDelay: Duration = .milliseconds(300)
    /// Resting on a button this long shows its tooltip.
    private static let tooltipDelay: Duration = .milliseconds(450)
    /// How far around the closed pill the pointer opens it, so the thin sliver needn't be hit exactly:
    /// about the open pill's size and then some.
    private static let reach = CGSize(width: 50, height: 22)
    private static let panelSize = NSSize(width: 300, height: 140)
    private static let spotKey = "recordingWindowPosition"
    private static let screenKey = "recordingWindowScreen"

    private let model = RecordingWindowModel()
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?
    private var openTask: Task<Void, Never>?
    private var tooltipTask: Task<Void, Never>?
    private var pointerPoll: Timer?
    private var screenObserver: Any?
    /// Where in the panel the pointer grabbed it, while dragging.
    private var grab: CGPoint?
    private var zones: SnapZones?

    init() {
        model.spot = UserDefaults.standard.string(forKey: Self.spotKey).flatMap(SnapSpot.init) ?? .home
        model.onDrag = { [weak self] ended in
            if ended { self?.endDrag() } else { self?.drag() }
        }
    }

    var actions: Actions {
        get { model.actions }
        set { model.actions = newValue }
    }

    /// The settings that shape the recording window; notices show even when it's off (`enabled` false).
    func configure(enabled: Bool, alwaysShow: Bool, shortcut: String, cleanup: Bool) {
        model.shortcut = shortcut
        model.cleanup = cleanup
        guard enabled != model.enabled || alwaysShow != model.alwaysShow else { return }
        model.enabled = enabled
        model.alwaysShow = alwaysShow
        if model.mode == .hidden { show(.hidden) }  // Shows or hides the idle sliver.
    }

    func show(_ mode: Mode) {
        hideTask?.cancel()
        var mode = mode
        if !model.enabled, mode == .transcribing || mode.isListening { mode = .hidden }
        if case .listening = mode, !model.mode.isListening { model.waveform.reset() }
        if mode == .hidden, !model.idleShown {
            model.mode = .hidden
            setPointer(inside: false)
            // Let the fade-out finish before ordering the panel out.
            hideTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                self.panel?.orderOut(nil)
                self.trackPointer()
            }
            return
        }
        let panel = self.panel ?? makePanel()
        if !panel.isVisible {
            position(panel)
            panel.orderFrontRegardless()
        }
        model.mode = mode
        trackPointer()
        pointerMoved()  // The pill changed size under a resting pointer.
        if case .notice = mode {
            hideTask = Task {
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                self.show(.hidden)
            }
        }
    }

    /// Where the waveform reads live microphone levels from.
    func attach(_ meter: LevelMeter) {
        model.waveform.meter = meter
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.appearance = NSAppearance(named: .darkAqua)  // Whatever theme the app's windows use.
        let host = FirstMouseHostingView(rootView: RecordingWindowView(model: model))
        host.sizingOptions = []
        panel.contentView = host
        self.panel = panel
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let panel = self.panel, panel.isVisible else { return }
                self.position(panel)
            }
        }
        return panel
    }

    // MARK: Position

    /// The screen the pill was last dropped on, if it's still connected.
    private var screen: NSScreen {
        let id = UserDefaults.standard.integer(forKey: Self.screenKey)
        return NSScreen.screens.first { $0.displayID == id } ?? NSScreen.screens.first ?? NSScreen.main!
    }

    private func position(_ panel: NSPanel) {
        panel.setFrame(model.spot.panelFrame(size: Self.panelSize, on: screen), display: false)
    }

    /// The centre of the pill at its current size.
    private func pillCenter(in frame: NSRect) -> CGPoint {
        let height = model.shape.size.height
        let y: CGFloat =
            switch model.spot.row {
            case .top: frame.maxY - height / 2
            case .bottom: frame.minY + height / 2
            default: frame.midY
            }
        return CGPoint(x: frame.midX, y: y)
    }

    // MARK: Pointer

    /// Polls the pointer while the pill can be hovered (always shown, or while recording). A global
    /// mouse-moved monitor misses moves while Localflow itself is active, e.g. with Settings open, so the
    /// pill wouldn't open; 20 checks a second of a point in a rectangle cost nothing.
    private func trackPointer() {
        let wanted = panel?.isVisible == true && model.isInteractive
        if wanted, pointerPoll == nil {
            let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.pointerMoved() }
            }
            timer.tolerance = 0.01
            RunLoop.main.add(timer, forMode: .common)
            pointerPoll = timer
        } else if !wanted, let timer = pointerPoll {
            timer.invalidate()
            pointerPoll = nil
            setPointer(inside: false)
        }
    }

    private func pointerMoved() {
        guard let panel, panel.isVisible, model.isInteractive else { return setPointer(inside: false) }
        if grab != nil { return }  // Dragging: the pill follows the pointer.
        let size = model.shape.size
        let center = pillCenter(in: panel.frame)
        let mouse = NSEvent.mouseLocation
        let (dx, dy) = (mouse.x - center.x, mouse.y - center.y)
        // Closed, the pill catches the pointer well around it; open, around its edges and on the
        // tooltip; at the top of a screen, anywhere above it too (the pointer thrown against the edge).
        let margin = model.expanded ? CGSize(width: 16, height: 14) : Self.reach
        let across = abs(dx) <= size.width / 2 + margin.width
        var inside = across && abs(dy) <= size.height / 2 + margin.height
        if model.spot.row == .top, across, dy > 0 { inside = true }
        if model.expanded, model.tooltipPart != nil, abs(dx) <= 100 {
            let reach = size.height / 2 + 10 + 37
            inside = inside || (model.spot.row == .bottom ? (dy > 0 && dy <= reach) : (dy < 0 && -dy <= reach))
        }
        setPointer(inside: inside)
        guard inside else { return }
        let part: PillPart =
            if !model.expanded || abs(dy) > size.height / 2 + 4 {
                .pill
            } else if model.mode == .hidden {
                dx < -23.5 ? .cleanup : dx > 23.5 ? .settings : .record
            } else {
                dx < -23.5 ? .record : .pill
            }
        if part != model.pointer {
            model.pointer = part
            showTooltip(after: part)
        }
    }

    private func setPointer(inside: Bool) {
        panel?.ignoresMouseEvents = !inside
        if inside {
            if !model.expanded, openTask == nil {
                openTask = Task {
                    try? await Task.sleep(for: Self.openDelay)
                    guard !Task.isCancelled else { return }
                    self.model.expanded = true
                    self.openTask = nil
                    self.pointerMoved()
                }
            }
        } else {
            openTask?.cancel()
            openTask = nil
            tooltipTask?.cancel()
            model.expanded = false
            model.pointer = nil
            model.tooltipPart = nil
        }
    }

    /// Tooltips appear once the pointer rests on a button.
    private func showTooltip(after part: PillPart) {
        tooltipTask?.cancel()
        if model.tooltipPart != nil {
            model.tooltipPart = part  // Moving between buttons keeps the tooltip up.
            return
        }
        tooltipTask = Task {
            try? await Task.sleep(for: Self.tooltipDelay)
            guard !Task.isCancelled, self.model.pointer == part else { return }
            self.model.tooltipPart = part
        }
    }

    // MARK: Dragging

    private func drag() {
        guard let panel else { return }
        let mouse = NSEvent.mouseLocation
        if grab == nil {
            grab = CGPoint(x: mouse.x - panel.frame.minX, y: mouse.y - panel.frame.minY)
            model.dragging = true
            model.tooltipPart = nil
            zones = SnapZones(Self.allSpots().map(\.pill))
            panel.orderFrontRegardless()  // Above the zones.
        }
        guard let grab else { return }
        panel.setFrameOrigin(NSPoint(x: mouse.x - grab.x, y: mouse.y - grab.y))
        zones?.highlight(nearestSpot(to: pillCenter(in: panel.frame))?.index)
    }

    private func endDrag() {
        guard let panel, grab != nil else { return }
        grab = nil
        model.dragging = false
        zones = nil
        if let target = nearestSpot(to: pillCenter(in: panel.frame)) {
            model.spot = target.spot
            UserDefaults.standard.set(target.spot.id, forKey: Self.spotKey)
            UserDefaults.standard.set(target.screen.displayID, forKey: Self.screenKey)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                panel.animator().setFrame(target.spot.panelFrame(size: Self.panelSize, on: target.screen), display: true)
            }
        }
        pointerMoved()
    }

    /// Every spot on every screen, with the open pill's frame there.
    private static func allSpots() -> [(spot: SnapSpot, screen: NSScreen, pill: NSRect)] {
        NSScreen.screens.flatMap { screen in
            SnapSpot.all.map { spot in (spot, screen, spot.panelFrame(size: PillShape.expanded.size, on: screen)) }
        }
    }

    private func nearestSpot(to point: CGPoint) -> (spot: SnapSpot, screen: NSScreen, index: Int)? {
        Self.allSpots().enumerated()
            .min { hypot($0.element.pill.midX - point.x, $0.element.pill.midY - point.y)
                < hypot($1.element.pill.midX - point.x, $1.element.pill.midY - point.y) }
            .map { ($0.element.spot, $0.element.screen, $0.offset) }
    }
}

/// A place the pill snaps to, 17 per screen: five along the top and five along the bottom, evenly from edge
/// to edge; three more down each side, a quarter, half and 70% of the way down; and the middle of the screen.
struct SnapSpot: Hashable {
    enum Row: String {
        case top, upper, middle, lower, bottom
    }

    /// 0 at the left edge to 4 at the right.
    let column: Int
    let row: Row

    static let home = SnapSpot(column: 2, row: .top)

    static let all: [SnapSpot] =
        (0...4).flatMap { [SnapSpot(column: $0, row: .top), SnapSpot(column: $0, row: .bottom)] }
        + [0, 4].flatMap { column in [Row.upper, .middle, .lower].map { SnapSpot(column: column, row: $0) } }
        + [SnapSpot(column: 2, row: .middle)]

    init(column: Int, row: Row) {
        self.column = column
        self.row = row
    }

    init?(_ id: String) {
        let parts = id.split(separator: "-")
        guard parts.count == 2, let column = Int(parts[0]), let row = Row(rawValue: String(parts[1])),
            let spot = Self.all.first(where: { $0.column == column && $0.row == row })
        else { return nil }
        self = spot
    }

    var id: String { "\(column)-\(row.rawValue)" }

    /// The frame of something `size` big placed here: against the top or bottom edge 4 pt in, or
    /// centred; horizontally 120 pt in from the sides at the edges.
    func panelFrame(size: CGSize, on screen: NSScreen) -> NSRect {
        let visible = screen.visibleFrame
        let x = visible.minX + 120 + CGFloat(column) * (visible.width - 240) / 4
        let y: CGFloat =
            switch row {
            case .top: visible.maxY - 4 - size.height
            case .upper: visible.maxY - 0.25 * visible.height - size.height / 2
            case .middle: visible.maxY - 0.5 * visible.height - size.height / 2
            case .lower: visible.maxY - 0.7 * visible.height - size.height / 2
            case .bottom: visible.minY + 4
            }
        return NSRect(x: x - size.width / 2, y: y, width: size.width, height: size.height)
    }

    var alignment: Alignment {
        switch row {
        case .top: .top
        case .bottom: .bottom
        default: .center
        }
    }
}

/// The places the pill can be dropped, shown while dragging it, the nearest one ringed.
@MainActor
private final class SnapZones {
    private let panels: [NSPanel]
    private let model = SnapZonesModel()

    init(_ frames: [NSRect]) {
        let model = model
        panels = frames.enumerated().map { index, frame in
            let panel = NSPanel(
                contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.ignoresMouseEvents = true
            panel.contentView = NSHostingView(rootView: SnapZoneView(model: model, index: index))
            panel.orderFrontRegardless()
            return panel
        }
    }

    deinit {
        let panels = panels
        MainActor.assumeIsolated { panels.forEach { $0.orderOut(nil) } }
    }

    func highlight(_ index: Int?) {
        model.highlighted = index
    }
}

@MainActor @Observable
private final class SnapZonesModel {
    var highlighted: Int?
}

private struct SnapZoneView: View {
    let model: SnapZonesModel
    let index: Int

    var body: some View {
        let on = model.highlighted == index
        Capsule()
            .fill(.black.opacity(0.22))
            .overlay(Capsule().strokeBorder(on ? Color.accentColor : .white.opacity(0.3), lineWidth: on ? 2.5 : 1))
            .animation(.easeOut(duration: 0.15), value: on)
    }
}

/// Takes the first click: the panel never becomes key, so a click must act at once.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private extension NSScreen {
    var displayID: Int { (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.intValue ?? 0 }
}

// MARK: Model

/// The pill's sizes: a sliver between dictations, compact while recording,
/// open while the pointer is on it.
enum PillShape: Equatable {
    case sliver, compact, expanded
    case notice(String, symbol: String)

    var size: CGSize {
        switch self {
        case .sliver: CGSize(width: 50, height: 9)
        case .compact: CGSize(width: 59, height: 30)
        case .expanded: CGSize(width: 141, height: 37)
        case .notice: CGSize(width: 260, height: 30)
        }
    }

    var isNotice: Bool {
        if case .notice = self { return true }
        return false
    }
}

/// What the pointer is on.
enum PillPart: Equatable {
    case pill, cleanup, record, settings
}

@MainActor @Observable
private final class RecordingWindowModel {
    var mode: RecordingWindow.Mode = .hidden
    var enabled = true
    var alwaysShow = false
    var shortcut = ""
    var cleanup = false
    var spot = SnapSpot.home
    var expanded = false
    var pointer: PillPart?
    var tooltipPart: PillPart?
    var dragging = false
    @ObservationIgnored var actions = RecordingWindow.Actions()
    /// Called as the pill is dragged (false) and dropped (true).
    @ObservationIgnored var onDrag: ((Bool) -> Void)?
    let waveform = WaveformBuffer()

    /// The sliver stays on screen between dictations.
    var idleShown: Bool { enabled && alwaysShow }

    var isShown: Bool { mode != .hidden || idleShown }

    /// The pointer can open the pill: between dictations when it's always shown, or while recording.
    var isInteractive: Bool {
        switch mode {
        case .hidden: idleShown
        case .listening, .transcribing: true
        case .notice: false
        }
    }

    var shape: PillShape {
        switch mode {
        case .notice(let text, let symbol): .notice(text, symbol: symbol)
        case .hidden: expanded || dragging ? .expanded : .sliver
        case .listening, .transcribing: expanded || dragging ? .expanded : .compact
        }
    }

    var tooltip: (text: String, key: String?)? {
        guard expanded, !dragging, let part = tooltipPart else { return nil }
        switch (part, mode) {
        case (.record, .hidden): return ("Start dictation", shortcut)
        case (.record, .listening): return ("Finish dictation", shortcut)
        case (.cleanup, .hidden): return (cleanup ? "Turn off cleanup" : "Turn on cleanup", nil)
        case (.settings, .hidden): return ("Open Settings", nil)
        default: return nil
        }
    }

    func tap() {
        switch (pointer, mode) {
        case (.record, .hidden), (.record, .listening): actions.record()
        case (.cleanup, .hidden): actions.toggleCleanup()
        case (.settings, .hidden): actions.openSettings()
        default: break
        }
    }
}

private extension RecordingWindow.Mode {
    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }
}

/// Smooths bursty level delivery (audio arrives in ~20–100 ms chunks) into a steady scroll.
@MainActor
final class WaveformBuffer {
    private let barCount: Int
    private(set) var bars: [Float]
    var meter: LevelMeter?
    private var queue: [Float] = []
    private var lastAdvance: TimeInterval = 0
    private let step: TimeInterval = 0.04  // Scroll speed: one bar per 40 ms.

    init(barCount: Int = 26) {
        self.barCount = barCount
        bars = [Float](repeating: 0, count: barCount)
    }

    private func push(_ levels: [Float]) {
        // Two 20 ms levels per bar; keep the louder one so syllables stay visible.
        var i = 0
        while i < levels.count {
            queue.append(levels[i..<min(i + 2, levels.count)].max() ?? 0)
            i += 2
        }
        if queue.count > 12 { queue.removeFirst(queue.count - 12) }  // Never lag behind live audio.
    }

    func reset() {
        bars = [Float](repeating: 0, count: barCount)
        queue.removeAll()
        _ = meter?.drain()
    }

    func advance(to time: TimeInterval) {
        if let levels = meter?.drain(), !levels.isEmpty { push(levels) }
        if lastAdvance == 0 || time - lastAdvance > 0.5 { lastAdvance = time }
        while time - lastAdvance >= step {
            lastAdvance += step
            let next = queue.isEmpty ? (bars.last ?? 0) * 0.6 : queue.removeFirst()
            bars.removeFirst()
            bars.append(next)
        }
    }
}

// MARK: Views

/// One layout for every state: what's leaving fades out at once, the capsule resizes, and what's arriving
/// fades in as it settles. The logo stays, sliding from the middle to the left and turning red when
/// recording starts. No bounce anywhere.
private struct RecordingWindowView: View {
    let model: RecordingWindowModel
    private static let red = Color(red: 1, green: 0.27, blue: 0.23)
    private static let resize = Animation.smooth(duration: 0.28).delay(0.03)

    var body: some View {
        pill
            .opacity(model.isShown ? 1 : 0)
            .scaleEffect(model.isShown ? 1 : 0.6, anchor: model.spot.alignment.unitPoint)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: model.spot.alignment)
            .animation(Self.resize, value: model.shape)
            .animation(Self.resize, value: model.isShown)
            .animation(.easeOut(duration: 0.2), value: model.tooltipPart)
    }

    /// Leaving: quickly. Arriving: once the capsule has nearly reached its new size.
    private func fade(_ visible: Bool) -> Animation {
        visible ? .easeOut(duration: 0.16).delay(0.16) : .easeOut(duration: 0.08)
    }

    private var pill: some View {
        let shape = model.shape
        let sliver = shape == .sliver
        let open = shape == .expanded
        let idle = model.mode == .hidden
        let recording = model.mode.isListening
        let processing = model.mode == .transcribing
        let buttons = open && idle
        let wave = open && !idle
        return ZStack {
            highlightCircle(open: open, idle: idle, recording: recording, wave: wave)
            sideButtons(visible: buttons)
            logoView(open: open, recording: recording, processing: processing, wave: wave)
            waveforms(shape: shape, wave: wave, processing: processing)
            if case .notice(let text, let symbol) = shape {
                HStack(spacing: 8) {
                    Image(systemName: symbol).foregroundStyle(.white.opacity(0.75))
                    Text(text).foregroundStyle(.white).lineLimit(1)
                }
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 14)
                .fixedSize()
                .transition(.opacity.animation(fade(true)))
            }
        }
        .foregroundStyle(.white)
        .frame(width: shape.isNotice ? nil : shape.size.width, height: shape.size.height)
        .background {
            // The sliver tints what's behind it; the open pill is black.
            Capsule().fill(sliver ? Color.black.opacity(0.45) : Color(white: 0.04))
        }
        .overlay { Capsule().strokeBorder(.white.opacity(sliver ? 0.4 : 0.14), lineWidth: sliver ? 1 : 0.75) }
        .clipShape(Capsule())
        .contentShape(Capsule())
        .overlay { tooltip(below: shape.size.height) }
        .onTapGesture { model.tap() }
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { _ in model.onDrag?(false) }
                .onEnded { _ in model.onDrag?(true) }
        )
        .contextMenu {
            Button("Open Settings…") { model.actions.openSettings() }
            Button("Copy Last Transcript") { model.actions.copyLastTranscript() }
        }
    }

    /// The circle behind the button under the pointer (red behind the stop button). It stays put
    /// when the logo slides back after a dictation and becomes that button's.
    private func highlightCircle(open: Bool, idle: Bool, recording: Bool, wave: Bool) -> some View {
        let highlight = highlight(open: open, idle: idle, recording: recording)
        let color: Color = highlight?.color ?? .clear
        let x: CGFloat = highlight?.x ?? (wave ? -47 : 0)
        return Circle()
            .fill(color)
            .animation(.easeOut(duration: 0.2), value: color)
            .frame(width: 31, height: 31)
            .animation(.smooth(duration: 0.2)) { $0.offset(x: x) }
    }

    private func sideButtons(visible: Bool) -> some View {
        let cleanup: Double = visible ? (model.cleanup ? 1 : 0.45) : 0
        return ZStack {
            Image(systemName: "eraser")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 31, height: 31)
                .animation(fade(visible)) { $0.opacity(cleanup) }
                .offset(x: -47)
            Image(systemName: "gearshape")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 31, height: 31)
                .animation(fade(visible)) { $0.opacity(visible ? 1 : 0) }
                .offset(x: 47)
        }
    }

    /// Recording starts: slides left at once. It ends: turns white, the waveform fades, then it
    /// slides back to the middle.
    private func logoView(open: Bool, recording: Bool, processing: Bool, wave: Bool) -> some View {
        let color: Color = recording ? Self.red : .white.opacity(processing ? 0.85 : 1)
        let x: CGFloat = wave ? -47 : 0
        return logo
            .animation(.easeOut(duration: 0.2).delay(recording ? 0.08 : 0)) { $0.foregroundStyle(color) }
            .frame(width: 31, height: 31)
            .animation(fade(open)) { $0.opacity(open ? 1 : 0) }
            .animation(.smooth(duration: 0.22).delay(wave ? 0 : 0.1)) { $0.offset(x: x) }
    }

    private func waveforms(shape: PillShape, wave: Bool, processing: Bool) -> some View {
        let compact = shape == .compact
        return ZStack {
            Waveform(
                buffer: model.waveform, shimmer: processing, bars: 14, barWidth: 2, minHeight: 2, paused: !wave)
                .frame(width: 72, height: 16)
                .animation(fade(wave)) { $0.opacity(wave ? 1 : 0) }
                .offset(x: 23)
            Waveform(
                buffer: model.waveform, shimmer: processing, bars: 6, barWidth: 2, minHeight: 2, paused: !compact)
                .frame(width: 33, height: 14)
                .animation(fade(compact)) { $0.opacity(compact ? 1 : 0) }
        }
    }

    private func highlight(open: Bool, idle: Bool, recording: Bool) -> (x: CGFloat, color: Color)? {
        guard open else { return nil }
        if recording { return (-47, Self.red.opacity(model.pointer == .record ? 0.4 : 0.28)) }
        if !idle { return (-47, .white.opacity(0.14)) }  // Transcribing.
        switch model.pointer {
        case .cleanup: return (-47, .white.opacity(0.2))
        case .record: return (0, .white.opacity(0.2))
        case .settings: return (47, .white.opacity(0.2))
        default: return nil
        }
    }

    /// The app's menu bar glyph.
    private var logo: some View {
        Image(nsImage: MenuBarGlyph.image(for: .idle)).renderingMode(.template)
    }

    /// 10 pt under the pill, or above it at the bottom of the screen.
    @ViewBuilder private func tooltip(below pillHeight: CGFloat) -> some View {
        let distance = pillHeight / 2 + 10 + 37 / 2
        if let tip = model.tooltip {
            HStack(spacing: 10) {
                Text(tip.text).foregroundStyle(.white.opacity(0.85))
                if let key = tip.key {
                    Text(key)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .frame(minHeight: 22)
                        .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.14)))
                }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(height: 37)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.07).opacity(0.96)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.12), lineWidth: 0.75))
            .fixedSize()
            .offset(y: model.spot.row == .bottom ? -distance : distance)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }
}

private extension Alignment {
    var unitPoint: UnitPoint {
        switch self {
        case .top: .top
        case .bottom: .bottom
        default: .center
        }
    }
}

/// Scrolling level bars, also used by the walkthrough's microphone test.
struct Waveform: View {
    let buffer: WaveformBuffer
    let shimmer: Bool
    /// How many of the newest bars to draw; nil draws all of them.
    var bars: Int?
    var barWidth: CGFloat = 2.5
    /// Silence draws dots this tall.
    var minHeight: CGFloat = 3
    var color = Color.white
    /// Stops redrawing while it's hidden.
    var paused = false

    var body: some View {
        TimelineView(.animation(paused: paused)) { context in
            Canvas { gc, size in
                let time = context.date.timeIntervalSinceReferenceDate
                if !shimmer { buffer.advance(to: time) }
                let levels = buffer.bars.suffix(bars ?? buffer.bars.count)
                let count = levels.count
                let gap = (size.width - barWidth * CGFloat(count)) / CGFloat(count - 1)
                for (i, level) in levels.enumerated() {
                    var height: CGFloat
                    var opacity = 0.9
                    if shimmer {
                        // A soft highlight sweeping across while the model works.
                        let phase = time * 2.2 - Double(i) / Double(count) * 2
                        let wave = (sin(phase * .pi) + 1) / 2
                        height = minHeight + CGFloat(wave) * (size.height * 0.4)
                        opacity = 0.35 + 0.55 * wave
                    } else {
                        height = minHeight + CGFloat(level) * (size.height - minHeight)
                    }
                    height = min(height, size.height)
                    let rect = CGRect(
                        x: CGFloat(i) * (barWidth + gap), y: (size.height - height) / 2, width: barWidth, height: height)
                    gc.fill(Path(roundedRect: rect, cornerRadius: barWidth / 2), with: .color(color.opacity(opacity)))
                }
            }
        }
    }
}
