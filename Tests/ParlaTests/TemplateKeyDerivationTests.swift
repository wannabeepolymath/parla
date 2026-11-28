import XCTest
@testable import Parla
import ParlaCore

final class TemplateKeyDerivationTests: XCTestCase {
    func testDerivedKeysAreValidAndUnique() {
        XCTAssertEqual(HubTemplatesView.derivedKey("Steps to reproduce", avoiding: []), "steps_to_reproduce")
        XCTAssertEqual(HubTemplatesView.derivedKey("Chief complaint (short)", avoiding: []), "chief_complaint_short")
        XCTAssertEqual(HubTemplatesView.derivedKey("Zoë's plan", avoiding: []), "zoe_s_plan")
        XCTAssertEqual(HubTemplatesView.derivedKey("3rd step", avoiding: []), "field_3rd_step")
        XCTAssertEqual(HubTemplatesView.derivedKey("Title", avoiding: ["title"]), "title_2")
        XCTAssertEqual(HubTemplatesView.derivedKey("!!!", avoiding: []), "")
        XCTAssertLessThanOrEqual(HubTemplatesView.derivedKey(String(repeating: "word ", count: 20), avoiding: []).count, 32)
    }

    func testClearingAQuestionKeepsItsPlaceholderUntilANewOneIsTyped() throws {
        var editor = GuidedTemplateDefinition(name: "Bug", body: "## {{title}}", fields: [.init(key: "title", label: "Title")])
        editor = HubTemplatesView.renamingField(editor, at: 0, to: "")
        XCTAssertEqual(editor.fields[0].key, "title")
        XCTAssertEqual(editor.body, "## {{title}}", "never rewritten to {{}}")
        for prefix in ["S", "Su", "Subject"] { editor = HubTemplatesView.renamingField(editor, at: 0, to: prefix) }
        XCTAssertEqual(editor.fields[0].key, "subject")
        XCTAssertEqual(editor.body, "## {{subject}}")
        XCTAssertNoThrow(try editor.compiled())
    }
}
