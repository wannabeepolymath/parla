# Shortcut labels and keyboard layouts

Shortcut labels in the Hub and status menu follow the selected macOS keyboard
layout. Bindings still use the same physical key positions and exact modifiers.
Changing the input source refreshes labels without saving settings, rebinding
shortcuts or restarting Parla. Saved canonical strings (for example
`ctrl+cmd+v`) remain unchanged, including the optional Run selected preset chord.

Labels show the base printable character without applying the chord's Shift or
Option modifiers. Named modifiers, Space, Return, arrows, navigation and function
keys retain their names. The resolver reads the selected input source's Unicode
keyboard-layout data and current keyboard type; it does not compose IME text or
substitute an IME's underlying layout. Dead-key display is stateless.

When no usable label is available, the pill says, for example,
`V (physical key 9)` or `Physical key 10`. These identify a physical position,
not a character promised by the current layout. The selected layout's declared
Carbon default table can label standard ANSI positions. Extra ISO/JIS positions
require a mapping for the current keyboard type; otherwise they use the explicit
physical fallback. A missing keyboard type or layout also uses that fallback.

Status-menu hints use current saved bindings and the same label formatter.
They appear in titles with no character key equivalents installed for the global
shortcuts. Menu actions still work by click; the global event tap still dispatches
physical chords. The ordinary Quit shortcut remains Command-Q.

Automated checks use injected value snapshots and notifications, owned temporary
settings/history/recording stores, and a synthetic native-endian `uchr` fixture
read by the real `UCKeyTranslate` API. They cover QWERTY/AZERTY/QWERTZ positions,
Unicode/punctuation/dead keys/failures, named keys, hardware mapping fallbacks,
canonical roundtrips, recorder and command labels, attempted-chord errors, menu
composition, main-thread refresh, unchanged settings bytes/save callbacks and
observer cleanup. They never switch the user's input source.

Still requires native qualification: switching real input sources, ANSI/ISO/JIS
hardware, IME and international punctuation labels, visible label sizing and live
menu refresh while tracking. Synthetic mappings do not qualify physical hardware
or rendered UI.
