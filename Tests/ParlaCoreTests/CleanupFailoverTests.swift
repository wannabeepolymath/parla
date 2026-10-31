import XCTest
import CryptoKit
@testable import ParlaCore

private final class FailoverMemory {
    var bytes: Data?
    init(_ settings: Settings) throws { bytes = try JSONEncoder().encode(settings) }
    func store(_ backend: FakeCredentialBackend) -> SettingsStore {
        SettingsStore(url: URL(fileURLWithPath: "/synthetic-b21/settings.json"), credentials: CredentialStore(backend: backend),
            scratchpadIO: .init(read: { _ in self.bytes }, write: { bytes, _ in self.bytes = bytes }),
            documentIO: .init(read: { self.bytes }), atomicWrite: { bytes, _ in self.bytes = bytes })
    }
}
private struct FailoverPrimary: HTTPPosting {
    var post: (URLRequest) throws -> (Data, URLResponse)
    func post(_ request: URLRequest) async throws -> (Data, URLResponse) { try post(request) }
    var driver: HistoryRetryHTTP.Driver { { request, callbacks in
        FailoverHandle(start: {
            do {
                let (data, response) = try post(request)
                _ = callbacks.response(response as! HTTPURLResponse); _ = callbacks.data(data); callbacks.completed(nil)
            } catch { callbacks.completed(error) }
            callbacks.exited()
        })
    } }
}
private final class FailoverHandle: HistoryRetryHTTPHandle {
    var start: () -> Void, stop: () -> Void
    init(start: @escaping () -> Void, stop: @escaping () -> Void = {}) { self.start = start; self.stop = stop }
    func resume() { start() }
    func cancel() { stop() }
}
final class CleanupFailoverTests: XCTestCase {
    private func configured() throws -> (FailoverMemory, SettingsStore, Settings, CleanupFailoverGrant, UUID, FakeCredentialBackend) {
        var settings = Settings(); settings.cleanup.provider = "openai-compatible"
        settings.cleanup.baseURL = "https://primary.test/v1"; settings.cleanup.model = "primary-model"
        let backend = FakeCredentialBackend(), memory = try FailoverMemory(settings), store = memory.store(backend)
        let backup = CleanupBackup(baseURL: "http://localhost:1234/v1", model: "backup-model", source: .keylessCompatible)
        let review = try store.reviewCleanupFailover(backups: [backup]); _ = try store.confirmCleanupFailover(review)
        settings = store.load()
        let operation = UUID()
        let grant = try XCTUnwrap(store.captureCleanupFailoverGrant(settings: settings, origin: .physicalOrdinary)).bound(to: operation)
        return (memory, store, settings, grant, operation, backend)
    }
    private func response(_ request: URLRequest, status: Int, text: String = "Polished.") -> (Data, URLResponse) {
        let data = status == 200 ? Data("{\"model\":\"private-model-sentinel\",\"choices\":[{\"message\":{\"content\":\"\(text)\"}}],\"usage\":{\"prompt_tokens\":12,\"completion_tokens\":3}}".utf8) : Data("{}".utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    func testReturnBoundaryPolicyDefaultSleepWithForwardingControl() async throws {
        let forwarding: (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
        let explicit = HistoryRetryExecutionPolicy(planned: 1, budget: 15, sleep: forwarding)
        let explicitValue = try await explicit.joined { "Polished." }
        XCTAssertEqual(explicitValue, "Polished.")
        let ordinary = HistoryRetryExecutionPolicy(planned: 1, budget: 15)
        let ordinaryValue = try await ordinary.joined { "Polished." }
        XCTAssertEqual(ordinaryValue, "Polished.")
    }
    func testOrdinaryFactoryExplicitNamedSleepWithForwardingControl() async throws {
        let forwarding: (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
        for sleeper: ((TimeInterval) async throws -> Void)? in [forwarding, HistoryRetryExecutionPolicy.defaultSleep, nil] {
            let (_, store, settings, grant, id, backend) = try configured()
            var primaryRequests = 0, backups = 0
            let run = CleanupFailoverRun()
            var pipeline = Pipeline(outputSettings: settings, bundleID: nil, failureLogging: .contentFree) { selected in
                try makeOrdinaryCleanupClient(settings: selected, origin: .physicalOrdinary, grant: grant, operationID: id,
                    store: store, env: [:], credentials: store.credentials, primaryDriver: FailoverPrimary(post: { request in
                        primaryRequests += 1; XCTAssertEqual(request.httpMethod, "POST")
                        return self.response(request, status: 200)
                    }).driver, backupDriver: { _, _ in
                        backups += 1; XCTFail("Primary success must not construct a backup")
                        return FailoverHandle(start: {})
                    }, sleep: sleeper, run: run, shouldContinue: { true },
                    usage: { _, _, _ in XCTFail("Owned run must not use global usage") })
            }
            pipeline.failoverRun = run
            let result = await pipeline.clean(transcript: "polished")
            await run.drain()
            XCTAssertNil(result.failure); XCTAssertEqual(result.text, "Polished.")
            XCTAssertEqual(primaryRequests, 1); XCTAssertEqual(backups, 0)
            XCTAssertEqual(backend.reads, 1); XCTAssertEqual(backend.statuses, 0)
            XCTAssertEqual(run.snapshot.acceptedProducerOrdinal, 0); XCTAssertEqual(run.metrics.promptTokens, 12)
        }
    }
    func testOrdinaryFactoryPipelineBackupAcceptedOnceAndLazyPrimarySuccess() async throws {
        for origin in [CleanupFailoverOrigin.physicalOrdinary, .shortcutsOrdinary] {
            for primaryStatus in [200, 503] {
                let (_, store, settings, grant, id, backend) = try configured()
                var backups = 0, primaryRequests = 0
                let run = CleanupFailoverRun()
                var pipeline = Pipeline(outputSettings: settings, bundleID: nil, failureLogging: .contentFree) { selected in
                    try makeOrdinaryCleanupClient(settings: selected, origin: origin, grant: grant, operationID: id,
                        store: store, env: [:], credentials: store.credentials, primaryDriver: FailoverPrimary(post: { request in
                            primaryRequests += 1; XCTAssertEqual(request.httpMethod, "POST")
                            return self.response(request, status: primaryStatus)
                        }).driver, backupDriver: { request, callbacks in
                            backups += 1
                            return FailoverHandle(start: {
                                let (bytes, response) = self.response(request, status: 200)
                                XCTAssertTrue(callbacks.response(response as! HTTPURLResponse)); XCTAssertTrue(callbacks.data(bytes))
                                callbacks.completed(nil); callbacks.exited()
                            })
                        }, run: run, shouldContinue: { true }, usage: { _, _, _ in XCTFail("Owned run must not use global usage") })
                }
                pipeline.failoverRun = run
                let result = await pipeline.clean(transcript: "polished")
            await run.drain()
                XCTAssertNil(result.failure); XCTAssertEqual(result.text, "Polished.")
                XCTAssertEqual(primaryRequests, 1); XCTAssertEqual(backups, primaryStatus == 200 ? 0 : 1)
                XCTAssertEqual(backend.reads, 1); XCTAssertEqual(backend.statuses, 0)
                XCTAssertEqual(run.snapshot.acceptedProducerOrdinal, primaryStatus == 200 ? 0 : 1)
                XCTAssertEqual(run.metrics.promptTokens, 12)
            }
        }
    }
    func testRevokedCapturedJobCannotRegainAuthorityAfterReconfirmButNewJobCan() throws {
        let (_, store, settings, grant, id, _) = try configured()
        try store.withCleanupFailoverGrant(grant, operationID: id, {})
        store.revokeCleanupFailover()
        let review = try store.reviewCleanupFailover(backups: settings.cleanupFailover!.backups)
        _ = try store.confirmCleanupFailover(review)
        XCTAssertThrowsError(try store.withCleanupFailoverGrant(grant, operationID: id, {}))
        let newID = UUID(), fresh = store.load()
        let newGrant = try XCTUnwrap(store.captureCleanupFailoverGrant(settings: fresh, origin: .shortcutsOrdinary)).bound(to: newID)
        try store.withCleanupFailoverGrant(newGrant, operationID: newID, {})
    }
    func testStaleFullWriterPreservesDedicatedPolicyAndPrimaryCAS() throws {
        let (_, store, settings, _, _, _) = try configured()
        _ = try store.disableCleanupFailover(expected: settings.cleanupFailover)
        var stale = settings; stale.showHudAlways.toggle()
        let committed = try store.savePreservingTemplates(stale, replacing: settings)
        XCTAssertNil(committed.cleanupFailover?.review); XCTAssertEqual(committed.showHudAlways, stale.showHudAlways)
        var primaryEdit = committed; primaryEdit.cleanup.model = "new-primary"
        _ = try store.savePreservingTemplates(primaryEdit, replacing: committed)
        XCTAssertThrowsError(try store.savePreservingTemplates(stale))
        XCTAssertEqual(store.load().cleanup.model, "new-primary")
    }
    func testTypedStopPrecedenceAndTransportAllowlist() {
        for status in [408, 429, 500, 503, 529, 599] {
            XCTAssertTrue(cleanupFailoverMayProceed(CleanupError.api(statusCode: status, data: Data("{}".utf8))))
            XCTAssertFalse(cleanupFailoverMayProceed(CleanupError.api(statusCode: status, data: Data("{\"error\":{\"code\":\"expired_api_key\"}}".utf8))))
        }
        for code in [URLError.timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .networkConnectionLost, .notConnectedToInternet] { XCTAssertTrue(cleanupFailoverMayProceed(URLError(code))) }
        for code in [URLError.cancelled, .secureConnectionFailed, .serverCertificateUntrusted, .userAuthenticationRequired, .unknown] { XCTAssertFalse(cleanupFailoverMayProceed(URLError(code))) }
    }
    func testPrimaryLateSuccessRejectedAndNoBackupAfterBudgetExhaustion() async throws {
        for status in [200, 503] {
            let (_, store, settings, grant, id, _) = try configured()
            var time: TimeInterval = 0, backups = 0
            let run = CleanupFailoverRun()
            var pipeline = Pipeline(outputSettings: settings, bundleID: nil, failureLogging: .contentFree) { selected in
                try makeOrdinaryCleanupClient(settings: selected, origin: .physicalOrdinary, grant: grant, operationID: id,
                    store: store, env: [:], credentials: store.credentials, primaryDriver: FailoverPrimary(post: { request in
                        time = 15; return self.response(request, status: status)
                    }).driver, backupDriver: { _, _ in backups += 1; return FailoverHandle(start: {}) }, now: { time }, run: run, shouldContinue: { true })
            }
            pipeline.failoverRun = run
            let result = await pipeline.clean(transcript: "raw")
            await run.drain()
            XCTAssertNotNil(result.failure); XCTAssertEqual(result.text, "raw"); XCTAssertEqual(backups, 0)
            XCTAssertNil(run.snapshot.acceptedProducerOrdinal); XCTAssertTrue(run.metrics.isEmpty)
        }
    }
    func testMalformedBlockRecoveryPreservesNondefaultGlobalsAndStrictWritesRefuse() throws {
        for block in ["null", "{\"version\":2,\"backups\":[]}", "{\"version\":1,\"backups\":\"bad\"}"] {
            var settings = Settings(); settings.historyEnabled = false; settings.recoveryAudioEnabled = false
            settings.historyTextCount = 77; settings.recoveryAudioDays = 3; settings.language = "hi"
            let memory = try FailoverMemory(settings), store = memory.store(FakeCredentialBackend())
            var object = try JSONSerialization.jsonObject(with: memory.bytes!) as! [String: Any]
            object["cleanupFailover"] = try JSONSerialization.jsonObject(with: Data(block.utf8), options: [.fragmentsAllowed])
            memory.bytes = try JSONSerialization.data(withJSONObject: object); let original = memory.bytes
            let recovered = store.load()
            XCTAssertFalse(recovered.historyEnabled); XCTAssertFalse(recovered.recoveryAudioEnabled)
            XCTAssertEqual(recovered.language, "hi"); XCTAssertEqual(recovered.historyTextCount, 77); XCTAssertEqual(recovered.recoveryAudioDays, 3)
            XCTAssertNil(recovered.cleanupFailover); XCTAssertNotNil(store.lastError)
            XCTAssertThrowsError(try store.savedRetrySnapshot()); XCTAssertThrowsError(try store.save(recovered))
            XCTAssertEqual(memory.bytes, original)
        }
    }
}


extension CleanupFailoverTests {
    func testB21IdentityOrderingCapsSourcesAndStaleDigest() throws {
        var s = B21SettingsDocument.primary
        let a = CleanupBackup(baseURL: "https://backup.test/v1/", model: String(repeating: "m", count: 160), source: .keylessCompatible)
        try a.validate(); var tooLong = a; tooLong.model += "m"; XCTAssertThrowsError(try tooLong.validate())
        var env = a; env.source = .namedEnvironment; env.environmentName = String(repeating: "A", count: 128); try env.validate()
        env.environmentName! += "A"; XCTAssertThrowsError(try env.validate())
        var b = a; b.model = "second"
        var p = CleanupFailoverPolicy(backups: [a,b]); try p.confirm(primary: .primary(s)); s.cleanupFailover = p
        XCTAssertTrue(p.isReviewed(for: s)); s.cleanup.model = "other"; XCTAssertFalse(p.isReviewed(for: s))
        var swapped = p; swapped.backups.swapAt(0,1); XCTAssertFalse(swapped.isReviewed(for: B21SettingsDocument.primary))
        XCTAssertThrowsError(try CleanupFailoverPolicy(backups: [a,a]).validate())
        XCTAssertThrowsError(try CleanupFailoverPolicy(backups: [a,b,a]).validate())
        var same = B21SettingsDocument.primary; same.cleanup.baseURL = "https://BACKUP.test/v1/"; same.cleanup.model = a.model
        XCTAssertThrowsError(try CleanupFailoverPolicy(backups: [a]).digest(primary: .primary(same)))
    }
    func testB21TwoBackupsSameInputAndInvalidReturnedCandidateStops() async throws {
        for invalid in [false,true] {
            let d = try B21SettingsDocument(B21SettingsDocument.primary)
            let s = try d.enable([.init(baseURL: "https://one.test/v1", model: "one", source: .keylessCompatible),
                                  .init(baseURL: "https://two.test/v1", model: "two", source: .keylessCompatible)])
            let id = UUID(), grant = try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings: s, origin: .physicalOrdinary)).bound(to:id)
            var requests: [URLRequest] = []; let run = CleanupFailoverRun()
            var p = Pipeline(outputSettings: s, bundleID: nil, failureLogging: .contentFree) { selected in
                try makeOrdinaryCleanupClient(settings:selected, origin:.physicalOrdinary, grant:grant, operationID:id, store:d.store,
                    env:[:], credentials:d.store.credentials, primaryDriver:FailoverPrimary(post:{r in self.response(r,status:503)}).driver, backupDriver:{r,c in
                        requests.append(r); let status = invalid || requests.count == 2 ? 200 : 529
                        return FailoverHandle(start:{
                            let (data,response) = self.response(r,status:status,text:invalid ? String(repeating:"x",count:20000) : "Polished.")
                            _ = c.response(response as! HTTPURLResponse); _ = c.data(data); c.completed(nil); c.exited()
                        })
                    }, run:run, shouldContinue:{true})
            }; p.failoverRun = run
            let result = await p.clean(transcript:"polished")
            await run.drain()
            XCTAssertEqual(requests.count,invalid ? 1 : 2)
            if invalid { XCTAssertNotNil(result.failure); XCTAssertNil(run.snapshot.acceptedProducerOrdinal) }
            else { XCTAssertNil(result.failure); XCTAssertEqual(run.snapshot.acceptedProducerOrdinal,2) }
            for r in requests { XCTAssertTrue(String(decoding:r.httpBody!,as:UTF8.self).contains("polished")); XCTAssertFalse(r.url!.path.contains("models")) }
        }
    }
    func testB21BackupSourceMissingAndRevocationDuringCredentialNeverConstructs() async throws {
        for revoke in [false,true] {
            let d = try B21SettingsDocument(B21SettingsDocument.primary)
            let row = CleanupBackup(baseURL:"https://backup.test/v1",model:"backup",source:.scopedKeychain)
            let s = try d.enable([row]), id = UUID()
            let grant = try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings:s,origin:.physicalOrdinary)).bound(to:id)
            if revoke { d.backend.values[try .compatible(row.baseURL)] = "backup-key" }
            d.backend.onRead = { if d.backend.reads == 2, revoke { d.store.revokeCleanupFailover() } }
            var constructs = 0; let run = CleanupFailoverRun()
            let client = try makeOrdinaryCleanupClient(settings:s,origin:.physicalOrdinary,grant:grant,operationID:id,store:d.store,
                env:["ANTHROPIC_API_KEY":"not-a-fallback"],credentials:d.store.credentials,
                primaryDriver:FailoverPrimary(post:{r in self.response(r,status:503)}).driver,backupDriver:{_,_ in constructs += 1; return FailoverHandle(start:{})},run:run,shouldContinue:{true})
            do { _ = try await client.clean(transcript:"source",context:.init(dictionary:[],snippets:[:],appName:nil)); XCTFail("Must stop") } catch {}
            await run.drain()
            XCTAssertEqual(constructs,0); XCTAssertEqual(d.backend.interactiveReads,[false,false]); XCTAssertEqual(d.backend.statuses,0)
        }
    }
    func testB21BudgetStartsBeforeCredentialAndThreeSecondBackupBoundary() async throws {
        for timeAtPrimaryReturn in [11.999,12,12.001,15] {
            let (_,store,s,grant,id,_) = try configured(); var time = 0.0, backups = 0
            let run = CleanupFailoverRun()
            let client = try makeOrdinaryCleanupClient(settings:s,origin:.physicalOrdinary,grant:grant,operationID:id,store:store,
                env:[:],credentials:store.credentials,primaryDriver:FailoverPrimary(post:{r in time = timeAtPrimaryReturn;return self.response(r,status:503)}).driver,
                backupDriver:{r,c in backups += 1;return FailoverHandle(start:{let(data,response)=self.response(r,status:200);_=c.response(response as! HTTPURLResponse);_=c.data(data);c.completed(nil);c.exited()})},
                now:{time},run:run,shouldContinue:{true})
            do { _ = try await client.clean(transcript:"source",context:.init(dictionary:[],snippets:[:],appName:nil)); try run.adjudicate(accepted: true) } catch {}
            await run.drain()
            XCTAssertEqual(backups,timeAtPrimaryReturn <= 12 ? 1 : 0)
        }
        let (_,store,s,grant,id,backend) = try configured(); var time = 0.0, posts = 0; let setupRun = CleanupFailoverRun()
        backend.onRead = {time = 15}
        let client = try makeOrdinaryCleanupClient(settings:s,origin:.physicalOrdinary,grant:grant,operationID:id,store:store,env:[:],credentials:store.credentials,
            primaryDriver:FailoverPrimary(post:{r in posts += 1;return self.response(r,status:200)}).driver,backupDriver:{_,_ in XCTFail("No backup");return FailoverHandle(start:{})},now:{time},run:setupRun,shouldContinue:{true})
        do {_ = try await client.clean(transcript:"source",context:.init(dictionary:[],snippets:[:],appName:nil));XCTFail("Expired setup")}catch{}
        await setupRun.drain(); XCTAssertEqual(posts,0)
    }
}


extension CleanupFailoverTests {
    func testB21RealAdaptersTypedTransientSemanticAndContentStopMatrix() async throws {
        let cases:[(Int,URLError.Code?,String,Bool)] = [
            (408,nil,"{}",true),(429,nil,"{}",true),(500,nil,"{}",true),(503,nil,"{}",true),(529,nil,"{}",true),(599,nil,"{}",true),
            (503,nil,"{\"error\":{\"code\":\"expired_api_key\"}}",false),
            (529,nil,"{\"error\":{\"type\":\"authentication_error\"}}",false),
            (503,nil,"{\"error\":{\"code\":\"content_filter\"}}",false),
            (503,nil,"{\"error\":{\"code\":\"model_not_found\"}}",false),
            (302,nil,"{}",false),(401,nil,"{}",false),(400,nil,"{}",false),
            (200,nil,"{}",false),(200,nil,"not-json",false),
            (200,nil,"{\"choices\":[{\"message\":{\"content\":\"\"}}]}",false),
            (200,nil,"{\"choices\":[{\"message\":{\"content\":\"partial\"},\"finish_reason\":\"length\"}]}",false),
            (200,nil,"{\"choices\":[{\"message\":{\"content\":\"text\",\"refusal\":\"private-refusal\"}}]}",false),
            (0,.timedOut,"",true),(0,.networkConnectionLost,"",true),
            (0,.cancelled,"",false),(0,.secureConnectionFailed,"",false),(0,.serverCertificateUntrusted,"",false),(0,.userAuthenticationRequired,"",false),(0,.unknown,"",false)]
        for backupFailure in [false,true] {
            for (status,urlError,body,proceed) in cases {
                let d=try B21SettingsDocument(B21SettingsDocument.primary)
                let rows=[CleanupBackup(baseURL:"https://one.test/v1",model:"one",source:.keylessCompatible),
                          CleanupBackup(baseURL:"https://two.test/v1",model:"two",source:.keylessCompatible)]
                let s=try d.enable(rows),id=UUID(),grant=try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings:s,origin:.physicalOrdinary)).bound(to:id)
                var backups=0;let run=CleanupFailoverRun()
                var p=Pipeline(outputSettings:s,bundleID:nil,failureLogging:.contentFree){selected in
                    try makeOrdinaryCleanupClient(settings:selected,origin:.physicalOrdinary,grant:grant,operationID:id,store:d.store,env:[:],credentials:d.store.credentials,
                        primaryDriver:FailoverPrimary(post:{r in
                            if backupFailure{return self.response(r,status:503)}
                            if let urlError{throw URLError(urlError)}
                            return(Data(body.utf8),HTTPURLResponse(url:r.url!,statusCode:status,httpVersion:nil,headerFields:nil)!)
                        }).driver,backupDriver:{r,c in
                            backups += 1;let first=backups == 1
                            return FailoverHandle(start:{
                                if backupFailure && first {
                                    if let urlError {c.completed(URLError(urlError));c.exited();return}
                                    _=c.response(HTTPURLResponse(url:r.url!,statusCode:status,httpVersion:nil,headerFields:nil)!);_=c.data(Data(body.utf8))
                                }else{let(b,response)=self.response(r,status:200);_=c.response(response as! HTTPURLResponse);_=c.data(b)}
                                c.completed(nil);c.exited()
                            })
                        },run:run,shouldContinue:{true})
                };p.failoverRun=run
                let result=await p.clean(transcript:"polished")
            await run.drain()
                XCTAssertEqual(backups,(backupFailure ? 1 : 0)+(proceed ? 1 : 0),"status \(status), URL \(String(describing:urlError)), backup arm \(backupFailure)")
                XCTAssertEqual(result.failure == nil,proceed)
                XCTAssertEqual(run.snapshot.acceptedProducerOrdinal,proceed ? (backupFailure ? 2 : 1):nil)
            }
        }
    }
    func testB21PrimaryAndBackupPromptExactCapAndNoTruncation() async throws {
        let context=CleanupContext(dictionary:[],snippets:[:],appName:nil)
        let overhead=PromptBuilder.system(context:context).utf8.count + PromptBuilder.user(transcript:"",context:context).utf8.count
        for extra in [0,1] {
            let (_,store,s,grant,id,_)=try configured();var primaryBytes=0,backups=0;let run=CleanupFailoverRun()
            let client=try makeOrdinaryCleanupClient(settings:s,origin:.physicalOrdinary,grant:grant,operationID:id,store:store,env:[:],credentials:store.credentials,
                primaryDriver:FailoverPrimary(post:{r in primaryBytes=r.httpBody!.count;return self.response(r,status:503)}).driver,backupDriver:{r,c in
                    backups += 1;return FailoverHandle(start:{let(b,response)=self.response(r,status:200);_=c.response(response as! HTTPURLResponse);_=c.data(b);c.completed(nil);c.exited()})
                },run:run,shouldContinue:{true})
            do {_=try await client.clean(transcript:String(repeating:"x",count:16*1024-overhead+extra),context:context);try run.adjudicate(accepted:true);XCTAssertEqual(extra,0)}catch{XCTAssertEqual(extra,1)}
            await run.drain(); XCTAssertEqual(primaryBytes > 16*1024,extra == 0);XCTAssertEqual(backups,extra == 0 ? 1:0)
        }
    }
    func testB21OnceOnlyLiteralsQuotesAndLockedSnippet() async throws {
        for locked in [false,true] {
            let (_,store,initial,grant,id,_)=try configured();var s=initial
            s.replacements=[.init(source:"Polished.",replacement:"next"),.init(source:"next",replacement:"wrong")]
            if locked{s.snippets=["polished":"locked"]}
            var posts=0;let run=CleanupFailoverRun()
            var p=Pipeline(outputSettings:s,bundleID:nil,failureLogging:.contentFree){selected in
                try makeOrdinaryCleanupClient(settings:selected,origin:.physicalOrdinary,grant:grant,operationID:id,store:store,env:[:],credentials:store.credentials,
                    primaryDriver:FailoverPrimary(post:{r in posts += 1;return self.response(r,status:200,text:"'Polished.'")}).driver,backupDriver:{_,_ in XCTFail("No backup on valid candidate");return FailoverHandle(start:{})},run:run,shouldContinue:{true})
            };p.failoverRun=run
            let result=await p.clean(transcript:"polished")
            await run.drain()
            XCTAssertEqual(result.text,locked ? "locked":"next");XCTAssertEqual(posts,locked ? 0:1)
        }
    }
}

private final class FailoverClock: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0.0
    var now: TimeInterval { lock.withLock { value } }
    func set(_ time: TimeInterval) { lock.withLock { value = time } }
}
private final class FailoverGate: @unchecked Sendable {
    private let lock = NSLock(); private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock { if open { return true }; waiters.append(continuation); return false }
            if ready { continuation.resume() }
        }
    }
    func release() {
        let pending = lock.withLock { open = true; let pending = waiters; waiters = []; return pending }
        for continuation in pending { continuation.resume() }
    }
}
extension CleanupFailoverTests {
    func testB21FinalSealRechecksClockAfterExternalAcceptanceAndCannotRevive() async throws {
        for time in [14.999, 15, 15.001] {
            let clock = FailoverClock(), run = CleanupFailoverRun()
            let policy = HistoryRetryExecutionPolicy(planned: 1, budget: 15, now: { clock.now })
            let text = try await run.start(policy: policy, check: { try policy.check() }) {
                let i = run.begin(B21SettingsDocument.primary); run.started(i); run.usage(i, model: "private", input: 12, output: 3)
                run.candidate(i, acceptance: { clock.set(time) }); return "Polished."
            }
            XCTAssertEqual(text, "Polished.")
            if time < 15 { try run.adjudicate(accepted: true); XCTAssertEqual(run.snapshot.acceptedProducerOrdinal, 0) }
            else { XCTAssertThrowsError(try run.adjudicate(accepted: true)); XCTAssertNil(run.snapshot.acceptedProducerOrdinal) }
            let frozen = run.snapshot
            clock.set(0); run.usage(0, model: "late", input: 999, output: 999); run.outcome(0, .returned)
            if time >= 15 { XCTAssertThrowsError(try run.adjudicate(accepted: true)) }
            XCTAssertEqual(run.snapshot, frozen); await run.drain()
        }
    }
    func testB21LogicalDeadlineOwnsLateWorkerAndSlowWatchdogDrain() async throws {
        for lateFailure in [false, true] {
            let clock = FailoverClock(), sleep = FailoverGate(), worker = FailoverGate(), run = CleanupFailoverRun()
            let entered = expectation(description: "worker")
            let policy = HistoryRetryExecutionPolicy(planned: 1, budget: 15, now: { clock.now }, sleep: { _ in await sleep.wait() })
            let caller = Task { () -> Bool in
                do { _ = try await run.start(policy: policy, check: { try policy.check() }) {
                    let i = run.begin(B21SettingsDocument.primary); run.started(i); entered.fulfill(); await worker.wait()
                    run.usage(i, model: "late", input: 999, output: 999); run.candidate(i, acceptance: {})
                    if lateFailure { throw URLError(.timedOut) }; return "Late result."
                }; return false } catch { return true }
            }
            await fulfillment(of: [entered], timeout: 3)
            clock.set(15); sleep.release()
            let selectedDeadline = await caller.value; XCTAssertTrue(selectedDeadline)
            let frozen = run.snapshot; XCTAssertNil(frozen.acceptedProducerOrdinal)
            worker.release(); await run.drain(); XCTAssertEqual(run.snapshot, frozen)
        }
        let clock = FailoverClock(), sleep = FailoverGate(), run = CleanupFailoverRun()
        let sleeping = expectation(description: "watchdog")
        let policy = HistoryRetryExecutionPolicy(planned: 1, now: { clock.now }, sleep: { _ in sleeping.fulfill(); await sleep.wait() })
        _ = try await run.start(policy: policy, check: {}) { let i = run.begin(B21SettingsDocument.primary); run.candidate(i, acceptance: {}); return "Polished." }
        try run.adjudicate(accepted: true)
        await fulfillment(of: [sleeping], timeout: 3)
        let drained = expectation(description: "drained"), drain = Task { await run.drain(); drained.fulfill() }
        // Watchdog cancellation is not exit; release is unconditional.
        sleep.release(); await drain.value; await fulfillment(of: [drained], timeout: 3)
    }
    func testB21CancellationBeforeAdmissionCannotStartWorker() async {
        let gate = FailoverGate(), admission = expectation(description: "admission")
        let run = CleanupFailoverRun(admit: { admission.fulfill(); await gate.wait(); return true })
        let policy = HistoryRetryExecutionPolicy(planned: 1)
        let caller = Task {
            do { _ = try await run.start(policy: policy, check: { try policy.check() }) { XCTFail("Canceled worker"); return "late" }; XCTFail("Canceled result") } catch {}
        }
        await fulfillment(of: [admission], timeout: 3); caller.cancel(); gate.release(); await caller.value; await run.drain()
        XCTAssertTrue(run.snapshot.attempts.isEmpty); XCTAssertNil(run.snapshot.acceptedProducerOrdinal)
    }
    func testB21OldReviewDecodesButNeedsNewContractConfirmation() throws {
        let (_, store, settings, _, _, _) = try configured()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var policy = try XCTUnwrap(settings.cleanupFailover)
        let identities = [try CleanupChainIdentity.primary(settings)] + (try policy.backups.map { try $0.identity() })
        // Prior contract encoded just the ordered identity array.
        let oldDigest = SHA256.hash(data: try encoder.encode(identities)).map { String(format: "%02x", $0) }.joined()
        policy.review = .init(primary: try .primary(settings), digest: oldDigest, revision: UUID())
        var old = settings; old.cleanupFailover = policy
        let decoded = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(old))
        XCTAssertNotNil(decoded.cleanupFailover?.review); XCTAssertFalse(policy.isReviewed(for: decoded))
        _ = try store.confirmCleanupFailover(store.reviewCleanupFailover(backups: policy.backups)); XCTAssertTrue(store.load().cleanupFailover!.isReviewed(for: store.load()))
    }
    func testB21PrimaryBoundsBothAdaptersAndPrimitiveKeepsDefaults() async throws {
        for anthropic in [false, true] {
            for kind in ["response", "headers", "redirect"] {
                var settings = B21SettingsDocument.primary
                if anthropic { settings.cleanup.provider = "anthropic" }
                let d = try B21SettingsDocument(settings)
                let s = try d.enable([.init(baseURL: "https://backup.test/v1", model: "backup", source: .keylessCompatible)])
                let id = UUID(), grant = try XCTUnwrap(d.store.captureCleanupFailoverGrant(settings: s, origin: .physicalOrdinary)).bound(to: id), run = CleanupFailoverRun()
                var requests = 0
                var p = Pipeline(outputSettings: s, bundleID: nil, failureLogging: .contentFree) { selected in
                    try makeOrdinaryCleanupClient(settings: selected, origin: .physicalOrdinary, grant: grant, operationID: id, store: d.store,
                        env: ["ANTHROPIC_API_KEY": "synthetic-key"], credentials: d.store.credentials, primaryDriver: { r, c in
                            requests += 1; XCTAssertLessThanOrEqual(r.timeoutInterval, 15)
                            return FailoverHandle(start: {
                                if kind == "redirect" { c.redirect() }
                                else {
                                    let headers = kind == "headers" ? ["X-Test": String(repeating: "x", count: 16 * 1024)] : [:]
                                    _ = c.response(HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!)
                                    if kind == "response" { _ = c.data(Data(repeating: 65, count: 256 * 1024 + 1)) }
                                }
                                c.completed(nil); c.exited()
                            })
                        }, backupDriver: { _, _ in XCTFail("Bounds stop chain"); return FailoverHandle(start: {}) }, run: run, shouldContinue: { true })
                }; p.failoverRun = run
                let result = await p.clean(transcript: "polished"); await run.drain()
                XCTAssertNotNil(result.failure); XCTAssertEqual(requests, 1); XCTAssertTrue(run.metrics.isEmpty)
            }
        }
        var settings = B21SettingsDocument.primary; settings.cleanup.apiKey = nil
        let backend = FakeCredentialBackend(); var bytes = 0
        let primitive = try makeCleanupClient(settings: settings, env: [:], credentials: CredentialStore(backend: backend), http: FailoverPrimary(post: { r in
            bytes = r.httpBody!.count; XCTAssertEqual(r.timeoutInterval, 15); return self.response(r, status: 200)
        }), usage: { _, _, _ in })
        _ = try await primitive.clean(transcript: String(repeating: "x", count: 20 * 1024), context: .init(dictionary: [], snippets: [:], appName: nil))
        XCTAssertGreaterThan(bytes, 20 * 1024); XCTAssertEqual(backend.interactiveReads, [true])
    }
}

extension CleanupFailoverTests {
    func testB21FrozenPrimarySurvivesDisableButBackupCandidateCannotBeAcceptedAfterRevocation() async throws {
        for backup in [false, true] {
            let (_, store, s, grant, id, _) = try configured(); let run = CleanupFailoverRun()
            let client = try makeOrdinaryCleanupClient(settings: s, origin: .physicalOrdinary, grant: grant, operationID: id, store: store,
                env: [:], credentials: store.credentials, primaryDriver: { r, c in
                    FailoverHandle(start: {
                        if !backup { store.revokeCleanupFailover() }
                        let (data, response) = self.response(r, status: backup ? 503 : 200)
                        _ = c.response(response as! HTTPURLResponse); _ = c.data(data); c.completed(nil); c.exited()
                    })
                }, backupDriver: { r, c in FailoverHandle(start: {
                    let (data, response) = self.response(r, status: 200)
                    _ = c.response(response as! HTTPURLResponse); _ = c.data(data); c.completed(nil); c.exited()
                }) }, run: run, shouldContinue: { true })
            do {
                _ = try await client.clean(transcript: "polished", context: .init(dictionary: [], snippets: [:], appName: nil))
                if backup { store.revokeCleanupFailover(); XCTAssertThrowsError(try run.adjudicate(accepted: true)) }
                else { try run.adjudicate(accepted: true) }
            } catch { XCTFail("Primary frozen intent / candidate handoff: \(error)") }
            await run.drain(); XCTAssertEqual(run.snapshot.acceptedProducerOrdinal, backup ? nil : 0)
        }
    }
    func testB21PrimaryCredentialPrecedenceAndNoninteractiveRefusals() throws {
        var s = B21SettingsDocument.primary; s.cleanup.apiKeyEnvVar = "B21_KEY"
        let backend = FakeCredentialBackend(), credentials = CredentialStore(backend: backend)
        s.cleanup.apiKey = "legacy-must-refuse"
        _ = try resolveOrdinaryFailoverPrimaryCredential(settings: s, env: ["B21_KEY": "synthetic-env"], credentials: credentials)
        XCTAssertEqual(backend.reads, 0)
        XCTAssertThrowsError(try resolveOrdinaryFailoverPrimaryCredential(settings: s, env: [:], credentials: credentials))
        XCTAssertEqual(backend.reads, 0); s.cleanup.apiKey = nil
        _ = try resolveOrdinaryFailoverPrimaryCredential(settings: s, env: [:], credentials: credentials)
        XCTAssertEqual(backend.interactiveReads, [false]) // compatible missing is keyless
        for state in [CredentialRead.denied, .canceled, .error] {
            backend.readState = state
            XCTAssertThrowsError(try resolveOrdinaryFailoverPrimaryCredential(settings: s, env: [:], credentials: credentials))
        }
        s.cleanup.provider = "anthropic"; backend.readState = .missing
        XCTAssertThrowsError(try resolveOrdinaryFailoverPrimaryCredential(settings: s, env: [:], credentials: credentials))
        XCTAssertTrue(backend.interactiveReads.allSatisfy { !$0 }); XCTAssertEqual(backend.statuses, 0)
    }
}
