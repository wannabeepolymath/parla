import Foundation

/// What kind of destination the text is landing in. Drives both the cleanup
/// prompt's tone hint (`PromptBuilder`) and the newline-flatten rule below.
/// `.unknown` is a real answer, not a fallback failure: unrecognized apps and
/// browser hosts get no tone sentence. Recognized email sites get email structure.
public enum AppCategory {
    case terminal, code, chat, email, prose, unknown
}

/// Pure safety rules for what/where dictated text may land. AppKit wiring
/// (focus, frontmost app, insertion) lives in Sources/Parla; this is the
/// decision logic so it stays unit-testable.
public enum TextRules {
    /// Bundle ID -> category, matched EXACTLY. Never by substring: "word" is
    /// inside "com.agilebits.onepassword7" and "code" is inside every barcode
    /// scanner, which is how voicetypr filed 1Password as a documents app.
    static let appCategories: [String: AppCategory] = [
        // Terminals: a bare newline SUBMITS, so each line would run as a command.
        // (Warp is in appCategoryPrefixes — it has no bare bundle ID.)
        "com.apple.Terminal": .terminal, "com.googlecode.iterm2": .terminal,
        "com.github.wez.wezterm": .terminal, "net.kovidgoyal.kitty": .terminal,
        "com.mitchellh.ghostty": .terminal, "org.alacritty": .terminal,
        "co.zeit.hyper": .terminal,
        // Chat: Return sends the message, so newlines are just as destructive.
        "com.tinyspeck.slackmacgap": .chat, "com.hnc.Discord": .chat,
        "com.apple.MobileSMS": .chat, "net.whatsapp.WhatsApp": .chat,
        "ru.keepcoder.Telegram": .chat, "org.telegram.desktop": .chat,
        // Editors (see appCategoryPrefixes for VS Code and JetBrains).
        "com.apple.dt.Xcode": .code, "dev.zed.Zed": .code,
        "com.sublimetext.4": .code, "com.panic.Nova": .code,
        "com.todesktop.230313mzl4w4u92": .code,  // Cursor; todesktop is a generic
                                                 // wrapper vendor, so no prefix.
        // Mail and long-form writing.
        "com.apple.mail": .email, "com.microsoft.Outlook": .email,
        "com.readdle.smartemail-Mac": .email, "com.superhuman.desktop": .email,
        "com.apple.Notes": .prose,
        "com.apple.TextEdit": .prose, "com.apple.iWork.Pages": .prose,
        "com.microsoft.Word": .prose, "notion.id": .prose, "md.obsidian": .prose,
        "com.openai.chat": .prose, "com.openai.chatgpt": .prose,
    ]

    /// Prefixes are allowed ONLY where a vendor namespaces a whole product
    /// family: every `com.jetbrains.*` is an IDE, VS Code ships as `.VSCode`,
    /// `.VSCodeInsiders`, `.VSCodeExploration`, and Warp ships one bundle per
    /// release channel — `dev.warp.Warp-Stable`, `dev.warp.Warp-Preview` — with
    /// no bare `dev.warp.Warp` to match exactly. Note the VS Code prefix stops
    /// at the product, not at `com.microsoft.` — Word and Outlook live in that
    /// namespace and are prose. Still ANCHORED, so the no-substring rule holds.
    static let appCategoryPrefixes: [(String, AppCategory)] = [
        ("com.microsoft.VSCode", .code),
        ("com.jetbrains.", .code),
        ("dev.warp.Warp", .terminal),
    ]

    public static func isBrowser(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
                "com.google.Chrome.canary", "com.google.Chrome.beta", "com.google.Chrome.dev",
                "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
                "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
                "company.thebrowser.Browser", "company.thebrowser.dia", "org.mozilla.firefox",
                "org.mozilla.nightly", "com.vivaldi.Vivaldi", "com.operasoftware.Opera"].contains(bundleID)
    }

    public static func category(bundleID: String?, browserURL: String? = nil) -> AppCategory {
        guard let bundleID else { return .unknown }
        // Parse the host, never search arbitrary titles/URLs for "mail". The URL
        // stays local; only this fixed category reaches the cleanup provider.
        if isBrowser(bundleID: bundleID), let browserURL,
           let url = URL(string: browserURL), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
           let host = url.host?.lowercased() {
            if ["mail.google.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com",
                "mail.proton.me", "mail.protonmail.com", "app.superhuman.com", "mail.yahoo.com",
                "app.fastmail.com"].contains(host)
                || (["www.icloud.com", "icloud.com"].contains(host)
                    && (url.path == "/mail" || url.path.hasPrefix("/mail/"))) { return .email }
            if ["app.slack.com", "discord.com", "web.whatsapp.com", "web.telegram.org",
                "chat.google.com", "teams.microsoft.com", "teams.cloud.microsoft"].contains(host) { return .chat }
            if ["chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com"].contains(host) { return .prose }
        }
        if let exact = appCategories[bundleID] { return exact }
        for (prefix, category) in appCategoryPrefixes where bundleID.hasPrefix(prefix) {
            return category
        }
        return .unknown
    }

    /// Terminals run each line; chat apps send it. Both must land on one line.
    /// The prompt already asks for a single line (see `PromptBuilder`); this is
    /// the guard for when the model ignores it.
    public static func flattensNewlines(bundleID: String?) -> Bool {
        let c = category(bundleID: bundleID)
        return c == .terminal || c == .chat
    }

    /// Collapse every whitespace run that contains a newline into a single space,
    /// then trim — so nothing typed into a terminal spans lines (each of which
    /// would run as its own command). Whitespace runs without a newline (e.g.
    /// aligned spaces) are left alone.
    public static func flattenForTerminal(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s*\\n\\s*", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whisper hallucinates ("Thank you.", "you") on sub-half-second or silent
    /// buffers. Gate transcription on a floor of duration AND loudness.
    /// Defaults: 6400 samples ≈0.4s @16kHz; RMS 1e-4 is orders of magnitude below
    /// real speech, so this only rejects near-digital-silence.
    // ponytail: fixed thresholds, no VAD — bump if quiet speech gets dropped.
    public static func audioWorthTranscribing(sampleCount: Int, rms: Float,
                                              minSamples: Int = 6400,
                                              minRMS: Float = 1e-4) -> Bool {
        sampleCount >= minSamples && rms >= minRMS
    }
}
