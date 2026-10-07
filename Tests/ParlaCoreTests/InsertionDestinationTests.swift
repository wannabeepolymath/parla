import XCTest
@testable import ParlaCore

final class InsertionDestinationTests: XCTestCase {
    typealias Destination = InsertionDestination<String>

    func target(process: Int32? = 42, window: String? = "window", number: UInt32? = 7,
                element: String? = "terminal", selection: String? = nil) -> Destination {
        Destination(process: process, window: window, windowNumber: number, element: element,
                    selection: selection)
    }

    func testSameTerminalIdentityAcceptsPendingText() {
        // AXValue and AXSelectedTextRange are deliberately absent from this
        // policy: screen output can change both without changing the target.
        XCTAssertTrue(target().matches(target()))
    }

    func testDifferentApplicationIsRejectedEvenWithMatchingElementTokens() {
        XCTAssertFalse(target().matches(target(process: 99)))
        XCTAssertFalse(target(process: nil).matches(target(process: nil)))
    }

    func testNewSelectionCannotBeOverwrittenByLatePaste() {
        XCTAssertFalse(target(selection: "").matches(target(selection: "user text")))
        XCTAssertFalse(target().matches(target(selection: "user text")))
        XCTAssertFalse(target(selection: "old text").matches(target(selection: "new text")))
        XCTAssertTrue(target(selection: "replace this").matches(target(selection: "replace this")))
        XCTAssertTrue(target(selection: "old selection").matches(target(selection: "")))
    }

    func testSwitchingWindowsIsRejectedEvenWhenFocusElementIsReused() {
        XCTAssertFalse(target().matches(target(window: "other-window", number: 8)))
    }

    func testSwitchingFieldsInsideSameWindowIsRejected() {
        XCTAssertFalse(target().matches(target(element: "search-box")))
    }

    func testOpaqueAppCanGainOrLoseAXFocusInSameWindow() {
        XCTAssertTrue(target(element: nil).matches(target()))
        XCTAssertTrue(target().matches(target(element: nil)))
        XCTAssertFalse(target(element: nil).matches(target(window: "other-window", number: 8)))
    }

    func testWindowServerIdentitySurvivesAnAXBridgeBecomingAvailable() {
        XCTAssertTrue(target(window: nil, element: nil).matches(target()))
        XCTAssertTrue(target().matches(target(window: nil, element: nil)))
        XCTAssertFalse(target(window: nil, element: nil).matches(target(number: 8)))
    }

    func testOpaqueWindowSwitchIsRejected() {
        XCTAssertFalse(target(window: nil, element: nil)
            .matches(target(window: nil, number: 8, element: nil)))
    }

    func testLossOfKnownWindowCannotFallBackToOnlyProcessIdentity() {
        XCTAssertFalse(target(element: nil)
            .matches(target(window: nil, number: nil, element: nil)))
        XCTAssertFalse(target(window: nil, number: nil, element: nil)
            .matches(target(element: nil)))
    }

    func testFullyOpaqueAppRetainsProcessFallback() {
        let opaque = target(window: nil, number: nil, element: nil)
        XCTAssertTrue(opaque.matches(target(window: nil, number: nil, element: nil)))
        XCTAssertFalse(opaque.matches(target(process: 99, window: nil, number: nil, element: nil)))
        XCTAssertFalse(opaque.matches(target(window: nil, number: nil)))
    }

    func testUnlistedAppWithMissingAXFocusUsesPasteFallback() {
        XCTAssertEqual(Inserter.pasteFocus(.none, trusted: true, hasFrontmostApplication: true), .unknown)
        XCTAssertEqual(Inserter.pasteFocus(.none, trusted: false, hasFrontmostApplication: true), .none)
        XCTAssertEqual(Inserter.pasteFocus(.none, trusted: true, hasFrontmostApplication: false), .none)
    }

    func testFallbackNeverOverridesSecureOrKnownFocus() {
        for focus in [Inserter.FocusTarget.secure, .editable, .unknown] {
            XCTAssertEqual(Inserter.pasteFocus(focus, trusted: true, hasFrontmostApplication: true), focus)
        }
    }
}
