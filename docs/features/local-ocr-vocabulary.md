# Local OCR: owned-window prerequisite

This is the six-file B08/P source prerequisite. It connects the reusable
`LocalOCRCapture` adapter to a synthetic `parla-insert-check` consumer. It does
not implement production B27 screen vocabulary, change ASR/manual vocabulary,
or complete B08/B27. The product-qualified set remains empty. The source review
count remains 25/57 (43.9%). The six-file source prerequisite was approved in one Sol review round. Native/UI execution remains untested; source approval is not native qualification.

## Invocation and fixture

The first executable statement parses the shared pure grammar. Only the exact
argv `[argv0, "--owned-ocr-qualification"]` enters the owned fixture. Any option
with ASCII case-insensitive prefix `--owned-ocr` reserves this grammar; malformed,
extra, duplicate, bundle, echo-file, field, paste or path arguments refuse before
the legacy watchdog, AX, app launch, typing, paste and readback. Other legacy
arguments retain their existing behavior. There is no top-level await, async
main or access to later legacy globals from the owned entry.

Unsupported imports or macOS below 14.4 refuse before UI or permission checks.
Constructors/rendering do no preflight, lookup, capture or OCR. The UI contains
only owned read-only synthetic NSTextView windows, with no restoration,
autosave, preferences, document IO or real application data. Plain, Secure,
Selection, Second and Close are in-window choices made before capture. Secure
is a direct fixture flag, not an external AX/secure-input qualification. Close
before the single click means not-tested with no capture. The second window
has distinct sentinels. One capture operation is allowed per process launch;
its button and selector never re-enable. All rendered strings, including Ready,
stay frozen from admission through settlement.

## Scope, identity and caps

After the explicit click starts the monotonic 2-second logical budget, order is
owned-state proof, preflight, metadata lookup, exact filter, native dimensions,
screenshot, returned header checks, then Vision. Equality at 2 seconds expires.
Preflight false gives zero ScreenCaptureKit calls, no request/prompt/settings
opening, no waiting for a later permission grant. Preflight true does not prove
TCC attribution or whether framework/OS interaction can occur later.

The only metadata API requested is
`SCShareableContent.getCurrentProcessShareableContent(completionHandler:)`
(macOS 14.4). Its process and permission semantics are undocumented beyond its
name: receipt scope is UNQUALIFIED. Read at most the returned windows count
(cap 8), then only owningApplication.processID, windowID and frame. Any absent
or foreign PID refuses the entire result; no filtering out foreign entries and
continuing. No title, display, application name, bundle ID or catalog is read
or logged. The framework can already have allocated metadata. Unused handles
are scoped to the joined lookup; the selected handle/filter is operation-owned.

Exactly one candidate must have the own PID, the safely UInt32-convertible,
positive NSWindow.windowNumber equal to windowID, and matching frame. The one
fixed coordinate hypothesis requires primary screen origin (0,0), a wholly
contained fixture and scale 1...2: convert AppKit bottom-left to capture top-left
by `captureY = primaryHeight - appKitY - frameHeight`; compare each physical
pixel edge rounded nearest, ties away from zero. No alternative conversion,
nearest, first, geometry-only or broad catalog fallback is tried. Current
key/visible/active/plain/collapsed/generation/frame/scale proof is rechecked
after awaits and before issuance. Owned change notifications revoke stickily.

This ID equality is an UNDOCUMENTED observational hypothesis. Apple's
windowNumber documentation explicitly cautions that its number differs from
the window-server global number. Identity stays UNVERIFIED even if all
predicates and the oracle match. CGImage contains no owner/window ID; checks
cover issued filter and pre/post owned state, plus actual width, height, bpp,
bpc, stride and known BGRA premultiplied-first little-endian RGB format.

TOTAL fixture frame INCLUDING titlebar is at most 640x384 points; at 2x that is
1280x768 = 983,040 pixels. The former 768x512-point suggestion exceeds the
1,048,576-pixel cap at 2x and is refused. Filter contentRect times pointPixelScale
is checked before issue: width <=1536, height <=1024, area <=1,048,576 with
checked arithmetic. Returned bytesPerRow times height must be <=8 MiB before
OCR or app pixel copy. Shadows are ignored; child windows are excluded.
There is no crop, downsample, display/stream/own-render fallback, pixel preview,
encoding, NSImage conversion, image file or image cache. Foreign images and
metadata may already exist: these checks make no RSS/framework-allocation cap.

Vision uses Revision3, accurate, en-US, automatic language detection false,
language correction false and customWords empty. It requests top1 only and
checks <=64 observations, <=256 UTF-8 bytes per candidate, <=4096 aggregate
before token expansion. Deterministic canonical normalization/lowercase/dedupe
allows <=16 terms, <=64 UTF-8 bytes and 32 graphemes each, <=512 bytes including
separators. Controls, NUL, multiline input, role delimiters, unsafe characters
and oversized scalar clusters refuse the whole contribution, never trim to
pass. Unicode tests establish bounds/refusal only, not multilingual support,
injection/hallucination resistance or name benefit.

The version-1 primary sentinels are amber/cobalt/willow, and secondary sentinels
are violet/copper/maple. Fixed chrome vocabulary is owned/ocr/plain/secure/
selection/second/close/capture/ready. Component oracle PASS requires every
primary sentinel and no projected term outside primary sentinels plus chrome.
Unexpected terms yield only a count. A component pass is overall
attempted-unverified, never native qualification or identity proof.

## Lifetime and evidence limits

One awaited operation uses PendingOperation(diagnostics:nil) for sticky revoke,
Vision's current cancel action, one final claim and finish. Metadata completion
and owned extraction body exit, screenshot completion and owned extraction body
exit, and Vision completion/body exit PLUS perform return are joined. Callback
state is locked and single admission; duplicate callbacks cannot resume twice.
A returned extraction body is the observed app-owned exit, not a claim that
foreign framework code or its callback thread stopped. No native cancellation
is assumed for lookup/screenshot. Vision cancellation is cooperative.

Close/quit revokes before requesting cancellation and defers termination while
owned work is pending, potentially forever. A logical timeout only rejects
acceptance; it does not release references, create a new job, stop the process
or certify erasure. No detached task, new queue/dispatcher, semaphore, main
blocking Vision perform or timer-as-exit is used. Awaited nonisolated Vision
perform may occupy a generic executor for its entire duration; no latency or
pool-capacity claim follows. Forced kill/SIGINT is future operator action and
cannot qualify cleanup. Release of app references is not zeroization or proof
of foreign-copy erasure.

Receipts contain finite statuses/reasons/config/counts/dimensions/elapsed/owned
exit markers only. They never contain pixels, candidates, terms, titles,
platform error descriptions or private paths. Binary/signing/OS-build/hardware/
TCC attribution remains UNRECORDED unless a future authorized observer supplies
actual evidence. No provider, network, model, mic, clipboard, keystroke,
dictionary, History or output-storage path is part of this prerequisite.

Conditional ScreenCaptureKit/Vision imports in ParlaCore can change linkage in
Parla/eval as well as the harness. Production behavior, reachable call graph,
Info.plist and permissions are unchanged; literal binary/linkage equality is
not claimed. The current-process symbol needs a macOS 14.4+ SDK. An actual API
availability/semantics failure in authorized test compilation is a STOP, with
no SDK install, package edit or broad metadata fallback.

## Original prerequisite checks and future native recipe

For the original prerequisite, authorized checks were ONLY `swift test --filter LocalOCRCaptureTests` through
the task gate with a fresh empty task manifest. Counted in-memory drivers use
the shipping parser/controller/adapter, fake headers/tokens and held phase
controls; unadmitted native bottoms fail on entry. No CGImage allocation,
bitmap rendering, OS window, screen, preflight, OCR or permission call occurs
in tests. The external frozen P01-P08 method matrix and gate receipts/logs
record actual counts and compilation outcomes. Core tests import ParlaCore;
P3/P4 executable dispatch/UI has structural source coverage only, even if
compiled internally. No executable launch is covered. No standalone build or
extra test suite was authorized in that original prerequisite.

No native execution is authorized by this document. A future separately
approved run must name the built binary/source revision, owned fixture and
whole-window scope, signing/launch-host/OS-build/hardware identities, human
permission action, finite receipt destination, process-exit/resource plan and
expected unverified identity label. A human must arrange the fixture and exact
binary's permission; the harness must never prompt or open Settings. Observe
denial/revoke, key/generation/second-window transitions, late callbacks, actual
owned settlement and the strict oracle. Missing evidence is not-tested or
pending, never pass. External apps/fields require separate B08 evidence; B02
held-out paired spoken/unspoken-name benefit remains open. This P neither
implements nor authorizes the larger B27 product vertical.

Primary source text: Apple [current-process method](https://developer.apple.com/documentation/screencapturekit/scshareablecontent/getcurrentprocessshareablecontent(completionhandler:)),
[windowNumber caution](https://developer.apple.com/documentation/appkit/nswindow/windownumber),
[specified-window filter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init(desktopindependentwindow:)),
[captureImage](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager/captureimage(contentfilter:configuration:completionhandler:)),
[Vision perform](https://developer.apple.com/documentation/vision/vnimagerequesthandler/perform(_:)),
and Swift [SE-0343](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0343-top-level-concurrency.md).
These establish declarations, not native outcomes.

## First bounded native observation — 2026-10-30

The existing helper passed the malformed reserved-invocation negative control (exact finite output, waited exit 2). The valid owned-mode launch could not be selected by native CUA: the exact executable path returned `Invalid app`. Zero Capture clicks occurred, so no ScreenCaptureKit/Vision operation or native receipt was admitted. The owned process was identity-checked and terminated before capture (waited SIGTERM status -15); GUI close/settlement qualification remains untested. No fallback target, permission prompt interaction, build, signing, retry or source change occurred. This establishes a tooling limit for this invocation, not an OCR result or a product defect. B08 stays partial, B27 stays planned, and product qualification remains empty. Evidence: `wave7i2-native-child-result.md` and `wave7i2-native-observation.json` under the named implementation artifact directory.

## Dedicated app experiment candidate — 2026-10-30

A separately authorized enabler, **approved in one full Sol review**, extracts the existing
fixture into the harness-only `OwnedOCRFixture` module. Only
`OwnedOCRQualification.enter()` is public. The insertion helper keeps its exact
reserved parser and legacy remainder, with an added import/dependency. The
production `Parla` target does not depend on the fixture module.

The new `parla-owned-ocr-check` executable rejects every unexpected argument
with `owned-ocr not-tested invalid-invocation` and exit 2 before constructing a
driver or entering AppKit. With no arguments its only entry is the synthetic
owned fixture; it cannot fall through to TextEdit, insertion or the legacy
watchdog. The existing unsupported-platform refusal still precedes UI. The
package minimum remains macOS 13.3; the native driver's existing availability
and Intel fallback are unchanged.

`scripts/make-owned-ocr-app.py` accepts an exact prebuilt dedicated debug
product in the experiment's isolated `build/<host-triple>/debug` directory and
a new output directory directly under the same artifact root. Paths must be
absolute and canonical (resolve `/var` aliases before invocation). It does not
build or execute any app. It validates Mach-O dependencies, copies only the
harness and its linked whisper runtime framework (excluding Headers/Modules)
from that same product directory,
adds the app framework rpath to the new executable copy only when needed, and
ad-hoc signs the copied framework and uniquely identified test app. It verifies
plist, dependencies/rpaths and signatures, records source/output inventories
and tool commands, and retains partial output on failure or cancellation.
Existing output is refused without replacement. Owned tool groups must exit
and close IO; a pending worker is a stop, not a cleanup claim. No production
packaging script, signing identity, entitlements, registration or install is
used. whisper's Metal library is embedded; no model or product resources are
added.

The current bounded implementation task permits standard-library Python inert
packaging tests, one host debug build of only `parla-owned-ocr-check` with
`--disable-automatic-resolution` and an isolated scratch path, then execution
of that pinned product **only with an unexpected argument**. Packaging/signing
is deferred until independent source review; the packager's real tools have
not yet been exercised. No default launch, app attachment, permission probe,
Capture click, OCR, production build or broad Swift test is part of this task.
The `Invalid app` observation did not establish a source defect or that an app
bundle is necessary or sufficient. App binding, default UI behavior and full
qualification remain unresolved; B08/B27 and the 25 reviewed / 15 implementing /
17 planned tracker counts are unchanged. Current evidence is recorded under
the fresh experiment artifact root, not reconstructed historical artifacts.

## Dedicated bundle static verification — 2026-10-30

The final 16 inert packaging tests passed. One isolated host build of the dedicated helper exited 0; its unexpected-argument check produced the exact refusal and exited 2. Full eight-path Sol source review approved with no retained findings. The reviewed packager then reused that exact compiled product without rebuilding. Real packaging, copy-only rpath modification, ad-hoc framework/app signing, strict signature checks, dependency/rpath/plist checks and final bundle inventory verification all passed. All 14 tool processes had waited exit 0, closed IO and absent owned groups. The source binary and framework were unchanged.

This is static bundle evidence, not app attachment, permission attribution, native capture/OCR or production qualification. Earlier candidate-task restrictions above describe that historical task; the subsequent user-approved static packaging step is now complete. A separately scoped owned-window native observation can use this app with existing grants only. No production app was rebuilt/installed, no permission was changed, and B08 remains partial/B27 planned. Overall item source-review progress remains 25/57. Fresh evidence: `root-package-result.json`, `sol-round1-report.md`, `child-result.md` and package command/inventory receipts under the dedicated task artifact root.
