import AppKit
import SwiftUI

enum HubPage: String, CaseIterable, Identifiable {
    case general = "General"
    case templates = "Voice Templates"
    case audioImport = "Import Audio"
    case meetings = "Meetings"
    case microphone = "Microphone Test"
    case cleanup = "AI Cleanup"
    case transforms = "Output & Presets"
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
        case .audioImport: return "waveform.badge.plus"
        case .meetings: return "waveform"
        case .microphone: return "mic"
        case .cleanup: return "wand.and.stars"
        case .transforms: return "text.badge.star"
        case .profiles: return "slider.horizontal.3"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .history: return "clock.arrow.circlepath"
        case .privacy: return "lock.shield"
        case .safeStart: return "pause.circle"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Permissions, speech recognition and shortcuts"
        case .templates: return "Fill in forms by voice, one field at a time"
        case .audioImport: return "Transcribe an audio file"
        case .meetings: return "Record a meeting, then transcribe it"
        case .microphone: return "Check that your microphone works"
        case .cleanup: return "Polish punctuation and wording after you dictate"
        case .transforms: return "Choose what gets typed, and save rewrite presets"
        case .profiles: return "Different settings for specific apps and websites"
        case .dictionary: return "Names and terms Parla should spell your way"
        case .snippets: return "Spoken triggers that expand to text"
        case .history: return "Your recent dictations, saved on this Mac"
        case .privacy: return "What Parla keeps and where"
        case .safeStart: return "Recover from a speech model that keeps crashing"
        }
    }
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
        if model.meetingPageActive { MainActor.assumeIsolated { model.meetingHub?.openPage() } }
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

struct HubRootView: View {
    @ObservedObject var model: HubModel
    @State private var page: HubPage = .general

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
                VStack {
                    OnboardingView(model: model)
                    Button("Open Voice Templates") { page = .templates }
                    Button("Transcribe an audio file instead") { page = .audioImport }
                        .padding(.bottom)
                }
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
            if let requested { page = requested; model.requestedPage = nil }
        }
        .onAppear {
            if let requested = model.requestedPage { page = requested; model.requestedPage = nil }
        }
        .ignoresSafeArea() // paint under the transparent titlebar
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 7) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.accent)
                Text("Parla")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)

            ForEach(HubPage.allCases) { p in
                Button {
                    page = p
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: p.icon)
                            .font(.system(size: 13))
                            .frame(width: 18)
                        Text(p.rawValue)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(page == p ? Theme.accent : Theme.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8)
                        .fill(page == p ? Theme.accentFill : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Text("On-device dictation")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 10)
        }
        .padding(.horizontal, 10)
        .padding(.top, 48) // room for traffic lights
        .padding(.bottom, 14)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(Theme.sidebar)
        .overlay(alignment: .trailing) { Rectangle().fill(Theme.border).frame(width: 1) }
    }

    @ViewBuilder private var content: some View {
        if page == .meetings {
            if let controller = model.meetingHub { HubMeetingView(controller:controller,openSettings:{page = .general}) }
            else { Text("Meetings are unavailable.").frame(maxWidth:.infinity,maxHeight:.infinity).background(Theme.bg) }
        } else { legacyContent }
    }
    private var legacyContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let err = model.loadError {
                    HubBanner(text: "Settings can't be read, so editing is off. Fix settings.json to continue. \(err)",
                              actionTitle: "Open file") { model.onOpenSettingsFile() }
                }
                if let err = model.saveError {
                    HubBanner(text: err)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.rawValue)
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Text(page.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
                pageView
                    .disabled(model.loadError != nil && page != .history && page != .privacy && page != .microphone && page != .audioImport && page != .templates)
                    .opacity(model.loadError == nil || page == .history || page == .privacy || page == .microphone || page == .audioImport || page == .templates ? 1 : 0.5)
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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
        case .microphone: HubMicrophoneTestView(model: model, test: model.microphoneTest)
        case .cleanup: CleanupPage(model: model)
        case .transforms: HubTransformsView(model: model)
        case .profiles: HubProfilesView(model: model)
        case .dictionary: DictionaryPage(model: model)
        case .snippets: SnippetsPage(model: model)
        case .history: HistoryPage(model: model)
        case .privacy: PrivacyPage(model: model)
        case .safeStart: NativePreparationView(model: model)
        }
    }
}
