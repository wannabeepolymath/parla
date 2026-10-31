import AppKit
import ParlaCore

/// Isolated synchronous entry: never reads main.swift's later legacy globals.
/// This source is an owned synthetic qualification consumer, not a product mode.
public enum OwnedOCRQualification {
    public static func enter() -> Never {
        MainActor.assumeIsolated {
            let driver = LocalOCRNativeDriver()
            guard driver.supported else {
                print("owned-ocr not-tested unsupported identity-unverified")
                exit(2)
            }
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let owner = OwnedOCRFixtureOwner(driver: driver)
            app.delegate = owner
            owner.show()
            withExtendedLifetime(owner) { app.run() }
            // No stop/run-loop timer/watchdog releases a pending operation.
            precondition(!owner.pending)
            exit(0)
        }
    }
}

@MainActor private final class OwnedOCRFixtureOwner: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let driver: LocalOCRNativeDriver
    private var window: NSWindow?
    private var second: NSWindow?
    private var text: NSTextView?
    private var primary: NSScreen?
    private var generation: UInt64 = 1
    private var variant = 0
    private var selector: NSPopUpButton?
    private var button: NSButton?
    private var wantsExit = false, deferredQuit = false, printed = false
    private var task: Task<Void, Never>?
    private lazy var capture = LocalOCRCapture(driver: driver, state: { [weak self] in self?.ownedState() })
    var pending: Bool { capture.pending }
    init(driver: LocalOCRNativeDriver) { self.driver = driver; super.init() }

    func show() {
        // Only own screen geometry, for layout and ONE coordinate assumption.
        // No SC display catalog, app catalog, restoration or user defaults.
        guard let screen = NSScreen.screens.first, screen.frame.origin == .zero,
              screen.frame.width >= 640, screen.frame.height >= 384 else {
            print("owned-ocr not-tested ownedState identity-unverified"); NSApp.terminate(nil); return
        }
        primary = screen
        let frame = NSRect(x: 0, y: 0, width: 640, height: 384)
        let win = makeWindow(frame: frame, words: LocalOCRFixture.sentinels)
        window = win
        let popup = NSPopUpButton(frame: NSRect(x: 30, y: 68, width: 180, height: 32), pullsDown: false)
        popup.addItems(withTitles: ["Plain", "Secure", "Selection", "Second", "Close"])
        popup.target = self; popup.action = #selector(chooseVariant)
        let captureButton = NSButton(title: "Capture", target: self, action: #selector(click))
        captureButton.frame = NSRect(x: 240, y: 68, width: 140, height: 32)
        let status = NSTextField(labelWithString: "Ready")
        status.frame = NSRect(x: 420, y: 70, width: 120, height: 28)
        win.contentView?.addSubview(popup); win.contentView?.addSubview(captureButton); win.contentView?.addSubview(status)
        selector = popup; button = captureButton
        win.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private func makeWindow(frame: NSRect, words: [String]) -> NSWindow {
        let win = NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false; win.isRestorable = false
        win.title = "Owned OCR"; win.setFrame(frame, display: false)
        win.delegate = self
        let view = NSTextView(frame: NSRect(x: 30, y: 140, width: 570, height: 140))
        view.string = words.joined(separator: " ")
        view.font = NSFont.systemFont(ofSize: 28); view.isEditable = false; view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.isContinuousSpellCheckingEnabled = false; view.isGrammarCheckingEnabled = false
        view.isSelectable = false; view.setSelectedRange(NSRange(location: 0, length: 0))
        win.contentView?.addSubview(view)
        if window == nil { text = view }
        return win
    }
    @objc private func chooseVariant(_ sender: NSPopUpButton) {
        guard !capture.admitted else { return }
        generation += 1; variant = sender.indexOfSelectedItem
        text?.setSelectedRange(NSRange(location: 0, length: variant == 2 ? 5 : 0))
        if variant == 3, second == nil {
            let win = makeWindow(frame: NSRect(x: 0, y: 0, width: 640, height: 384),
                                 words: LocalOCRFixture.secondarySentinels)
            second = win; win.orderBack(nil) // separate fixed oracle; never shares primary sentinels
        }
        if variant == 4 { requestExit() } // before click => no capture, not-tested
    }
    private func ownedState() -> LocalOCROwnedState? {
        guard let window, let primary, let text else { return nil }
        let f = window.frame, s = primary.frame
        return LocalOCROwnedState(pid: getpid(), windowNumber: window.windowNumber, generation: generation,
            frame: LocalOCRRect(x: f.minX, y: f.minY, width: f.width, height: f.height),
            primaryScreen: LocalOCRRect(x: s.minX, y: s.minY, width: s.width, height: s.height),
            scale: window.backingScaleFactor, primary: window.screen === primary,
            key: window.isKeyWindow, visible: window.isVisible, active: NSApp.isActive,
            plain: variant != 1, collapsed: text.selectedRange().length == 0)
    }
    @objc private func click() {
        guard capture.admitClick() else { return }
        // All rendered strings (including Ready) stay frozen until settlement.
        // These controls never re-enable in this process, even after refusal.
        button?.isEnabled = false; selector?.isEnabled = false
        task = Task { [self] in
            let receipt = await capture.run()
            emit(receipt)
            task = nil
            if deferredQuit { NSApp.reply(toApplicationShouldTerminate: true) }
            else if wantsExit { NSApp.terminate(nil) }
        }
    }
    private func emit(_ receipt: LocalOCRReceipt) {
        guard !printed else { return }; printed = true
        if let data = try? JSONEncoder().encode(receipt), let line = String(data: data, encoding: .utf8) { print(line) }
        else { print("owned-ocr fail platform identity-unverified") }
    }
    private func changed() { generation += 1; if pending { capture.revoke() } }
    private func requestExit() {
        wantsExit = true
        if pending {
            capture.revoke()
            print("owned-ocr pending owned-settlement") // no captured status mutation
        } else {
            if !capture.admitted { emit(LocalOCRReceipt()) }
            NSApp.terminate(nil)
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { requestExit(); return false }
    func windowDidResignKey(_ notification: Notification) { changed() }
    func windowDidMove(_ notification: Notification) { changed() }
    func windowDidResize(_ notification: Notification) { changed() }
    func windowDidChangeBackingProperties(_ notification: Notification) { changed() }
    func windowWillClose(_ notification: Notification) { changed() }
    func applicationDidResignActive(_ notification: Notification) { changed() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        wantsExit = true
        if pending {
            capture.revoke(); deferredQuit = true
            print("owned-ocr pending owned-settlement")
            return .terminateLater
        }
        if !capture.admitted { emit(LocalOCRReceipt()) }
        return .terminateNow
    }
}
