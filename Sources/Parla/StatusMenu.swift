import AppKit
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
        let scratchItem = NSMenuItem(title: "Open Scratchpad", action: #selector(openScratchpad), keyEquivalent: "s")
        // Display only — the global ⌃⌘S lives in HotkeyMonitor (swallowed there).
        scratchItem.keyEquivalentModifierMask = [.control, .command]
        scratchItem.target = self
        menu.addItem(scratchItem)
        menu.addItem(.separator())

        if let update = availableUpdate {
            let item = NSMenuItem(title: "Update available (\(update.version))…",
                                   action: #selector(openUpdate), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        if !modelReady {
            if let downloading = hubModel.downloadingModel {
                let item = NSMenuItem(title: "Downloading \(downloading.displayName)…", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            } else {
                let m = ModelCatalog.default
                let item = NSMenuItem(title: "Download model (\(m.displayName), \(m.sizeLabel))",
                                       action: #selector(downloadModel), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        if let error = store.lastError {
            let item = NSMenuItem(title: "⚠️ settings.json invalid — click to open",
                                   action: #selector(openSettings), keyEquivalent: "")
            item.target = self
            item.toolTip = error
            menu.addItem(item)
            menu.addItem(.separator())
        }

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

        let report = NSMenuItem(title: "Report a Bug or Feature…", action: #selector(reportIssue), keyEquivalent: "")
        report.target = self
        menu.addItem(report)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "Quit Parla", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        showIdle() // menu open is a free moment to reconcile the icon too
    }

    /// "Paste Last Dictation" + a "Recent" submenu (up to 8, newest first) with
    /// a "Clear History" action. Nil action ⇒ auto-disabled when empty.
    private func addHistoryItems(to menu: NSMenu) {
        let entries = history.entries
        let pasteLast = NSMenuItem(title: "Paste Last Dictation",
                                    action: entries.isEmpty ? nil : #selector(pasteLastDictation),
                                    keyEquivalent: "v")
        // Display only — the global ⌃⌘V lives in HotkeyMonitor (and is swallowed
        // there before any menu could see it).
        pasteLast.keyEquivalentModifierMask = [.control, .command]
        pasteLast.target = self
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
                item.target = self
                item.representedObject = entry.best
                item.toolTip = entry.appName
                sub.addItem(item)
            }
            sub.addItem(.separator())
            let clear = NSMenuItem(title: "Clear History", action: #selector(clearHistory), keyEquivalent: "")
            clear.target = self
            sub.addItem(clear)
        }
        recent.submenu = sub
        menu.addItem(recent)
        menu.addItem(.separator())
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
        guard let text = sender.representedObject as? String else { return }
        insertFromMenu(text)
    }

    @objc func clearHistory() { history.clear() }

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
        // Warm the new mic. A warm engine still running on the OLD one is left
        // alone (see AudioRecorder.prepare()); start() rebinds it, so the first
        // press after a mic switch is cold but correct — accepted over a rebind
        // here, which would tear the tap down mid-capture when hands-free is
        // latched. The real win is switching away from a gated Bluetooth mic:
        // the engine is idle then, so this warms the new one immediately.
        recorder.prepare()
    }

    private func permissionItem(name: String, pane: String) -> NSMenuItem {
        let item = NSMenuItem(title: "⚠️ \(name): not granted — click to open settings",
                               action: #selector(openPrivacyPane(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = pane
        return item
    }
}
