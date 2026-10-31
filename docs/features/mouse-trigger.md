# Optional mouse push to talk

General → Shortcuts → Mouse push to talk is **Off** by default. Choose Middle or an explicit Button 4–16. Hold to dictate, release to finish. A tap under 0.2 seconds discards the capture. Esc cancels. Mouse holds use the existing dictation recorder, reducer, recognition queue, output preferences and delivery guards. Mouse does not introduce hands-free or command-mode gestures; those keyboard gestures remain available.

The chosen button's down and matching up are consumed by Parla. This replaces its normal click action, including a side button's Back/Forward browser navigation. Parla never synthesizes navigation or clicks. Left/right clicks, other buttons, scrolling and dragging remain available. Marked Parla synthetic events are ignored. Merely configuring this choice does not start recording, load a model, query credentials or invoke a provider.

Settings keep canonical keyboard chords in `hotkeys`. The separate optional `mouseBinding` stores an object such as `{"buttonNumber":2}` for Middle. Internal numbers 2–15 map to displayed buttons 3–16. Missing/null means Off. Wrong types, left/right and out-of-range numbers disable only mouse input and show a settings warning; valid keyboard bindings survive unchanged. Layout-dependent keyboard labels and physical key matching are unchanged.

## Input ownership and mixed sources

Only an eligible selected down creates a press identity and release debt. Duplicate downs create no additional capture or debt, and an up without consumed down passes through. A canceled/rebound original press still owes its own up; repeated downs for that unsettled press are treated as duplicates, even after rebinding. Debts are bounded by the 14 supported button numbers. A new selected button may begin after the old mouse capture is canceled, while the old button's release settles its own debt.

Native edges take the existing main-queue hop. The production input router binds a press to the actual accepted reducer session's operation and generation, rather than sending generic stop/cancel events. Keyboard starts cancel an owned mouse capture before starting. Mouse cannot steal an active keyboard capture. Deliberate physical starts retain the existing automation-preemption policy. Late mouse edges cannot stop a newer keyboard, automation or mouse capture, and a non-mouse start invalidates mouse downs still queued for main. Diagnostic review/Listen, tryout and shortcut recording exclude mouse through the same admission and additive suspension owners. An exclusion that starts and ends before queued delivery still invalidates that start.

Secure preflight refusal creates no capture; the original consumed release remains balanced. The existing post-start focus guard also remains in force. Capture failure or cancellation revokes only the accepted mouse operation. Release before recorder acknowledgement cancels conservatively, so a late acknowledgement cannot revive it.

## Missed release and availability

The injected physical-button seam is used by the native callback and watchdog. Physical state is trusted to prove release only if it agreed with the original down. A trusted missed release cancels/discards the mouse capture and reconciles its debt; it never invents a successful release timestamp. Unknown state, unplug/capture end, tap disable, invalid port and permission loss also cancel only the owned mouse capture. Uncertain debts survive until an observed up or trusted physical-up safely settles them. Repeated resets cannot finalize again. Remappers and remote input can be invisible to physical state: an untracked hold is canceled conservatively on reconciliation rather than claimed physically released.

Keyboard missed-release finalization deliberately remains unchanged. Global input unavailable/permission-loss status disables mouse starts and appears beside the selected binding, with automatic recovery and an explicit Retry control. Existing tap recreation/watchdog recovery is reused. No alternate hidden capture pipeline runs while input is unavailable.

## Qualification

Injected tests exercise native receive, the real dispatch hop, production router/host/reducer, and the existing recognition/provider queue with inert fakes. They do not qualify hardware button numbering, remappers, browser navigation suppression, secure-input interruption, macOS Accessibility permission transitions or native tap recovery. Those checks remain pending on actual hardware. No real input is posted by these tests.
