import AppKit
import SwiftUI

enum HubPage: String, CaseIterable, Identifiable {
    case general = "General"
    case templates = "Voice Templates"
    case audioImport = "Import Audio"
    case meetings = "Meetings"
    case microphone = "Microphone Test"
    case cleanup = "AI Cleanup"
    case transforms = "Rewrite Presets"
    case profiles = "App & Site Profiles"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case history = "History"
    case privacy = "Data & Privacy"
    case safeStart = "Safe Start"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .templates: return "list.bullet.rectangle"
        case .audioImport: return "square.and.arrow.down"
        case .meetings: return "person.2"
        case .microphone: return "mic"
        case .cleanup: return "wand.and.stars"
        case .transforms: return "pencil.line"
        case .profiles: return "macwindow"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.insert"
        case .history: return "clock.arrow.circlepath"
        case .privacy: return "lock.shield"
        case .safeStart: return "lifepreserver"
        }
    }

    /// Microphone Test and Safe Start share the Troubleshooting page.
    var title: String {
        switch self {
        case .microphone, .safeStart: return "Troubleshooting"
        default: return rawValue
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Shortcuts, speech recognition and app behavior"
        case .templates: return "Fill in a form by voice, one field at a time"
        case .audioImport: return "Turn an audio file into text"
        case .meetings: return "Record your microphone and one app, then transcribe"
        case .microphone: return "Check your microphone, recover from crashes and review diagnostics"
        case .cleanup: return "Fix punctuation and wording after you dictate"
        case .transforms: return "Rewrite highlighted text with a preset"
        case .profiles: return "Different settings for specific apps and websites"
        case .dictionary: return "Names and terms Parla should spell your way"
        case .snippets: return "Short phrases that expand into longer text"
        case .history: return "Your recent dictations, kept on this Mac"
        case .privacy: return "What Parla keeps, where, and for how long"
        case .safeStart: return "Check your microphone, recover from crashes and review diagnostics"
        }
    }

    /// Sidebar grouping: everyday settings, tools, then data and troubleshooting.
    static let groups: [(title: String, pages: [HubPage])] = [
        ("", [.general]), // app-wide, so it sits above the groups
        ("Dictation", [.cleanup, .transforms, .dictionary, .snippets, .profiles]),
        ("Tools", [.templates, .meetings, .audioImport, .history]),
        ("Privacy & Help", [.privacy, .safeStart]),
    ]
}

/// Owns the single Hub window. Created lazily; closing just hides it
/// (isReleasedWhenClosed = false), the app stays menu-bar-only.
final class HubWindowController: NSObject, NSWindowDelegate {
    private let model: HubModel
    private var window: NSWindow?
    private var preparationOnly = false

    init(model: HubModel) {
        self.model = model
    }

    func show(preparationOnly: Bool = false, audioImportOnly: Bool = false, templatesOnly: Bool = false) {
        // Before the window exists, not after: the root view branches on
        // onboardingCompleted, and building it against unloaded settings would
        // render the first-run flow for a moment to an existing user.
        self.preparationOnly = preparationOnly
        // openPage() stops an active capture, so a menu-bar entry during a recording
        // only brings the window forward; a requested page asks first (HubRootView.go).
        let recording = MainActor.assumeIsolated { model.meetingPageActive && model.meetingHub?.model.stoppingAvailable == true }
        if recording {}
        else if model.meetingPageActive { MainActor.assumeIsolated { model.meetingHub?.openPage() } }
        else if templatesOnly || model.templatesPageActive { model.refreshTemplates() }
        else if audioImportOnly || model.audioImportPageActive { model.refreshAudioImportConfiguration() }
        else if preparationOnly { model.refreshPreparationConfiguration() } else { model.refresh() }
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true) // LSUIElement app: needs explicit focus
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if model.meetingPageActive { return }
        if model.templatesPageActive { model.refreshTemplates() }
        else if model.audioImportPageActive { model.refreshAudioImportConfiguration() }
        else if preparationOnly { model.refreshPreparationConfiguration() } else { model.refresh() }
    }

    /// Closing the window ends a meeting recording (capture is bound to the page),
    /// so ask first. Stop and Save closes through the ordinary path below.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let recording = MainActor.assumeIsolated { model.meetingPageActive && model.meetingHub?.model.stoppingAvailable == true }
        guard recording else { return true }
        model.meetingExitRequest = MeetingExitRequest(leaving: "close this window") { [weak sender] in sender?.close() }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { model.meetingHub?.windowClosed() }
        model.leaveTemplates()
        model.leaveAudioImport()
        model.microphoneTestLifecycle(.windowClose); model.stopRecoveryPlayback()
    }
    func windowDidResignKey(_ notification: Notification) { model.templates.cancel("Form canceled."); model.cancelTemplateEditor(); model.microphoneTestLifecycle(.resign) }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Parla"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.minSize = NSSize(width: 760, height: 480)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: HubRootView(model: model))
        w.center()
        return w
    }
}

extension HubModel {
    /// Owner-approved recovery: the unreadable file is renamed beside itself, then defaults load.
    func resetUnreadableSettings() {
        // Same runtime application as an ordinary save (warm mic, HUD, input device).
        do { _ = try store.resetUnreadableSettings(); refresh(); onSaved() }
        catch { saveError = "Couldn’t reset settings: \(error)" }
    }
}

/// A pending action that would stop a meeting recording.
struct MeetingExitRequest: Identifiable {
    let id = UUID()
    let leaving: String
    let proceed: () -> Void
}

/// Asks before an ordinary action ends a meeting recording. Keep Recording is the default.
struct MeetingStopConfirmation: View {
    let leaving: String
    let keep: () -> Void
    let stop: () -> Void
    var body: some View {
        HubSheet(title: "Stop recording this meeting?", width: 420) {
            Text("To \(leaving), Parla has to stop the recording. Everything recorded so far is saved.")
                .font(.system(size: 13)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
        } actions: {
            Button("Stop and Save", action: stop).buttonStyle(HubButtonStyle())
            Button("Keep Recording", action: keep)
                .buttonStyle(HubButtonStyle(kind: .primary)).keyboardShortcut(.defaultAction)
        }
        .onExitCommand(perform: keep)
    }
}

struct HubRootView: View {
    @ObservedObject var model: HubModel
    @State private var page: HubPage = .general
    @State private var confirmReset = false

    var body: some View {
        Group {
            // First run owns the whole window: there is nothing useful to
            // configure until the permissions and the model are in place.
            if page == .meetings || model.requestedPage == .meetings || page == .templates || model.requestedPage == .templates || model.loadError != nil || model.settings.onboardingCompleted || page == .safeStart || model.requestedPage == .safeStart || page == .history || page == .privacy || page == .microphone || model.requestedPage == .microphone || model.requestedPage == .history || page == .audioImport || model.requestedPage == .audioImport {
                HStack(spacing: 0) {
                    sidebar
                    content
                }
            } else {
                OnboardingView(model: model)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .onChange(of: page) { value in
            model.meetingPageActive = value == .meetings
            if value == .meetings { model.meetingHub?.openPage() } else { model.meetingHub?.leavePage() }
            if value != .templates { model.leaveTemplates() }
            else { model.templatesPageActive = true; model.refreshTemplates() }
            model.discardAudioImport(); model.audioImportPageActive = value == .audioImport
            if value == .audioImport { model.refreshAudioImportConfiguration() }
            model.stopRecoveryPlayback(); model.microphoneTestLifecycle(.pageLeave)
        }
        .onDisappear { model.meetingHub?.leavePage(); model.leaveTemplates(); model.discardAudioImport(); model.microphoneTestLifecycle(.pageLeave) }
        .onChange(of: model.requestedPage) { requested in
            if let requested { model.requestedPage = nil; go(requested) }
        }
        .sheet(item: $model.meetingExitRequest) { request in
            MeetingStopConfirmation(leaving: request.leaving, keep: { model.meetingExitRequest = nil }, stop: {
                model.meetingExitRequest = nil
                DispatchQueue.main.async(execute: request.proceed) // after the sheet is gone
            })
        }
        .onAppear {
            if let requested = model.requestedPage { page = requested; model.requestedPage = nil }
        }
        .ignoresSafeArea() // paint under the transparent titlebar
    }

    /// One readable sentence for a settings.json load error; the raw text stays under Details.
    private func settingsProblem(_ error: String) -> String {
        func capture(_ pattern: String) -> String? {
            guard let range = error.range(of: pattern, options: .regularExpression) else { return nil }
            let match = String(error[range])
            guard let quote = match.firstIndex(where: { $0 == "\"" || $0 == "=" }) else { return nil }
            return match[match.index(after: quote)...].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        if error.contains("not valid JSON") || error.contains("Code=3840") {
            var where_ = ""
            // The stored error is truncated; re-parse the (small) file for the position.
            if let data = try? Data(contentsOf: model.store.url) {
                do { _ = try JSONSerialization.jsonObject(with: data) } catch {
                    if let index = (error as NSError).userInfo["NSJSONSerializationErrorIndex"] as? Int, index <= data.count {
                        where_ = " near line \(data.prefix(index).filter { $0 == 10 }.count + 1)"
                    }
                }
            }
            return "a formatting error\(where_)"
        }
        if let key = capture("stringValue: \"[^\"]+\"") {
            return "“\(key)” has a value Parla can’t use"
        }
        return "settings.json"
    }

    /// Every page change goes through here. Leaving Meetings mid-recording asks
    /// first; Stop and Save then switches pages, which stops and saves as before.
    private func go(_ target: HubPage) {
        guard target != page, page == .meetings, model.meetingHub?.model.stoppingAvailable == true else { page = target; return }
        model.meetingExitRequest = MeetingExitRequest(leaving: "open \(target.title)") { page = target }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                    .accessibilityHidden(true)
                Text("Parla")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            ForEach(HubPage.groups, id: \.title) { group in
                if group.title.isEmpty {
                    Color.clear.frame(height: 10)
                } else {
                    Text(group.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, 8)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(group.pages) { p in sidebarItem(p) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 46) // room for traffic lights
        .padding(.bottom, 14)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    private func isCurrent(_ p: HubPage) -> Bool {
        page == p || (p == .safeStart && page == .microphone)
    }

    private func sidebarItem(_ p: HubPage) -> some View {
        let current = isCurrent(p)
        return Button {
            go(p)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: p.icon)
                    .font(.system(size: 13))
                    .frame(width: 18)
                    .foregroundStyle(current ? Theme.accent : Theme.muted)
                Text(p.title)
                    .foregroundStyle(current ? Theme.accent : Theme.text)
                Spacer(minLength: 0)
                if p == .meetings, let controller = model.meetingHub { MeetingRecordingBadge(controller: controller) }
                if p == .general, model.settings.onboardingCompleted, !(model.micGranted && model.axGranted) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(Theme.warning)
                        .help("A permission Parla needs is missing")
                        .accessibilityLabel("Permission missing")
                }
            }
            .font(.system(size: 13, weight: current ? .semibold : .regular))
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(current ? Theme.accentFill : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(current ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        if page == .meetings {
            if let controller = model.meetingHub { HubMeetingView(controller:controller,openSettings:{ go(.general) },microphone:$model.settings.inputDeviceUID,settingsLocked:model.loadError != nil) }
            else {
                VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
                    HubPageHeader(title: page.title, subtitle: page.subtitle)
                    HubSection(nil) { EmptyHint(text: "Meetings aren’t available in this version") }
                }
                .hubColumn()
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.bg)
            }
        } else { legacyContent }
    }

    /// Pages that stay usable while settings.json can't be read.
    private var worksWithoutSettings: Bool {
        [.history, .privacy, .microphone, .safeStart, .audioImport, .templates].contains(page)
    }

    private var legacyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: HubLayout.sectionSpacing) {
                HubPageHeader(title: page.title, subtitle: page.subtitle)
                if let err = model.loadError {
                    HubBanner(text: "Parla can’t read its settings file (\(settingsProblem(err))). Changes are paused and nothing was overwritten. Fix the file and click Try Again, or reset to defaults.",
                              detail: err, actionTitle: "Open Settings File", actionKind: .primary,
                              secondaryTitle: "Try Again", secondaryAction: { model.refresh() },
                              destructiveTitle: "Reset Settings…", destructiveAction: { confirmReset = true },
                              action: { model.onOpenSettingsFile() })
                    .confirmationDialog("Reset Parla’s settings?", isPresented: $confirmReset) {
                        Button("Reset Settings", role: .destructive) { model.resetUnreadableSettings() }
                    } message: {
                        Text("settings.json will be renamed to settings.json.broken-<date and time> in \((model.store.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath), so nothing is deleted. Parla then starts with default settings. Your API keys in Keychain aren’t affected.")
                    }
                }
                if let err = model.saveError {
                    HubBanner(text: err)
                }
                // Controls disable themselves; explanations stay readable.
                pageView
                    .disabled(model.loadError != nil && !worksWithoutSettings)
            }
            .hubColumn()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if page == .templates, model.templateEditor != nil, !model.templates.ownsSession {
                TemplateEditorBar(model: model)
            }
        }
        .background(Theme.bg)
        .tint(Theme.accent)
    }

    @ViewBuilder private var pageView: some View {
        switch page {
        case .general: GeneralPage(model: model)
        case .templates: HubTemplatesView(model: model, owner: model.templates)
        case .audioImport: HubAudioImportView(model: model, owner: model.audioImport)
        case .meetings: EmptyView() // dedicated content owns its persistent action rail
        case .microphone, .safeStart: TroubleshootingPage(model: model)
        case .cleanup: CleanupPage(model: model)
        case .transforms: HubTransformsView(model: model)
        case .profiles: HubProfilesView(model: model)
        case .dictionary: DictionaryPage(model: model)
        case .snippets: SnippetsPage(model: model)
        case .history: HistoryPage(model: model)
        case .privacy: PrivacyPage(model: model)
        }
    }
}

/// Red dot on the Meetings sidebar item while a meeting is being recorded.
private struct MeetingRecordingBadge: View {
    @ObservedObject var controller: MeetingHubController
    var body: some View {
        if controller.model.stoppingAvailable {
            Circle().fill(Theme.danger).frame(width: 7, height: 7)
                .help("Recording a meeting")
                .accessibilityLabel("Recording")
        }
    }
}
