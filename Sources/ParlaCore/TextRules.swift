import Foundation

/// What kind of destination the text is landing in. Drives both the cleanup
/// prompt's tone hint (`PromptBuilder`) and the newline-flatten rule below.
/// `.unknown` is a real answer, not a fallback failure: browsers and everything
/// unrecognized get no tone sentence at all, because a vague one is worse.
public enum AppCategory {
    case terminal, code, chat, prose, unknown
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
        "com.apple.Terminal": .terminal, "com.googlecode.iterm2": .terminal,
        "dev.warp.Warp": .terminal, "com.github.wez.wezterm": .terminal,
        "net.kovidgoyal.kitty": .terminal, "com.mitchellh.ghostty": .terminal,
        "org.alacritty": .terminal, "co.zeit.hyper": .terminal,
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
        "com.apple.mail": .prose, "com.microsoft.Outlook": .prose,
        "com.readdle.smartemail-Mac": .prose, "com.apple.Notes": .prose,
        "com.apple.TextEdit": .prose, "com.apple.iWork.Pages": .prose,
        "com.microsoft.Word": .prose, "notion.id": .prose, "md.obsidian": .prose,
    ]

    /// Prefixes are allowed ONLY where a vendor namespaces a whole product
    /// family: every `com.jetbrains.*` is an IDE, and VS Code ships as
    /// `.VSCode`, `.VSCodeInsiders`, `.VSCodeExploration`. Note the VS Code
    /// prefix stops at the product, not at `com.microsoft.` — Word and Outlook
    /// live in that namespace and are prose.
    static let appCategoryPrefixes: [(String, AppCategory)] = [
        ("com.microsoft.VSCode", .code),
        ("com.jetbrains.", .code),
    ]

    public static func category(bundleID: String?) -> AppCategory {
        guard let bundleID else { return .unknown }
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
