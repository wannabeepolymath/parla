import AppKit
import AVFoundation
import Carbon
import ParlaCore

// Constructed by Watch only. No selected-source observer is installed at launch.
private final class LayoutObservation: NSObject {
    private let center = DistributedNotificationCenter.default()
    private let action: () -> Void
    private var active = true
    init(action: @escaping () -> Void) {
        self.action = action; super.init()
        center.addObserver(self, selector: #selector(refresh),
            name: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
    }
    @objc private func refresh(_ notification: Notification) {
        if Thread.isMainThread { if active { action() } }
        else { DispatchQueue.main.async { [weak self] in guard let self, self.active else { return }; self.action() } }
    }
    func stop() { active = false; center.removeObserver(self) }
    deinit { center.removeObserver(self) }
}

enum InputCheckWorkbench {
    static func enter() -> Never {
        MainActor.assumeIsolated {
            print("input-check pid \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let owner = InputCheckWindow()
            app.delegate = owner; owner.show()
            // exit is inside this lifetime: never deallocate the live tap refcon.
            return withExtendedLifetime(owner) { app.run(); exit(0) }
        }
    }
}

private final class MouseReceiver: NSView {
    var receive: (Int, Bool) -> Void = { _, _ in }
    private let caption = NSTextField(labelWithString: "Click here")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true; layer?.borderWidth = 1; layer?.cornerRadius = 6
        layer?.borderColor = NSColor.separatorColor.cgColor
        caption.translatesAutoresizingMaskIntoConstraints = false; addSubview(caption)
        NSLayoutConstraint.activate([caption.centerXAnchor.constraint(equalTo: centerXAnchor), caption.centerYAnchor.constraint(equalTo: centerYAnchor)])
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Mouse test area")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func mouseDown(with event: NSEvent) { receive(event.buttonNumber, true) }
    override func mouseUp(with event: NSEvent) { receive(event.buttonNumber, false) }
    override func rightMouseDown(with event: NSEvent) { receive(event.buttonNumber, true) }
    override func rightMouseUp(with event: NSEvent) { receive(event.buttonNumber, false) }
    override func otherMouseDown(with event: NSEvent) { receive(event.buttonNumber, true) }
    override func otherMouseUp(with event: NSEvent) { receive(event.buttonNumber, false) }
    func counts(presses: Int, releases: Int, otherPresses: Int, otherReleases: Int) {
        let value = "Received: presses \(presses), releases \(releases)\nOther buttons: presses \(otherPresses), releases \(otherReleases)"
        caption.stringValue = "Click here\n\(value)"; caption.maximumNumberOfLines = 3
        setAccessibilityValue(value)
    }
}

@MainActor private final class InputCheckWindow: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let ram = InputCheckSettings()
    private let authority = PhysicalInputAuthority()
    private let recorder = AudioRecorder() // inert; no engine until explicit Start
    private var layout: LayoutCheck!
    private var mic: MicCheck!
    private var mouse: MouseCheck!
    private var window: NSWindow!
    private let tabs = NSTabView()
    private let tabButtons = NSSegmentedControl(labels: ["Keyboard Layout", "Microphone", "Mouse Button"], trackingMode: .selectOne, target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "Ready.")
    private var labelCells: [NSTextField] = []
    private var layoutResult: NSTextField!, fallbackNote: NSTextField!, watchNote: NSTextField!
    private var watchButton: NSButton!, stopWatch: NSButton!, readButton: NSButton!
    private var micMessage: NSTextField!, micRoute: NSTextField!, micDuration: NSTextField!, heardPrompt: NSTextField!
    private var micStart: NSButton!, micStop: NSButton!, listen: NSButton!, clear: NSButton!, allow: NSButton!, yes: NSButton!, no: NSButton!
    private var mouseStart: NSButton!, mouseStop: NSButton!, mouseCounts: NSTextField!, mouseNote: NSTextField!
    private var popup: NSPopUpButton!
    private let level = NSLevelIndicator()
    private let receiver = MouseReceiver(frame: .zero)
    private var selectedTab = 0
    private var wantsExit = false, printed = false, acknowledgingMouse = false
    private var lastAnnouncement = ""
    private var acknowledgementGeneration = 0

    private var scope: Bool { !wantsExit && window?.isKeyWindow == true && NSApp.isActive }
    func show() {
        layout = LayoutCheck(snapshot: ShortcutDisplayFormatter.current, observe: { action in
            let observation = LayoutObservation(action: action)
            return { observation.stop() }
        }, canonical: { [ram] in ram.canonical() })
        mic = MicCheck(capture: RecorderMicrophoneCapture(recorder: recorder), admission: recorder.admission,
            permission: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: return .granted
                case .notDetermined: return .notDetermined
                case .denied: return .denied
                case .restricted: return .restricted
                @unknown default: return .restricted
                }
            }, request: { finished in
                AVCaptureDevice.requestAccess(for: .audio) { granted in DispatchQueue.main.async { finished(granted) } }
            }, allowed: { [weak self] in self?.scope == true && self?.selectedTab == 1 && self?.mouse?.phaseStarted != true },
            retained: { [recorder] in
                let c = recorder.retainedAudioCounts
                return RetainedCounts(samples: c.samples, preRoll: c.preRoll, converter: c.converter)
            }, playerFactory: { MicrophoneTestPlayer() })
        mouse = MouseCheck(settings: ram, authority: authority, admission: recorder.admission,
            create: { [ram, authority, recorder] in
                HotkeyMonitor(store: ram.store, inputAuthority: authority, captureAdmission: recorder.admission, tapEvents: .otherMouseOnly)
            }, scope: { [weak self] in self?.scope == true && self?.selectedTab == 2 })
        mouse.phaseExpired = { NSApp.terminate(nil) }
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Parla Input Check"; window.isRestorable = false; window.isReleasedWhenClosed = false; window.delegate = self
        let header = text("Nothing starts until you press a button. Audio stays in memory and is never saved, sent or transcribed. Results record only counts and yes/no answers.")
        tabButtons.target = self; tabButtons.action = #selector(changeTab); tabButtons.selectedSegment = 0
        // Native segmented tabs provide per-tab disabled controls; NSTabView owns the pages.
        tabs.tabViewType = .noTabsNoBorder
        for (name, page) in zip(["Keyboard Layout", "Microphone", "Mouse Button"], [layoutPage(), micPage(), mousePage()]) {
            let item = NSTabViewItem(identifier: name); item.label = name; item.view = scroll(page); tabs.addTabViewItem(item)
        }
        let finish = button("Finish and Quit", #selector(finish))
        let footer = NSStackView(views: [status, finish]); footer.orientation = .horizontal; footer.alignment = .centerY
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let content = NSStackView(views: [header, tabButtons, tabs, footer]); content.orientation = .vertical
        content.alignment = .leading; content.spacing = 12; content.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 16),
            content.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor, constant: -16),
            tabs.widthAnchor.constraint(equalTo: content.widthAnchor), footer.widthAnchor.constraint(equalTo: content.widthAnchor)
        ])
        layout.changed = { [weak self] in self?.refresh() }; mic.changed = { [weak self] in self?.refresh() }; mouse.changed = { [weak self] in self?.refresh() }
        installMenu(); refresh(); window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func installMenu() {
        let menu = NSMenu(), app = NSMenuItem(), items = NSMenu()
        items.addItem(withTitle: "Quit Parla Input Check", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = items; menu.addItem(app)
        let win = NSMenuItem(), windows = NSMenu(title: "Window")
        windows.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.submenu = windows; menu.addItem(win); NSApp.mainMenu = menu
    }
    private func text(_ value: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: value); label.font = .systemFont(ofSize: 12)
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
    private func button(_ title: String, _ selector: Selector) -> NSButton { NSButton(title: title, target: self, action: selector) }
    private func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .horizontal; stack.spacing = 6; stack.alignment = .centerY; return stack
    }
    private func page(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        return stack
    }
    private func scroll(_ view: NSView) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        view.translatesAutoresizingMaskIntoConstraints = false; scroll.documentView = view
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 6),
            view.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 8),
            view.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -20)])
        return scroll
    }
    private func layoutPage() -> NSView {
        readButton = button("Read Current Labels", #selector(readLayout)); watchButton = button("Watch for a Layout Switch (60 s)", #selector(watchLayout))
        stopWatch = button("Stop Watching", #selector(stopLayout))
        var rows: [[NSView]] = [[text("Key (US position)"), text("Label now"), text("Saved shortcut")]]
        for (name, code) in LayoutCheck.keys {
            let current = text("—"); labelCells.append(current)
            let canonical = (try? JSONEncoder().encode(KeyChord(code))).flatMap { String(data: $0, encoding: .utf8) } ?? "—"
            rows.append([text(name), current, text(canonical)])
        }
        let grid = NSGridView(views: rows); grid.rowSpacing = 5; grid.columnSpacing = 20
        layoutResult = text(""); fallbackNote = text("Some keys show their position name because this layout has no printable label for them. This is expected for some input methods.")
        watchNote = text("Switch to another keyboard layout you already use, using the Input menu in the menu bar, then switch back. Watching ends after 60 seconds.")
        return page([text("Shows how Parla labels shortcut keys for your current keyboard layout. Your saved shortcuts are not changed."), readButton, row([watchButton, stopWatch]), watchNote, grid, layoutResult, fallbackNote])
    }
    private func micPage() -> NSView {
        micMessage = text(""); micRoute = text("Input in use: Unknown"); micDuration = text("0.0 s of 10 s")
        level.minValue = 0; level.maxValue = 1; level.levelIndicatorStyle = .continuousCapacity
        level.setAccessibilityLabel("Input level"); level.widthAnchor.constraint(equalToConstant: 280).isActive = true
        micStart = button("Start Microphone Test", #selector(startMic)); micStop = button("Stop", #selector(stopMic))
        listen = button("Listen", #selector(listenMic)); clear = button("Clear", #selector(clearMic))
        allow = button("Allow Microphone Access…", #selector(allowMic))
        heardPrompt = text("Did you hear your recording?"); yes = button("Yes, I Heard It", #selector(heardYes)); no = button("No", #selector(heardNo))
        return page([text("Records up to 10 seconds from your microphone into memory so you can play it back. Nothing is saved, sent or transcribed. Clear erases it."),
            micMessage, micRoute, level, micDuration, micStart, row([micStop, listen, clear]), allow,
            text("Use headphones to avoid feedback."), heardPrompt, row([yes, no]),
            text("Switching tabs, switching to another app, closing the window or quitting stops the test and erases the recording.")])
    }
    private func mousePage() -> NSView {
        popup = NSPopUpButton(frame: .zero, pullsDown: false); popup.addItem(withTitle: "Off")
        for number in MouseButtonBinding.supportedNumbers { popup.addItem(withTitle: MouseButtonBinding(buttonNumber: number)!.display) }
        popup.target = self; popup.action = #selector(rebindMouse)
        receiver.heightAnchor.constraint(equalToConstant: 80).isActive = true
        receiver.widthAnchor.constraint(equalToConstant: 460).isActive = true
        receiver.receive = { [weak self] in self?.mouse.receiver(button: $0, down: $1) }
        mouseStart = button("Start 30-Second Check", #selector(startMouse)); mouseStop = button("Stop Check", #selector(stopMouse))
        mouseCounts = text(""); mouseNote = text("")
        return page([text("Checks that Parla can use your middle or extra mouse button without the click reaching other apps. Left and right buttons are never used. Only counts are recorded."),
            row([text("Button"), popup]), receiver, row([mouseStart, mouseStop]), mouseCounts, mouseNote,
            text("If your mouse software turns side buttons into keyboard shortcuts, this check can't see them.")])
    }
    private func refresh() {
        guard window != nil, mouse != nil, mic != nil, layout != nil else { return }
        for (cell, label) in zip(labelCells, layout.labels) { cell.stringValue = label }
        let l = layout.receipt
        layoutResult.stringValue = "Layout switches seen: \(l.switchesSeen). Labels updated: \(l.labelsChanged). Saved shortcuts unchanged: \(l.savedUnchanged ? "Yes" : "No")."
        fallbackNote.isHidden = l.fallbackKeys == 0; watchNote.isHidden = !layout.watching
        stopWatch.isEnabled = layout.watching; watchButton.isEnabled = !layout.watching
        micMessage.stringValue = mic.permissionMessage ?? mic.state.message
        micRoute.stringValue = "Input in use: \(mic.route.name ?? "Unknown")"
        level.doubleValue = Double(mic.level); micDuration.stringValue = String(format: "%.1f s of 10 s", mic.elapsed)
        micStop.isEnabled = mic.capturing; listen.title = mic.playerActive ? "Stop Listening" : "Listen"
        listen.isEnabled = !mic.capturing && !mic.review.isEmpty
        allow.isHidden = mic.receipt.permission != .notDetermined
        heardPrompt.isHidden = !mic.askingHeard; yes.isHidden = !mic.askingHeard; no.isHidden = !mic.askingHeard
        let final = mouse.phaseStarted
        for index in 0...1 { tabButtons.setEnabled(!final, forSegment: index) }
        tabButtons.toolTip = final ? "Quit and reopen the app to run this check again." : nil
        mouseStart.isEnabled = mouse.canArm && !mouse.armed; mouseStop.isEnabled = mouse.armed
        popup.isEnabled = !mouse.onlyFinish
        let m = mouse.receipt
        mouseCounts.stringValue = "Parla saw: presses \(m.accepted) · quick taps \(m.quickTaps) · holds \(m.holds) · cancelled \(m.cancels)"
        receiver.counts(presses: mouse.receiverPresses, releases: mouse.receiverReleases, otherPresses: mouse.receiverOtherPresses, otherReleases: mouse.receiverOtherReleases)
        if mouse.onlyFinish && !mouse.finishing {
            mouseNote.stringValue = "Accessibility access is off for this app, so the mouse check can't run. You can turn it on in System Settings › Privacy & Security › Accessibility, then reopen this app."
        } else if final && mouse.monitor?.tapStatus != .ready {
            mouseNote.stringValue = "Mouse input is unavailable. Quit and reopen the app to run this check again."
        } else if mouse.armed {
            mouseNote.stringValue = "Over the area above, press and release the chosen button once quickly, then hold it for about a second and release. The check ends automatically after 30 seconds."
        } else { mouseNote.stringValue = final ? "Paused. Press Start again when you're back." : "Choose a button. The mouse check is the final step." }
        if wantsExit { status.stringValue = "Release the mouse button to finish…" }
        else if selectedTab == 0 { status.stringValue = layout.watching ? "Watching for a layout switch." : "Layout check stopped." }
        else if selectedTab == 1 { status.stringValue = mic.permissionMessage ?? mic.state.message }
        else { status.stringValue = mouse.armed ? "Mouse check running." : "Mouse check stopped." }
        for stop in [stopWatch, micStop, mouseStop] { stop?.keyEquivalent = "" }
        [stopWatch, micStop, mouseStop][selectedTab]?.keyEquivalent = "\u{1b}"
        if !mic.capturing && !mic.playerActive && !mouse.armed && !layout.watching && status.stringValue != lastAnnouncement {
            lastAnnouncement = status.stringValue
            NSAccessibility.post(element: window!, notification: .announcementRequested,
                userInfo: [.announcement: status.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }
    @objc private func changeTab() {
        let next = tabButtons.selectedSegment
        guard next >= 0, next != selectedTab else { return }
        if mouse.phaseStarted && next != 2 { tabButtons.selectedSegment = 2; return }
        acknowledgementGeneration += 1
        layout.stop(); mic.clear(); mouse.disarm() // revoke before displaying another page
        selectedTab = next; tabs.selectTabViewItem(at: next); refresh()
    }
    @objc private func readLayout() { layout.read() }
    @objc private func watchLayout() { layout.watch() }
    @objc private func stopLayout() { layout.stop() }
    @objc private func startMic() { layout.stop(); mouse.disarm(); mic.start() }
    @objc private func stopMic() { mic.stop() }
    @objc private func listenMic() { if mic.playerActive { mic.stopListening() } else { mic.listen() } }
    @objc private func clearMic() { mic.clear() }
    @objc private func allowMic() { mic.allowMicrophone() }
    @objc private func heardYes() { mic.heard(true) }
    @objc private func heardNo() { mic.heard(false) }
    @objc private func rebindMouse() {
        acknowledgementGeneration += 1
        let index = popup.indexOfSelectedItem
        mouse.rebind(index == 0 ? nil : MouseButtonBinding(buttonNumber: index + 1))
    }
    @objc private func startMouse() {
        guard scope, !acknowledgingMouse else { return }
        if mouse.phaseStarted { mouse.arm(acknowledged: true); return }
        acknowledgingMouse = true; acknowledgementGeneration += 1
        let generation = acknowledgementGeneration
        let alert = NSAlert()
        alert.messageText = "The mouse check is the last step. When you finish, this app quits so nothing keeps watching the mouse."
        alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        alert.buttons[0].keyEquivalent = "" // Return never starts a check.
        alert.beginSheetModal(for: window) { [weak self] answer in
            guard let self else { return }
            self.acknowledgingMouse = false
            guard answer == .alertFirstButtonReturn, self.acknowledgementGeneration == generation, self.scope, self.selectedTab == 2 else { return }
            self.layout.stop(); self.mic.clear(); self.mouse.arm(acknowledged: true); self.refresh()
        }
    }
    @objc private func stopMouse() { acknowledgementGeneration += 1; mouse.disarm() }
    @objc private func finish() { NSApp.terminate(nil) }
    func windowShouldClose(_ sender: NSWindow) -> Bool { NSApp.terminate(nil); return false }
    func windowDidResignKey(_ notification: Notification) {
        // Our acknowledgement sheet is the same owned interaction. App resign still revokes it.
        if acknowledgingMouse && window.attachedSheet != nil { return }
        resign()
    }
    func applicationDidResignActive(_ notification: Notification) { resign() }
    private func resign() {
        acknowledgementGeneration += 1
        mic?.clear(); mouse?.focusLost(); refresh()
        if mouse?.phaseStarted == true && !wantsExit {
            status.stringValue = "Paused because you switched away. Press Start again when you're back."
            NSAccessibility.post(element: window!, notification: .announcementRequested,
                userInfo: [.announcement: status.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
        // Layout watch deliberately survives resign; switching layouts may leave the window.
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !wantsExit else { return .terminateLater }
        acknowledgementGeneration += 1
        wantsExit = true; layout.stop(); mic.clear()
        var synchronous = true
        let later = mouse.finish { [weak self] in
            self?.printReceipt()
            if !synchronous { sender.reply(toApplicationShouldTerminate: true) }
        }
        synchronous = false; refresh()
        return later ? .terminateLater : .terminateNow
    }
    private func printReceipt() {
        guard !printed else { return }; printed = true
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let arch = InputCheckReceipt.Architecture.arm64
        #elseif arch(x86_64)
        let arch = InputCheckReceipt.Architecture.x86_64
        #else
        let arch = InputCheckReceipt.Architecture.other
        #endif
        let receipt = InputCheckReceipt(arch: arch, osMajorMinor: .init(major: os.majorVersion, minor: os.minorVersion),
            layout: layout.receipt, microphone: mic.receipt, mouse: mouse.receipt)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        if let bytes = try? encoder.encode(receipt), let line = String(data: bytes, encoding: .utf8) { print(line); fflush(stdout) }
    }
}
