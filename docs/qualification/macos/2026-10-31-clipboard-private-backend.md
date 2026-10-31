# Clipboard restore: bounded native private-backend observation

B25 remains **PARTIAL** against its canonical app, clipboard-manager and remote-client criteria. The default-off source experiment now has a successful native backend/lifetime observation on the current macOS host. This does not change completion credit or the ordinary fixed restore default.

The reviewed test used a fresh private named pasteboard with synthetic data, the production `ClipboardDelivery(board:)` adapter, a separate consumer process, and a broker/issuer that observed actual process exit and output closure. It exercised fixed, repeated, delayed, near-maximum and absent reads, independent ownership changes, shutdown coordination and oversized-input refusal.

All 25 exchanges completed. After the owner exited, the consumer freshly read all five representations and matched the complete captured native baseline. This includes a platform-advertised representation, whose semantic correctness is not independently established. A separately configured root policy issued one exact release decision only after validated post-exit evidence. The consumer then released that new board. No system clipboard, old test board, model, microphone or provider was accessed.

The owner XCTest deliberately skips after handing off; it cannot prove its own death. The broker and issuer supplied that lifetime evidence, with normal raw-zero exits and individual stream EOFs. The outer wrapper tool session completed with exit 0 and empty output; its PID and separate EOF receipts were not returned by the tool. Outer group settlement relies on the reviewed separate-session/no-same-group-descendant source discipline, not process enumeration or a post-reap probe. No signal or forced settlement occurred.

Root rechecked all 15 final evidence hash bindings, executable closure pins, 369 repository records, and Git HEAD/branch/stage/index. The independent acceptance audit corroborated the bounded observation. Every posted case remains `postedUnverified`: a pasteboard request is not proof of insertion or target acceptance.

Still unproved: named receiving-app outcomes, real clipboard managers and remote clients, general-board integration, physical insertion, UI behavior and measured usability benefit. No concrete source correction follows from these gaps. The experimental feature remains opt-in.

The native attempt is spent: effective authorization is false, attempts 1, no retry. Historical invocation/policy files retain the original true decision fields and cannot be reused. Evidence, copied consumer and compiler/scratch artifacts are retained; the exact new board's release is receipt/source-backed, with no post-release board query. Earlier failed boards were untouched.

Evidence is retained under `/private/var/folders/vp/_gvcxwbx3rg9cz0193_n4kr00000gn/T/parla-owned-ocr-20261030-0av9ol73/b25-private-native-draft/native-baseline-plan1/candidate1/release-handshake-candidate1/`:

- `execution-preparation1/root-runtime1/`: root decisions, outer observation, final evidence pins and independent `acceptance-audit1/`.
- `execution1/`: bound sources, spent plan, broker/issuer final records, readiness and decision/authority records.
- Native fixture: the sibling B25 root `baseline-native-run-0b874821-7cba-4e41-9e07-c2614a9f9dc6`.

Source review and controls are retained in the handshake candidate's review directories, including the final deadline and signal corrections. Fake controls and the nine owned-file publication checks do not establish native fault/cancellation behavior.
