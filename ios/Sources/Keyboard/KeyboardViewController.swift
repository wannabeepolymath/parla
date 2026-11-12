import UIKit

final class KeyboardViewController: UIInputViewController {
    private let root = UIStackView()
    private let panel = UIStackView()
    private let keys = UIStackView()
    private let status = UILabel()
    private let detail = UILabel()
    private let transcript = UITextView()
    private let actions = UIStackView()
    private var timer: Timer?
    private var deleteTimer: Timer?
    private let instanceID = UUID()
    private var requestID: UUID?
    private var generation: UUID?
    private var currentSession: DictationSession?
    private var voice = false
    private var waveform: UIView {
        let stack = UIStackView(); stack.axis = .horizontal; stack.alignment = .center; stack.spacing = 5
        for height in [10, 16, 24, 34, 22, 42, 28, 18, 30, 12] {
            let bar = UIView(); bar.backgroundColor = UIColor(named: "keyboardText"); bar.layer.cornerRadius = 2.5
            bar.widthAnchor.constraint(equalToConstant: 5).isActive = true
            bar.heightAnchor.constraint(equalToConstant: CGFloat(height)).isActive = true; stack.addArrangedSubview(bar)
        }
        let container = UIView(); stack.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo: container.centerXAnchor), stack.centerYAnchor.constraint(equalTo: container.centerYAnchor), container.heightAnchor.constraint(equalToConstant: 72)])
        container.accessibilityLabel = "Recording active"
        return container
    }
    private var symbols = false
    private var moreSymbols = false
    private var shift = false
    private var caps = false
    private var lastShift = Date.distantPast
    private var sessionError: String?
    private var lastRender = ""
    private var heightConstraint: NSLayoutConstraint?
    override func viewDidLoad() {
        super.viewDidLoad()
        hasDictationKey = true
        view.backgroundColor = UIColor(named: "keyboardBackground") ?? .systemGray4
        root.axis = .vertical; root.spacing = 8; root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6), root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6), root.topAnchor.constraint(equalTo: view.topAnchor, constant: 8), root.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -6)])
        panel.axis = .vertical; panel.spacing = 10
        keys.axis = .vertical; keys.spacing = 7
        root.addArrangedSubview(panel); root.addArrangedSubview(keys)
        status.font = .systemFont(ofSize: 17, weight: .semibold); status.textAlignment = .center; status.numberOfLines = 2
        detail.font = .systemFont(ofSize: 12); detail.textAlignment = .center; detail.numberOfLines = 4
        transcript.font = .systemFont(ofSize: 16); transcript.isEditable = false; transcript.isSelectable = false
        transcript.backgroundColor = UIColor(named: "keyboardKey"); transcript.layer.cornerRadius = 12
        actions.axis = .horizontal; actions.spacing = 10; actions.distribution = .fillEqually
        render(force: true)
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated); timer?.invalidate(); timer = nil; deleteTimer?.invalidate(); deleteTimer = nil
        transcript.text = nil; currentSession = nil; lastRender = ""
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        // Traits and the public document identifier are used; surrounding/selected text is never read.
        if sensitive {
            if let currentSession, currentSession.id == requestID, currentSession.active { send(.cancel) }
            voice = false
        }
        render(force: true)
    }
    private var sensitive: Bool {
        textDocumentProxy.isSecureTextEntry == true || [.phonePad, .namePhonePad].contains(textDocumentProxy.keyboardType ?? .default) ||
        [UITextContentType.password, .newPassword, .oneTimeCode, .creditCardNumber].contains(textDocumentProxy.textContentType ?? UITextContentType(rawValue: ""))
    }
    private func poll() {
        guard hasFullAccess else { currentSession = nil; render(); return }
        do { currentSession = try SessionStore().read(); sessionError = nil; render() }
        catch { currentSession = nil; sessionError = error.localizedDescription; render() }
    }
    private func button(_ title: String, special: Bool = false, action: @escaping () -> Void) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: title.count == 1 ? 23 : 14)
        button.setTitleColor(UIColor(named: "keyboardKeyTitle") ?? .label, for: .normal)
        button.backgroundColor = UIColor(named: special ? "keyboardKeyDark" : "keyboardKey") ?? .secondarySystemBackground
        button.layer.cornerRadius = 6
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 42).isActive = true
        return button
    }
    private func render(force: Bool = false) {
        let signature = "\(voice)|\(symbols)|\(moreSymbols)|\(shift)|\(caps)|\(hasFullAccess)|\(needsInputModeSwitchKey)|\(textDocumentProxy.documentIdentifier)|\(currentSession?.id.uuidString ?? "")|\(currentSession?.phase.rawValue ?? "")|\(currentSession?.generation.uuidString ?? "")|\(currentSession?.result?.utf8.count ?? 0)|\(currentSession?.result?.hashValue ?? 0)|\(currentSession?.error ?? "")|\(sessionError ?? "")"
        guard force || signature != lastRender else { return }; lastRender = signature
        for stack in [panel, keys, actions] { for child in stack.arrangedSubviews { stack.removeArrangedSubview(child); child.removeFromSuperview() } }
        transcript.text = nil
        if voice { renderVoice() } else { renderTyping() }
        let bottom = UIStackView(); bottom.axis = .horizontal; bottom.spacing = 6; bottom.distribution = .fillProportionally
        let mode = button(voice ? "ABC" : symbols ? "ABC" : "123", special: true) { [weak self] in
            guard let self else { return }; if voice { voice = false } else { symbols.toggle() }; render(force: true)
        }
        bottom.addArrangedSubview(mode)
        // Public keyboard-switch control supports both tapping and the system's press-and-hold list.
        let globe = UIButton(type: .system); globe.setImage(UIImage(systemName: "globe"), for: .normal)
        globe.tintColor = UIColor(named: "keyboardText"); globe.accessibilityLabel = "Next keyboard"
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globe.widthAnchor.constraint(equalToConstant: 44).isActive = true
        if needsInputModeSwitchKey { bottom.addArrangedSubview(globe) }
        let space = button("space") { [weak self] in self?.typeSpace() }; bottom.addArrangedSubview(space)
        space.widthAnchor.constraint(greaterThanOrEqualTo: mode.widthAnchor, multiplier: 2).isActive = true
        let returnTitle: String
        switch textDocumentProxy.returnKeyType ?? .default { case .go: returnTitle = "go"; case .send: returnTitle = "send"; case .search: returnTitle = "search"; case .done: returnTitle = "done"; case .next: returnTitle = "next"; default: returnTitle = "return" }
        bottom.addArrangedSubview(button(returnTitle, special: true) { [weak self] in self?.textDocumentProxy.insertText("\n") })
        let dismiss = button("⌄", special: true) { [weak self] in self?.dismissKeyboard() }; dismiss.accessibilityLabel = "Hide keyboard"; bottom.addArrangedSubview(dismiss)
        keys.addArrangedSubview(bottom)
        heightConstraint?.isActive = false
        let constraint = view.heightAnchor.constraint(equalToConstant: voice ? 350 : 292); constraint.priority = .defaultHigh
        constraint.isActive = true; heightConstraint = constraint
    }
    private func renderTyping() {
        let header = UIStackView(); header.axis = .horizontal; header.distribution = .fill; header.spacing = 10
        let brand = UILabel(); brand.text = "Parla"; brand.font = UIFont(name: "Manrope-ExtraLight", size: 20) ?? .systemFont(ofSize: 20, weight: .bold)
        brand.textColor = UIColor(named: "keyboardText")
        header.addArrangedSubview(brand)
        let mic = button("●  Dictate", special: true) { [weak self] in self?.voice = true; self?.render(force: true) }
        mic.accessibilityLabel = "Voice dictation"; header.addArrangedSubview(mic)
        panel.addArrangedSubview(header)
        let rows: [[String]] = symbols ? (moreSymbols ? [Array("[]{}#%^*+=" ).map(String.init), Array("_\\|~<>€£¥•").map(String.init), [".", ",", "?", "!", "'"]] : [Array("1234567890").map(String.init), ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""], [".", ",", "?", "!", "'"]]) : [Array("qwertyuiop").map(String.init), Array("asdfghjkl").map(String.init), Array("zxcvbnm").map(String.init)]
        for (index, letters) in rows.enumerated() {
            let row = UIStackView(); row.axis = .horizontal; row.spacing = 5; row.distribution = .fillEqually
            if index == 2 {
                row.addArrangedSubview(button(symbols ? (moreSymbols ? "123" : "#+=") : (caps ? "⇪" : "⇧"), special: true) { [weak self] in
                    guard let self else { return }
                    if symbols { moreSymbols.toggle() }
                    else { if Date().timeIntervalSince(lastShift) < 0.35 { caps.toggle(); shift = caps } else { caps = false; shift.toggle() }; lastShift = Date() }
                    render(force: true)
                })
            }
            for letter in letters {
                let text = (shift || caps) && !symbols ? letter.uppercased() : letter
                row.addArrangedSubview(button(text) { [weak self] in
                    guard let self else { return }; textDocumentProxy.insertText(text)
                    if shift && !caps { shift = false; render(force: true) }
                })
            }
            if index == 2 {
                let delete = button("⌫", special: true) { [weak self] in self?.textDocumentProxy.deleteBackward() }
                delete.accessibilityLabel = "Delete"; delete.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(deleteHeld(_:))))
                row.addArrangedSubview(delete)
            }
            keys.addArrangedSubview(row)
        }
        if [.emailAddress, .URL, .webSearch].contains(textDocumentProxy.keyboardType ?? .default) {
            let row = UIStackView(); row.spacing = 5; row.distribution = .fillEqually
            for text in ["@", ".", "/", ".com"] { row.addArrangedSubview(button(text) { [weak self] in self?.textDocumentProxy.insertText(text) }) }; keys.addArrangedSubview(row)
        }
    }
    private func renderVoice() {
        panel.addArrangedSubview(status); panel.addArrangedSubview(detail)
        status.textColor = UIColor(named: "keyboardText"); detail.textColor = UIColor(named: "keyboardText")
        if sensitive {
            status.text = "Use Apple’s keyboard for this field"; detail.text = "Voice handoff is unavailable for sensitive input."; return
        }
        guard hasFullAccess else {
            status.text = "Allow Full Access for voice"
            detail.text = "Open iPhone Settings → General → Keyboard → Keyboards → Parla. Typing works without Full Access."
            return
        }
        if let session = currentSession, session.id == requestID, session.keyboardInstance == instanceID {
            switch session.phase {
            case .requested:
                status.text = "Open Parla to start"
                detail.text = "Open Parla manually, tap Start microphone, then return here. No automatic app switch or return is promised."
                addAction("Cancel") { [weak self] in self?.send(.cancel) }
            case .recording:
                panel.insertArrangedSubview(waveform, at: 0)
                status.text = "Listening"
                detail.text = "Parla owns the microphone · Up to 5 minutes"
                addAction("Cancel") { [weak self] in self?.send(.cancel) }
                addAction("✓ Stop") { [weak self] in self?.send(.stop) }
            case .processing:
                status.text = "Transcribing on iPhone…"; detail.text = "Waiting for the app. If it was suspended, open Parla."
                let progress = UIActivityIndicatorView(style: .medium); progress.startAnimating(); panel.addArrangedSubview(progress)
                addAction("Cancel") { [weak self] in self?.send(.cancel) }
            case .completed:
                guard session.result != nil else {
                    status.text = "Text is ready in Parla"; detail.text = session.error ?? "Open Parla and copy from the app."
                    addAction("Discard") { [weak self] in self?.discard() }
                    panel.addArrangedSubview(actions); return
                }
                status.text = "Review your dictation"
                let sameDocument = session.documentID == textDocumentProxy.documentIdentifier
                detail.text = sameDocument ? "Check the text and cursor. Insert adds text at your current selection." : "The field identity changed. Cancel and request dictation again from this field."
                transcript.text = session.result; transcript.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true; panel.addArrangedSubview(transcript)
                addAction("Discard") { [weak self] in self?.discard() }
                if sameDocument { addAction("Insert once") { [weak self] in self?.insertReviewed() } }
            case .failed:
                status.text = "Dictation could not complete"; detail.text = session.error ?? "Open Parla to check the recording."
                addAction("New attempt") { [weak self] in self?.request() }
                addAction("Discard") { [weak self] in self?.discard() }
            case .cancelled, .consumed:
                status.text = session.phase == .consumed ? "Inserted" : "Dictation cancelled or expired"
                detail.text = "No text will be inserted automatically."
                addAction("New dictation") { [weak self] in self?.request() }
            }
        } else if let session = currentSession, session.active {
            status.text = "Another session is active"
            detail.text = "Open Parla to manage it, or cancel it here. This keyboard will not insert another request’s text."
            addAction("Cancel session") { [weak self] in self?.send(.cancel, session: session) }
        } else {
            status.text = "Think it. Speak it."
            detail.text = sessionError ?? "Request dictation, then open Parla manually to activate the microphone. Return here to stop and review."
            addAction("Request dictation") { [weak self] in self?.request() }
        }
        panel.addArrangedSubview(actions)
    }
    private func addAction(_ title: String, action: @escaping () -> Void) { actions.addArrangedSubview(button(title, special: true, action: action)) }
    private func request() {
        guard hasFullAccess, !sensitive else { return }
        do {
            let session = try SessionStore().request(destination: .keyboard, document: textDocumentProxy.documentIdentifier, instance: instanceID)
            requestID = session.id; generation = session.generation; currentSession = session; sessionError = nil; render(force: true)
        } catch { sessionError = error.localizedDescription; render(force: true) }
    }
    private func send(_ command: SessionCommand, session: DictationSession? = nil) {
        guard hasFullAccess, let current = session ?? currentSession else { return }
        do { try SessionStore().command(command, id: current.id, generation: current.generation); poll() }
        catch { sessionError = error.localizedDescription; render(force: true) }
    }
    private func discard() {
        guard let session = currentSession else { return }
        do { try SessionStore().update(id: session.id, generation: session.generation) { $0.phase = .cancelled; $0.result = nil }; poll() }
        catch { sessionError = error.localizedDescription; render(force: true) }
    }
    private func insertReviewed() {
        guard hasFullAccess, let requestID else { return }
        do {
            if let text = try SessionStore().consume(request: requestID, instance: instanceID,
                document: textDocumentProxy.documentIdentifier, sensitive: sensitive, reviewed: true) {
                textDocumentProxy.insertText(text)
            } else { sessionError = "The request expired or field changed. Start a new dictation." }
            poll()
        } catch { sessionError = error.localizedDescription; render(force: true) }
    }
    private func typeSpace() {
        // No preceding-text inspection or automatic deletion. Double-space simply inserts spaces.
        textDocumentProxy.insertText(" ")
    }
    @objc private func deleteHeld(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            deleteTimer?.invalidate(); textDocumentProxy.deleteBackward()
            deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in self?.textDocumentProxy.deleteBackward() }
        } else if [.ended, .cancelled, .failed].contains(gesture.state) { deleteTimer?.invalidate(); deleteTimer = nil }
    }
}
