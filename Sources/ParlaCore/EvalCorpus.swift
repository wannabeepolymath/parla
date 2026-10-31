import Foundation

/// Finite diagnostics never interpolate untrusted text, paths or decoder errors.
public enum EvalCorpusError: String, Error, LocalizedError {
    case arguments, json, schema, bounds, duplicate, path, unreadable, fileKind
    case changed, binding, attestation, consent, provenance, reference, split, coverage, route
    public var errorDescription: String? {
        "corpus-check refused: \(rawValue)" + (self == .path ? "; select a canonical non-symlink path with supported components" : "")
    }
}

/// Bounded offline admission and reporting; never creates a model or writes.
public enum EvalCorpus {
    public static let limitations = "Declarations only: consent truth/legal adequacy, human origin, reference correctness, engine identity and pretraining exposure are unverified; later withdrawals require a refreshed snapshot. File observations are not an atomic filesystem transaction."
    struct Selection {
        let manifest: String, results: String?, against: String?
    }
    static func selection(_ arguments: [String]) throws -> Selection {
        guard arguments.first == "corpus-check", arguments.count >= 2,
              !arguments[1].hasPrefix("-"), !arguments[1].isEmpty else { throw EvalCorpusError.arguments }
        var results: String?, against: String?
        var index = 2
        while index < arguments.count {
            let flag = arguments[index]
            guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-"),
                  !arguments[index + 1].isEmpty else { throw EvalCorpusError.arguments }
            switch flag {
            case "--results":
                guard results == nil else { throw EvalCorpusError.arguments }
                results = arguments[index + 1]
            case "--against":
                guard against == nil else { throw EvalCorpusError.arguments }
                against = arguments[index + 1]
            default: throw EvalCorpusError.arguments
            }
            index += 2
        }
        guard against == nil || results != nil else { throw EvalCorpusError.arguments }
        return Selection(manifest: arguments[1], results: results, against: against)
    }
    public static func check(arguments: [String]) throws -> String {
        try evaluate(selection(arguments))
    }
    /// Internal deterministic clock/read seams; production dispatch exposes neither.
    static func evaluate(_ selection: Selection, clock: () -> TimeInterval = { Date().timeIntervalSince1970 },
                         afterRead: (() throws -> Void)? = nil) throws -> String {
        let now = clock()
        let io = try EvalCorpusIO(manifest: selection.manifest)
        io.afterRead = afterRead
        let snapshot = try io.manifest(selection.manifest)
        let manifest = try Manifest(EvalCorpusJSON.parse(snapshot.data), digest: snapshot.digest, io: io, now: now)
        var runs: [Run] = []
        for path in [selection.results, selection.against].compactMap({ $0 }) {
            let saved = try io.run(path)
            runs.append(try Run(EvalCorpusJSON.parse(saved.data), manifest: manifest))
        }
        if runs.count == 2 { try comparable(runs[0], runs[1]) }
        // Validate all inputs and combined workload before the first quadratic scorer call.
        var cells = 0
        for run in runs {
            for row in run.rows where row.status == "success" {
                let reference = manifest.cases[row.caseID]!.reference(row.leg)
                let a = try tokenCount(reference.body), b = try tokenCount(row.hypothesis!)
                let (product, overflow) = (a + 1).multipliedReportingOverflow(by: b + 1)
                guard !overflow else { throw EvalCorpusError.bounds }
                try add(product, to: &cells, max: 16_777_216)
            }
        }
        try io.revalidate()
        // Permission is checked again at use-time, not just at header admission.
        try manifest.permission(runs: runs, now: clock())
        var lines = ["corpus-check: admitted declared bindings; exit 0 is not a quality pass",
                     "manifest-sha256=\(snapshot.digest) revision=\(manifest.revision) purpose=\(manifest.purpose)",
                     "declared=\(manifest.cases.count) eligible=\(manifest.cases.count) speakers=\(manifest.identities.count) takes=\(manifest.cases.count) repetition-groups=\(Set(manifest.cases.values.map(\.repetitionGroup)).count)",
                     limitations,
                     "Cohorts overlap and are not additive; holdout is a project split attestation, not proof of unseen pretraining. No speech/audio decoding performed."]
        for (name, ids) in groups(manifest) {
            let identities = Set(ids.flatMap { manifest.cases[$0]!.speakerIDs.map { manifest.speakers[$0]!.group } })
            lines.append("inventory \(name) declared=\(ids.count) eligible=\(ids.count) speakers=\(identities.count) takes=\(ids.count)")
        }
        if runs.isEmpty {
            lines.append("Metadata/bindings checked; no model quality measured.")
        } else {
            lines.append("Recorded hypotheses rescored; human qualification and generator/engine truth unverified. No live quality, latency or memory measurement.")
            var scored: [[String: Score]] = []
            for run in runs {
                var cache: [String: Score] = [:]
                for row in run.rows where row.status == "success" {
                    let ref = manifest.cases[row.caseID]!.reference(row.leg).body
                    let hyp = row.hypothesis!
                    cache[row.key] = Score(wer: Eval.wer(reference: ref, hypothesis: hyp),
                                           zero: Eval.normalize(ref) == Eval.normalize(hyp),
                                           structure: Eval.normalizeStructure(ref) == Eval.normalizeStructure(hyp),
                                           newline: Eval.newlineLayout(ref) == Eval.newlineLayout(hyp))
                }
                scored.append(cache)
                lines += report(run, manifest: manifest, scores: cache)
            }
            if runs.count == 2 { lines += paired(runs[0], runs[1], manifest: manifest, a: scored[0], b: scored[1]) }
        }
        // Recheck observations and current declared permission at reporting time.
        // This narrows race windows; it still cannot create an atomic snapshot.
        try io.revalidate()
        try manifest.permission(runs: runs, now: clock())
        return lines.joined(separator: "\n")
    }

    /// Identical extraction of the legacy parser, shared without changing headers/body behavior.
    public static func parseCaseFile(_ text: String) -> (headers: [String: String], body: String) {
        let headerKeys: Set<String> = ["category", "app", "bundle"]
        var headers: [String: String] = [:]
        var lines = ArraySlice(text.components(separatedBy: "\n"))
        while let line = lines.first, line.hasPrefix("#") {
            let parts = line.dropFirst().split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { break }
            let key = parts[0].trimmingCharacters(in: .whitespaces)
            guard headerKeys.contains(key) else { break }
            headers[key] = parts[1].trimmingCharacters(in: .whitespaces)
            lines = lines.dropFirst()
        }
        return (headers, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }
    static func tokenCount(_ text: String) throws -> Int {
        guard text.utf8.count <= 32_768 else { throw EvalCorpusError.bounds }
        let count = Eval.werTokens(text).count
        guard count <= 2048 else { throw EvalCorpusError.bounds }
        return count
    }
    private static func add(_ count: Int, to total: inout Int, max: Int) throws {
        let (sum, overflow) = total.addingReportingOverflow(count)
        guard count >= 0, !overflow, sum <= max else { throw EvalCorpusError.bounds }
        total = sum
    }
    struct Speaker {
        let id: String, group: String, cohorts: Set<String>
        init(_ json: EvalCorpusJSON) throws {
            let o = try json.object("id identityGroup identityKnown aliasesReconciled cohorts")
            id = try o.field("id").id(); group = try o.field("identityGroup").id()
            try o.field("identityKnown").attested(); try o.field("aliasesReconciled").attested()
            cohorts = Set(try o.field("cohorts").ids(limit: 32))
        }
    }
    struct Consent {
        let id: String, speakers: Set<String>, uses: Set<String>, destinations: Set<String>
        let effective: Int, reviewed: Int, retention: Int
        let active: Bool
        init(_ json: EvalCorpusJSON) throws {
            let o = try json.object("id revision speakerIDs attester effectiveAt reviewedAt retentionUntil status withdrawalEffectiveAt uses destinations accessPolicyRevision withdrawalPolicyRevision")
            id = try o.field("id").id()
            for key in ["revision", "attester", "accessPolicyRevision", "withdrawalPolicyRevision"] { _ = try o.field(key).id() }
            speakers = Set(try o.field("speakerIDs").ids(limit: 128))
            guard !speakers.isEmpty else { throw EvalCorpusError.consent }
            uses = try o.field("uses").choices("binding-check reference-review asr cleanup", limit: 4)
            destinations = try o.field("destinations").choices("local provider external-command", limit: 3)
            effective = try o.field("effectiveAt").integer(); reviewed = try o.field("reviewedAt").integer()
            retention = try o.field("retentionUntil").integer()
            let status = try o.field("status").choice("active pending unknown withdrawn revoked")
            let withdrawal = try o.field("withdrawalEffectiveAt")
            if !withdrawal.isNull { _ = try withdrawal.integer() }
            active = status == "active" && withdrawal.isNull
        }
        func permits(_ requiredUses: Set<String>, _ requiredDestinations: Set<String>, snapshot: Int, now: Double) -> Bool {
            active && effective <= reviewed && reviewed <= snapshot && Double(snapshot) <= now && now < Double(retention)
                && requiredUses.isSubset(of: uses) && requiredDestinations.isSubset(of: destinations)
        }
    }
    struct Reference {
        let hash: String, revision: String, body: String
        init(_ json: EvalCorpusJSON, audio: String, take: String, human: Bool, verbatim: Bool,
             snapshot: Int, io: EvalCorpusIO, bytes: inout Int) throws {
            let o = try json.object("path sha256 revision review reviewer reviewedAt audioSHA256 takeID draftOrigin")
            hash = try o.field("sha256").hash(); revision = try o.field("revision").id()
            _ = try o.field("reviewer").id()
            guard try o.field("review").choice("reviewed unresolved") == "reviewed",
                  try o.field("reviewedAt").integer() <= snapshot,
                  try o.field("audioSHA256").hash() == audio,
                  try o.field("takeID").id() == take else { throw EvalCorpusError.reference }
            let origin = try o.field("draftOrigin").choice("independent-human hypothesis-assisted script authored")
            guard !human || (verbatim ? ["independent-human", "hypothesis-assisted"].contains(origin) : origin != "script") else {
                throw EvalCorpusError.reference
            }
            let file = try io.payload(o.field("path").string(), extension: ".txt", limit: 32_768, retain: true)
            try add(file.bytes, to: &bytes, max: 8_388_608)
            guard file.digest == hash, let text = String(data: file.data, encoding: .utf8) else { throw EvalCorpusError.binding }
            body = parseCaseFile(text).body
            _ = try tokenCount(body)
        }
    }
    struct Case {
        let id: String, provenance: String, take: String, family: String, split: String, repetitionGroup: String
        let parents: [String], speakerIDs: Set<String>, consentIDs: Set<String>, cohorts: Set<String>
        let audio: String, verbatim: Reference, cleaned: Reference
        var human: Bool { provenance == "human-speech" || provenance == "human-no-speech" }
        var noSpeech: Bool { provenance == "human-no-speech" }
        func reference(_ leg: String) -> Reference { leg == "asr" ? verbatim : cleaned }
        init(_ json: EvalCorpusJSON, purpose: String, snapshot: Int, speakers: [String: Speaker],
             cohortIDs: Set<String>, io: EvalCorpusIO, audioBytes: inout Int, refBytes: inout Int) throws {
            let o = try json.object("id provenance takeID familyID parentIDs lineageComplete speakersComplete speakerIDs consentIDs split repetitionGroup cohorts audio verbatim cleaned")
            id = try o.field("id").id(); take = try o.field("takeID").id(); family = try o.field("familyID").id()
            provenance = try o.field("provenance").choice("human-speech human-no-speech tts synthetic-signal authored unknown")
            let human = ["human-speech", "human-no-speech"].contains(provenance)
            guard provenance != "unknown", human == (purpose == "human-qualification") else { throw EvalCorpusError.provenance }
            try o.field("lineageComplete").attested(); try o.field("speakersComplete").attested()
            parents = try o.field("parentIDs").ids(limit: 256)
            guard !parents.contains(id) else { throw EvalCorpusError.split }
            speakerIDs = Set(try o.field("speakerIDs").ids(limit: 128))
            consentIDs = Set(try o.field("consentIDs").ids(limit: 256))
            guard speakerIDs.isSubset(of: Set(speakers.keys)), !human || !speakerIDs.isEmpty else { throw EvalCorpusError.attestation }
            guard human || (speakerIDs.isEmpty && consentIDs.isEmpty) else { throw EvalCorpusError.provenance }
            split = try o.field("split").choice("development holdout")
            repetitionGroup = try o.field("repetitionGroup").id()
            let tags = Set(try o.field("cohorts").ids(limit: 32))
            guard tags.isSubset(of: cohortIDs) else { throw EvalCorpusError.schema }
            cohorts = speakerIDs.reduce(tags) { $0.union(speakers[$1]!.cohorts) }
            let a = try o.field("audio").object("path sha256 bytes")
            audio = try a.field("sha256").hash()
            let size = try a.field("bytes").integer(max: 67_108_864)
            guard size > 0 else { throw EvalCorpusError.bounds }
            try add(size, to: &audioBytes, max: 536_870_912)
            let file = try io.payload(a.field("path").string(), extension: ".wav", limit: 67_108_864, retain: false)
            guard file.bytes == size, file.digest == audio else { throw EvalCorpusError.binding }
            verbatim = try Reference(o.field("verbatim"), audio: audio, take: take, human: human, verbatim: true,
                                     snapshot: snapshot, io: io, bytes: &refBytes)
            cleaned = try Reference(o.field("cleaned"), audio: audio, take: take, human: human, verbatim: false,
                                    snapshot: snapshot, io: io, bytes: &refBytes)
            if provenance == "human-no-speech" {
                guard verbatim.body.isEmpty, cleaned.body.isEmpty else { throw EvalCorpusError.reference }
            } else {
                guard try tokenCount(verbatim.body) > 0, try tokenCount(cleaned.body) > 0 else { throw EvalCorpusError.reference }
            }
        }
    }
    struct Manifest {
        let digest: String, revision: String, purpose: String, snapshot: Int
        let speakers: [String: Speaker], consents: [String: Consent], cases: [String: Case], cohortIDs: Set<String>
        var identities: Set<String> { Set(speakers.values.map(\.group)) }
        init(_ json: EvalCorpusJSON, digest: String, io: EvalCorpusIO, now: Double) throws {
            let o = try json.object("version corpusID revision purpose protocolRevision snapshotAt cohorts speakers consents cases")
            guard try o.field("version").integer() == 1 else { throw EvalCorpusError.schema }
            _ = try o.field("corpusID").id(); _ = try o.field("protocolRevision").id()
            revision = try o.field("revision").id(); self.digest = digest
            purpose = try o.field("purpose").choice("human-qualification nonhuman-regression")
            snapshot = try o.field("snapshotAt").integer()
            guard Double(snapshot) <= now, now.isFinite, now >= 0 else { throw EvalCorpusError.consent }
            var labels = Set<String>()
            for value in try o.field("cohorts").array(limit: 32) {
                let c = try value.object("id dimension")
                guard labels.insert(try c.field("id").id()).inserted else { throw EvalCorpusError.duplicate }
                _ = try c.field("dimension").choice("language accent microphone noise length other")
            }
            cohortIDs = labels
            var people: [String: Speaker] = [:]
            for value in try o.field("speakers").array(limit: 128) {
                let speaker = try Speaker(value)
                guard people[speaker.id] == nil, speaker.cohorts.isSubset(of: labels) else { throw EvalCorpusError.duplicate }
                if let alias = people.values.first(where: { $0.group == speaker.group }), alias.cohorts != speaker.cohorts {
                    throw EvalCorpusError.attestation
                }
                people[speaker.id] = speaker
            }
            speakers = people
            var consent: [String: Consent] = [:]
            for value in try o.field("consents").array(limit: 256) {
                let c = try Consent(value)
                guard consent[c.id] == nil, c.speakers.isSubset(of: Set(people.keys)) else { throw EvalCorpusError.consent }
                consent[c.id] = c
            }
            consents = consent
            var entries: [String: Case] = [:], audios = Set<String>(), takes = Set<String>()
            var audioBytes = 0, refBytes = 0, splitGroups: [String: String] = [:], parentFamilies: [String: String] = [:]
            for value in try o.field("cases").array(limit: 256) {
                let c = try Case(value, purpose: purpose, snapshot: snapshot, speakers: people, cohortIDs: labels,
                                 io: io, audioBytes: &audioBytes, refBytes: &refBytes)
                guard entries[c.id] == nil, audios.insert(c.audio).inserted, takes.insert(c.take).inserted else {
                    throw EvalCorpusError.duplicate
                }
                let groups = c.speakerIDs.map { "speaker/" + people[$0]!.group }
                    + ["family/" + c.family] + c.parents.map { "ancestor/" + $0 }
                for group in groups {
                    guard splitGroups[group] == nil || splitGroups[group] == c.split else { throw EvalCorpusError.split }
                    splitGroups[group] = c.split
                }
                for parent in c.parents {
                    guard parentFamilies[parent] == nil || parentFamilies[parent] == c.family else { throw EvalCorpusError.split }
                    parentFamilies[parent] = c.family
                }
                entries[c.id] = c
            }
            guard !entries.isEmpty else { throw EvalCorpusError.coverage }
            for c in entries.values {
                var visiting = Set<String>(), visited = Set<String>()
                func walk(_ value: Case) throws {
                    guard !visiting.contains(value.id) else { throw EvalCorpusError.split }
                    if visited.contains(value.id) { return }
                    visiting.insert(value.id)
                    for id in value.parents {
                        if let parent = entries[id] {
                            guard parent.family == value.family, parent.split == value.split else { throw EvalCorpusError.split }
                            try walk(parent)
                        }
                    }
                    visiting.remove(value.id); visited.insert(value.id)
                }
                try walk(c)
            }
            cases = entries
            guard Set(entries.values.flatMap(\.speakerIDs)) == Set(people.keys),
                  Set(entries.values.flatMap(\.consentIDs)) == Set(consent.keys),
                  Set(entries.values.flatMap(\.cohorts)) == labels else { throw EvalCorpusError.coverage }
            try permission(runs: [], now: now)
        }
        func permission(runs: [Run], now: Double) throws {
            for c in cases.values where c.human {
                var uses: Set<String> = ["binding-check", "reference-review"], destinations: Set<String> = ["local"]
                for run in runs {
                    uses.formUnion(run.legs)
                    destinations.formUnion(run.engines.values.map(\.transport))
                }
                guard !c.consentIDs.isEmpty, c.consentIDs.isSubset(of: Set(consents.keys)) else { throw EvalCorpusError.consent }
                let selected = c.consentIDs.map { consents[$0]! }
                guard selected.allSatisfy({ $0.speakers.isSubset(of: c.speakerIDs) && $0.permits(uses, destinations, snapshot: snapshot, now: now) }),
                      selected.reduce(into: Set<String>(), { $0.formUnion($1.speakers) }) == c.speakerIDs else {
                    throw EvalCorpusError.consent
                }
            }
        }
    }
    struct Engine {
        let leg: String, id: String, revision: String, config: String, transport: String
        init(_ json: EvalCorpusJSON) throws {
            let o = try json.object("leg id revision configRevision transport")
            leg = try o.field("leg").choice("asr cleanup"); id = try o.field("id").id()
            revision = try o.field("revision").id(); config = try o.field("configRevision").id()
            transport = try o.field("transport").choice("local provider external-command")
            guard leg != "asr" || transport == "local" else { throw EvalCorpusError.route }
        }
    }
    struct Row {
        let caseID: String, leg: String, audio: String, reference: String, revision: String
        let status: String, reason: String?, hypothesis: String?, seconds: Double?
        let inputOrigin: String, inputHash: String?
        var key: String { leg + "/" + caseID }
        init(_ json: EvalCorpusJSON) throws {
            let o = try json.object("caseID leg audioSHA256 referenceSHA256 referenceRevision status reason hypothesis seconds inputOrigin inputSHA256")
            caseID = try o.field("caseID").id(); leg = try o.field("leg").choice("asr cleanup")
            audio = try o.field("audioSHA256").hash(); reference = try o.field("referenceSHA256").hash()
            revision = try o.field("referenceRevision").id()
            status = try o.field("status").choice("success failed skipped")
            let why = try o.field("reason"), hyp = try o.field("hypothesis"), time = try o.field("seconds")
            reason = why.isNull ? nil : try why.choice("decode engine transport timeout cancelled upstream-failed policy not-attempted silence-gate")
            hypothesis = hyp.isNull ? nil : try hyp.string()
            seconds = time.isNull ? nil : try time.real()
            inputOrigin = try o.field("inputOrigin").choice("audio verbatim-reference asr-hypothesis unavailable")
            let hash = try o.field("inputSHA256"); inputHash = hash.isNull ? nil : try hash.hash()
            if let hypothesis { _ = try tokenCount(hypothesis) }
            switch status {
            case "success":
                guard reason == nil, hypothesis != nil, seconds != nil else { throw EvalCorpusError.coverage }
            case "failed":
                guard let reason, ["decode", "engine", "transport", "timeout", "cancelled"].contains(reason),
                      hypothesis == nil, seconds != nil,
                      reason != "decode" || leg == "asr", reason != "transport" || leg == "cleanup" else { throw EvalCorpusError.coverage }
            default:
                guard let reason, ["upstream-failed", "policy", "not-attempted", "silence-gate"].contains(reason),
                      hypothesis == nil, seconds == nil else { throw EvalCorpusError.coverage }
            }
        }
    }
    struct Run {
        let id: String, route: String, legs: Set<String>, engines: [String: Engine], rows: [Row]
        init(_ json: EvalCorpusJSON, manifest: Manifest) throws {
            let o = try json.object("version runID manifestSHA256 manifestRevision route engines rows")
            guard try o.field("version").integer() == 1,
                  try o.field("manifestSHA256").hash() == manifest.digest,
                  try o.field("manifestRevision").id() == manifest.revision else { throw EvalCorpusError.binding }
            id = try o.field("runID").id(); route = try o.field("route").choice("asr-only reference-cleanup asr-pipeline")
            legs = route == "asr-only" ? ["asr"] : (route == "reference-cleanup" ? ["cleanup"] : ["asr", "cleanup"])
            var labels: [String: Engine] = [:]
            for value in try o.field("engines").array(limit: 2) {
                let engine = try Engine(value)
                guard labels[engine.leg] == nil else { throw EvalCorpusError.duplicate }
                labels[engine.leg] = engine
            }
            guard Set(labels.keys) == legs else { throw EvalCorpusError.coverage }
            engines = labels
            var mapped: [String: Row] = [:]
            for value in try o.field("rows").array(limit: 512) {
                let row = try Row(value)
                guard let c = manifest.cases[row.caseID], legs.contains(row.leg), mapped[row.key] == nil else { throw EvalCorpusError.coverage }
                let ref = c.reference(row.leg)
                guard row.audio == c.audio, row.reference == ref.hash, row.revision == ref.revision else { throw EvalCorpusError.binding }
                mapped[row.key] = row
            }
            guard mapped.count == manifest.cases.count * legs.count else { throw EvalCorpusError.coverage }
            for row in mapped.values {
                let c = manifest.cases[row.caseID]!
                let origin: String, hash: String?
                var input: String?
                if row.leg == "asr" { origin = "audio"; hash = c.audio }
                else if route == "reference-cleanup" {
                    origin = "verbatim-reference"; input = c.verbatim.body
                    hash = EvalCorpusIO.digest(Data(c.verbatim.body.utf8))
                } else {
                    let upstream = mapped["asr/" + row.caseID]!
                    if upstream.status == "success" {
                        origin = "asr-hypothesis"; input = upstream.hypothesis!
                        hash = EvalCorpusIO.digest(Data(upstream.hypothesis!.utf8))
                        guard row.reason != "upstream-failed" else { throw EvalCorpusError.route }
                    } else {
                        origin = "unavailable"; hash = nil
                        guard row.status == "skipped", row.reason == "upstream-failed" else { throw EvalCorpusError.route }
                    }
                }
                guard row.inputOrigin == origin, row.inputHash == hash,
                      row.reason != "upstream-failed" || origin == "unavailable",
                      row.reason != "silence-gate" || (row.leg == "cleanup" && input == "") else { throw EvalCorpusError.route }
            }
            rows = mapped.values.sorted { $0.key < $1.key }
        }
    }
    private struct Score {
        let wer: Eval.WERScore, zero: Bool, structure: Bool, newline: Bool
    }
    private static func comparable(_ a: Run, _ b: Run) throws {
        guard a.id != b.id, a.route == b.route, a.legs == b.legs,
              a.legs.allSatisfy({ a.engines[$0]!.transport == b.engines[$0]!.transport }) else { throw EvalCorpusError.route }
        // Each Run already binds every scheduled row to this exact Manifest.
    }
    private static func groups(_ manifest: Manifest) -> [(String, Set<String>)] {
        [("all", Set(manifest.cases.keys))]
            + ["development", "holdout"].map { split in ("split/" + split, Set(manifest.cases.values.filter { $0.split == split }.map(\.id))) }
            + manifest.cohortIDs.sorted().map { tag in ("cohort/" + tag, Set(manifest.cases.values.filter { $0.cohorts.contains(tag) }.map(\.id))) }
    }
    private static func report(_ run: Run, manifest: Manifest, scores: [String: Score]) -> [String] {
        var lines = ["run=\(run.id) route=\(run.route)" + (run.route == "asr-pipeline" ? " pipeline-dependent cleanup" : "")]
        for leg in run.legs.sorted() {
            let engine = run.engines[leg]!
            lines.append("engine leg=\(leg) id=\(engine.id) revision=\(engine.revision) config=\(engine.config) transport=\(engine.transport) (attested)")
            for (name, ids) in groups(manifest) {
                let rows = run.rows.filter { $0.leg == leg && ids.contains($0.caseID) }
                let successes = rows.filter { $0.status == "success" }
                let spoken = successes.filter { !manifest.cases[$0.caseID]!.noSpeech }
                let controls = successes.filter { manifest.cases[$0.caseID]!.noSpeech }
                let selected = spoken.compactMap { scores[$0.key] }
                let edits = selected.reduce(0) { $0 + $1.wer.edits }, words = selected.reduce(0) { $0 + $1.wer.referenceWords }
                let wer = words > 0 ? String(format: "%.6f", Double(edits) / Double(words)) : "unavailable"
                let people = Set(ids.flatMap { manifest.cases[$0]!.speakerIDs.map { manifest.speakers[$0]!.group } })
                let failed = rows.filter { $0.status == "failed" }.count, skipped = rows.filter { $0.status == "skipped" }.count
                let bad = selected.filter { $0.wer.rate > 0.20 }.count
                lines.append("\(leg) \(name) declared=\(ids.count) eligible=\(ids.count) scheduled=\(rows.count) attempted=\(successes.count + failed) scored=\(successes.count) operational-failed=\(failed) skipped=\(skipped) speakers=\(people.count) takes=\(ids.count)")
                lines.append("  speech-scored=\(spoken.count) edits=\(edits) reference-words=\(words) WER=\(wer) quality-failed(>20%)=\(bad)/\(spoken.count) zero-edit=\(selected.filter(\.zero).count)/\(spoken.count) structure=\(selected.filter(\.structure).count)/\(spoken.count) newline=\(selected.filter(\.newline).count)/\(spoken.count)")
                lines.append("  no-speech-scheduled=\(rows.filter { manifest.cases[$0.caseID]!.noSpeech }.count) no-speech-scored=\(controls.count) hallucinations=\(controls.filter { !($0.hypothesis ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count)/\(controls.count); no-speech WER unavailable")
                for reason in Set(rows.compactMap(\.reason)).sorted() {
                    lines.append("  terminal-reason/\(reason)=\(rows.filter { $0.reason == reason }.count)/\(rows.count)")
                }
            }
        }
        lines.append("Scored-only metrics omit operational failures/skips; they do not establish complete performance. >20% is descriptive, not an admission gate.")
        return lines
    }
    private static func paired(_ left: Run, _ right: Run, manifest: Manifest, a: [String: Score], b: [String: Score]) -> [String] {
        let other = Dictionary(uniqueKeysWithValues: right.rows.map { ($0.key, $0) })
        var lines = ["paired runs=\(left.id),\(right.id); deltas apply only to both-success speech rows, not complete performance"]
        for leg in left.legs.sorted() {
            for (name, ids) in groups(manifest) {
                let rows = left.rows.filter { $0.leg == leg && ids.contains($0.caseID) }
                var both = 0, unilateral = 0, bilateral = 0, aFailed = 0, bFailed = 0, aSkipped = 0, bSkipped = 0
                var changedInputs = 0, speechPairs = 0, delta = 0.0, noSpeechPairs = 0
                var unilateralFailed = 0, bilateralFailed = 0
                for row in rows {
                    let mate = other[row.key]!
                    if row.status == "failed" && mate.status == "failed" { bilateralFailed += 1 }
                    else if row.status == "failed" || mate.status == "failed" { unilateralFailed += 1 }
                    if row.status == "failed" { aFailed += 1 }; if mate.status == "failed" { bFailed += 1 }
                    if row.status == "skipped" { aSkipped += 1 }; if mate.status == "skipped" { bSkipped += 1 }
                    if row.status == "success" && mate.status == "success" {
                        both += 1
                        if row.inputHash != mate.inputHash { changedInputs += 1 }
                        if manifest.cases[row.caseID]!.noSpeech { noSpeechPairs += 1 }
                        else { speechPairs += 1; delta += b[row.key]!.wer.rate - a[row.key]!.wer.rate }
                    } else if row.status != "success" && mate.status != "success" { bilateral += 1 }
                    else { unilateral += 1 }
                }
                let value = speechPairs > 0 ? String(format: "%.6f", delta / Double(speechPairs)) : "unavailable"
                lines.append("paired \(leg) \(name) scheduled=\(rows.count) both-success=\(both) unilateral-nonsuccess=\(unilateral) bilateral-nonsuccess=\(bilateral) unilateral-failed=\(unilateralFailed) bilateral-failed=\(bilateralFailed) A-failed=\(aFailed) B-failed=\(bFailed) A-skipped=\(aSkipped) B-skipped=\(bSkipped) speech-pairs=\(speechPairs) no-speech-pairs=\(noSpeechPairs) input-different-success-pairs=\(changedInputs) mean-paired-WER-delta=\(value)")
            }
        }
        return lines
    }
}
