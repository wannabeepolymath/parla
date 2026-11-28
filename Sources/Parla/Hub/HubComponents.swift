import ParlaCore
import SwiftUI

/// One spacing grid for every Hub page: 4-pt based, a single content column,
/// one row inset and one trailing-control width so right edges line up.
enum HubLayout {
    static let pageInset: CGFloat = 32
    static let pageTop: CGFloat = 32
    static let columnWidth: CGFloat = 680   // incl. page insets
    static let sectionSpacing: CGFloat = 24
    static let rowInset: CGFloat = 14
    static let controlWidth: CGFloat = 220  // popups and text fields in rows
}

// MARK: - Page

/// Title + one-line subtitle used by every page (Meetings included).
struct HubPageHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Theme.text)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    /// The page column: fixed insets, capped width, pinned to the leading edge.
    func hubColumn(top: CGFloat = HubLayout.pageTop, bottom: CGFloat = HubLayout.pageInset) -> some View {
        self.padding(.horizontal, HubLayout.pageInset)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .frame(maxWidth: HubLayout.columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Sections and rows

/// Section: heading (with an optional trailing accessory such as "Add"),
/// one rounded card, optional footnote.
struct HubSection<Content: View, Accessory: View>: View {
    let title: String?
    let caption: String?
    let footer: String?
    let accessory: Accessory
    let content: Content

    init(_ title: String?, caption: String? = nil, footer: String? = nil,
         @ViewBuilder accessory: () -> Accessory,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.caption = caption
        self.footer = footer
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || Accessory.self != EmptyView.self {
                HStack(alignment: .lastTextBaseline) {
                    Text(title ?? "")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    accessory
                }
                .frame(minHeight: 22)
            }
            if let caption {
                Text(caption)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, -4)
            }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .hubCard()
            if let footer {
                Text(footer)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension HubSection where Accessory == EmptyView {
    init(_ title: String?, caption: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title, caption: caption, footer: footer, accessory: { EmptyView() }, content: content)
    }
}

extension View {
    func hubCard() -> some View {
        self.background(Theme.card)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.border))
    }
    /// Free-form content inside a card gets the same inset as a row.
    func hubInset() -> some View {
        self.padding(.horizontal, HubLayout.rowInset).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Label + optional description on the left, the control trailing.
struct HubRow<Control: View>: View {
    let label: String
    let detail: String?
    var detailColor: Color = Theme.muted
    let control: Control
    @Environment(\.isEnabled) private var enabled

    init(_ label: String, detail: String? = nil, detailColor: Color = Theme.muted,
         @ViewBuilder control: () -> Control) {
        self.label = label
        self.detail = detail
        self.detailColor = detailColor
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 12))
                        .foregroundStyle(detailColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(enabled ? 1 : 0.45) // labels dim with their controls, like native forms
            control
        }
        .padding(.horizontal, HubLayout.rowInset)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

extension HubRow where Control == EmptyView {
    init(_ label: String, detail: String? = nil) {
        self.init(label, detail: detail) { EmptyView() }
    }
}

/// A switch row. The label doubles as the switch's accessibility label.
struct HubToggleRow: View {
    let label: String
    var detail: String? = nil
    @Binding var isOn: Bool

    init(_ label: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.label = label; self.detail = detail; _isOn = isOn
    }

    var body: some View {
        HubRow(label, detail: detail) {
            Toggle(label, isOn: $isOn).toggleStyle(.switch).labelsHidden()
        }
    }
}

/// A row that expands more rows beneath it, with an optional one-line summary.
struct HubDisclosureRow: View {
    let title: String
    var summary: String? = nil
    @Binding var isExpanded: Bool

    var body: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() } } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(Theme.muted)
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.text)
                Spacer(minLength: 12)
                if let summary, !isExpanded {
                    Text(summary).font(.system(size: 12)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            .padding(.horizontal, HubLayout.rowInset)
            .frame(minHeight: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

/// Read-only trailing value.
struct HubValue: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Theme.muted)
            .multilineTextAlignment(.trailing)
            .textSelection(.enabled)
    }
}

struct HubDivider: View {
    var body: some View {
        Rectangle().fill(Theme.border).frame(height: 1).padding(.leading, HubLayout.rowInset)
    }
}

extension View {
    /// Popup or text field in a row: one fixed width so trailing edges align.
    func hubControl(_ width: CGFloat = HubLayout.controlWidth) -> some View {
        self.labelsHidden().frame(width: width, alignment: .trailing)
    }
}

// MARK: - Buttons

/// Three roles. Primary: at most one per surface. Normal: everything else.
/// Danger: destructive actions that need a confirmation step.
struct HubButtonStyle: ButtonStyle {
    enum Kind { case primary, normal, danger }
    var kind: Kind = .normal

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, kind: kind)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let kind: Kind
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: kind == .primary ? .semibold : .regular))
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 11)
                .frame(minHeight: 24)
                .foregroundStyle(kind == .primary ? Theme.onAccent : kind == .danger ? Theme.danger : Theme.text)
                .background(RoundedRectangle(cornerRadius: 6)
                    .fill(kind == .primary ? Theme.accent : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(kind == .primary ? .clear : kind == .danger ? Theme.danger.opacity(0.45) : Theme.control))
                .shadow(color: .black.opacity(kind == .primary ? 0 : 0.04), radius: 0.5, y: 0.5)
                .opacity(enabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Icon-only button: always labelled for VoiceOver and with a tooltip.
struct HubIconButton: View {
    let systemName: String
    let label: String
    var tint: Color = Theme.muted
    let action: () -> Void

    init(_ systemName: String, label: String, tint: Color = Theme.muted, action: @escaping () -> Void) {
        self.systemName = systemName; self.label = label; self.tint = tint; self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(IconPress())
        .help(label)
        .accessibilityLabel(label)
    }

    private struct IconPress: ButtonStyle {
        @Environment(\.isEnabled) private var enabled
        func makeBody(configuration: Configuration) -> some View {
            configuration.label
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.border.opacity(configuration.isPressed ? 1 : 0)))
                .opacity(enabled ? 1 : 0.3)
        }
    }
}

/// "…" menu for secondary row actions.
struct HubMoreMenu<Content: View>: View {
    var label = "More actions"
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis.circle")
                .font(.system(size: 14))
                .foregroundStyle(Theme.muted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .tint(Theme.muted)
        .fixedSize()
        .frame(width: 24, height: 24)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Section-header "+ Add …" action.
struct HubAddButton: View {
    let title: String
    let action: () -> Void
    init(_ title: String, action: @escaping () -> Void) { self.title = title; self.action = action }
    var body: some View {
        Button(action: action) { Label(title, systemImage: "plus") }
            .buttonStyle(HubButtonStyle())
    }
}

// MARK: - Status

/// Colored-dot status capsule (Granted / In use / …).
struct StatusChip: View {
    let text: String
    var color: Color = Theme.success

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.text)
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(Capsule().fill(color.opacity(0.14)))
        .fixedSize()
    }
}

/// Read-only keyboard shortcut keycap, the same size as the editable one.
struct ShortcutPill: View {
    let text: String

    var body: some View {
        Text(keycapText(text))
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .frame(minWidth: 44, minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.border))
            .fixedSize()
    }
}

/// Inline notice. Danger for things that stop Parla working, warning for
/// degraded states. Long technical text goes behind "Details".
struct HubBanner: View {
    enum Kind { case danger, warning }
    let text: String
    var detail: String? = nil
    var kind: Kind = .danger
    var actionTitle: String? = nil
    var actionKind: HubButtonStyle.Kind = .normal
    var secondaryTitle: String? = nil
    var secondaryAction: () -> Void = {}
    var destructiveTitle: String? = nil
    var destructiveAction: () -> Void = {}
    var action: () -> Void = {}
    @State private var showDetail = false

    private var color: Color { kind == .danger ? Theme.danger : Theme.warning }

    /// Several actions or details get their own row so the message isn't squeezed.
    private var stacked: Bool { detail != nil || secondaryTitle != nil || destructiveTitle != nil }

    @ViewBuilder private var actions: some View {
        if detail != nil {
            Button(showDetail ? "Hide Details" : "Show Details") { showDetail.toggle() }
                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.accent)
        }
        if stacked { Spacer(minLength: 8) }
        if let destructiveTitle {
            Button(destructiveTitle, action: destructiveAction).buttonStyle(HubButtonStyle(kind: .danger))
        }
        if let secondaryTitle {
            Button(secondaryTitle, action: secondaryAction).buttonStyle(HubButtonStyle())
        }
        if let actionTitle {
            Button(actionTitle, action: action).buttonStyle(HubButtonStyle(kind: actionKind))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: stacked ? .firstTextBaseline : .center, spacing: 8) {
                Image(systemName: kind == .danger ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(color)
                    .accessibilityHidden(true)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !stacked { actions }
            }
            if showDetail, let detail {
                Text(detail)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 22)
            }
            if stacked {
                HStack(spacing: 8) { actions }.padding(.leading, 22)
            }
        }
        .padding(.leading, 12).padding(.trailing, HubLayout.rowInset).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(color.opacity(0.3)))
    }
}

/// Quiet one-line status under a control (save results, "Key updated." …).
struct HubNote: View {
    let text: String
    var warning = false
    init(_ text: String, warning: Bool = false) { self.text = text; self.warning = warning }
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: warning ? "exclamationmark.triangle.fill" : "info.circle")
                .foregroundStyle(warning ? Theme.warning : Theme.muted)
        }
        .font(.system(size: 12))
        .foregroundStyle(warning ? Theme.text : Theme.muted)
        .textSelection(.enabled)
    }
}

/// Centered placeholder for empty lists, with an optional hint.
struct EmptyHint: View {
    let text: String
    var detail: String? = nil

    var body: some View {
        VStack(spacing: 4) {
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text)
            if let detail {
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, HubLayout.rowInset)
    }
}

/// Horizontal input-level meter. Empty track at rest.
struct LevelMeter: View {
    let level: Float
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.border)
                if level > 0.005 {
                    Capsule().fill(Theme.accent)
                        .frame(width: max(6, geo.size.width * CGFloat(min(1, level))))
                }
            }
        }
        .frame(height: 6)
        .accessibilityElement()
        .accessibilityLabel("Input level")
        .accessibilityValue("\(Int(level * 100)) percent")
    }
}

// MARK: - Sheets

/// Title, content, and right-aligned Cancel / confirm in HIG order.
struct HubSheet<Content: View, Actions: View>: View {
    let title: String
    var width: CGFloat = 520
    @ViewBuilder let content: () -> Content
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(Theme.text)
            content()
            HStack(spacing: 8) { actions() }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(24)
        .frame(width: width)
        .background(Theme.bg)
        .tint(Theme.accent)
    }
}

// MARK: - Fields

extension View {
    /// Themed text-field chrome (use with TextField/SecureField).
    func hubField() -> some View {
        self.textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 4) // multi-line fields keep the same inset as single-line ones
            .frame(minHeight: 24)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.control))
            .modifier(DimWhenDisabled())
    }

    /// Bordered multi-line editor matching hubField.
    func hubEditor(monospaced: Bool = false) -> some View {
        self.font(.system(size: 13, design: monospaced ? .monospaced : .default))
            .scrollContentBackground(.hidden)
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.control))
    }
}

/// Bridges an optional-String setting to a TextField: "" <-> nil.
func optBinding(_ source: Binding<String?>) -> Binding<String> {
    Binding(get: { source.wrappedValue ?? "" },
            set: { source.wrappedValue = $0.isEmpty ? nil : $0 })
}

// MARK: - Display names

/// "Shure MV7", or "MacBook Pro Microphone (system default)" — never just "System default".
func microphoneDisplayName(uid: String?) -> String {
    if let uid, !uid.isEmpty {
        return AudioRecorder.availableInputs().first { $0.uid == uid }?.name ?? "Disconnected microphone"
    }
    return AudioRecorder.defaultInputName().map { "\($0) (system default)" } ?? "System default"
}

/// Human name for a locale identifier: "English (United States)".
func localeDisplayName(_ identifier: String) -> String {
    Locale.current.localizedString(forIdentifier: identifier) ?? identifier
}

/// Custom-drawn controls don't dim on their own; this matches native disabled controls.
struct DimWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    func body(content: Content) -> some View { content.opacity(enabled ? 1 : 0.45) }
}

// MARK: - Shared row controls

/// Microphone choice, identical on General, Meetings and Microphone Test.
struct MicrophonePicker: View {
    @Binding var selection: String?
    var body: some View {
        Picker("Microphone", selection: optBinding($selection)) {
            Text("System default").tag("")
            Divider()
            ForEach(Self.options(selected: selection), id: \.uid) { Text($0.name).tag($0.uid) }
        }
        .hubControl()
    }
    /// Live input devices, plus the saved device if it's currently unplugged —
    /// so the picker still shows the user's choice instead of blanking.
    static func options(selected uid: String?) -> [AudioRecorder.InputDevice] {
        var devices = AudioRecorder.availableInputs()
        if let uid, !uid.isEmpty, !devices.contains(where: { $0.uid == uid }) {
            devices.append(.init(uid: uid, name: "Disconnected device"))
        }
        return devices
    }
    /// "Using MacBook Air Microphone" when following the system default.
    static func detail(for uid: String?) -> String? {
        (uid ?? "").isEmpty ? AudioRecorder.defaultInputName().map { "Using \($0)" } : nil
    }
}

/// One popup for what dictation types: original text, cleaned-up text, or a preset.
/// Lives in AI Cleanup; presets appear here so a preset can rewrite every dictation.
struct DictationOutputPicker: View {
    @ObservedObject var model: HubModel
    private enum Choice: Hashable { case raw, cleanup, preset(UUID), noPreset }

    private var selection: Binding<Choice> {
        Binding(get: {
            switch model.settings.outputMode {
            case .raw: return .raw
            case .cleanup: return .cleanup
            case .selectedPreset: return model.settings.selectedPresetID.map(Choice.preset) ?? .noPreset
            }
        }, set: { choice in
            switch choice {
            case .raw: model.settings.outputMode = .raw
            case .cleanup: model.settings.outputMode = .cleanup
            case .preset(let id): model.selectPreset(id); model.settings.outputMode = .selectedPreset
            case .noPreset: break
            }
        })
    }

    var body: some View {
        Picker("Dictation output", selection: selection) {
            Text("Original text").tag(Choice.raw)
            Text("Cleaned up").tag(Choice.cleanup)
            if !model.settings.transformPresets.isEmpty || model.settings.outputMode == .selectedPreset { Divider() }
            ForEach(model.settings.transformPresets) { Text($0.name).tag(Choice.preset($0.id)) }
            if model.settings.outputMode == .selectedPreset, let id = model.settings.selectedPresetID,
               !model.settings.transformPresets.contains(where: { $0.id == id }) {
                Text("Missing preset — choose another").tag(Choice.preset(id))
            }
            if model.settings.outputMode == .selectedPreset, model.settings.selectedPresetID == nil {
                Text("Preset (none chosen)").tag(Choice.noPreset)
            }
        }
        .hubControl()
    }
}

/// Secondary row actions (trash, ⋯) appear on hover so lists stay calm; the
/// same actions are always in the row's context menu.
struct HoverReveal: ViewModifier {
    let hovering: Bool
    func body(content: Content) -> some View {
        content.opacity(hovering ? 1 : 0).animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// Keycap text in Mac notation: "⌃⌥R", not "^⌥r".
func keycapText(_ display: String) -> String {
    display.replacingOccurrences(of: "^", with: "⌃")
        .split(separator: " ", omittingEmptySubsequences: false)
        .map { token -> String in
            guard let last = token.last, last.isLetter, last.isLowercase,
                  token.dropLast().allSatisfy({ !$0.isLetter }) else { return String(token) }
            return token.dropLast() + String(last).uppercased()
        }
        .joined(separator: " ")
}
