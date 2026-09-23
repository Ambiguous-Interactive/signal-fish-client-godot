# Session 037 — Decode fidelity + state-machine hardening (#97, #99–#102) + local iteration speed

Date: 2026-09-23. Scope: one focused surface — an adversarial two-agent
sweep over the protocol and client/transport/mesh layers — plus issue #97
(deferred from session 036) and a local iteration-speed pass on the suite
runner. Drift check first: main green on `266f8b6` (PR #98), local ==
origin/main, one open issue (#97), no open PRs, baseline
`run-runtime-checks.sh all` green.

## Issue debt (filed + fixed this session)

- **#99 (P1, silent corruption):** `StreamPeerBuffer.get_string()` maps
  bytes 1:1 to code points — every multi-byte UTF-8 string in decoded
  MessagePack game data (opt-in `decode_msgpack_payloads`) arrived as
  mojibake, and the codec's own round-trip broke for any char ≥ U+0080.
  The class doc's replacement-character promise was also false. Fix:
  `get_utf8_string()` at both string reads (`sf_msgpack.gd`,
  `sf_binary_frames.gd`); pinned with multi-byte round-trip values, a
  hostile invalid-UTF-8 vector (U+FFFD, no byte-identity code points),
  and a high-byte encoding token that still fails the frame's
  exact-match checks.
- **#100 (P2, guard bypass):** a roomless `LobbyStateChanged` mapped
  lobby state onto in-room session states, so one off-contract frame
  forged `IN_ROOM_*` with no baseline — flipping `is_authenticated()`
  pre-`Authenticated` and putting `Ping`/`PlayerReady` on the wire
  pre-auth (the pinned server rejects any pre-auth frame). Fix: the
  handler's cache write and state mapping are gated on a room baseline
  (`_room_id`; spectator baselines set it too, so the `SPECTATING`
  exclusion stays); the signal still emits. New helper suite
  `tests/client/session_guard_tests.gd` pins both the pre-auth and
  authenticated cases (red-green verified).
- **#97 (open from session 036):** `to_dict()` round-trip loss. The
  resend path is deliberately canonicalizing (pinned by the session-032
  tests: cross-variant fields stripped, upstream defaults applied), so
  raw-verbatim everywhere would break the contract. Fix scoped to the
  true loss sites: webrtc `ice_candidates` round-trip raw-verbatim so
  the outbound validation refuses a hostile entry loudly instead of
  silently sending a shortened array (pinned in the resend
  canonicalization test), and the `RoomJoinedInfo`/
  `SpectatorJoinedInfo` roster rebuilds preserve wrong-typed entries
  verbatim (containers copied per the #73 no-aliasing contract) while
  dict entries still canonicalize in raw order. The keep-only-valid
  string-array coercion moved into one shared documented helper
  (`SFTypeUtils.coerce_string_array`, replacing five inner copies);
  typed accessors keep only valid entries by design and `raw` stays the
  unfiltered view (option A from the issue, now honestly true).
- **#101 (P3, #70-class):** an explicit `close()` at `STATE_CLOSED`
  skipped the queued-frame drain the poll path performs, so a consumer
  close could race the final pre-close frames out of the queue. Fix: the
  drain-then-close sequence (with the mid-drain redial re-check) is
  shared by both paths; data-driven transport test covers drain-within-
  cap and cap-deferred (follow-up poll completes the close).
- **#102 (P3):** the mesh flipped `_reported_connected` before calling
  `send_transport_status` and ignored the return code, so a report
  refused under backpressure consumed the boundary edge — the server
  never learned the data path connected. Fix: flip only on `OK`; a
  refused report stays armed and retries. Test drives the boundary
  through a real backpressured fake transport.
- **Adversarial loop results (review round):** the zero-knowledge
  red-team verified all six claims red-green and probed UTF-8 key
  forgery, re-entrant closes, mid-drain redials, tar edge cases, and
  warm-mode races — one P2 (the tar stream swallowed deleted-in-
  worktree files noisily; now filtered and loud through pipefail) and
  the actionable P3s landed: the roster round-trip helper is shared
  (one copy, not two), the #101 close-drain read-error path is pinned,
  and bugbot's flood finding reshaped #102's retry into the heartbeat's
  backpressured-beat rule (at most one retry per injectable interval;
  a flap that resolves the edge drops the leftover deadline so a fresh
  edge reports immediately). The "roster raw aliasing" note was assessed
  and skipped: raw is by-reference across all value objects by the
  issue-#48 decode-aliasing design; post-construction caller mutation
  showing through is consistent, documented behavior.

## Sweep method

Two zero-context sub-agents adversarially hunted the protocol layer
(msgpack/binary frames/json guard/error codes) and the
client/transport/mesh layer (state machines, redaction, peer
lifecycle), each required to verify findings with godot probes against
HEAD; every confirmed finding became an issue above. Verified-clean
surfaces recorded for future sweeps: json dup-key guard (15×15
spelling oracle, 0 bypasses), binary envelope (6000 mutation-fuzzed
frames), msgpack non-string surface (12k random decodes + 4k round-
trips), error-code table, timer/negative-delta handling, heartbeat ×
auto-reconnect interplay, mesh plan-churn peer accounting, secret
redaction. The base64 trailing-bits parity nit (#99 probe finding 2)
was assessed as a P3 leniency whose decoded bytes are identical to the
canonical spelling; left alone.

## Local iteration speed (agent loop) + CI

- `run-runtime-checks.sh godot` accepts a suite selector
  (`protocol transport client binary reconnect demo_boot p2p_boot`);
  an explicit single suite runs warm in-tree (live `.godot` cache, no
  cold copy) — `SF_COLD=1` forces the CI-identical cold copy.
  Multi-suite selections keep the concurrent cold-copy isolation.
  Local loop: edit → affected suite ≈ 2.9 s (was 5.5 s for the full
  gate); full `godot` gate 5.5 s → 2.3 s; `all` ≈ 11.3 s → 6.6 s.
- The per-file `mkdir`/`cp` cold-copy loop became one tar stream over
  `git ls-files -z` (same file set, symlinks included), which is where
  the full-gate wall dropped; CI's test legs share the runner, so their
  wall shrinks the same way with zero coverage change.
- CI jobs/workflows otherwise untouched; no new steps, so no gate time
  added anywhere.

## Validation

- `run-runtime-checks.sh all` green before and after (5 suites + 2 demo
  boots); static (private-helpers, gdformat, gdlint) clean; every fix
  red-green verified by stashing just the production hunk; probes and
  mutation checks recorded above. CI: watch the PR run.

## PR review round (post-open follow-up)

- Fetched all PR feedback (two bugbot rounds + zero-knowledge red team).
  Both bot findings were already fixed on HEAD; their **classes** were then
  swept across the runtime by a fresh probe-armed sub-agent:
  - *Diagnostic amplification* (a refused send retried per frame floods
    `protocol_error`): all emit sites traced; the two known instances
    (heartbeat, mesh status) are the only frame-rate-adjacent retries —
    clean elsewhere.
  - *Stale armed-state across flap/re-entrancy/session-swap*: every
    pending/deadline/latch var in the client, mesh, and transports audited
    against all three axes; one more real bug found and fixed.
- **New fix (same class, exhaustion path):** `_schedule_auto_reconnect`
  wiped the retained reconnect identity *after* emitting the exhaustion
  `connection_failed`. Because Godot emission is synchronous, a consumer
  redialing from that handler had its fresh capture (issue #73 contract)
  clobbered, so the manual dial's later death silently dead-ended
  auto-reconnect. The post-emit wipe now yields to an in-flight dial
  (state `CONNECTING`); pinned by
  `_test_redial_from_exhaustion_handler_keeps_the_fresh_identity`
  (redial inside the handler, manual dial dies pre-baseline, fresh
  terminal exhaustion notice asserted). Red-green verified.
- **Guidance updates:** `.llm/skills/runtime-architecture.md` gains
  "Signals are synchronous: audit every emit site" (post-emit writes,
  three-axis invalidation for armed state, retry-throttling rule,
  handler-re-entry test pattern); `.llm/skills/testing-automation.md`
  documents the suite selector/warm mode and the shell rules the tar
  cold copy taught (set -e suppression in command substitutions, ls-files
  filtering, exit-status gating). Index regenerated; agent-check green.

## Leftovers / follow-ups

- PLAN §13 items 4–8, 10 (upstream verification) remain open; P7
  (Godot 3.6, rkyv) behind their gates.
- v3 `seq`/`epoch` stamps are still decoded-and-dropped (feature
  decision, session 033 leftover).
- Possible future guard: duplicate off-baseline `RoomJoined` re-emits
  (noted during the sweep, weaker than #100 — no once-per-baseline
  latch yet).
