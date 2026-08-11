import XCTest
@testable import ParlaCore

final class TextRulesTests: XCTestCase {
    // MARK: category
    func testKnownTerminalsMatch() {
        for id in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp",
                   "com.github.wez.wezterm", "net.kovidgoyal.kitty",
                   "com.mitchellh.ghostty", "org.alacritty", "co.zeit.hyper"] {
            XCTAssertEqual(TextRules.category(bundleID: id), .terminal, id)
        }
    }

    func testKnownChatAndProseAndCodeMatch() {
        for id in ["com.tinyspeck.slackmacgap", "com.hnc.Discord", "com.apple.MobileSMS",
                   "net.whatsapp.WhatsApp", "ru.keepcoder.Telegram", "org.telegram.desktop"] {
            XCTAssertEqual(TextRules.category(bundleID: id), .chat, id)
        }
        for id in ["com.apple.mail", "com.microsoft.Outlook", "com.microsoft.Word",
                   "com.apple.Notes", "notion.id", "md.obsidian"] {
            XCTAssertEqual(TextRules.category(bundleID: id), .prose, id)
        }
        for id in ["com.apple.dt.Xcode", "dev.zed.Zed", "com.todesktop.230313mzl4w4u92"] {
            XCTAssertEqual(TextRules.category(bundleID: id), .code, id)
        }
    }

    func testUnknownAndNil() {
        XCTAssertEqual(TextRules.category(bundleID: "com.apple.Safari"), .unknown)
        XCTAssertEqual(TextRules.category(bundleID: nil), .unknown)
        XCTAssertEqual(TextRules.category(bundleID: ""), .unknown)
    }

    // The bug substring matching ships with: "onepassword" contains "word",
    // "barcode" contains "code", "Terminology" contains "termino". None of these
    // are the app the substring belongs to.
    func testNearMissesThatSubstringMatchingGetsWrong() {
        for id in ["com.agilebits.onepassword7", "com.1password.1password",
                   "com.example.barcodescanner", "com.agiletortoise.Terminology",
                   "com.apple.iWork.Keynote", "com.apple.MobileSMSBackup",
                   "com.tinyspeck.slackmacgap.helper", "co.zeit.hyperlink"] {
            XCTAssertEqual(TextRules.category(bundleID: id), .unknown, id)
        }
    }

    // The VS Code prefix must stop at the product: com.microsoft.* also holds
    // Word and Outlook, which are prose, not code.
    func testPrefixMatchingIsAnchoredToTheProductNotTheVendor() {
        XCTAssertEqual(TextRules.category(bundleID: "com.microsoft.VSCode"), .code)
        XCTAssertEqual(TextRules.category(bundleID: "com.microsoft.VSCodeInsiders"), .code)
        XCTAssertEqual(TextRules.category(bundleID: "com.microsoft.Word"), .prose)
        XCTAssertEqual(TextRules.category(bundleID: "com.microsoft.Outlook"), .prose)
        XCTAssertEqual(TextRules.category(bundleID: "com.microsoft.Excel"), .unknown)
        // JetBrains namespaces its whole family, so the vendor prefix is correct there.
        XCTAssertEqual(TextRules.category(bundleID: "com.jetbrains.intellij"), .code)
        XCTAssertEqual(TextRules.category(bundleID: "com.jetbrains.pycharm"), .code)
        // ...but only as a prefix, not anywhere in the string.
        XCTAssertEqual(TextRules.category(bundleID: "org.fake.com.jetbrains.clone"), .unknown)
    }

    func testFlattenNewlineTargets() {
        XCTAssertTrue(TextRules.flattensNewlines(bundleID: "com.apple.Terminal"))
        XCTAssertTrue(TextRules.flattensNewlines(bundleID: "com.tinyspeck.slackmacgap"))
        // Editors and documents keep their line breaks.
        XCTAssertFalse(TextRules.flattensNewlines(bundleID: "com.apple.TextEdit"))
        XCTAssertFalse(TextRules.flattensNewlines(bundleID: "com.apple.dt.Xcode"))
        XCTAssertFalse(TextRules.flattensNewlines(bundleID: "com.microsoft.VSCode"))
        XCTAssertFalse(TextRules.flattensNewlines(bundleID: nil))
    }

    // MARK: flattenForTerminal
    func testFlattenSingleNewline() {
        XCTAssertEqual(TextRules.flattenForTerminal("ls\nrm -rf /"), "ls rm -rf /")
    }

    func testFlattenCollapsesNewlineRunToOneSpace() {
        XCTAssertEqual(TextRules.flattenForTerminal("a\n\n\nb"), "a b")
        XCTAssertEqual(TextRules.flattenForTerminal("a  \n  b"), "a b")
    }

    func testFlattenTrims() {
        XCTAssertEqual(TextRules.flattenForTerminal("\n  hello world  \n"), "hello world")
    }

    func testFlattenLeavesNonNewlineSpacingAlone() {
        // A run of spaces with no newline is preserved (only leading/trailing trimmed).
        XCTAssertEqual(TextRules.flattenForTerminal("echo  hi"), "echo  hi")
    }

    func testFlattenSingleLineUnchanged() {
        XCTAssertEqual(TextRules.flattenForTerminal("git status"), "git status")
    }

    func testFlattenEmpty() {
        XCTAssertEqual(TextRules.flattenForTerminal(""), "")
        XCTAssertEqual(TextRules.flattenForTerminal("\n\n"), "")
    }

    // MARK: audioWorthTranscribing
    func testRejectsTooShort() {
        // 6399 samples (<0.4s) even at healthy loudness.
        XCTAssertFalse(TextRules.audioWorthTranscribing(sampleCount: 6399, rms: 0.1))
    }

    func testRejectsSilence() {
        // Plenty long, but near-digital-silence.
        XCTAssertFalse(TextRules.audioWorthTranscribing(sampleCount: 160_000, rms: 1e-5))
    }

    func testAcceptsRealSpeech() {
        XCTAssertTrue(TextRules.audioWorthTranscribing(sampleCount: 6400, rms: 1e-4))
        XCTAssertTrue(TextRules.audioWorthTranscribing(sampleCount: 32_000, rms: 0.05))
    }

    func testBoundaryExactlyAtFloor() {
        // Both thresholds are inclusive floors.
        XCTAssertTrue(TextRules.audioWorthTranscribing(sampleCount: 6400, rms: 1e-4))
        XCTAssertFalse(TextRules.audioWorthTranscribing(sampleCount: 6400, rms: 9e-5))
        XCTAssertFalse(TextRules.audioWorthTranscribing(sampleCount: 6399, rms: 1e-4))
    }
}
