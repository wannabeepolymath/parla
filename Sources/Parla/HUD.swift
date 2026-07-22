import AppKit
import ParlaCore

/// Floating pill shown while dictating. All methods are main-thread only.
// ponytail: @unchecked Sendable — main-thread-only by contract, lets async
// callers hand it to DispatchQueue.main without non-Sendable capture warnings.
final class HUD: NSObject, @unchecked Sendable {
    enum State {
        case listening(command: Bool)  // command: transform-selection mode ("Command…")
        case handsFree      // fn+Space latched: still recording, fn can be released
        case transcribing   // fn-up → raw text landing (fast, on-device)
        case polishing        // raw landed; LLM cleanup in flight — resolves to done/savedToHistory/cleanedInHistory
        case polishingSelection // one-tap polish in flight over the selection
        case noChange         // selection edit returned identical text — nothing typed
        case done
        case savedToHistory   // nothing landed in a field; transcript lives in history
        case cleanedInHistory // swap unverifiable; cleaned text only in history
        case rawFallback(String) // cleanup failed; raw transcript is final, with a safe reason
        case cancelled      // dictation aborted (key pressed while fn held)
        case error(String)
    }

    private let panel: NSPanel
    private let pill = DraggablePill(frame: HUD.activePillFrame)
    private let label = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let waveform = WaveformView()
    private let appIcon = NSImageView() // shown only inside the drag chip
    private let polishButton = NSButton(title: "✦ Polish", target: nil, action: nil)
    private let scratchpadButton = NSButton(title: "", target: nil, action: nil)
    private let moveGrip = GripView() // decorative drag handle; hits fall through to the pill
    private var hideItem: DispatchWorkItem?
    // Currently collapsed to the mini idle capsule (vs. the full active pill).
    private var isIdle = false
    // A non-terminal state (listening/transcribing/polishing) is showing: Esc
    // must not hide the pill — a polish finishing behind a dismissed HUD would
    // otherwise replace text invisibly.
    private var busy = false

    /// Pill polish button clicked: the app layer proofreads the current
    /// selection. The panel is non-activating, so the click never steals focus
    /// — the front app's selection survives.
    var onPolish: (() -> Void)?

    /// Hover-bar scratchpad button clicked: the app layer opens the scratchpad.
    var onScratchpad: (() -> Void)?

    /// Which screen edge the pill docks to, and where along it (0…1). A drag
    /// snaps to the nearest edge; both persist across sessions.
    enum DockEdge: String { case bottom, top, left, right }
    private var dockEdge: DockEdge = .bottom
    private var dockOffset: CGFloat = 0.5
    private static let edgeKey = "hudDockEdge"
    private static let offsetKey = "hudDockOffset"

    private static let activePillFrame = NSRect(x: 20, y: 40, width: 260, height: 44)

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

    override init() {
        // Panel is larger than the pill so the lavender glow has room to render,
        // and tall enough for the vertical hover bar on left/right docks.
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 124),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.level = .statusBar
        // Never take key on a click: a key panel becomes the system-wide AX
        // focus, and the polish button must read the FRONT APP's selection.
        // Buttons don't need key status to receive clicks.
        panel.becomesKeyOnlyIfNeeded = true
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
        let container = PassthroughView(frame: panel.contentView!.bounds)
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

        // Hover-bar controls, revealed by hovering the idle bar (see hover(_:)):
        // a move grip, the polish button, and a scratchpad button.
        polishButton.isBordered = false
        polishButton.font = .systemFont(ofSize: 11, weight: .medium)
        polishButton.contentTintColor = .white
        polishButton.target = self
        polishButton.action = #selector(polishClicked)
        polishButton.toolTip = "Polish selection"
        polishButton.isHidden = true
        pill.addSubview(polishButton)

        scratchpadButton.isBordered = false
        scratchpadButton.image = NSImage(systemSymbolName: "square.and.pencil",
                                         accessibilityDescription: "Open scratchpad")?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .medium))
        scratchpadButton.contentTintColor = .white
        scratchpadButton.target = self
        scratchpadButton.action = #selector(scratchpadClicked)
        scratchpadButton.toolTip = "Open scratchpad"
        scratchpadButton.isHidden = true
        pill.addSubview(scratchpadButton)

        moveGrip.toolTip = "Drag to move"
        moveGrip.isHidden = true
        pill.addSubview(moveGrip)

        // Migration: the old free-pin origin is gone — drop its stale pref once.
        UserDefaults.standard.removeObject(forKey: "hudOrigin")
        if let raw = UserDefaults.standard.string(forKey: Self.edgeKey),
           let e = DockEdge(rawValue: raw) { dockEdge = e }
        if UserDefaults.standard.object(forKey: Self.offsetKey) != nil {
            dockOffset = CGFloat(UserDefaults.standard.double(forKey: Self.offsetKey))
        }
        pill.onDragStart = { [weak self] in self?.beginDragChip() }
        pill.onDragEnd = { [weak self] in self?.snapToNearestEdge() }
        pill.onHover = { [weak self] inside in self?.hover(inside) }
        pill.clickThroughButtons = [polishButton, scratchpadButton] // drags over a button still move the pill

        // Display set changed (external screen plugged/unplugged, resolution
        // switch): the panel's absolute origin is stale in the new coordinate
        // space and macOS clamps it onto whatever screen edge is nearest.
        // Re-dock to the persisted edge/offset instead.
        NotificationCenter.default.addObserver(
            self, selector: #selector(screensDidChange),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    /// Re-dock the visible panel after a display-configuration change.
    /// currentScreen() keeps it on the screen it lives on; if that screen went
    /// away it falls back to the active screen.
    @objc private func screensDidChange() {
        guard panel.isVisible, let screen = currentScreen() else { return }
        panel.setFrameOrigin(dockOrigin(idle: isIdle, on: screen))
    }

    /// Hovering the idle bar morphs it into a Wispr-Flow-style hover bar with
    /// three controls — a move grip, "✦ Polish", and a scratchpad button;
    /// leaving (or any state change — dictation, drag, toast) collapses back.
    /// Idle only: during dictation the pill shows state and must not grow
    /// buttons under the cursor. Dock-aware: the bar lays out horizontally on
    /// top/bottom docks and stacks vertically on left/right docks, and always
    /// grows inward from the docked screen edge, never off-screen.
    private func hover(_ inside: Bool) {
        guard isIdle, panel.isVisible else { return }
        guard inside else {
            setHoverControls(hidden: true)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                pill.animator().frame = idlePillFrame(for: dockEdge)
            }
            pill.layer?.cornerRadius = min(idleBarSize.width, idleBarSize.height) / 2
            return
        }
        let bar = idlePillFrame(for: dockEdge)
        let vertical = dockEdge == .left || dockEdge == .right
        let pad: CGFloat = 10, gap: CGFloat = 7
        // No room for a text label along a vertical bar — icon-only there.
        polishButton.title = vertical ? "✦" : "✦ Polish"
        polishButton.sizeToFit()
        scratchpadButton.sizeToFit()
        let pb = polishButton.frame.size, sb = scratchpadButton.frame.size
        let grip = NSSize(width: vertical ? 14 : 9, height: vertical ? 9 : 14)
        // The chip must CONTAIN the bar's footprint: shrinking under the
        // cursor fires mouseExited → collapse → mouseEntered in a loop.
        var chip = NSRect.zero
        if vertical {
            chip.size.width = max(pad + max(pb.width, sb.width, grip.width) + pad, bar.width)
            chip.size.height = max(pad + pb.height + gap + sb.height + gap + grip.height + pad, bar.height)
        } else {
            chip.size.width = max(pad + grip.width + gap + pb.width + gap + sb.width + pad, bar.width)
            chip.size.height = max(26, bar.height)
        }
        chip.origin.x = (panel.frame.width - chip.width) / 2
        chip.origin.y = (panel.frame.height - chip.height) / 2
        // Keep the chip's outer edge where the bar's was so it grows inward
        // from the docked screen edge, not off-screen.
        switch dockEdge {
        case .left: chip.origin.x = bar.minX
        case .right: chip.origin.x = bar.maxX - chip.width
        case .bottom: chip.origin.y = bar.minY
        case .top: chip.origin.y = bar.maxY - chip.height
        }
        if vertical {
            // Top → bottom: polish, scratchpad, grip at the bottom end.
            polishButton.frame = NSRect(x: (chip.width - pb.width) / 2,
                                        y: chip.height - pad - pb.height,
                                        width: pb.width, height: pb.height)
            scratchpadButton.frame = NSRect(x: (chip.width - sb.width) / 2,
                                            y: polishButton.frame.minY - gap - sb.height,
                                            width: sb.width, height: sb.height)
            moveGrip.frame = NSRect(x: (chip.width - grip.width) / 2, y: pad,
                                    width: grip.width, height: grip.height)
        } else {
            // Left → right: grip, polish, scratchpad.
            moveGrip.frame = NSRect(x: pad, y: (chip.height - grip.height) / 2,
                                    width: grip.width, height: grip.height)
            polishButton.frame = NSRect(x: moveGrip.frame.maxX + gap,
                                        y: (chip.height - pb.height) / 2,
                                        width: pb.width, height: pb.height)
            scratchpadButton.frame = NSRect(x: polishButton.frame.maxX + gap,
                                            y: (chip.height - sb.height) / 2,
                                            width: sb.width, height: sb.height)
        }
        moveGrip.needsDisplay = true
        setHoverControls(hidden: false)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            pill.animator().frame = chip
        }
        pill.layer?.cornerRadius = min(chip.width, chip.height) / 2
    }

    private func setHoverControls(hidden: Bool) {
        polishButton.isHidden = hidden
        scratchpadButton.isHidden = hidden
        moveGrip.isHidden = hidden
    }

    @objc private func polishClicked() {
        hover(false) // collapse now; show(.polishingSelection) follows from the app layer
        onPolish?()
    }

    @objc private func scratchpadClicked() {
        hover(false) // collapse now; the scratchpad window takes over
        onScratchpad?()
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
        setHoverControls(hidden: true)
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
        setHoverControls(hidden: true) // in case dictation starts mid-hover
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
        switch state {
        case .listening, .handsFree, .transcribing, .polishing, .polishingSelection:
            busy = true
        default:
            busy = false
        }
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
        case .polishingSelection:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "Polishing…"
            panel.orderFrontRegardless() // no scheduleHide — a terminal state follows
        case .noChange:
            dot.isHidden = true
            waveform.isHidden = true
            label.stringValue = "✓ No changes"
            panel.orderFrontRegardless()
            scheduleHide()
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
    /// (Esc fires constantly in normal use — this must be a no-op then). Busy
    /// states (a polish in flight) stay visible — the work continues.
    func dismiss() {
        guard panel.isVisible, !isIdle, !busy else { return }
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
        setHoverControls(hidden: true) // a drag from the hover bar shows the icon instead
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

/// The panel's content-filling backdrop. The panel itself is padded well
/// beyond the visible pill (room for the glow, and for the hover chip to grow
/// into), so a plain NSView here would swallow every click in that whole
/// padded rect — including clicks meant for whatever's underneath the idle
/// bar's dead space. Only forward hits that land on an actual subview (the
/// pill and its controls); anywhere else, return nil so the click passes
/// through to the window below.
final class PassthroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        return view === self ? nil : view
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
    /// Cursor entered/left the pill (tracks the live frame via .inVisibleRect).
    var onHover: ((Bool) -> Void)?
    /// Buttons whose hits the pill claims for itself, so a drag STARTING over
    /// one still moves the pill (the button would otherwise swallow the
    /// mouseDown and the docked pill could never be dragged from under the
    /// hover bar). A press that never drags and releases inside a button fires
    /// that button's action instead.
    var clickThroughButtons: [NSButton] = []
    private var dragOffset: NSPoint?  // mouse → window-origin gap at mouseDown
    private var didDrag = false       // plain clicks must not pin the pill
    private var downAt = NSPoint.zero // screen point of mouseDown, for the drag threshold

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let view = super.hitTest(point)
        if let view, clickThroughButtons.contains(where: { $0 === view && !$0.isHidden }) { return self }
        return view
    }

    override func mouseDown(with event: NSEvent) {
        guard let win = window else { return }
        didDrag = false
        let m = NSEvent.mouseLocation
        downAt = m
        dragOffset = NSPoint(x: m.x - win.frame.origin.x, y: m.y - win.frame.origin.y)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let win = window, let off = dragOffset else { return }
        let m = NSEvent.mouseLocation
        if !didDrag {
            // A few points of jitter is still a click — don't eat button taps.
            guard abs(m.x - downAt.x) > 3 || abs(m.y - downAt.y) > 3 else { return }
            didDrag = true
            onDragStart?()
        }
        win.setFrameOrigin(NSPoint(x: m.x - off.x, y: m.y - off.y))
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOffset = nil; didDrag = false }
        guard window != nil else { return }
        if didDrag { onDragEnd?(); return }
        // Plain click: fire the claimed button when released inside it.
        let p = convert(event.locationInWindow, from: nil)
        if let button = clickThroughButtons.first(where: { !$0.isHidden && $0.frame.contains(p) }) {
            button.performClick(nil)
        }
    }
}

/// Six-dot drag handle shown in the hover bar. Purely decorative: hit-testing
/// returns nil so presses land on the DraggablePill beneath — dragging the
/// grip always moves the pill and can never be swallowed by a control. The
/// dot grid follows the frame's orientation (2×3 upright, 3×2 sideways).
final class GripView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let cols = bounds.width > bounds.height ? 3 : 2
        let rows = cols == 3 ? 2 : 3
        let d: CGFloat = 3, gap: CGFloat = 2.5
        let w = CGFloat(cols) * d + CGFloat(cols - 1) * gap
        let h = CGFloat(rows) * d + CGFloat(rows - 1) * gap
        let x0 = (bounds.width - w) / 2, y0 = (bounds.height - h) / 2
        NSColor.white.withAlphaComponent(0.45).setFill()
        for r in 0..<rows {
            for c in 0..<cols {
                NSBezierPath(ovalIn: NSRect(x: x0 + CGFloat(c) * (d + gap),
                                            y: y0 + CGFloat(r) * (d + gap),
                                            width: d, height: d)).fill()
            }
        }
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
