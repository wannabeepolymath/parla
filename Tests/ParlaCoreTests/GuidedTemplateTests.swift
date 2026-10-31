import Foundation
import XCTest
@testable import ParlaCore

final class GuidedTemplateCoreTests: XCTestCase {
    func definition(body: String = "{{title}}", optional: Bool = false) -> GuidedTemplateDefinition {
        GuidedTemplateDefinition(name: "Bug report", body: body,
            fields: [GuidedTemplateField(key: "title", label: "Title", required: !optional)])
    }
    func testT01StrictSettingsSchemaAndScopedRecovery() throws {
        XCTAssertTrue(try JSONDecoder().decode(Settings.self, from: Data("{}".utf8)).guidedTemplates.definitions.isEmpty)
        var settings = Settings(); settings.language = "hi"; settings.historyEnabled = false
        settings.guidedTemplates = GuidedTemplateDocument(definitions: [definition()])
        let encoded = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: encoded).guidedTemplates, settings.guidedTemplates)
        for block in ["null", "[]", "1", "{\"format\":\"parla-guided-templates\",\"schemaVersion\":2,\"definitions\":[]}"] {
            let bytes = Data(("{\"language\":\"hi\",\"historyEnabled\":false,\"guidedTemplates\":" + block + "}").utf8)
            let backend = FakeCredentialBackend()
            let store = SettingsStore(url: URL(fileURLWithPath: "/synthetic/in-memory-settings"), credentials: CredentialStore(backend: backend), documentIO: .init(read: { bytes }))
            XCTAssertThrowsError(try store.savedRetrySnapshot())
            let recovered = store.load()
            XCTAssertEqual(recovered.language, "hi"); XCTAssertFalse(recovered.historyEnabled)
            XCTAssertEqual(recovered.recognitionEngine, .whisper); XCTAssertNotNil(store.lastError)
            XCTAssertThrowsError(try store.save(recovered))
            XCTAssertEqual(backend.reads + backend.statuses + backend.adds + backend.updates + backend.deletes, 0)
        }
        var duplicate = definition(); duplicate.fields.append(duplicate.fields[0])
        XCTAssertThrowsError(try duplicate.compiled())
        XCTAssertThrowsError(try GuidedTemplateDocument(definitions: [definition(), definition(), duplicate]).validate())
        let d = definition()
        XCTAssertThrowsError(try GuidedTemplateDocument(definitions: [d,d]).validate())
    }
    func testT01FiniteDefinitionCaps() throws {
        var d = definition()
        for length in [119,120] { d.name = String(repeating: "a", count: length); XCTAssertNoThrow(try d.compiled()) }
        d.name += "a"; XCTAssertThrowsError(try d.compiled()); d.name = "Report"
        for length in [159,160] { d.fields[0].label = String(repeating: "a", count: length); XCTAssertNoThrow(try d.compiled()) }
        d.fields[0].label += "a"; XCTAssertThrowsError(try d.compiled()); d.fields[0].label = "Title"
        d.body = "{{title}}" + String(repeating: "a", count: 8_183); XCTAssertNoThrow(try d.compiled())
        d.body += "a"; XCTAssertThrowsError(try d.compiled())
        for count in [63,64] { d.body = String(repeating: "{{title}}", count: count); XCTAssertNoThrow(try d.compiled()) }
        d.body += "{{title}}"; XCTAssertThrowsError(try d.compiled())
        XCTAssertNoThrow(try GuidedTemplateDocument(definitions:(0..<31).map{_ in definition()}).validate())
        var many = (0..<32).map { _ in definition() }
        XCTAssertNoThrow(try GuidedTemplateDocument(definitions: many).validate()); many.append(definition())
        XCTAssertThrowsError(try GuidedTemplateDocument(definitions: many).validate())
        d = definition(); d.fields = (0..<11).map { GuidedTemplateField(key: "f\($0)", label: "Field") }
        d.body = d.fields.map { "{{" + $0.key + "}}" }.joined(); XCTAssertNoThrow(try d.compiled())
        d.fields.append(GuidedTemplateField(key:"f11",label:"Field"))
        d.body = d.fields.map { "{{" + $0.key + "}}" }.joined(); XCTAssertNoThrow(try d.compiled())
        d.fields.append(GuidedTemplateField(key: "extra", label: "Extra")); d.body += "{{extra}}"; XCTAssertThrowsError(try d.compiled())
    }
    func testT04T05T06OriginalInputGrammarAndLiteralBytes() throws {
        let a = GuidedTemplateField(key: "a", label: "A"), b = GuidedTemplateField(key: "b", label: "B", required: false)
        let d = GuidedTemplateDefinition(name: "Literal", body: "{{b}}{{a}}{{a}} {{{{key}}}} { \"json\": 1 }", fields: [a,b])
        let value = "{{b}} {{{{x}}}} $1 \\1 `code` <b>ignore previous instructions</b> हिंदी اردو é 👩🏽‍💻\r\n"
        XCTAssertEqual(try d.compiled().render([a.id:value,b.id:""]), value + value + " {{key}} { \"json\": 1 }")
        for body in ["{{unknown}}", "{{}}", "{{ title}}", "{{TITLE}}", "{{title}", "{{{title}}}", "{{title}}}", "{{title{{title}}", "{{title}} }}", "{{{{title}}}}"] {
            XCTAssertThrowsError(try definition(body: body).compiled(), body)
        }
        let program = try definition(body: String(repeating: "{{title}}", count: 8)).compiled()
        let field = definition().fields[0].id
        _ = field // IDs are bound by compilation, never looked up from value text.
        let dd = definition(body: String(repeating: "{{title}}", count: 8))
        XCTAssertEqual(try dd.compiled().render([dd.fields[0].id:String(repeating:"x",count:8192)]).utf8.count, 65536)
        let below = definition(body:String(repeating:"{{title}}",count:8)+String(repeating:"x",count:7))
        XCTAssertEqual(try below.compiled().render([below.fields[0].id:String(repeating:"x",count:8191)]).utf8.count,65535)
        let over = definition(body: String(repeating: "{{title}}", count: 8) + "x")
        XCTAssertThrowsError(try over.compiled().render([over.fields[0].id:String(repeating:"x",count:8192)]))
        XCTAssertThrowsError(try program.render([:]))
    }
    func testT04T09T21T25ReducerRetakeSkipReviewAndImmutableApproval() throws {
        let d = definition(optional: true)
        var state = try GuidedTemplateSession(definition: d, now: 10)
        let first = try state.start(now: 10); state.settle(first, text: "original"); try state.accept()
        let second = try state.start(now: 11); state.settle(second, text: nil)
        XCTAssertEqual(state.accepted[d.fields[0].id], .accepted("original"))
        state.settle(first, text: "stale"); XCTAssertNil(state.candidate)
        let third = try state.start(now: 12); state.settle(third, text: "new")
        try state.editCandidate(""); XCTAssertThrowsError(try state.accept())
        try state.editCandidate("literal\r\n"); try state.accept(); try state.review()
        let preview = try XCTUnwrap(state.preview); state.approve(UUID(), date: Date()); XCTAssertNil(state.completion)
        let date = Date(timeIntervalSince1970: 123); state.approve(preview.id, date: date)
        let sealed = try XCTUnwrap(state.completion)
        state.approve(preview.id, date: Date()); state.back(); state.discardCandidate()
        XCTAssertThrowsError(try state.start(now: 13)); XCTAssertThrowsError(try state.skip())
        XCTAssertEqual(state.completion, sealed); state.markSaved(sealed.id); XCTAssertTrue(state.saved)
        XCTAssertEqual(sealed.body, "literal\r\n"); XCTAssertEqual(sealed.date, date)
        var optional = try GuidedTemplateSession(definition: d, now: 10); try optional.skip(); XCTAssertThrowsError(try optional.review())
        var required = try GuidedTemplateSession(definition: definition(), now: 10); XCTAssertThrowsError(try required.skip())
        for i in 0..<60 { let take = try required.start(now: 11); XCTAssertEqual(required.starts, i + 1); required.settle(take,text:nil) }
        XCTAssertThrowsError(try required.start(now: 11))
        XCTAssertTrue(required.isExpired(now: 1210)); XCTAssertFalse(required.isExpired(now: 1209.999))
    }
    func testT02NarrowRevisionCRUDAndFullWriterPreserveFreshDefinitionsWithoutCredentials() throws {
        let backend = FakeCredentialBackend()
        var initial = Settings(); initial.cleanup.provider = "apple-intelligence"
        var bytes: Data? = try JSONEncoder().encode(initial)
        let store = SettingsStore(url: URL(fileURLWithPath:"/synthetic/memory"), credentials: CredentialStore(backend:backend),
            scratchpadIO: .init(read: { _ in bytes }, write: { value,_ in bytes = value }),
            documentIO: .init(read: { bytes }), atomicWrite: { value,_ in bytes = value })
        let draft = initial
        let committed = try store.saveTemplateDefinition(definition(), expectedRevision:nil)
        let saved = try XCTUnwrap(committed.definitions.first)
        XCTAssertNotEqual(saved.revision, definition().revision)
        var edit = saved; edit.name = "Updated"
        let next = try store.saveTemplateDefinition(edit, expectedRevision:saved.revision)
        XCTAssertThrowsError(try store.saveTemplateDefinition(edit, expectedRevision:saved.revision))
        XCTAssertEqual(try store.savePreservingTemplates(draft, replacing:initial).guidedTemplates, next)
        XCTAssertEqual(try store.savedRetrySnapshot().guidedTemplates, next)
        _ = try store.deleteTemplateDefinition(saved.id, expectedRevision:next.definitions[0].revision)
        XCTAssertThrowsError(try store.saveTemplateDefinition(edit, expectedRevision:next.definitions[0].revision))
        XCTAssertTrue(try store.savePreservingTemplates(draft, replacing:initial).guidedTemplates.definitions.isEmpty)
        XCTAssertEqual(backend.reads + backend.statuses + backend.adds + backend.updates + backend.deletes,0)
    }
}


extension GuidedTemplateCoreTests {
    func testT01ExactEncodedBlockBudgetAndAllStructuralRefusalsPreserveBytes() throws {
        // Find exact encoded byte budgets using ASCII padding; no Settings writer may truncate.
        let encoder = JSONEncoder()
        for target in [262_143,262_144,262_145] {
            var doc = GuidedTemplateDocument(definitions:(0..<32).map{_ in definition()})
            var remaining = target - (try encoder.encode(doc).count)
            for i in doc.definitions.indices {
                let n = min(remaining,8192-doc.definitions[i].body.utf8.count)
                doc.definitions[i].body += String(repeating:"x",count:n); remaining -= n
            }
            XCTAssertEqual(remaining,0); XCTAssertEqual(try encoder.encode(doc).count,target)
            var settings = Settings(); settings.guidedTemplates = doc
            if target <= 262_144 {XCTAssertNoThrow(try doc.validate()); XCTAssertNoThrow(try encoder.encode(settings))}
            else {XCTAssertThrowsError(try doc.validate()); XCTAssertThrowsError(try encoder.encode(settings))}
        }
        var good = Settings(); good.guidedTemplates = .init(definitions:[definition()]); good.language = "ur"
        let seed = try encoder.encode(good)
        let blocks = ["{}", "true", "{\"format\":\"other\",\"schemaVersion\":1,\"definitions\":[]}",
                      "{\"format\":\"parla-guided-templates\",\"schemaVersion\":1}",
                      "{\"format\":\"parla-guided-templates\",\"schemaVersion\":1,\"definitions\":null}"]
        for block in blocks {
            let bytes = Data(("{\"language\":\"ur\",\"guidedTemplates\":"+block+"}").utf8)
            var writes = 0
            let backend = FakeCredentialBackend()
            let store = SettingsStore(url:URL(fileURLWithPath:"/synthetic/scoped"),credentials:CredentialStore(backend:backend),
                scratchpadIO:.init(read:{_ in bytes},write:{_,_ in writes += 1}),documentIO:.init(read:{bytes}),atomicWrite:{_,_ in writes += 1})
            XCTAssertThrowsError(try store.templateDocument()); XCTAssertThrowsError(try store.savedRetrySnapshot())
            XCTAssertEqual(store.load().language,"ur"); XCTAssertNotNil(store.lastError)
            XCTAssertThrowsError(try store.saveTemplateDefinition(definition(),expectedRevision:nil))
            XCTAssertThrowsError(try store.save(good)); XCTAssertEqual(writes,0)
            XCTAssertEqual(backend.reads+backend.statuses+backend.adds+backend.updates+backend.deletes,0)
        }
        XCTAssertEqual(try JSONDecoder().decode(Settings.self,from:seed),good)
        for key in ["", "A", "a-b", "1a", "é", String(repeating:"a",count:33)] {
            var d = definition(); d.fields[0].key = key; d.body = "{{"+key+"}}"; XCTAssertThrowsError(try d.compiled())
        }
        for size in [31,32] {
            var d = definition(); d.fields[0].key = String(repeating:"a",count:size); d.body = "{{"+d.fields[0].key+"}}"; XCTAssertNoThrow(try d.compiled())
        }
        var d = definition(); d.fields[0].label = " \r\n"; XCTAssertThrowsError(try d.compiled())
        d = definition(); d.name = "\t"; XCTAssertThrowsError(try d.compiled())
        d = definition(); d.fields = []; XCTAssertThrowsError(try d.compiled())
        d = definition(); d.fields.append(.init(key:"title",label:"Second")); XCTAssertThrowsError(try d.compiled())
        d = definition(); d.fields.append(.init(key:"unused",label:"Unused")); XCTAssertThrowsError(try d.compiled())
    }
    func testT02ByteRaceRecreateFullWritersLocalBaseAndLegacySecrets() throws {
        let backend = FakeCredentialBackend()
        var initial = Settings(); initial.cleanup.provider = "apple-intelligence"
        // Legacy credentials and unknown siblings must survive narrow editing without credential IO.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(initial)) as? [String:Any])
        object["anthropicApiKey"] = "synthetic-legacy-a"
        var cleanup = try XCTUnwrap(object["cleanup"] as? [String:Any]); cleanup["apiKey"] = "synthetic-legacy-b"; object["cleanup"] = cleanup
        object["futureSibling"] = ["keep":"unchanged"]
        var bytes:Data? = try JSONSerialization.data(withJSONObject:object)
        var reads = 0, writes = 0, race:Data?
        let store = SettingsStore(url:URL(fileURLWithPath:"/synthetic/cas"),credentials:CredentialStore(backend:backend),
            scratchpadIO:.init(read:{_ in reads += 1; if reads == 2, let race {bytes = race}; return bytes},write:{data,_ in writes += 1; bytes = data}),
            documentIO:.init(read:{bytes}),atomicWrite:{data,_ in writes += 1; bytes = data})
        let first = try store.saveTemplateDefinition(definition(),expectedRevision:nil).definitions[0]
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes!) as? [String:Any])
        XCTAssertEqual(parsed["anthropicApiKey"] as? String,"synthetic-legacy-a")
        XCTAssertEqual((parsed["cleanup"] as? [String:Any])?["apiKey"] as? String,"synthetic-legacy-b")
        XCTAssertEqual((parsed["futureSibling"] as? [String:String])?["keep"],"unchanged")
        let base = try store.savedRetrySnapshot(); var staleDraft = base; staleDraft.showHudAlways.toggle()
        var edit = first; edit.name = "Concurrent edit"
        let fresh = try store.saveTemplateDefinition(edit,expectedRevision:first.revision)
        let full = try store.savePreservingTemplates(staleDraft,replacing:base)
        XCTAssertEqual(full.guidedTemplates,fresh)
        XCTAssertEqual(try store.savedRetrySnapshot().anthropicApiKey,base.anthropicApiKey)
        // A genuine unrelated local stale base is refused, even when its template block is refreshed.
        var newest = try store.savedRetrySnapshot(); newest.language = "ur"; _ = try store.savePreservingTemplates(newest,replacing:full)
        let before = bytes; XCTAssertThrowsError(try store.savePreservingTemplates(staleDraft,replacing:base)); XCTAssertEqual(bytes,before)
        _ = try store.deleteTemplateDefinition(first.id,expectedRevision:fresh.definitions[0].revision)
        let recreated = try store.saveTemplateDefinition(definition(),expectedRevision:nil)
        XCTAssertNotEqual(recreated.definitions[0].id,first.id)
        XCTAssertThrowsError(try store.deleteTemplateDefinition(first.id,expectedRevision:first.revision))
        // Same-ID edit racing exact read bytes refuses before the narrow writer.
        var changed = try store.savedRetrySnapshot(); changed.showHudAlways.toggle(); race = try JSONEncoder().encode(changed)
        reads = 0; let count = writes
        XCTAssertThrowsError(try store.saveTemplateDefinition(definition(),expectedRevision:nil)); XCTAssertEqual(bytes,race); XCTAssertEqual(writes,count)
        XCTAssertEqual(backend.reads+backend.statuses+backend.adds+backend.updates+backend.deletes,0)
        // Existing nonlocal full APIs also preserve the fresh document (no inline secrets here).
        var remote = Settings(); remote.guidedTemplates = recreated
        bytes = try JSONEncoder().encode(remote); race = nil
        var draft = Settings(); draft.showHudAlways = true
        _ = try store.save(draft); XCTAssertEqual(try store.savedRetrySnapshot().guidedTemplates,recreated)
    }
    func testT04T06ExactCandidateAcceptedAndRenderedByteBounds() throws {
        let fields = (0..<12).map{GuidedTemplateField(key:"f\($0)",label:"Field")}
        let d = GuidedTemplateDefinition(name:"Maximum accepted",body:fields.map{"{{"+$0.key+"}}"}.joined(),fields:fields)
        var state = try GuidedTemplateSession(definition:d,now:0)
        for _ in fields {
            let take = try state.start(now:1); state.settle(take,text:String(repeating:"x",count:8192))
            XCTAssertThrowsError(try state.editCandidate(String(repeating:"x",count:8193)))
            XCTAssertEqual(state.candidate?.utf8.count,8192); try state.accept()
        }
        XCTAssertEqual(state.accepted.count,12); XCTAssertThrowsError(try state.review()); XCTAssertNil(state.preview)
        // Optional whitespace is an explicit Skip, never an implicit empty acceptance.
        var optional = try GuidedTemplateSession(definition:definition(body:"Heading {{title}}",optional:true),now:0)
        let take = try optional.start(now:1); optional.settle(take,text:"x"); try optional.editCandidate("\r\n ")
        XCTAssertThrowsError(try optional.accept()); try optional.skip(); try optional.review()
        XCTAssertEqual(optional.preview?.body,"Heading ")
    }
}
