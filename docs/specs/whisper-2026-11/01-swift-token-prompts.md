# Lane 01 — Token-aware prompts on Swift (macOS + iOS) and the vocabulary UI count

Wave 1 · Risk: Medium · Depends on: Wave 0 fixture block

## Goal

The prompt string handed to `whisper_full` must fit the loaded model's prompt budget so the
highest-priority dictionary terms are never the ones native truncation drops. Streaming passes
reserve room for confirmed context. The Hub's "how many words help" line reports token retention.

## Files owned

- `Sources/ParlaCore/Transcriber.swift`
- `Sources/ParlaCore/RecognitionRequest.swift`
- `Sources/ParlaCore/Vocabulary.swift`
- `Sources/ParlaCore/Streaming.swift`
- `Sources/Parla/Hub/HubPages.swift`
- `Sources/Parla/Hub/HubModel.swift`
- `Sources/Parla/main.swift` (one wiring line + the stale comment)
- `Tests/ParlaCoreTests/VocabularyTests.swift`, `StreamingTests.swift`, `TranscriberTests.swift`,
  `AndroidSharedPolicyTests.swift`

Do not touch `RecognitionFactory.swift`, `Pipeline.swift` or `Sources/parla-eval` (lane 04).

## Current code (anchors by symbol)

- `VocabularyHints.select(_:byteLimit:)`, `VocabularyHints.asrPrompt(_:)`, `asrBytes = 2_048`.
- `StreamWindow.tailPrompt(dictionary:confirmed:maxContext:)`, `confirmedContextBytes = 800`.
- `RecognitionHandle.recognizePass`: the `switch pass` that builds `prompt`. This is the single
  production choke point (stream head/tail, windowed final, full final, command, HUD preview).
- `protocol RecognitionClient`, `protocol WhisperNativeContext`, `WhisperCContext.API`,
  `WhisperCContext.init(_:_:preparation:)` (where the `API` closures capture `ctx`).
- `HubPages.swift`: `let usedWords = VocabularyHints.select(model.words.map(\.text), byteLimit: VocabularyHints.asrBytes).count`
  and the text "The list is long, so only the top \(usedWords) words help recognition."
- `main.swift`: `let m = HubModel(store: ...)` block; `var residentRecognition`; the doc comment
  above `configureMeetingHub()`.

## Design

1. **Budget value type** in `Vocabulary.swift`:

   ```swift
   public struct PromptBudget {
       public let capacity: Int              // whisper_n_text_ctx / 2 - 1
       public let count: (String) -> Int     // loaded model's tokenizer
   }
   ```

2. **Native seam** in `Transcriber.swift`:
   - `WhisperCContext.API` gains `var textContext: Int32 = 448` and
     `var tokenize: (String) -> Int = { $0.utf8.count }`.
   - Production init sets `textContext: whisper_n_text_ctx(ctx)` and `tokenize` to a closure that
     allocates `[whisper_token](repeating: 0, count: max(1, text.utf8.count))`, calls
     `whisper_tokenize`, and returns `max(0, result)`. Never `whisper_token_count`.
   - `WhisperNativeContext` gains `var promptBudget: PromptBudget? { get }` with a protocol-extension
     default of `nil` (existing test fakes keep compiling). `WhisperCContext` returns
     `PromptBudget(capacity: max(0, Int(api.textContext) / 2 - 1), count: api.tokenize)`.
   - `WhisperTranscriber` exposes `public var promptBudget: PromptBudget? { native.promptBudget }`.
   - `whisper_tokenize` only reads the context's vocabulary, so calling it while another thread is in
     `whisper_full` is safe. The closure captures the `WhisperCContext` strongly; callers use the
     budget transiently and never store it (storing it would defeat the idle unload).

3. **Client seam** in `RecognitionRequest.swift`: `RecognitionClient` gains
   `var promptBudget: PromptBudget? { get }`, default `nil` in the existing extension. Apple Speech,
   Parakeet and injected test clients inherit `nil` and keep today's byte-only behaviour.

4. **Selection** in `Vocabulary.swift`, following the README's shared contract exactly:
   - `static func select(_ words: [String], budget: PromptBudget?) -> [String]` — byte admission
     first (`select(words, byteLimit: asrBytes)`), then token admission when `budget != nil`.
   - `asrPrompt(_ words:, budget: PromptBudget? = nil) -> String?` joins the result with `", "`.
   - Update the type's doc comment: bytes are the resource guard, tokens decide retention.
   - `// ponytail:` comment: selection is recomputed per pass; memoize on (words, capacity) only if
     profiling shows it.

5. **Streaming reserve** in `Streaming.swift`:
   - `public static let contextReserveTokens = 64` with a comment: starting value, roughly today's
     200-character English context; revisit with lane 12 evidence.
   - `tailPrompt(dictionary:confirmed:maxContext:budget:)` (new trailing parameter, default `nil`):
     1. Build `tail` exactly as today (character and byte caps).
     2. With a budget: `reserve = min(contextReserveTokens, budget.capacity)`; while
        `budget.count(tail) > reserve`, drop `max(1, tail.count / 8)` leading characters.
     3. Dictionary capacity = `budget.capacity - budget.count(tail) - (tail.isEmpty ? 0 : 1)`,
        clamped at 0; select terms against a `PromptBudget` with that capacity.
     4. Join as today (`dict + " " + tail`). While `budget.count(joined) > budget.capacity` and a
        dictionary term remains, drop the last term and rejoin.
   - When the tail is short, the dictionary gets the unused reserve.

6. **Choke point** in `RecognitionHandle.recognizePass`: pass `client.promptBudget` into
   `tailPrompt` and `asrPrompt`. A caller-supplied `initialPrompt` stays verbatim (lane 04 stops
   `parla-eval` from supplying one).

7. **Hub count**:
   - `HubModel`: `var vocabularyBudget: () -> PromptBudget? = { nil }` plus one memo tuple
     `(words: [String], capacity: Int?, count: Int)` behind a method
     `func retainedVocabularyCount() -> (count: Int, exact: Bool)`. `exact` is true when a budget
     was available. Recompute only when words or capacity change (the view re-renders per keystroke).
   - `main.swift`, next to the other `m.` wiring:
     `m.vocabularyBudget = { [weak self] in self?.residentRecognition?.client.promptBudget }`.
   - `HubPages.swift`: replace `usedWords`. Show the line only when fewer words are retained than
     non-empty words exist. Copy (short, no "top N" because selection can skip a long term):
     - exact: "\(count) of \(total) words fit the speech model's prompt. Words higher in the list win."
     - no model loaded or non-Whisper engine: "About \(count) of \(total) words help recognition.
       The exact number appears once the speech model is loaded."
   - `modelLoaded` is already `@Published`, so the line refreshes when the resident loads.

8. **Stale comment** in `main.swift` above `configureMeetingHub()`: replace
   "Production capture stays OFF pending separately scoped native qualification." with a sentence
   that matches the code (`captureCapability: true`, microphone and selected-application capture
   enabled). Comment only; no behaviour change.

## Acceptance criteria and checks (one per behaviour)

| Behaviour | Test |
|---|---|
| Shared selection contract | `AndroidSharedPolicyTests`: loop the fixture's `promptBudget` vectors with `count = utf8.count` |
| Priority survives an over-budget dictionary | `VocabularyTests`: `Name0…Name199`, capacity 223, `count = utf8.count` → first selected term is `Name0`, joined count ≤ 223 |
| No budget keeps today's behaviour | Existing `VocabularyTests` / `ProfileTests` byte assertions pass unchanged |
| Context reserve | `StreamingTests`: dictionary `["alpha","beta"]`, confirmed `"hello world"`, capacity 20, reserve 8 (inject via a test-only parameter) → `"alpha, beta lo world"` |
| Unused reserve returns to the dictionary | `StreamingTests`: empty confirmed text → dictionary uses full capacity |
| Final joined guard | `VocabularyTests`: a non-additive fake counter (adds 1 per `", "` join) never yields a joined count above capacity |
| Native boundary | `TranscriberTests`, skipped without the default model: real `promptBudget` reports capacity 223; the joined `Name0…Name199` string counts above 223; `asrPrompt(words, budget:)` counts ≤ 223 and starts with `Name0` |
| UI count | `ParlaTests` Hub test (or `VocabularyTests` on `retainedVocabularyCount` logic): budget present → exact count; absent → byte count with `exact == false` |

## Checks to run

- `swift test --filter 'VocabularyTests|StreamingTests|AndroidSharedPolicyTests|ProfileTests|RecognitionRequestTests|AsyncRecognitionTests'`
- `swift test --filter TranscriberTests` (model-gated tests skip without the model; say so in the report)
- `python3 ios/Scripts/typecheck.py` (shared ParlaCore files compile for iOS; semantic check only)
- Final: `swift test` once.

## Out of scope

- `carry_initial_prompt`, prompt content/format changes, cleanup-prompt budgets (`cleanupBytes`).
- Persisting or caching token costs; loading a model just to count tokens for the UI.
- iOS vocabulary UI (it shows no retention count today).
- `GuidedTemplateOwner`'s byte selection (`VocabularyHints.select(saved.dictionary, byteLimit:)`).

## Needs a human

- [ ] With `large-v3-turbo-q5_0` installed, add 200 names in the Hub and confirm the line shows an
      exact count below 200 and that the first names are recognized in a dictation.
- [ ] Decide whether `contextReserveTokens = 64` holds for Hindi dictation once lane 12 can measure
      it (Devanagari tokenizes densely; the reserve may hold fewer than 200 characters).
