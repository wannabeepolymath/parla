# In-App Updater — Design

Scope: Parla downloads, verifies and installs a newer GitHub release itself,
on one click, then relaunches. Replaces the browser-only "Update available"
menu item as the primary path; the browser link stays as the fallback.

## Decisions already made

- **Custom updater, no Sparkle.** `docs/research/FEATURES-TO-ADD.md:101`
  argued against any bundled updater; this design keeps the three rules from
  `docs/research/09-ux.md:340-343` instead of dropping the feature:
  never interrupt a dictation, never stage quit-time updates, gate
  concurrent update operations.
- **One-click install.** Nothing downloads or installs without the click.
- **Discovery:** a 24 h re-check while running (not only at launch) plus a
  manual **Check for Updates…** menu item.
- **No crash-leftover recovery.** Staging lives in a system
  item-replacement directory the OS reaps; a leftover hidden mount clears at
  reboot. Add recovery only if leftovers are actually observed.

Design reviewed by gpt-6-astra (high effort) on 2026-10-13; its three
blockers and the should-fix items below are incorporated.

## Components

### 1. `ParlaCore/UpdateCheck.swift` (extended)

- Decode the release's `assets`; pick the asset named exactly
  `Parla-<version>.dmg` (version = tag without `v`). `Update` gains
  `dmgURL: URL?` (nil → browser fallback).
- `check()` returns a distinct outcome instead of `Update?`:
  `.available(Update)`, `.upToDate`, `.throttled`, `.failed`. Only the manual
  check surfaces `.upToDate` ("You're up to date") and `.failed`
  ("Couldn't check for updates"); the scheduled check stays silent on both.
- `force: Bool` bypasses the 24 h throttle (manual check). The throttle
  timestamp is still written only after a successful fetch.
- Hidden override: UserDefaults `Parla.updateCheck.feedURL` replaces the
  releases/latest URL, so two locally signed builds can be tested against
  each other before anything is published. Settings-only, undocumented in the
  Hub.

### 2. `ParlaCore/UpdateInstaller.swift` (new)

Runs one install transaction, in order. Every step before **commit** is
non-destructive.

1. **Eligibility (before offering Install at all).**
   - The running app has a valid **Developer ID Application** signature
     (`SecCodeCopySelf` → `SecCodeCheckValidity` against
     `anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6]
     exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists` —
     the Developer ID CA intermediate and a Developer ID Application leaf). Local ad-hoc builds (`make-app.sh` gives them an
     identifier-only DR) and `swift run` fail here → browser fallback.
   - The install location is a real, writable path: not under
     `/AppTranslocation/`, not on a read-only volume, and its **parent
     directory** is writable. Treated as advisory; actual failures are
     handled at each step.
2. **Download** the DMG with a URLSession download task into a private
   temp dir; report progress.
3. **Mount** with `hdiutil attach -nobrowse -readonly -plist
   -mountrandom <tmp>`, stdin closed, bounded by a timeout. The mount point
   comes from the plist; only that attachment is detached later
   (`hdiutil detach <device>`), and detach status is checked.
4. **Stage:** copy `Parla.app` into a staging dir from
   `FileManager.url(for: .itemReplacementDirectory, in: .userDomainMask,
   appropriateFor: installURL, create: true)` (same volume as the install).
   Detach.
5. **Verify** the staged app with `SecStaticCodeCreateWithPath` +
   `SecStaticCodeCheckValidity`, flags
   `kSecCSCheckNestedCode | kSecCSCheckAllArchitectures |
   kSecCSStrictValidate`, against the **running app's designated
   requirement** (only reachable after step 1 proved it is a Developer ID
   requirement: identifier + team). Every Security API result must succeed
   and the requirement must be non-nil. The staging dir is not modified
   between verify and commit.
6. **Version:** staged `CFBundleShortVersionString` must be strictly newer
   than the running one (reuse `UpdateCheck.isNewer`).
7. **Wait for safe-to-restart** (see below). Menu shows "Waiting for
   dictation to finish…".
8. **Commit:** `renameatx_np(staged, installed, RENAME_SWAP)` — one atomic
   exchange; the old app ends up in the staging dir. If the filesystem
   doesn't support it (`ENOTSUP`/`EXDEV`), abort to the browser fallback
   with the installed app untouched. After the swap, delete the old copy
   (failure here is harmless).
9. **Relaunch:** run `/bin/sh -c '<fixed script>' sh <pid> <appPath>` via
   `Process` with PID and canonical app path as separate arguments (quoted
   `"$1"`/`"$2"` in the script, absolute `/bin/kill`, `/usr/bin/open`). The
   script polls `kill -0 "$1"` every 0.2 s for at most 30 s; on timeout it
   exits without launching. `Process.run()` failure is reported as
   "Installed — reopen Parla to finish", distinct from pre-install
   failures. Then `NSApp.terminate`.

`UpdateInstaller` takes its side effects (download, hdiutil, Security checks,
rename, process launch) as injectable functions so the transaction logic is
unit-testable without a network, a mount or a signed app.

### 3. Safe-to-restart

`isCapturing` is not enough: it is false through transcription, polishing,
delivery and the clipboard restore (`DictationSession.swift:274`,
`Inserter.swift:34`). Safe-to-restart means, all on the main actor:

- session state is `.idle`, and
- the `processTask` chain (`Dictation.swift`) has finished, and
- no `ClipboardDelivery` restore is pending (it gains a pending-restore
  count).

When the installer reaches step 7 it waits for that condition, then sets an
`updateCommitting` flag **before** committing. While the flag is set, a
dictation hotkey press is refused with the HUD message "Updating Parla…".
Before terminating, pending Hub settings and the scratchpad are flushed (the
same saves `applicationWillTerminate` does today, plus settings).

### 4. App wiring (`main.swift`, `StatusMenu.swift`)

- One `UpdateController` (main actor) owns discovery and install state:
  `idle | available(Update) | installing(progress) | waiting | failed`.
  Checks are serialized; an in-flight check is coalesced with a new request.
  The `Update` is captured immutably when Install is clicked; later checks
  cannot change that transaction.
- Install gate: a single bool set before the first suspension and held
  through restart (rule 3).
- 24 h re-check: the next due time is computed from the persisted
  last-successful-check timestamp, not from app launch.
- Menu items:
  - **Install Update vX.Y.Z** (or **Update available (vX.Y.Z)…** opening
    the browser when not eligible or no DMG asset).
  - **Updating… 42%** / **Waiting for dictation to finish…** — the visible
    item's title is updated live on the main thread while the menu is open.
  - **Check for Updates…** — always present.
- **Quit during an install:** before commit, `applicationShouldTerminate`
  returns `.terminateLater`, cancels the transaction, awaits subprocess exit
  and cleanup (detach, remove temp), then replies. Once commit has started,
  Quit waits for it to finish.

### 5. Release pipeline (`scripts/make-dmg.sh`)

Notarize and **staple the app** before packaging, then build, sign, notarize
and staple the DMG as today. The DMG's ticket is not ingested by a
programmatic `hdiutil attach`, so an app copied out of it must carry its
own ticket to launch cleanly offline.

## Error handling

- Any failure before commit: transaction cleanup always runs (detach our
  mount, remove temp/staging), HUD shows "Update failed: <step>", the menu
  item falls back to opening the release page. Not sticky — the next check
  or click can retry.
- Commit is a single atomic exchange: either the new app is in place or the
  old one still is.
- Post-commit relaunch failure leaves the new app installed and says so.
- Discovery failures stay silent except on the manual check.

## Testing

**Unit (ParlaCore, CI, no network):**
- Asset selection: exact name match, missing asset, near-miss names.
- Check outcomes: `.upToDate` / `.failed` / `.throttled` are distinct;
  `force` bypasses the throttle while the scheduled check obeys it; the
  feed-URL override is honored.
- Transaction logic with injected side effects: step order; cleanup runs on
  failure at every step; no commit before safe-to-restart; downgrade or
  equal version rejected; `ENOTSUP` from the swap falls back without touching
  the install path; relaunch failure reported as installed.
- Eligibility: translocated / read-only / unwritable-parent paths rejected.
- Signature: an ad-hoc-signed running identity is rejected as a trust
  source; an ad-hoc candidate is rejected; a candidate with a tampered
  nested framework is rejected (throwaway bundles built in the test).

**Manual end-to-end (before publishing the release that ships this):**
build signed **A** (with the updater) and newer signed **B**; point A at a
test feed via `Parla.updateCheck.feedURL`. Verify: install + relaunch;
Mic and Accessibility grants survive; Install clicked mid-dictation waits for
the paste and clipboard restore; Quit during download cleans up; going
offline after download still launches B; a forced swap failure leaves A
intact.

## Out of scope

Delta updates, a beta channel, release-notes UI, automatic install, a
confirm-before-relaunch dialog, crash-leftover recovery, a privileged
installer for non-writable locations (browser fallback covers it).
