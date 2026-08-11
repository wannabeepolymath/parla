import XCTest
@testable import ParlaCore

final class InserterTests: XCTestCase {
    func assertValidChunks(_ chunks: [[UInt16]], reproduce units: [UInt16], max: Int = 200) {
        for chunk in chunks {
            XCTAssertFalse(chunk.isEmpty)
            XCTAssertLessThanOrEqual(chunk.count, max)
            // No chunk ends with a lone high surrogate...
            if let last = chunk.last {
                XCTAssertFalse((0xD800...0xDBFF).contains(last), "chunk ends with unpaired high surrogate")
            }
            // ...or starts with a lone low surrogate.
            if let first = chunk.first {
                XCTAssertFalse((0xDC00...0xDFFF).contains(first), "chunk starts with unpaired low surrogate")
            }
        }
        XCTAssertEqual(chunks.flatMap { $0 }, units)
    }

    // Boundary behaviour is tested against an explicit `max` so these keep
    // testing the property rather than whatever the current default happens
    // to be — the default moved from 20 to 200 once and can move again.
    func testASCIIChunksExactlyAtMax() {
        let units = Array(String(repeating: "a", count: 45).utf16)
        let chunks = Inserter.chunkUTF16(units, max: 20)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 5])
        assertValidChunks(chunks, reproduce: units, max: 20)
    }

    func testSurrogatePairStraddlingBoundaryNotSplit() {
        // 19 ASCII units then an emoji (2 UTF-16 units) — the pair would straddle index 20.
        let text = String(repeating: "x", count: 19) + "😀😀😀"
        let units = Array(text.utf16)
        let chunks = Inserter.chunkUTF16(units, max: 20)
        assertValidChunks(chunks, reproduce: units, max: 20)
        // First chunk must stop at 19 to keep the pair intact.
        XCTAssertEqual(chunks[0].count, 19)
    }

    /// The regression this size exists to prevent: terminals frame each burst as
    /// its own paste, so a typical transcript must not fan out into dozens of them.
    func testTypicalTranscriptIsFewBursts() {
        let units = Array(String(repeating: "a", count: 600).utf16)
        XCTAssertEqual(Inserter.chunkUTF16(units).count, 3)
    }

    func testAllEmoji() {
        let units = Array(String(repeating: "😀", count: 25).utf16) // 50 units
        // max 20 so the pairs actually straddle boundaries — at the default 200
        // this is a single chunk and tests nothing.
        let chunks = Inserter.chunkUTF16(units, max: 20)
        assertValidChunks(chunks, reproduce: units, max: 20)
    }

    func testSecureEventInputRefusesBeforeAnyAXLookup() {
        // Secure input short-circuits: no AX query, no accessibility-flag write,
        // just the same refusal a password field gets.
        XCTAssertEqual(Inserter.focusTarget(secureInput: true), .secure)
    }

    // MARK: - canErase (the pure (text, cursor, selLength, typed) decision)

    func testCanEraseWithBareCaretAfterOurText() {
        // Caret sits right after what we typed: erasing removes only our own.
        XCTAssertTrue(Inserter.canErase(text: "hello world", cursor: 11, selLength: 0, typed: " world"))
    }

    func testCannotEraseIntoForeignTailWithBareCaret() {
        XCTAssertFalse(Inserter.canErase(text: "hello world", cursor: 11, selLength: 0, typed: " there"))
    }

    /// ISSUES.md #6: Parla must never delete text it did not write. The offset
    /// before a live selection matches our text just as well as a caret does,
    /// but the first Delete eats the selection instead of one of our characters.
    func testCannotEraseWhenSelectionIsLive() {
        // "hello world" typed by us, and the user has since selected "worl" —
        // the offset before that selection still ends with "hello ".
        XCTAssertFalse(Inserter.canErase(text: "hello world", cursor: 6, selLength: 4, typed: "hello "))
    }

    func testCannotEraseWhenSelectionCoversOurOwnText() {
        // Even a selection of exactly our text is refused: the erase run's count
        // assumes one character per Delete, and the first one takes all four.
        XCTAssertFalse(Inserter.canErase(text: "hi Parla", cursor: 3, selLength: 5, typed: "hi "))
    }

    func testCanEraseOutOfBoundsCursor() {
        // Cursor past the reported text, or too close to the start to hold what
        // we typed: unverifiable either way.
        XCTAssertFalse(Inserter.canErase(text: "hi", cursor: 9, selLength: 0, typed: "hi"))
        XCTAssertFalse(Inserter.canErase(text: "hello", cursor: 2, selLength: 0, typed: "hello"))
    }

    func testCanEraseNothingIsAlwaysTrue() {
        // Zero backspaces touch nothing, so a live selection is harmless here.
        XCTAssertTrue(Inserter.canErase(text: "hello", cursor: 2, selLength: 3, typed: ""))
    }

    // MARK: - AX tree walk (the search behind focusFirstTextInput)

    /// Stand-in for an AX subtree. A live AXUIElement can't be constructed in a
    /// test, which is the whole reason the walk is generic over its node type;
    /// everything below the roles and the shape is untestable here.
    private final class AXNode {
        let role: String
        var children: [AXNode]
        init(_ role: String, _ children: [AXNode] = []) { self.role = role; self.children = children }
    }

    /// Uses the real role set, so that is under test too — not a copy of it.
    private func firstTextInput(_ roots: [AXNode], maxDepth: Int) -> AXNode? {
        Inserter.firstMatch(in: roots, maxDepth: maxDepth,
                            children: { $0.children },
                            matches: { Inserter.textInputRoles.contains($0.role) })
    }

    func testTreeWalkFindsNestedTextInputDepthFirst() {
        // TextEdit's shape: window > scroll area > text area, behind a toolbar
        // whose roles must not match.
        let target = AXNode("AXTextArea")
        let window = AXNode("AXWindow", [
            AXNode("AXToolbar", [AXNode("AXButton"), AXNode("AXImage")]),
            AXNode("AXScrollArea", [target]),
            AXNode("AXTextField"), // later sibling: depth-first must return the earlier hit
        ])
        XCTAssertTrue(firstTextInput([window], maxDepth: 8) === target)
    }

    func testTreeWalkFindsNothingWhenNoRoleMatches() {
        // Static text and buttons are not somewhere to type a transcript.
        let window = AXNode("AXWindow", [AXNode("AXGroup", [AXNode("AXStaticText"), AXNode("AXButton")])])
        XCTAssertNil(firstTextInput([window], maxDepth: 8))
    }

    func testTreeWalkStopsAtDepthCap() {
        // Roots count as level 1, so this text area sits at level 3.
        let roots = [AXNode("AXWindow", [AXNode("AXScrollArea", [AXNode("AXTextArea")])])]
        XCTAssertNil(firstTextInput(roots, maxDepth: 2))
        XCTAssertNotNil(firstTextInput(roots, maxDepth: 3))
    }

    /// What the cap is actually for: an AX tree can report a child that reports
    /// an ancestor back, and an unbounded walk would never return.
    func testTreeWalkTerminatesOnCyclicTree() {
        let a = AXNode("AXGroup")
        let b = AXNode("AXGroup", [a])
        a.children = [b]
        XCTAssertNil(firstTextInput([a], maxDepth: 12))
    }

    func testAXCenterToAppKitFlipsYThroughPrimaryScreenHeight() {
        // AX top-left origin (10, 20), size 100x50, on a 900pt-tall primary screen.
        // Center in AX space is (60, 45); AppKit y = 900 - 45 = 855.
        let p = Inserter.axCenterToAppKit(origin: CGPoint(x: 10, y: 20), size: CGSize(width: 100, height: 50),
                                           primaryScreenHeight: 900)
        XCTAssertEqual(p.x, 60)
        XCTAssertEqual(p.y, 855)
    }

    func testAXCenterToAppKitAtScreenTopLandsNearBottom() {
        // An element flush against the AX origin (top-left of the primary screen)
        // must land near the bottom of AppKit space, not the top.
        let p = Inserter.axCenterToAppKit(origin: .zero, size: CGSize(width: 10, height: 10),
                                           primaryScreenHeight: 1080)
        XCTAssertEqual(p.y, 1075) // 1080 - 5
    }
}
