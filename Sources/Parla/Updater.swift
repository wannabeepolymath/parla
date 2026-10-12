import AppKit
import ParlaCore

/// Discovery and install state for the in-app updater; the transaction itself
/// is UpdateInstaller's. Checks are serialized — a request during one joins
/// it — and an install captures its Update when clicked, so no later check
/// can change the transaction under way. Used on the main thread by the app;
/// its own tasks hop back to the main actor.
final class UpdateController {
    enum State {
        case idle
        case available(UpdateCheck.Update)
        case installing(percent: Int)
        case waiting
        case failed(UpdateCheck.Update) // not sticky: the next check offers Install again
    }

    private(set) var state = State.idle {
        didSet { if let title = menuTitle { liveItem?.title = title } }
    }
    /// The menu's update line, retitled in place while the menu is open.
    weak var liveItem: NSMenuItem?
    /// Set (by `claimRestart`) right before the swap and held until the
    /// relaunch: a dictation started now would be killed mid-sentence.
    var committing = false

    private let hud: HUD
    private let claimRestart: () async -> Bool
    private var checkTask: Task<UpdateCheck.Outcome, Never>?
    /// The install gate: set before the first suspension, held through restart.
    private var installTask: Task<Void, Never>?
    private var installed = false
    private var quitPending = false

    init(hud: HUD, claimRestart: @escaping () async -> Bool) {
        self.hud = hud
        self.claimRestart = claimRestart
    }

    /// Canonical, so the relaunch opens the app that was swapped.
    static let installURL = Bundle.main.bundleURL.resolvingSymlinksInPath()

    /// Step 1, once per launch: Developer ID-signed and in a writable place.
    /// nil ⇒ every update goes through the browser.
    private lazy var requirement: SecRequirement? = {
        if let problem = UpdateInstaller.locationProblem(Self.installURL) {
            NSLog("%@", "Parla update: browser only — install location \(problem)")
            return nil
        }
        do { return try UpdateInstaller.runningRequirement() } catch {
            NSLog("%@", "Parla update: browser only — \(error)")
            return nil
        }
    }()

    private func canInstall(_ update: UpdateCheck.Update) -> Bool {
        update.dmgURL != nil && requirement != nil
    }

    /// nil ⇒ no update line in the menu.
    var menuTitle: String? {
        switch state {
        case .idle: return nil
        case .available(let update) where canInstall(update): return "Install Update \(update.version)"
        case .available(let update), .failed(let update): return "Update available (\(update.version))…"
        case .installing(let percent): return "Updating… \(percent)%"
        case .waiting: return "Waiting for dictation to finish…"
        }
    }

    var isBusy: Bool { installTask != nil }

    /// The launch check, then an hourly tick. ponytail: the 24 h is the
    /// persisted last-success throttle, so a check is due from that stamp, not
    /// from launch — up to an hour late; a precise one-shot timer if that matters.
    func start() {
        check(manual: false)
        Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(manual: false) }
        }
    }

    /// Manual checks bypass the throttle and are the only ones that speak.
    func check(manual: Bool) {
        Task { @MainActor in
            let outcome = await runCheck(force: manual)
            guard manual else { return }
            switch outcome {
            case .upToDate: hud.show(.notice("You're up to date"))
            case .failed: hud.show(.error("Couldn't check for updates"))
            case .available, .throttled: break
            }
        }
    }

    @MainActor private func runCheck(force: Bool) async -> UpdateCheck.Outcome {
        if let checkTask { return await checkTask.value }
        let task = Task.detached { await UpdateCheck.check(currentVersion: AppDelegate.appVersion, force: force) }
        checkTask = task
        let outcome = await task.value
        checkTask = nil
        guard installTask == nil else { return outcome } // never retarget a transaction
        switch outcome {
        case .available(let update): state = .available(update)
        case .upToDate: state = .idle
        case .throttled, .failed: break
        }
        return outcome
    }

    /// The menu line's action: install when we can, else the release page.
    func menuItemClicked() {
        switch state {
        case .available(let update) where canInstall(update): install(update)
        case .available(let update), .failed(let update): NSWorkspace.shared.open(update.url)
        case .idle, .installing, .waiting: break
        }
    }

    private func install(_ update: UpdateCheck.Update) {
        guard installTask == nil, let dmg = update.dmgURL, let requirement,
              let version = AppDelegate.appVersion else { return }
        state = .installing(percent: 0)
        let installer = UpdateInstaller.live(requirement: requirement, progress: { fraction in
            let percent = Int(fraction * 100)
            DispatchQueue.main.async { [weak self] in
                // Whole percents only; and never over .waiting or a failure.
                guard let self, case .installing(let shown) = self.state, shown != percent else { return }
                self.state = .installing(percent: percent)
            }
        }, claimRestart: { @MainActor [weak self] in
            guard let self else { return false }
            if await self.claimRestart() { return true }
            self.state = .waiting
            return false
        })
        installTask = Task { @MainActor in
            do {
                let result = try await installer.install(dmg: dmg, currentVersion: version, at: Self.installURL)
                installed = true
                if result == .reopenToFinish {
                    hud.show(.error("Installed — reopen Parla to finish"))
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // long enough to read it
                }
                if quitPending { NSApp.reply(toApplicationShouldTerminate: true) } else { NSApp.terminate(nil) }
            } catch {
                NSLog("%@", "Parla update failed: \(error)")
                committing = false
                installTask = nil
                state = .failed(update)
                if quitPending { return NSApp.reply(toApplicationShouldTerminate: true) }
                let step = (error as? UpdateInstaller.Failure)?.step.rawValue ?? "unknown"
                hud.show(.error("Update failed: \(step)"))
            }
        }
    }

    /// Quit before the swap cancels the transaction and replies once its
    /// cleanup (detach, temp removal) is done; after, Quit waits for the swap.
    func shouldTerminate() -> NSApplication.TerminateReply {
        guard let installTask, !installed else { return .terminateNow }
        quitPending = true
        if !committing { installTask.cancel() }
        return .terminateLater
    }
}
