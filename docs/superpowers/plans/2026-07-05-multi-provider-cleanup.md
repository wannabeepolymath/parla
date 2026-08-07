# Multi-Provider Cleanup Implementation Plan

> **EXECUTED — kept as a record.** This plan shipped — tolerant `Settings`
> decoding, `CleanupSettings`, `CleanupProviding`, `OpenAICompatClient`,
> `CleanupSanitizer`, `makeCleanupClient` — but the checkboxes below were never
> ticked. Three details were superseded: the default `cleanupModel` is
> `claude-sonnet-5`, not the `claude-haiku-4-5` the Task 1 test snippet asserts
> (`Sources/ParlaCore/Settings.swift:28`); an unknown `cleanup.provider` throws
> "unknown cleanup.provider" rather than being treated as anthropic
> (`Sources/ParlaCore/CleanupFactory.swift:91-93`); and for openai-compatible
> only `baseURL` is required — a missing `cleanup.model` makes the client ask
> the server for its first model (`CleanupFactory.swift:76-81`). Current
> behavior is documented in README, "Cleanup providers".

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cleanup step works against any OpenAI-compatible provider (Groq, Gemini, OpenAI, Ollama) plus the existing Anthropic client; existing settings.json files keep working.

**Architecture:** Per docs/superpowers/specs/2026-07-05-multi-provider-cleanup-design.md — tolerant Settings decoding + `CleanupSettings` block, `CleanupProviding` protocol, new `OpenAICompatClient`, shared `makeCleanupClient` factory, `Cleanup.sanitize` applied in Pipeline.

**Tech Stack:** unchanged (Swift 5.9 SPM, XCTest, raw URLSession via existing `HTTPPosting`).

## Global Constraints

- Existing behavior is the default: absent `cleanup` block ⇒ Anthropic with `cleanupModel` + `ANTHROPIC_API_KEY`/`anthropicApiKey`, byte-identical request to today.
- Any cleanup failure (including misconfig) ⇒ raw transcript inserted; never a crash. parla-eval: misconfig ⇒ exit 2.
- Tolerant decoding: a settings.json missing any subset of fields decodes with defaults for the missing ones; unknown keys ignored; only malformed JSON falls back to full defaults.
- OpenAI-compat request: `POST {baseURL}/chat/completions`, `content-type: application/json`, `Authorization: Bearer <key>` only when a key resolves; body `{"model", "max_tokens": 1024, "messages": [{"role":"system","content":<PromptBuilder.system>}, {"role":"user","content":<transcript>}]}`. Response text = `choices[0].message.content`.
- Tests: no network (MockHTTP), no permissions, no model file.
- Env prefix for all builds/tests: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- Commits: conventional prefix, trailing `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Tolerant Settings decoding + CleanupSettings

**Files:**
- Modify: `Sources/ParlaCore/Settings.swift`
- Modify: `Tests/ParlaCoreTests/SettingsTests.swift` (add tests; keep existing 3 passing)

**Interfaces:**
- Produces: `CleanupSettings` (fields per spec, all with defaults, `Codable`, `Equatable`) and `Settings.cleanup: CleanupSettings` (default `CleanupSettings()`).
- `Settings` gains a custom `init(from decoder:)` using `decodeIfPresent` for EVERY field (including `cleanup`), falling back to the current defaults. Encoding stays synthesized.

- [ ] **Step 1: Add failing tests**

```swift
func testPartialFileDecodesWithDefaults() throws {
    let store = tempStore()
    try FileManager.default.createDirectory(
        at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"dictionary":["Kubernetes"]}"#.utf8).write(to: store.url)
    let s = store.load()
    XCTAssertEqual(s.dictionary, ["Kubernetes"])
    XCTAssertEqual(s.cleanupModel, "claude-haiku-4-5")   // default survives
    XCTAssertEqual(s.cleanup, CleanupSettings())          // default block
}

func testUnknownKeysIgnored() throws {
    let store = tempStore()
    try FileManager.default.createDirectory(
        at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"futureField":true,"cleanupModel":"m"}"#.utf8).write(to: store.url)
    XCTAssertEqual(store.load().cleanupModel, "m")
}

func testCleanupBlockRoundTrip() throws {
    let store = tempStore()
    var s = Settings()
    s.cleanup.provider = "openai-compatible"
    s.cleanup.baseURL = "https://api.groq.com/openai/v1"
    s.cleanup.model = "llama-3.3-70b-versatile"
    s.cleanup.apiKeyEnvVar = "GROQ_API_KEY"
    try store.save(s)
    XCTAssertEqual(store.load(), s)
}
```

- [ ] **Step 2: Run `swift test --filter SettingsTests` — FAIL**
- [ ] **Step 3: Implement** — `CleanupSettings` struct per spec; explicit `CodingKeys` for `Settings`; `init(from:)` with `decodeIfPresent` per field defaulting to current values; keep memberwise behavior via existing `init()`.
- [ ] **Step 4: Full `swift test` — PASS (all prior tests unchanged)**
- [ ] **Step 5: Commit** — `feat: tolerant settings decoding and cleanup provider block`

---

### Task 2: CleanupProviding + OpenAICompatClient + sanitizer

**Files:**
- Modify: `Sources/ParlaCore/Cleanup.swift` (add protocol conformance + `sanitize`)
- Create: `Sources/ParlaCore/OpenAICompatClient.swift`
- Create: `Tests/ParlaCoreTests/OpenAICompatTests.swift`
- Modify: `Sources/ParlaCore/Pipeline.swift` (apply sanitize to cleanup result)
- Modify: `Tests/ParlaCoreTests/PipelineTests.swift` (sanitize applied test)

**Interfaces:**
- Produces:
  - `public protocol CleanupProviding { func clean(transcript: String, context: CleanupContext) async throws -> String }` — `CleanupClient: CleanupProviding` (method already matches).
  - `public struct OpenAICompatClient: CleanupProviding { public init(baseURL: String, apiKey: String?, model: String, http: HTTPPosting = URLSessionPoster()) }`
  - `public extension of Cleanup namespace or enum: `Cleanup` doesn't exist — put `public enum CleanupSanitizer { public static func sanitize(_ s: String) -> String }`
- Sanitize semantics: trim whitespace/newlines; if the result starts AND ends with a matching quote pair (`"…"`, `'…'`, `“…”`) strip one pair, trim again. Nothing else (ponytail comment: no preamble stripping — too risky).

- [ ] **Step 1: Failing tests** — OpenAICompatTests using the existing `MockHTTP` pattern from CleanupTests:
  - request shape: URL `{baseURL}/chat/completions` (no double slash when baseURL has trailing `/`), `Authorization: Bearer k` when key given, header ABSENT when `apiKey: nil`, body model/max_tokens/messages roles+contents.
  - response parsing: `{"choices":[{"message":{"content":"Hi."}}]}` → `"Hi."`.
  - non-200 → throws CleanupError containing status code; invalid UTF-8 body safe (reuse `String(decoding:)` pattern).
  - empty content → throws.
  - Sanitizer tests: `"\"Hello.\"" → "Hello."`, `"'Hi'" → "Hi"`, curly quotes, `"He said \"hi\" loudly."` unchanged (quote pair not wrapping — strip only when BOTH first and last chars are the pair), plain text unchanged.
  - Pipeline test: cleanup closure returns `"\"Cleaned.\""` → process returns `"Cleaned."`.
- [ ] **Step 2: Run — FAIL. Implement.** OpenAICompatClient mirrors CleanupClient structure (URLRequest build, 15s timeout, JSONSerialization body, Decodable response `{choices:[{message:{content:String?}}]}`). Pipeline: wrap the `try await cleanup(...)` result in `CleanupSanitizer.sanitize(...)` (raw-transcript fallback path also sanitized? NO — raw transcript returned as-is).
- [ ] **Step 3: Full suite PASS. Commit** — `feat: openai-compatible cleanup client and output sanitizer`

---

### Task 3: Factory + wiring + README presets

**Files:**
- Create: `Sources/ParlaCore/CleanupFactory.swift`
- Create: `Tests/ParlaCoreTests/CleanupFactoryTests.swift`
- Modify: `Sources/Parla/main.swift`, `Sources/parla-eval/main.swift` (use factory), `README.md`

**Interfaces:**
- Produces: `public func makeCleanupClient(settings: Settings, env: [String: String], http: HTTPPosting = URLSessionPoster()) throws -> CleanupProviding`
- Resolution:
  - key: `env[cleanup.apiKeyEnvVar ?? ""]` → `cleanup.apiKey` → (anthropic only) `env["ANTHROPIC_API_KEY"]` → `settings.anthropicApiKey`.
  - provider `"anthropic"` (or unknown value → treat as anthropic): model = `cleanup.model ?? settings.cleanupModel`; missing key → throw CleanupError("no API key ...").
  - provider `"openai-compatible"`: baseURL and model required (throw CleanupError naming the missing field); key optional (nil OK — local Ollama).
- App wiring: replace the inline `CleanupClient` construction in `finish()` with `try makeCleanupClient(settings: settings, env: ProcessInfo.processInfo.environment)` inside the cleanup closure (throw → existing raw fallback). Eval wiring: same factory; a thrown misconfig at startup (when cases exist) → print error, exit 2 (replaces the current key-only check; keep model-missing exit 2).
- README: add "Cleanup providers" section with the Groq and Gemini JSON preset blocks from the spec doc, an Ollama example (`http://localhost:11434/v1`, no key), and note Anthropic remains default.

- [ ] **Step 1: Failing factory tests** — anthropic default path returns CleanupClient-backed provider using legacy key/model (verify by issuing a clean() against MockHTTP and asserting the anthropic URL + x-api-key header); env-var precedence over inline key; openai-compatible path hits `{baseURL}/chat/completions` with Bearer; missing baseURL/model/key throws with the field named.
- [ ] **Step 2: Implement factory; run tests PASS.**
- [ ] **Step 3: Wire app + eval; `swift build`, full `swift test`, `swift run parla-eval` (no cases → guidance, exit 0), `scripts/make-app.sh` OK.**
- [ ] **Step 4: README section. Commit** — `feat: provider factory, app/eval wiring, provider presets`
