import AppKit
import ParlaCore

/// Floating pill shown while dictating. All methods are main-thread only.
// ponytail: @unchecked Sendable — main-thread-only by contract, lets async
// callers hand it to DispatchQueue.main without non-Sendable capture warnings.
final class HUD: @unchecked Sendable {
    /// The cases live in ParlaCore (see HUDState) so DictationSession can name
    /// them without importing AppKit. Every call site still says `HUD.State`.
    typealias State = HUDState

    private let panel: NSPanel
    private let pill = DraggablePill(frame: HUD.activePillFrame)
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let waveform = WaveformView()
    private let appIcon = NSImageView() // shown only inside the drag chip
    private var hideItem: DispatchWorkItem?
    // Currently collapsed to the mini idle capsule (vs. the full active pill).
    private var isIdle = false

    /// Which screen edge the pill docks to, and where along it (0…1). A drag
    /// snaps to the nearest edge; both persist across sessions.
    enum DockEdge: String { case bottom, top, left, right }
    private var dockEdge: DockEdge = .bottom
    private var dockOffset: CGFloat = 0.5
    private static let edgeKey = "hudDockEdge"
    private static let offsetKey = "hudDockOffset"

    private static let activePillFrame = NSRect(x: 12, y: 12, width: 260, height: 44)

    /// Idle bar size, from settings.hudIdleSize. Applied live when changed while idle.
    var idleBarSize = NSSize(width: 44, height: 10) {
        didSet {
            guard idleBarSize != oldValue, isIdle else { return }
            collapse(animated: false)
        }
    }
    /// Idle pill frame, centered in the panel. On left/right edges the bar is
    /// vertical, so width/height swap; the active pill stays horizontal (it holds text).
    private func idlePillFrame(for edge: DockEdge) -> NSRect {
        let vertical = edge == .left || edge == .right
        let w = vertical ? idleBarSize.height : idleBarSize.width
        let h = vertical ? idleBarSize.width : idleBarSize.height
        return NSRect(x: (panel.frame.width - w) / 2, y: (panel.frame.height - h) / 2,
                      width: w, height: h)
    }

    /// Square app-icon chip shown while dragging the idle bar; scales with the
    /// size preset (small/medium/large → 40/48/56).
    private var chipSide: CGFloat { 40 + (idleBarSize.height - 10) * 2 }
    private func chipFrame() -> NSRect {
        NSRect(x: (panel.frame.width - chipSide) / 2, y: (panel.frame.height - chipSide) / 2,
               width: chipSide, height: chipSide)
    }

    /// Map the settings preset to a bar size; unknown strings fall back to small.
    static func idleSize(_ preset: String) -> NSSize {
        switch preset {
        case "large": return NSSize(width: 88, height: 18)
        case "medium": return NSSize(width: 64, height: 14)
        default: return NSSize(width: 44, height: 10)
        }
    }

    /// Keep the pill floating as a mini idle capsule whenever not dictating.
    var showAlways = false {
        didSet {
            guard showAlways != oldValue else { return }
            if showAlways {
                if !panel.isVisible { showIdle() }
            } else if isIdle {
                panel.orderOut(nil)
            }
        }
    }

    init() {
        // Panel is larger than the pill so the lavender glow has room to render.
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 284, height: 68),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false // the pill's own glow is the only shadow
        // Borderless + clear background: macOS routes clicks straight through
        // fully transparent window pixels, so only the opaque pill (alpha 0.97)
        // catches them — the panel accepts events without stealing clicks nearby.
        panel.ignoresMouseEvents = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        // Flow-bar look (docs/plan.md §Flow Bar): near-black capsule with a thin
        // purple ring and soft lavender glow. Static colors in both appearances.
        let container = NSView(frame: panel.contentView!.bounds)
        container.autoresizingMask = [.width, .height]
        pill.autoresizingMask = [.width, .height]
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(srgbRed: 0.102, green: 0.102, blue: 0.102, alpha: 0.97).cgColor // vast-950
        pill.layer?.cornerRadius = 22
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor(srgbRed: 0.635, green: 0.431, blue: 0.757, alpha: 0.6).cgColor // brand-700
        pill.layer?.shadowColor = NSColor(srgbRed: 0.941, green: 0.843, blue: 1.0, alpha: 1).cgColor // brand-500 glow
        pill.layer?.shadowOpacity = 0.45
        pill.layer?.shadowRadius = 9
        pill.layer?.shadowOffset = .zero
        container.addSubview(pill)
        panel.contentView = container

        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor(srgbRed: 0.933, green: 0.416, blue: 0.416, alpha: 1).cgColor // coral (destructive-500)
        dot.layer?.cornerRadius = 4
        dot.frame = NSRect(x: 14, y: 18, width: 8, height: 8)
        pill.addSubview(dot)

        waveform.frame = NSRect(x: 30, y: 8, width: 120, height: 28)
        pill.addSubview(waveform)

        label.frame = NSRect(x: 158, y: 12, width: 92, height: 20)
        label.textColor = .white
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.backgroundColor = .clear
        label.isBezeled = false
        label.isEditable = false
        pill.addSubview(label)

        appIcon.image = NSApp.applicationIconImage
        appIcon.imageScaling = .scaleProportionallyUpOrDown
        appIcon.isHidden = true
        pill.addSubview(appIcon)

        // Migration: the old free-pin origin is gone — drop its stale pref once.
        UserDefaults.standard.removeObject(forKey: "hudOrigin")
        if let raw = UserDefaults.standard.string(forKey: Self.edgeKey),
           let e = DockEdge(rawValue: raw) { dockEdge = e }
        if UserDefaults.standard.object(forKey: Self.offsetKey) != nil {
            dockOffset = CGFloat(UserDefaults.standard.double(forKey: Self.offsetKey))
        }
        pill.onDragStart = { [weak self] in self?.beginDragChip() }
        pill.onDragEnd = { [weak self] in self?.snapToNearestEdge() }
    }

    /// Show the idle capsule (position on the active screen if the panel was off).
    private func showIdle() {
        hideItem?.cancel()
        hideItem = nil
        collapse(animated: false, to: Self.activeScreen())
        panel.orderFrontRegardless()
    }

    /// Collapse to the slim bare idle bar — dot/waveform/label hidden.
    /// Moves the panel to the idle auto-position (or a passed target screen),
    /// animating the panel origin alongside the pill morph.
    private func collapse(animated: Bool, to screen: NSScreen? = nil) {
        isIdle = true
        dot.isHidden = true
        waveform.isHidden = true
        label.isHidden = true
        let target = (screen ?? currentScreen()).map { dockOrigin(idle: true, on: $0) }
        let frame = idlePillFrame(for: dockEdge)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                pill.animator().frame = frame
                if let target { panel.animator().setFrame(NSRect(origin: target, size: panel.frame.size), display: true) }
            }
        } else {
            pill.frame = frame
            if let target { panel.setFrameOrigin(target) }
        }
        pill.layer?.cornerRadius = min(idleBarSize.width, idleBarSize.height) / 2
    }

    /// Expand to the full active pill. Animates (pill + panel origin) only when
    /// coming from idle. `screen` moves to a specific screen (dictation start);
    /// nil keeps the panel on its current screen.
    private func expand(to screen: NSScreen? = nil) {
        let wasIdle = isIdle
        isIdle = false
        appIcon.isHidden = true // in case fn lands mid-drag
        label.isHidden = false
        let target = (screen ?? currentScreen()).map { dockOrigin(idle: false, on: $0) }
        if wasIdle {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                pill.animator().frame = HUD.activePillFrame
                if let target { panel.animator().setFrame(NSRect(origin: target, size: panel.frame.size), display: true) }
            }
        } else {
            pill.frame = HUD.activePillFrame
            if let target { panel.setFrameOrigin(target) }
        }
        pill.layer?.cornerRadius = 22
    }

    /// Settle after a dictation: collapse to idle when always-on, else order out.
    private func settle() {
        hideItem?.cancel()
        hideItem = nil
        if showAlways { collapse(animated: true) } else { panel.orderOut(nil) }
    }

    func show(_ state: State) {
        hideItem?.cancel()
        hideItem = nil
        // .listening moves to the screen the user is dictating into; every other
        // state stays on the panel's current screen.
        if case .listening = state { expand(to: Self.activeScreen()) } else { expand() }
        switch state {
        case .listening, .handsFree:
            label.frame = NSRect(x: 158, y: 12, width: 92, height: 20)
        default:
            // No waveform in these states — let longer labels use the full pill.
            label.frame = NSRect(x: 16, y: 12, width: 228, height: 20)
        }
        switch state {
        case .listening(let command):
            dot.isHidden = false
            waveform.isHidden = false
            waveform.clear()
            label.stringValue = command ? "Command…" : "Listening…"
            panel.orderFrontRegardless()
        case .handsFree:
            // Mid-recording relabel: keep the waveform flowing (no clear()).
            dot.isHidden = false
            waveform.isHidden = false
            label.stringValue = "Hands-free…"
            panel.orderFrontRegardless()
        case .transcribing:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "Transcribing…"
            panel.orderFrontRegardless()
        case .polishing:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✓ · polishing…"
            panel.orderFrontRegardless() // no scheduleHide — a terminal state follows
        case .done:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✓ Pasted"
            panel.orderFrontRegardless()
            scheduleHide()
        case .savedToHistory:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✓ Saved to history"
            panel.orderFrontRegardless()
            scheduleHide()
        case .cleanedInHistory:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✓ cleaned in history"
            panel.orderFrontRegardless()
            scheduleHide()
        case .rawFallback(let reason):
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✓ raw (\(reason))"
            panel.orderFrontRegardless()
            scheduleHide()
        case .cancelled:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✕ Cancelled"
            panel.orderFrontRegardless()
            scheduleHide()
        case .error(let msg):
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "⚠️ \(msg)"
            panel.orderFrontRegardless()
            scheduleHide()
        }
    }

    func push(level: Float) { waveform.push(level: level) }

    func hide() { settle() }

    /// Esc while idle: dismiss a visible toast without disturbing the idle bar
    /// (Esc fires constantly in normal use — this must be a no-op then).
    func dismiss() {
        guard panel.isVisible, !isIdle else { return }
        settle()
    }

    private func scheduleHide() {
        let item = DispatchWorkItem { [weak self] in self?.settle() }
        hideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: item)
    }

    /// Panel origin that docks the pill to `dockEdge` at `dockOffset` along it,
    /// its outer edge a margin (10 idle / 16 active) from the screen edge. Anchors
    /// top/bottom off visibleFrame (respects Dock + menu bar) and the along-edge
    /// span off visibleFrame too; left/right x off screen.frame (true screen edge).
    /// The pill center is clamped so the pill stays fully within the span, then the
    /// panel origin is backed out (the pill sits at `pf.origin` inside the panel —
    /// a partly off-screen panel is fine, it's transparent).
    private func dockOrigin(idle: Bool, on screen: NSScreen) -> NSPoint {
        let vis = screen.visibleFrame, f = screen.frame
        let margin: CGFloat = idle ? 10 : 16
        let pf = idle ? idlePillFrame(for: dockEdge) : HUD.activePillFrame
        let px: CGFloat, py: CGFloat
        switch dockEdge {
        case .bottom, .top:
            let cx = clamp(vis.minX + dockOffset * vis.width, vis.minX + pf.width / 2, vis.maxX - pf.width / 2)
            px = cx - pf.width / 2
            py = dockEdge == .bottom ? vis.minY + margin : vis.maxY - margin - pf.height
        case .left, .right:
            let cy = clamp(vis.minY + dockOffset * vis.height, vis.minY + pf.height / 2, vis.maxY - pf.height / 2)
            py = cy - pf.height / 2
            px = dockEdge == .left ? f.minX + margin : f.maxX - margin - pf.width
        }
        return NSPoint(x: px - pf.origin.x, y: py - pf.origin.y)
    }

    /// Drag pickup: the idle bar morphs into a small app-icon chip that travels
    /// with the cursor. Mid-dictation drags keep the full pill (it shows state).
    private func beginDragChip() {
        guard isIdle else { return }
        let chip = chipFrame()
        appIcon.frame = chip.insetBy(dx: 6, dy: 6).offsetBy(dx: -chip.minX, dy: -chip.minY)
        appIcon.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            pill.animator().frame = chip
        }
        pill.layer?.cornerRadius = chipSide * 0.3
    }

    /// Drop-target of a drag: pick the nearest edge, remember it + the offset,
    /// then animate to the snapped spot (re-orienting the idle bar if the edge
    /// flipped horizontal↔vertical; a mid-dictation drag just moves the panel).
    private func snapToNearestEdge() {
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(c) }) ?? Self.activeScreen() else { return }
        let f = screen.frame, vis = screen.visibleFrame
        let pf = isIdle ? idlePillFrame(for: dockEdge) : HUD.activePillFrame
        let pc = NSPoint(x: panel.frame.minX + pf.midX, y: panel.frame.minY + pf.midY)
        // left/right off the true screen edge; top/bottom off visibleFrame.
        let dists: [(DockEdge, CGFloat)] = [
            (.left, pc.x - f.minX), (.right, f.maxX - pc.x),
            (.bottom, pc.y - vis.minY), (.top, vis.maxY - pc.y),
        ]
        dockEdge = dists.min { $0.1 < $1.1 }!.0
        switch dockEdge {
        case .bottom, .top: dockOffset = clamp((pc.x - vis.minX) / vis.width, 0.05, 0.95)
        case .left, .right: dockOffset = clamp((pc.y - vis.minY) / vis.height, 0.05, 0.95)
        }
        UserDefaults.standard.set(dockEdge.rawValue, forKey: Self.edgeKey)
        UserDefaults.standard.set(Double(dockOffset), forKey: Self.offsetKey)
        appIcon.isHidden = true // drop the drag chip; the bar re-forms below
        let target = dockOrigin(idle: isIdle, on: screen)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if isIdle { pill.animator().frame = idlePillFrame(for: dockEdge) }
            panel.animator().setFrame(NSRect(origin: target, size: panel.frame.size), display: true)
        }
        if isIdle { pill.layer?.cornerRadius = min(idleBarSize.width, idleBarSize.height) / 2 }
    }

    /// Screen the panel currently occupies (by its center), else the active
    /// screen — used during morphs so the pill doesn't jump screens.
    private func currentScreen() -> NSScreen? {
        let c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return NSScreen.screens.first { $0.frame.contains(c) } ?? Self.activeScreen()
    }

    /// Screen to show on, in order: the AX-focused element's screen (where the
    /// user is dictating into), else the screen under the mouse, else main.
    private static func activeScreen() -> NSScreen? {
        if let p = Inserter.focusedElementScreenPoint(),
           let s = NSScreen.screens.first(where: { $0.frame.contains(p) }) {
            return s
        }
        let mouse = NSEvent.mouseLocation
        if let s = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) {
            return s
        }
        return NSScreen.main
    }
}

/// The pill view, draggable by the user. Manual drag (not performDrag /
/// isMovableByWindowBackground) so we get a clean end-of-drag hook and never
/// confuse a programmatic panel move with a user drag. Subviews (label, dot,
/// waveform) don't handle mouseDown, so it bubbles up to here.
final class DraggablePill: NSView {
    /// Called once when a real drag begins (first mouseDragged of a press).
    var onDragStart: (() -> Void)?
    /// Called after a real drag (not a plain click); the window is at its dropped origin.
    var onDragEnd: (() -> Void)?
    private var dragOffset: NSPoint?  // mouse → window-origin gap at mouseDown
    private var didDrag = false       // plain clicks must not pin the pill

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        didDrag = false
        let m = NSEvent.mouseLocation
        dragOffset = NSPoint(x: m.x - win.frame.origin.x, y: m.y - win.frame.origin.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window, let off = dragOffset else { return }
        if !didDrag { didDrag = true; onDragStart?() }
        let m = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(x: m.x - off.x, y: m.y - off.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOffset = nil; didDrag = false }
        guard didDrag, window != nil else { return }
        onDragEnd?()
    }
}

private func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, v)) }

/// Draws the last ~30 pushed levels as centered vertical bars. No timers —
/// motion comes only from real pushed values.
final class WaveformView: NSView {
    private var levels: [Float] = []
    private let capacity = 30

    func push(level: Float) {
        levels.append(level)
        if levels.count > capacity { levels.removeFirst(levels.count - capacity) }
        needsDisplay = true
    }

    func clear() {
        levels.removeAll()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let barW: CGFloat = 3, gap: CGFloat = 1
        let step = barW + gap
        NSColor.white.withAlphaComponent(0.85).setFill()
        for (i, level) in levels.enumerated() {
            let norm = min(1, CGFloat(level) * 8)
            let h = max(2, norm * bounds.height) // floor so silence shows a line
            let x = CGFloat(i) * step
            let rect = NSRect(x: x, y: (bounds.height - h) / 2, width: barW, height: h)
            NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
        }
    }
}
