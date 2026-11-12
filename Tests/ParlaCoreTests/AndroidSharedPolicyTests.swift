import Foundation
import XCTest
@testable import ParlaCore

final class AndroidSharedPolicyTests: XCTestCase {
    func testCompleteDesktopAndroidPromptContract() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("fixtures/desktop-prompts-v1.json"))
        let document = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(document["version"] as? Int, 1)
        let categories: [String: AppCategory] = ["unknown": .unknown, "email": .email, "terminal": .terminal, "prose": .prose]
        for item in try XCTUnwrap(document["cases"] as? [[String: Any]]) {
            let name = try XCTUnwrap(item["name"] as? String)
            let source = try XCTUnwrap(item["source"] as? String)
            let instruction = item["instruction"] as? String
            let style = try XCTUnwrap(ProfileStyle(rawValue: try XCTUnwrap(item["style"] as? String)))
            var context = CleanupContext(dictionary: try XCTUnwrap(item["dictionary"] as? [String]),
                snippets: try XCTUnwrap(item["snippets"] as? [String: String]), appName: nil,
                selection: instruction == nil ? nil : source,
                singleLine: try XCTUnwrap(item["singleLine"] as? Bool), style: style)
            context.category = try XCTUnwrap(categories[try XCTUnwrap(item["category"] as? String)])
            XCTAssertEqual(PromptBuilder.system(context: context), item["system"] as? String, name)
            XCTAssertEqual(PromptBuilder.user(transcript: instruction ?? source, context: context), item["user"] as? String, name)
        }
    }

    func testVersionedAndroidDesktopPolicyFixtures() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("fixtures/desktop-android-v1.json"))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(fixture["version"] as? Int, 1)
        for item in try XCTUnwrap(fixture["length"] as? [[String: Any]]) {
            XCTAssertEqual((item["input"] as? String)?.count, item["expected"] as? Int)
        }
        for item in try XCTUnwrap(fixture["normalization"] as? [[String: String]]) {
            XCTAssertEqual(Eval.normalizeForWER(item["input"]!), item["expected"]!)
        }
        for item in try XCTUnwrap(fixture["literal"] as? [[String: String]]) {
            XCTAssertEqual(LiteralReplacement.apply([.init(source: item["source"]!, replacement: item["replacement"]!)], to: item["input"]!), item["expected"]!)
        }
        for item in try XCTUnwrap(fixture["snippets"] as? [[String: String]]) {
            XCTAssertEqual(Pipeline.snippetExpansion(transcript: item["input"]!, snippets: [item["trigger"]!: item["expansion"]!]), item["expected"]!)
        }
    }
}
