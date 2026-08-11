import AppKit
import SwiftUI

enum HubPage: String, CaseIterable, Identifiable {
    case general = "General"
    case cleanup = "AI Cleanup"
    case dictionary = "Dictionary"
    case snippets = "Snippets"
    case history = "History"
    case privacy = "Data & Privacy"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .cleanup: return "wand.and.stars"
        case .dictionary: return "character.book.closed"
        case .snippets: return "text.badge.plus"
        case .history: return "clock.arrow.circlepath"
        case .privacy: return "lock.shield"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "Permissions, whisper model, and app behavior"
        case .cleanup: return "Where transcripts get polished"
        case .dictionary: return "Exact spellings that bias transcription"
        case .snippets: return "Spoken triggers that expand to text"
        case .history: return "Your recent dictations, stored locally"
        case .privacy: return "What Parla keeps and where"
        }
    }
}

/// Owns the single Hub window. Created lazily; closing just hides it
/// (isReleasedWhenClosed = false), the app stays menu-bar-only.
final class HubWindowController: NSObject, NSWindowDelegate {
    private let model: HubModel
    private var window: NSWindow?

    init(model: HubModel) {
        self.model = model
    }

    func show() {
        // Before the window exists, not after: the root view branches on
        // onboardingCompleted, and building it against unloaded settings would
        // render the first-run flow for a moment to an existing user.
        model.refresh()
        if window == nil { window = makeWindow() }
        NSApp.activate(ignoringOtherApps: true) // LSUIElement app: needs explicit focus
        window?.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.refresh() // pick up external settings edits / new dictations
    }

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
            if model.settings.onboardingCompleted {
                HStack(spacing: 0) {
                    sidebar
                    content
                }
            } else {
                OnboardingView(model: model)
            }
        }
        .frame(minWidth: 760, minHeight: 480)
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

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let err = model.loadError {
                    HubBanner(text: "settings.json is invalid — editing is disabled until it's fixed. \(err)",
                              actionTitle: "Open File") { model.onOpenSettingsFile() }
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
                    .disabled(model.loadError != nil)
                    .opacity(model.loadError == nil ? 1 : 0.5)
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
        case .cleanup: CleanupPage(model: model)
        case .dictionary: DictionaryPage(model: model)
        case .snippets: SnippetsPage(model: model)
        case .history: HistoryPage(model: model)
        case .privacy: PrivacyPage(model: model)
        }
    }
}
