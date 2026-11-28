// Screenshot harness for design review. Skipped unless PARLA_SNAPSHOT_DIR is set.
//
// Run:
//   export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
//   PARLA_TEST_FIXTURE_MANIFEST=$(mktemp) PARLA_SNAPSHOT_DIR=/tmp/parla-ui/round-0 swift test --filter UISnapshotTests
//
// Writes 2x PNGs (and menu-*.txt dumps) into PARLA_SNAPSHOT_DIR. The whole run uses a
// throwaway home directory (CFFIXED_USER_HOME), fake credentials and temp stores: no real
// settings, Keychain, microphone or network. Hub windows are never ordered in. Two exceptions,
// both fully transparent (alpha 0): the HUD panel (its show() always orders itself front) and
// the first-run window, parked at -30000,-30000 so synthesized clicks can step through it.
import AppKit
import SwiftUI
import XCTest
import ParlaCore
@testable import Parla

final class UISnapshotTests: XCTestCase {
    private static let home = FileManager.default.temporaryDirectory.appendingPathComponent("parla-snapshot-home-\(UUID().uuidString)")
    private static let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    private var outDir: URL!
    private var tempDirs: [URL] = []

    override class func setUp() {
        super.setUp()
        guard ProcessInfo.processInfo.environment["PARLA_SNAPSHOT_DIR"] != nil else { return }
        // Before anything reads Application Support: ModelCatalog, DictionaryLearner.Store.shared,
        // the scratchpad preference and UserDefaults all resolve under this fake home.
        try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("CFFIXED_USER_HOME", home.path, 1)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    override func setUpWithError() throws {
        guard let dir = ProcessInfo.processInfo.environment["PARLA_SNAPSHOT_DIR"] else {
            throw XCTSkip("Set PARLA_SNAPSHOT_DIR to write UI snapshots.")
        }
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        guard support.path.hasPrefix(Self.home.path) else {
            throw XCTSkip("Application Support isn't redirected (\(support.path)); refusing to touch the real one.")
        }
        outDir = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        // A "downloaded" default model: catalog rows check file existence only.
        try FileManager.default.createDirectory(at: ModelCatalog.directory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: ModelCatalog.path(for: ModelCatalog.default), contents: Data())
    }

    override func tearDownWithError() throws {
        for dir in tempDirs { try? FileManager.default.removeItem(at: dir); try recordWave4BFixture(dir, "removed") }
    }

    // MARK: - Sample data

    private func tempDir(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("parla-snapshot-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try recordWave4BFixture(dir, "created")
        tempDirs.append(dir)
        return dir
    }

    private static func sampleSettings() -> ParlaCore.Settings {
        var s = ParlaCore.Settings()
        s.onboardingCompleted = true
        s.whisperModelPath = ModelCatalog.path(for: ModelCatalog.default)
        s.streamPreviewEnabled = true
        s.cleanup.provider = "anthropic"
        s.cleanupModel = "claude-haiku-4-5"
        s.dictionary = ["Parla", "Kubernetes", "Priya Raman", "SwiftUI", "Postgres", "Zoë Laurent", "OAuth", "Q3 roadmap"]
        s.snippets = [
            "my address": "221B Baker Street, London NW1 6XE",
            "sign off": "Best,\nAlex",
            "standup": "Yesterday: shipped the export fix.\nToday: onboarding polish.\nBlockers: none.",
            "zoom link": "https://zoom.us/j/5551234567",
        ]
        s.replacements = [.init(source: "gonna", replacement: "going to"),
                          .init(source: "k8s", replacement: "Kubernetes"),
                          .init(source: "eta", replacement: "ETA")]
        let friendly = TransformPreset(name: "Make it friendlier", instruction: "Rewrite in a warm, friendly tone. Keep it short.")
        s.transformPresets = [
            friendly,
            TransformPreset(name: "Bullet points", instruction: "Turn this into a concise bulleted list."),
            TransformPreset(name: "Spanish", kind: .translation, targetLanguage: "Spanish"),
        ]
        s.selectedPresetID = friendly.id
        s.hotkeys.runSelectedPreset = KeyChord(15, [.ctrl, .opt]) // ⌃⌥R
        func profile(_ name: String, _ kind: ProfileTargetKind, _ target: String, style: ProfileStyle? = nil,
                     cleanup: ProfileCleanup = .inherit, enabled: Bool = true) -> DictationProfile {
            var p = DictationProfile(); p.name = name; p.targetKind = kind; p.target = target
            p.style = style; p.cleanup = cleanup; p.enabled = enabled; return p
        }
        s.profiles = [
            profile("Slack", .app, "com.tinyspeck.slackmacgap", style: .conversational),
            profile("Mail", .app, "com.apple.mail", style: .formal),
            profile("Terminal", .app, "com.apple.Terminal", cleanup: .off),
            profile("GitHub", .host, "github.com"),
            profile("Google Docs", .host, "docs.google.com", style: .formal, enabled: false),
        ]
        func field(_ key: String, _ label: String) -> GuidedTemplateField { .init(key: key, label: label) }
        let bug = [field("title", "Title"), field("steps", "Steps to reproduce"), field("expected", "Expected result")]
        let visit = [field("patient", "Patient"), field("complaint", "Chief complaint"), field("plan", "Plan")]
        s.guidedTemplates = GuidedTemplateDocument(definitions: [
            .init(name: "Bug report", body: "## {{title}}\n\nSteps:\n{{steps}}\n\nExpected:\n{{expected}}", fields: bug),
            .init(name: "Visit note", body: "Patient: {{patient}}\nComplaint: {{complaint}}\nPlan: {{plan}}", fields: visit),
        ])
        return s
    }

    private static func sampleHistory() -> [HistoryEntry] {
        let now = Date()
        func entry(_ minutesAgo: Double, _ app: String, _ raw: String, _ cleaned: String?, tokens: (Int, Int)? = (420, 60)) -> HistoryEntry {
            var m = PipelineMetrics()
            m.model = "base.en"; m.captureMs = 4200; m.asrMs = 380; m.insertMs = 40; m.totalMs = 5300
            if cleaned != nil, let tokens { m.cleanupModel = "claude-haiku-4-5"; m.promptTokens = tokens.0; m.completionTokens = tokens.1; m.cleanupMs = 640 }
            return HistoryEntry(date: now.addingTimeInterval(-minutesAgo * 60), raw: raw, cleaned: cleaned, appName: app, metrics: m)
        }
        // Oldest first: HistoryStore.entries is newest first.
        return [
            entry(9_000, "Mail", "hi priya thanks for the notes um i'll have the q3 roadmap draft to you by thursday",
                  "Hi Priya, thanks for the notes. I'll have the Q3 roadmap draft to you by Thursday."),
            entry(4_300, "Notes", "groceries oat milk eggs coffee beans and um those little tomatoes", "Groceries: oat milk, eggs, coffee beans, and cherry tomatoes."),
            entry(1_500, "Linear", "the export button does nothing when history is empty we should disable it",
                  "The Export button does nothing when history is empty. We should disable it."),
            entry(1_420, "Slack", "yeah lgtm ship it", "Yeah, LGTM — ship it!"),
            entry(300, "Terminal", "git log --oneline -n 20", nil),
            entry(180, "Safari", "best ramen near kings cross", "Best ramen near King's Cross"),
            entry(95, "Mail", "dear zoe laurent please find attached the signed contract let me know if anything is missing",
                  "Dear Zoë Laurent,\n\nPlease find attached the signed contract. Let me know if anything is missing."),
            entry(42, "Slack", "running five minutes late to standup start without me", "Running 5 minutes late to standup — start without me."),
            entry(12, "Xcode", "todo handle the oauth refresh token expiring mid request", "TODO: Handle the OAuth refresh token expiring mid-request."),
            entry(3, "Notes", "so the main idea is that parla should feel invisible you hold a key you talk and the text is just there",
                  "So the main idea is that Parla should feel invisible: you hold a key, you talk, and the text is just there."),
        ]
    }

    private struct Rig {
        let hub: HubModel
        let store: SettingsStore
        let history: HistoryStore
        let dir: URL
    }

    /// A lived-in install. `mutate` adjusts the saved settings; `key` nil leaves cleanup unconfigured.
    private func makeRig(_ name: String, history entries: [HistoryEntry] = UISnapshotTests.sampleHistory(),
                         key: String? = "sk-ant-api03-snapshot-fake", meetingHub: MeetingHubController? = nil,
                         mutate: (inout ParlaCore.Settings) -> Void = { _ in }) throws -> Rig {
        let dir = try tempDir(name)
        var s = Self.sampleSettings(); mutate(&s)
        var keyed = s; keyed.anthropicApiKey = key
        let store = SettingsStore(url: dir.appendingPathComponent("settings.json"), credentials: testCredentialStore(keyed))
        try store.saveTestSettings(s)
        // Ordinary saves preserve the on-disk templates, so they go through their own write.
        for definition in s.guidedTemplates.definitions { _ = try store.saveTemplateDefinition(definition, expectedRevision: nil) }
        let history = HistoryStore(url: dir.appendingPathComponent("history.json"))
        for e in entries { history.append(e) }
        let hub = HubModel(store: store, history: history, clipboard: { _ in },
                           recordings: RecordingStore(directory: dir.appendingPathComponent("recordings")),
                           diagnostics: DiagnosticStore(), meetingHub: meetingHub)
        hub.credentialEnvironment = { [:] }
        hub.refresh()
        hub.selectedTemplateID = hub.templateDocument.definitions.first?.id
        hub.micGranted = true; hub.axGranted = true; hub.modelLoaded = true; hub.launchAtLogin = true
        hub.lastRecognitionProfile = "Slack (app)"; hub.lastOutputProfile = "Slack (app) · conversational"
        return Rig(hub: hub, store: store, history: history, dir: dir)
    }

    // MARK: - Hub

    @MainActor func testHubPages() throws {
        let meetings = try MeetingHubRig(); defer { meetings.release() }
        let rig = try makeRig("hub", meetingHub: meetings.controller)
        // Seeded before the Dictionary page first reads the (fake-home) shared store.
        _ = DictionaryLearner.Store.shared.add(.init(from: "Kuber Netties", to: "Kubernetes"))
        _ = DictionaryLearner.Store.shared.add(.init(from: "post gress", to: "Postgres"))
        for page in HubPage.allCases {
            try snapshotHub(rig.hub, page: page, name: "hub-\(slug(page))", full: true) {
                // Page entry can reset the selection; the lived-in state has one selected.
                if page == .templates { rig.hub.selectedTemplateID = rig.hub.templateDocument.definitions.first?.id }
            }
        }
    }

    @MainActor func testHubAlternateStates() throws {
        let empty = try makeRig("empty", history: [])
        try snapshotHub(empty.hub, page: .history, name: "hub-history-empty", full: false)

        let perms = try makeRig("perms")
        try snapshotHub(perms.hub, page: .general, name: "hub-general-permissions-missing", full: false) {
            perms.hub.micGranted = false; perms.hub.axGranted = false; perms.hub.modelLoaded = false
        }

        let noKey = try makeRig("nokey", key: nil)
        try snapshotHub(noKey.hub, page: .cleanup, name: "hub-cleanup-not-configured", full: false)

        let broken = try makeRig("broken")
        try Data("{ \"dictionary\": [\"Parla\", ".utf8).write(to: broken.store.url)
        broken.hub.refresh()
        broken.hub.micGranted = true; broken.hub.axGranted = true
        XCTAssertNotNil(broken.hub.loadError)
        try snapshotHub(broken.hub, page: .general, name: "hub-general-settings-error", full: false)
        try snapshotHub(broken.hub, page: .dictionary, name: "hub-dictionary-settings-error", full: false)

        let editing = try makeRig("template-editor")
        try snapshotHub(editing.hub, page: .templates, name: "hub-templates-editor", full: true) {
            editing.hub.refreshTemplates()
            if editing.hub.templateEditor == nil { editing.hub.editTemplate(editing.hub.templateDocument.definitions.first?.id) }
        }

        // A meeting mid-recording: one fresh rig per appearance, since leaving the page stops it.
        var meetingRigs: [MeetingHubRig] = []
        defer { meetingRigs.forEach { $0.release() } } // released when the test ends, like testHubPages
        for (suffix, appearance) in Self.appearances {
            let meetings = try MeetingHubRig(); meetingRigs.append(meetings)
            let rig = try makeRig("meeting-recording-\(suffix)", meetingHub: meetings.controller)
            let host = hostHub(rig.hub, page: .meetings, size: NSSize(width: 920, height: 640), appearance: appearance) {}
            // The rig's clock drives the meeting's start time: 12 min 34 s ago, not 1970.
            meetings.clock = Int64((Date().timeIntervalSince1970 - 754) * 1_000_000_000)
            meetings.controller.startConsentedRecording(); settle(0.8)
            try write(host.view, "hub-meetings-recording-\(suffix)")
            host.window.close()
            // The question asked before navigation or closing would end that recording.
            let confirm = self.host(MeetingStopConfirmation(leaving: "open History", keep: {}, stop: {}),
                                    size: NSSize(width: 420, height: 150), appearance: appearance)
            settle(0.2); try write(confirm.view, "hub-meetings-stop-confirm-\(suffix)"); confirm.window.close()
        }

        let downloading = try makeRig("downloading")
        try snapshotHub(downloading.hub, page: .general, name: "hub-general-model-downloading", full: true) {
            downloading.hub.catalogDownloads[ModelCatalog.all[1].id] = CatalogDownloadRow(phase: .downloading, percent: 42)
            downloading.hub.downloadingModel = ModelCatalog.all[1]
        }
    }

    private func slug(_ page: HubPage) -> String {
        switch page {
        case .general: return "general"
        case .templates: return "templates"
        case .audioImport: return "audio-import"
        case .meetings: return "meetings"
        case .microphone: return "microphone"
        case .cleanup: return "cleanup"
        case .transforms: return "transforms"
        case .profiles: return "profiles"
        case .dictionary: return "dictionary"
        case .snippets: return "snippets"
        case .history: return "history"
        case .privacy: return "privacy"
        case .safeStart: return "safe-start"
        }
    }

    /// Window-size capture, plus `-full` when the page scrolls.
    @MainActor private func snapshotHub(_ hub: HubModel, page: HubPage, name: String, full: Bool,
                                        prepare: () -> Void = {}) throws {
        for (suffix, appearance) in Self.appearances {
            let host = hostHub(hub, page: page, size: NSSize(width: 920, height: 640), appearance: appearance, prepare: prepare)
            try write(host.view, "\(name)-\(suffix)")
            let overflow = Self.scrollOverflow(in: host.view)
            host.window.close()
            guard full, overflow > 1 else { continue }
            let tall = hostHub(hub, page: page, size: NSSize(width: 920, height: ceil(640 + overflow)), appearance: appearance, prepare: prepare)
            try write(tall.view, "\(name)-full-\(suffix)")
            tall.window.close()
        }
    }

    @MainActor private func hostHub(_ hub: HubModel, page: HubPage, size: NSSize, appearance: NSAppearance.Name,
                                    prepare: () -> Void) -> (window: NSWindow, view: NSView) {
        prepare()
        hub.requestedPage = page
        let host = host(HubRootView(model: hub), size: size, appearance: appearance)
        settle(0.5)
        prepare() // page entry may refresh; re-apply the faked live state
        settle(0.3)
        return host
    }

    /// How much taller than its viewport the largest scroll view's document is.
    private static func scrollOverflow(in view: NSView) -> CGFloat {
        var best: CGFloat = 0
        func walk(_ v: NSView) {
            if let scroll = v as? NSScrollView, let doc = scroll.documentView {
                best = max(best, doc.frame.height - scroll.contentView.bounds.height)
            }
            v.subviews.forEach(walk)
        }
        walk(view)
        return best
    }

    // MARK: - Onboarding

    @MainActor func testOnboarding() throws {
        var pendingStop: ((String) -> Void)?
        func rig(_ name: String, model installed: Bool = true) throws -> HubModel {
            let r = try makeRig(name, history: []) { s in
                s.onboardingCompleted = false
                if !installed { s.whisperModelPath = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).bin").path }
            }
            r.hub.onTryoutStart = { nil }
            r.hub.onTryoutStop = { pendingStop = $0 }
            r.hub.onTryoutCancel = {}
            return r.hub
        }
        for (suffix, appearance) in Self.appearances {
            // Step 1: permissions missing, then granted.
            let missing = try rig("onb-perm-missing-\(suffix)")
            let (w0, v0) = onboardingHost(missing, appearance) { missing.micGranted = false; missing.axGranted = false }
            try write(v0, "onboarding-1-permissions-missing-\(suffix)"); w0.close()
            let granted = try rig("onb-perm-\(suffix)")
            let (w1, v1) = onboardingHost(granted, appearance) { granted.micGranted = true; granted.axGranted = true }
            try write(v1, "onboarding-1-permissions-granted-\(suffix)")

            // Step 2: model downloaded.
            click(Footer.continueX, Footer.y, in: v1)
            settle(0.4); try write(v1, "onboarding-2-model-downloaded-\(suffix)")
            // Step 3: tryout idle → listening → transcribing → result.
            click(Footer.continueX, Footer.y, in: v1); settle(0.4)
            try write(v1, "onboarding-3-tryout-idle-\(suffix)")
            click(Footer.startX, Footer.startY, in: v1); settle(0.4)
            try write(v1, "onboarding-3-tryout-listening-\(suffix)")
            click(Footer.startX, Footer.startY, in: v1); settle(0.4)
            try write(v1, "onboarding-3-tryout-transcribing-\(suffix)")
            pendingStop?("Testing one two three. This is my first dictation with Parla."); pendingStop = nil
            settle(0.4); try write(v1, "onboarding-3-tryout-result-\(suffix)")
            w1.close()

            // Step 2: model not downloaded, then downloading.
            let none = try rig("onb-model-\(suffix)", model: false)
            let (w2, v2) = onboardingHost(none, appearance) { none.micGranted = true; none.axGranted = true }
            click(Footer.continueX, Footer.y, in: v2); settle(0.4)
            try write(v2, "onboarding-2-model-missing-\(suffix)")
            none.downloadProgress = 0.37
            none.catalogDownloads[ModelCatalog.default.id] = CatalogDownloadRow(phase: .downloading, percent: 37); settle(0.3)
            try write(v2, "onboarding-2-model-downloading-\(suffix)")
            // Step 3 with a refusal banner.
            none.onTryoutStart = { "Download a speech model first." }
            // A running download satisfies the step; clear it so Skip shows and step 3 sees no model.
            none.downloadProgress = nil; none.catalogDownloads = [:]; settle(0.3)
            click(Footer.skipX, Footer.y, in: v2); settle(0.4)
            click(Footer.startX, Footer.startY, in: v2); settle(0.4)
            try write(v2, "onboarding-3-tryout-error-\(suffix)")
            w2.close()
        }
    }

    @MainActor private func onboardingHost(_ hub: HubModel, _ appearance: NSAppearance.Name,
                                           permissions: () -> Void) -> (NSWindow, NSView) {
        permissions()
        let h = host(HubRootView(model: hub), size: NSSize(width: 920, height: 640), appearance: appearance)
        // Clicks only reach SwiftUI in an ordered window: fully transparent and far off-screen.
        h.0.alphaValue = 0; h.0.ignoresMouseEvents = false; h.0.orderFrontRegardless()
        settle(0.3); permissions(); settle(0.2)
        return h
    }

    /// Button centers (points, top-left origin) in the 920×640 first-run window. SwiftUI builds no
    /// in-process accessibility tree for an offscreen window, so steps are driven by clicks.
    private enum Footer {
        static let y: CGFloat = 612, continueX: CGFloat = 719, skipX: CGFloat = 651
        static let startX: CGFloat = 717, startY: CGFloat = 247
    }

    /// Clicks at a point given in top-left view coordinates, straight through the (unordered) window.
    private func click(_ x: CGFloat, _ y: CGFloat, in view: NSView) {
        guard let window = view.window else { return }
        let point = NSPoint(x: x, y: view.bounds.height - y)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                window.sendEvent(event)
            }
            settle(0.05)
        }
    }

    // MARK: - HUD

    @MainActor func testHUD() throws {
        let hud = HUD()
        let panel = try XCTUnwrap(Mirror(reflecting: hud).children.first { $0.label == "panel" }?.value as? NSPanel)
        panel.alphaValue = 0 // show() orders it front; keep it invisible on screen
        defer { hud.showAlways = false; hud.hide(); panel.orderOut(nil) }
        let levels: [Float] = (0..<30).map { i in 0.02 + 0.09 * abs(sin(Float(i) * 0.55)) * (i % 4 == 0 ? 0.5 : 1) }
        let states: [(String, HUD.State)] = [
            ("listening", .listening(command: false)),
            ("command", .listening(command: true)),
            ("hands-free", .handsFree),
            ("preview", .preview("so the main idea is that Parla should feel invisible you hold a key")),
            ("speculative-preview-draft", .speculativePreview(.draft("you hold a key, you talk, and the", englishOnly: true))),
            ("speculative-preview-status", .speculativePreview(.status(.languageUnavailable))),
            ("transcribing", .transcribing),
            ("polishing", .polishing),
            ("done", .done),
            ("saved-to-history", .savedToHistory),
            ("cleaned-in-history", .cleanedInHistory),
            ("raw-fallback", .rawFallback("cleanup timed out")),
            ("cancelled", .cancelled),
            ("error", .error("Microphone unavailable")),
            ("notice", .notice("You're up to date")),
        ]
        for (name, state) in states {
            hud.show(state)
            if case .listening = state { levels.forEach(hud.push) }
            if case .handsFree = state { levels.reversed().forEach(hud.push) }
            try writeHUD(panel, "hud-\(name)")
        }
        let token = UUID()
        for (name, view) in [("canceled-offer", CanceledCaptureView.offer(token)), ("canceled-processing", .processing(token)),
                             ("canceled-preview", .preview(token, "Okay so for the launch email I think we lead with the privacy angle, everything stays on your Mac, then the speed numbers, then pricing. Actually never mind, let me start over."))] {
            hud.showCanceledCapture(view)
            try writeHUD(panel, "hud-\(name)")
        }
        hud.showCanceledCapture(.empty); hud.hide()
        hud.showAlways = true
        for size in ["small", "medium", "large"] {
            hud.idleBarSize = HUD.idleSize(size)
            hud.hide() // settle: collapses to the idle bar when always-on
            try writeHUD(panel, "hud-idle-\(size)")
        }
    }

    private func writeHUD(_ panel: NSPanel, _ name: String) throws {
        let content = try XCTUnwrap(panel.contentView)
        content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
        let pill = try bitmap(of: content)
        let margin: CGFloat = 16
        for (suffix, color) in [("gray", NSColor(white: 0.5, alpha: 1)), ("white", NSColor.white)] {
            let size = NSSize(width: content.bounds.width + margin * 2, height: content.bounds.height + margin * 2)
            let rep = Self.rep(size)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            color.setFill(); NSRect(origin: .zero, size: size).fill()
            pill.draw(in: NSRect(x: margin, y: margin, width: content.bounds.width, height: content.bounds.height),
                      from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
            try save(rep, "\(name)-\(suffix)")
        }
    }

    // MARK: - Menu

    @MainActor func testMenuDumps() throws {
        let originals = OriginalCopyController(configuration: { ParlaCore.Settings() }, generation: { 0 }, security: { .safe }, copy: { _ in })
        let originalMenu = OriginalCopyMenuActions(controller: originals)

        func compose(_ r: Rig, cleanupIssue: Bool, update: String?, catalog: CatalogDownloadRow?, modelReady: Bool,
                     settingsError: String?, clipboardFailed: Bool, original: OriginalCopyStatus, receipt: UUID?,
                     pending: PendingOperation?, mic: Bool, ax: Bool, launch: Bool) -> NSMenu {
            // Mirrors AppDelegate.menuNeedsUpdate (StatusMenu.swift) item for item; AppDelegate itself
            // owns a real status item, recorder and Keychain store, so the static parts are called and
            // the instance-only lines are rebuilt with the same titles.
            let menu = NSMenu(); menu.autoenablesItems = false
            func item(_ title: String, _ enabled: Bool = true, key: String = "") -> NSMenuItem {
                let i = NSMenuItem(title: title, action: enabled ? #selector(NSApplication.terminate(_:)) : nil, keyEquivalent: key)
                i.isEnabled = enabled; return i
            }
            menu.addItem(item("Open Parla…")); menu.addItem(item("Voice Templates…"))
            if cleanupIssue, let issue = cleanupConfigurationIssue(settings: r.hub.settings, env: [:], credentials: r.store.credentials) {
                menu.addItem(item("⚠️ AI cleanup isn’t running: " + issue))
            }
            AppDelegate.addScratchpadItem(to: menu, bindings: r.hub.settings.hotkeys, formatter: r.hub.shortcutLabels.formatter, target: nil)
            menu.addItem(.separator())
            if let update { menu.addItem(item(update)); menu.addItem(.separator()) }
            if let catalog {
                let m = ModelCatalog.all[1]
                menu.addItem(item("\(m.displayName): \(catalog.phase.rawValue) \(catalog.percent)%", false))
                for action in catalog.actions { menu.addItem(item(action.rawValue)) }
                menu.addItem(.separator())
            }
            if !modelReady {
                let m = ModelCatalog.default
                menu.addItem(item("Download speech model (\(m.displayName), \(m.sizeLabel))")); menu.addItem(.separator())
            }
            if let settingsError {
                let i = item("⚠️ Settings file has an error — open it…"); i.toolTip = settingsError
                menu.addItem(i); menu.addItem(.separator())
            }
            AppDelegate.addClipboardRestoreStatus(to: menu, failed: clipboardFailed)
            AppDelegate.addOriginalCopy(to: menu, status: original, target: originalMenu, receipt: receipt)
            AppDelegate.addPendingOperation(to: menu, operation: pending, target: nil)
            AppDelegate.addHistoryItems(to: menu, history: r.history, target: nil, bindings: r.hub.settings.hotkeys, formatter: r.hub.shortcutLabels.formatter)
            if !mic { menu.addItem(item("⚠️ Allow Microphone access…")) }
            if !ax { menu.addItem(item("⚠️ Allow Accessibility access…")) }
            if !mic || !ax { menu.addItem(.separator()) }
            let micItem = item("Microphone"); let sub = NSMenu(); sub.autoenablesItems = false
            let def = item("System default"); def.state = .on; sub.addItem(def); sub.addItem(.separator())
            for name in ["MacBook Pro Microphone", "AirPods Pro", "Shure MV7"] { sub.addItem(item(name)) }
            micItem.submenu = sub; menu.addItem(micItem)
            let launchItem = item("Launch at login"); launchItem.state = launch ? .on : .off; menu.addItem(launchItem)
            menu.addItem(.separator())
            menu.addItem(item("Check for updates…")); menu.addItem(item("Send feedback…"))
            menu.addItem(.separator())
            menu.addItem(item("Quit Parla", key: "q"))
            return menu
        }

        let normal = try makeRig("menu-normal")
        try dump(compose(normal, cleanupIssue: true, update: nil, catalog: nil, modelReady: true, settingsError: nil,
                         clipboardFailed: false, original: .postedUnverified(UUID()), receipt: UUID(), pending: nil,
                         mic: true, ax: true, launch: true), "menu-normal")

        let warn = try makeRig("menu-warnings", key: nil)
        let operation = PendingOperation(name: "Dictation")
        try dump(compose(warn, cleanupIssue: true, update: "Update available (0.9.0)…",
                         catalog: CatalogDownloadRow(phase: .downloading, percent: 42), modelReady: true,
                         settingsError: nil, clipboardFailed: true, original: .unavailable, receipt: nil, pending: operation,
                         mic: true, ax: true, launch: false), "menu-warnings")
        operation.finish()

        let first = try makeRig("menu-first-run", history: []) { $0.onboardingCompleted = false }
        try dump(compose(first, cleanupIssue: true, update: nil, catalog: nil, modelReady: false,
                         settingsError: "The data couldn’t be read because it isn’t in the correct format.",
                         clipboardFailed: false, original: .disabled, receipt: nil, pending: nil,
                         mic: false, ax: false, launch: false), "menu-first-run-settings-error")
    }

    private func dump(_ menu: NSMenu, _ name: String) throws {
        var lines: [String] = []
        func walk(_ menu: NSMenu, _ depth: Int) {
            let pad = String(repeating: "    ", count: depth)
            for item in menu.items {
                if item.isSeparatorItem { lines.append(pad + "---"); continue }
                var line = pad + item.title
                if !item.isEnabled || (item.action == nil && item.submenu == nil) { line += "  [disabled]" }
                if item.state == .on { line += "  [✓]" } else if item.state == .mixed { line += "  [–]" }
                if !item.keyEquivalent.isEmpty {
                    var mods = ""
                    let mask = item.keyEquivalentModifierMask
                    if mask.contains(.control) { mods += "⌃" }; if mask.contains(.option) { mods += "⌥" }
                    if mask.contains(.shift) { mods += "⇧" }; if mask.contains(.command) { mods += "⌘" }
                    line += "  [key: \(mods)\(item.keyEquivalent.uppercased())]"
                }
                if item.submenu != nil { line += "  ▸" }
                if let tip = item.toolTip { line += "  (tooltip: \(tip))" }
                lines.append(line)
                if let sub = item.submenu { walk(sub, depth + 1) }
            }
        }
        walk(menu, 0)
        try (lines.joined(separator: "\n") + "\n").write(to: outDir.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
    }

    // MARK: - Rendering

    /// Borderless, never ordered on screen; SwiftUI still lays out and draws for cacheDisplay.
    @MainActor private func host<V: View>(_ view: V, size: NSSize, appearance: NSAppearance.Name) -> (window: NSWindow, view: NSView) {
        let window = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        let hosting = NSHostingView(rootView: view)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = NSRect(origin: .zero, size: size)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func settle(_ seconds: TimeInterval) { RunLoop.main.run(until: Date() + seconds) }

    private static func rep(_ size: NSSize) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        return rep
    }

    private func bitmap(of view: NSView) throws -> NSBitmapImageRep {
        view.layoutSubtreeIfNeeded()
        let rep = Self.rep(view.bounds.size)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Over the window background, as the real (opaque) Hub window shows it.
    private func write(_ view: NSView, _ name: String) throws {
        let content = try bitmap(of: view), out = Self.rep(view.bounds.size), rect = NSRect(origin: .zero, size: view.bounds.size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill(); rect.fill()
            content.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
        NSGraphicsContext.restoreGraphicsState()
        try save(out, name)
    }

    private func save(_ rep: NSBitmapImageRep, _ name: String) throws {
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        try png.write(to: outDir.appendingPathComponent("\(name).png"))
    }
}
