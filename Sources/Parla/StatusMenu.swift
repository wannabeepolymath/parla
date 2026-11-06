import AppKit
import Combine
import ParlaCore
import ServiceManagement

extension AppDelegate: NSMenuDelegate {
    /// Rebuilt from scratch right before the menu shows, so permission/model/
    /// settings status is always current — cheaper than tracking diffs.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let openHubItem = NSMenuItem(title: "Open Parla…", action: #selector(openHub), keyEquivalent: "")
        openHubItem.target = self
        menu.addItem(openHubItem)
        let templatesItem = NSMenuItem(title: "Voice Templates…", action: #selector(openTemplates), keyEquivalent: "")
        templatesItem.target = self; menu.addItem(templatesItem)
        if hubModel.settings.recognitionEngine == .parakeet {
            let request = RecognitionRequest(settings: hubModel.settings)
            let reason = MainActor.assumeIsolated { parakeetPreparation.cachedRefusal(for: request) }
            let item = NSMenuItem(title: reason?.message ?? parakeetPreparation.snapshot.message, action: #selector(openNativePreparation), keyEquivalent: "")
            item.target = self
            item.toolTip = hubModel.recognitionCapabilityDetail; menu.addItem(item)
        }
        if hubModel.settings.recognitionEngine == .appleSpeech {
            let speech = NSMenuItem(title: hubModel.appleSpeechSnapshot.message, action: #selector(openNativePreparation), keyEquivalent: "")
            speech.target = self; speech.toolTip = hubModel.recognitionCapabilityDetail; menu.addItem(speech)
        }
        let safeStart = NSMenuItem(title: nativePreparation.snapshot.message, action: #selector(openNativePreparation), keyEquivalent: "")
        safeStart.target = self; menu.addItem(safeStart)
        if nativePreparation.core.isEnabled {
            for action in NativePreparation.Action.allCases {
                let item = NSMenuItem(title: action.rawValue, action: #selector(NativePreparationMenuActions.invoke(_:)), keyEquivalent: "")
                item.target = nativePreparationMenu
                item.representedObject = NativePreparationMenuRoute(action, nativePreparation.snapshot.token)
                menu.addItem(item)
            }
        }
        if hubModel.settings.usesAppleIntelligence {
            let local = NSMenuItem(title: "Apple Intelligence: " + (hubModel.localCleanupStatus?.message ?? "eligible; rechecked per request"), action: #selector(openHub), keyEquivalent: "")
            local.target = self; menu.addItem(local)
        }
        Self.addScratchpadItem(to: menu, bindings: store.load().hotkeys,
                               formatter: hubModel.shortcutLabels.formatter, target: self)
        menu.addItem(.separator())

        // Install, the browser fallback, or the live progress line (disabled).
        if let title = updater.menuTitle {
            let item = NSMenuItem(title: title, action: updater.isBusy ? nil : #selector(updateClicked),
                                   keyEquivalent: "")
            item.target = self
            updater.liveItem = item
            menu.addItem(item)
            menu.addItem(.separator())
        }

        for model in ModelCatalog.all {
            guard let row = hubModel.catalogDownloads[model.id], row.phase != .installed else { continue }
            let item = NSMenuItem(title: "\(model.displayName): \(row.phase.rawValue) \(row.percent)%", action: nil, keyEquivalent: "")
            item.isEnabled = false; menu.addItem(item)
            for action in row.actions {
                let control = NSMenuItem(title: action.rawValue, action: #selector(catalogDownloadMenuAction(_:)), keyEquivalent: "")
                control.target = self
                control.representedObject = CatalogDownloadMenuRoute(action, model)
                control.isEnabled = !catalogDownloads.isActive || catalogDownloads.activeID == model.id
                menu.addItem(control)
            }
            menu.addItem(.separator())
        }
        if hubModel.settings.recognitionEngine == .whisper && !modelReady && !catalogDownloads.isActive && (hubModel.catalogDownloads[ModelCatalog.default.id] == nil || hubModel.catalogDownloads[ModelCatalog.default.id]?.phase == .installed) {
            let m = ModelCatalog.default
            let item = NSMenuItem(title: "Download model (\(m.displayName), \(m.sizeLabel))", action: #selector(downloadModel), keyEquivalent: "")
            item.target = self; menu.addItem(item); menu.addItem(.separator())
        }

        if let error = store.lastError {
            let item = NSMenuItem(title: "⚠️ settings.json invalid — click to open",
                                   action: #selector(openSettings), keyEquivalent: "")
            item.target = self
            item.toolTip = error
            menu.addItem(item)
            menu.addItem(.separator())
        }

        Self.addClipboardRestoreStatus(to: menu, failed: Inserter.clipboardRestoreFailed)
        Self.addOriginalCopy(to: menu, status: originalCopy.refresh(), target: originalCopyMenu,
                             receipt: guardedEdits.refresh())
        Self.addPendingOperation(to: menu, operation: session.pendingOperation, target: self)
        addHistoryItems(to: menu)

        // Permissions surface only when missing — a granted app needs no reminder.
        if !micGranted { menu.addItem(permissionItem(name: "Microphone", pane: "Privacy_Microphone")) }
        if !axGranted { menu.addItem(permissionItem(name: "Accessibility", pane: "Privacy_Accessibility")) }
        if !micGranted || !axGranted { menu.addItem(.separator()) }

        addMicrophoneItem(to: menu)

        let launch = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        launch.target = self
        launch.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launch)
        menu.addItem(.separator())

        let check = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        check.target = self
        menu.addItem(check)
        let report = NSMenuItem(title: "Report a Bug or Feature…", action: #selector(reportIssue), keyEquivalent: "")
        report.target = self
        menu.addItem(report)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Parla", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        showIdle() // menu open is a free moment to reconcile the icon too
    }

    static func addOriginalCopy(to menu: NSMenu, status: OriginalCopyStatus, target: OriginalCopyMenuActions, receipt: UUID? = nil) {
        for (title, action) in [("Undo Last Dictation", #selector(OriginalCopyMenuActions.undoLastDictation(_:))),
                                ("Restore Raw Text", #selector(OriginalCopyMenuActions.restoreRawText(_:)))] {
            let item = NSMenuItem(title: title, action: receipt == nil ? nil : action, keyEquivalent: "")
            item.target = target; item.representedObject = receipt; item.isEnabled = receipt != nil
            menu.addItem(item)
        }
        // No permanent grey status row. A legacy explicit Copy opt-out hides
        // that item; guarded edits remain enabled independently of the setting.
        guard status != .disabled else { menu.addItem(.separator()); return }
        let item = NSMenuItem(title: "Copy Original", action: status.token == nil ? nil : #selector(OriginalCopyMenuActions.copyOriginal(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = status.token
        item.isEnabled = status.token != nil
        menu.addItem(item)
        menu.addItem(.separator())
    }

    static func addPendingOperation(to menu: NSMenu, operation: PendingOperation?, target: AnyObject?) {
        guard let operation, !operation.hasExited else { return }
        let stopping = operation.shouldAbort
        let item = NSMenuItem(title: stopping ? "Discarded — stopping work…"
            : "Discard pending \(operation.name) (\(operation.stage.rawValue))", action: stopping ? nil : #selector(discardPending(_:)), keyEquivalent: "")
        item.target = target
        item.representedObject = operation.id
        item.toolTip = "Drops uncommitted output and its recovery audio. Native/network work may take time to stop. Already dispatched text and saved history cannot be undone."
        menu.addItem(item)
        menu.addItem(.separator())
    }

    @objc func discardPending(_ sender: NSMenuItem) {
        guard let token = sender.representedObject as? UUID else { return }
        send(.discardPending(token: token))
    }

    /// "Paste Last Dictation" + a "Recent" submenu (up to 8, newest first) with
    /// a "Clear History" action. Nil action ⇒ auto-disabled when empty.
    private func addHistoryItems(to menu: NSMenu) {
        hubModel.reloadHistory()
        Self.addHistoryItems(to: menu, history: history, target: self, bindings: store.load().hotkeys,
                             formatter: hubModel.shortcutLabels.formatter)
    }

    /// The real menu composition, callable without constructing AppDelegate's
    /// recorder, status item, model loader or window.
    static func addHistoryItems(to menu: NSMenu, history: HistoryStore, target: AnyObject?,
                                bindings: HotkeyBindings = HotkeyBindings(),
                                formatter: ShortcutDisplayFormatter = .current()) {
        if history.needsAttention {
            let warning = NSMenuItem(title: "History needs attention — Open History…",
                                     action: #selector(openHistory), keyEquivalent: "")
            warning.target = target
            warning.toolTip = history.lastError ?? "Unsaved results: Copy, Retry Save or Discard in History."
            menu.addItem(warning)
        }
        let entries = history.entries
        let pasteLast = NSMenuItem(title: "Paste Last Dictation",
                                    action: entries.isEmpty ? nil : #selector(pasteLastDictation),
                                    keyEquivalent: "")
        pasteLast.identifier = NSUserInterfaceItemIdentifier("paste-last")
        applyShortcutHint(to: pasteLast, title: "Paste Last Dictation", chord: bindings.pasteLast, formatter: formatter)
        pasteLast.target = target
        menu.addItem(pasteLast)

        let recent = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        if entries.isEmpty {
            let none = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            sub.addItem(none)
        } else {
            for entry in entries.prefix(8) {
                let item = NSMenuItem(title: Self.menuTitle(entry.best),
                                       action: #selector(pasteRecent(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = entry.id
                item.toolTip = entry.appName
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let clearTitle = history.pendingEntries.isEmpty ? "Clear Text History"
                : "Clear Saved + Unsaved Text (\(history.pendingEntries.count) unsaved)"
            let clear = NSMenuItem(title: clearTitle, action: #selector(clearHistory), keyEquivalent: "")
            clear.toolTip = "Removes text only. Recording files are managed separately."
            clear.target = target
            sub.addItem(clear)
        }
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(.separator())
    }

    static func addScratchpadItem(to menu: NSMenu, bindings: HotkeyBindings,
                                  formatter: ShortcutDisplayFormatter, target: AnyObject?) {
        let item = NSMenuItem(title: "Open Scratchpad", action: #selector(openScratchpad), keyEquivalent: "")
        item.identifier = NSUserInterfaceItemIdentifier("open-scratchpad")
        item.target = target
        applyShortcutHint(to: item, title: "Open Scratchpad", chord: bindings.openScratchpad, formatter: formatter)
        menu.addItem(item)
    }

    static func observeShortcutHints(in menu: NSMenu, labels: ShortcutLabels, store: SettingsStore) -> AnyCancellable {
        labels.$revision.dropFirst().sink { [weak menu, weak labels] _ in
            guard let menu, let labels else { return }
            refreshShortcutHints(in: menu, bindings: store.load().hotkeys, formatter: labels.formatter)
        }
    }

    /// Refresh the already visible menu without rebuilding history, permissions
    /// or actions. Read bindings at invocation, just like menuNeedsUpdate.
    static func refreshShortcutHints(in menu: NSMenu, bindings: HotkeyBindings,
                                     formatter: ShortcutDisplayFormatter) {
        for item in menu.items {
            switch item.identifier?.rawValue {
            case "open-scratchpad":
                applyShortcutHint(to: item, title: "Open Scratchpad", chord: bindings.openScratchpad, formatter: formatter)
            case "paste-last":
                applyShortcutHint(to: item, title: "Paste Last Dictation", chord: bindings.pasteLast, formatter: formatter)
            default: break
            }
        }
    }

    private static func applyShortcutHint(to item: NSMenuItem, title: String, chord: KeyChord,
                                          formatter: ShortcutDisplayFormatter) {
        item.title = "\(title)    \(formatter.display(chord))"
        // A title hint, never a localized character dispatcher. The event tap
        // remains the sole dispatcher for these global physical shortcuts.
        item.keyEquivalent = ""
        item.keyEquivalentModifierMask = []
    }

    /// First non-empty line of `text`, capped ~40 chars with an ellipsis.
    static func menuTitle(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > 40 ? String(line.prefix(40)) + "…" : line
    }

    @objc func pasteLastDictation() {
        guard let best = history.entries.first?.best else { return }
        insertFromMenu(best)
    }

    @objc func pasteRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = history.entries.first(where: { $0.id == id }) else { return }
        insertFromMenu(entry.best)
    }

    @objc func clearHistory() { hubModel.clearHistory(); showIdle() }
    @objc func openHistory() { hubModel.requestedPage = .history; hubController.show() }

    /// SMAppService registration only works from the installed .app bundle
    /// (Info.plist + code signature). ponytail: running via `swift run` still
    /// shows the toggle, it'll just log-and-HUD the thrown error instead of
    /// crashing — fine for dev, real usage is always the bundled app.
    @objc func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("%@", "Parla: launch-at-login toggle failed: \(error)")
            hud.show(.error("Launch at Login failed"))
        }
    }

    /// Menu actions fire once the menu has dismissed, but focus handoff back to
    /// the previous app can lag the click — typing too early hits nothing.
    /// Delay a beat; worst case the text is still in history to retry.
    private func insertFromMenu(_ text: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { self.insertStoredText(text) }
    }

    /// "Microphone" submenu: "System Default" + each input device, a checkmark
    /// on the current selection. Empty representedObject ⇒ clear to default.
    private func addMicrophoneItem(to menu: NSMenu) {
        let selected = store.load().inputDeviceUID
        let mic = NSMenuItem(title: "Microphone", action: nil, keyEquivalent: "")
        let sub = NSMenu()

        let def = NSMenuItem(title: "System Default", action: #selector(selectMicrophone(_:)), keyEquivalent: "")
        def.target = self
        def.representedObject = ""
        def.state = selected == nil ? .on : .off
        sub.addItem(def)
        sub.addItem(.separator())

        for device in AudioRecorder.availableInputs() {
            let item = NSMenuItem(title: device.name, action: #selector(selectMicrophone(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = device.uid
            item.state = device.uid == selected ? .on : .off
            sub.addItem(item)
        }
        mic.submenu = sub
        menu.addItem(mic)
    }

    @objc func selectMicrophone(_ sender: NSMenuItem) {
        guard store.lastError == nil else { return } // never clobber a file being hand-fixed
        let uid = sender.representedObject as? String
        var s = store.load()
        s.inputDeviceUID = (uid?.isEmpty ?? true) ? nil : uid
        try? store.save(s)
        recorder.inputDeviceUID = s.inputDeviceUID
        // Warm the new mic, if the user asked for a warm mic at all. A warm engine
        // still running on the OLD one is left alone (see AudioRecorder.setWarm());
        // start() rebinds it, so the first press after a mic switch is cold but
        // correct — accepted over a rebind here, which would tear the tap down
        // mid-capture when hands-free is latched. The real win is switching away
        // from a gated Bluetooth mic: the engine is idle then, so this warms the
        // new one immediately.
        recorder.setWarm(s.warmMic)
    }

    private func permissionItem(name: String, pane: String) -> NSMenuItem {
        let item = NSMenuItem(title: "⚠️ \(name): not granted — click to open settings",
                               action: #selector(openPrivacyPane(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = pane
        return item
    }
}

extension AppDelegate {
    static func addClipboardRestoreStatus(to menu: NSMenu, failed: Bool) {
        guard failed else { return }
        let item = NSMenuItem(title: "Clipboard restore unresolved — original retained; restart blocked", action: nil, keyEquivalent: "")
        item.isEnabled = false; menu.addItem(item)
    }
}
