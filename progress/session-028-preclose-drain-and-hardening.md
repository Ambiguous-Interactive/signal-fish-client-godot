# Session 028 — Pre-close packet loss + hostile-input hardening

Date: 2026-09-22. Scope: one focused surface — a zero-knowledge adversarial
audit of all three runtime layers (client/reconnect, protocol codec, WebRTC
mesh) with the confirmed findings fixed. Drift check first: main was green on
`000b4b0`, local main matched origin/main, 0 open issues, 0 open PRs, no
in-progress work.

## Issue debt

- Open issues were 0, so this session created the debt it paid down: filed
  #70–#73 from the audit, fixed #70/#71/#72 in this PR, and left #73 as the
  recorded hardening backlog (7 low-severity/design-gray items).
- Backlog item 7 (Reconnected diagnostics mislabel the payload as RoomJoined)
  was fixed in passing; the issue body was updated accordingly.

## Audit results

Three parallel adversarial reviews, every candidate re-verified against the
code before reporting. No P1s anywhere. Confirmed: one P2 (transport), two
P3 classes fixed (client guard, codec strictness), seven P3/backlog items
deferred to #73 with fix directions. The codec's never-crash contract,
MessagePack byte accounting, depth bounds, mesh lifecycle/routing, and the
reconnect budget/sticky-close machinery all survived review.

## Delivered

1. **#70 (P2): transport drops packets queued at close.** Godot's poll()
   deframes data frames and the close frame in one read; the transport only
   drained in OPEN/CLOSING, so pre-close frames were silently discarded.
   Fix: drain in CLOSED before emitting `closed`, deferring the close
   emission across polls while the per-poll cap leaves packets queued.
   Engine research (documented on #70): the web peer keeps packets queued at
   CLOSED (so this fix recovers them — web is the primary export target);
   native wslay wipes them engine-side (`WSLPeer::close()` clears
   `in_buffer`), an upstream limitation no GDScript layer can recover.
   Coverage: data-driven transport unit tests (drain-within-cap,
   cap-deferred close, read-error-at-CLOSED, plus a synchronous-redial-
   mid-drain case) and an opt-in smoke phase asserting end-to-end
   message-before-close ordering.
2. **#71: duplicate `Reconnected` re-emitted.** The issue-#24
   once-per-dial `Authenticated` guard had no `Reconnected` counterpart, so a
   hostile duplicate re-emitted the baseline and invited consumers to replay
   `missed_events` twice. Fix: `_reconnected_seen`, reset per dial; post-
   handshake duplicates fully silent. Covered in the reconnect suite.
3. **#72: silent String() coercion of wrong-typed optional strings.**
   `Authenticated.organization` and `RoomJoinedInfo.reconnection_token`
   (echoed back on `Reconnect`, so security-adjacent) skipped validation
   while every other optional string in the codec is gated; a full sweep of
   `_string_or_empty` consumers confirmed these were the only two. Fix:
   optional-string validation → `protocol_error`, link stays up. Covered by
   a data-driven hardening test across absent/null/valid/wrong-type for both
   fields and both RoomJoined/Reconnected envelopes.
4. **#73 item 7:** `Reconnected` decode diagnostics now name the envelope
   (`Reconnected requires ...`) instead of hardcoding RoomJoined.

## Validation

- Adversarial review round (zero-knowledge red team over the full diff):
  confirmed the three fixes and their pins; caught one new P2 my first
  transport revision introduced — a synchronous redial from a
  `packet_received` handler during the CLOSED-state drain acted on the
  replacement peer and failed the fresh dial with the old session's close.
  Fixed with a peer-identity re-check after the drain and pinned by a
  dedicated test. Review P3s also addressed: the "explicit present-null"
  decode cases now actually construct null (previously duplicated the absent
  case), and a handler-based connect avoids a reference cycle the lambda
  version introduced ("resources still in use at exit").
- `run-runtime-checks.sh godot` green (all suites + demo boots).
- `run-runtime-checks.sh smoke` green (including the new phase).
- `run-runtime-checks.sh static` green (private helpers, gdformat, gdlint).
- Suite wall time 8.1s vs 9.9s baseline; added tests are data-driven, so the
  fast gate stays flat.

## Leftovers / follow-ups

- #73 records the deferred items (mesh CLOSING-window send noise, manual
  reconnect() vs retained auto-reconnect context, `ConnectionInfo.custom.data`
  `to_dict()` aliasing, `max_outbound_message_size` i64 overflow collapse,
  defensive CLOSING guard in `_start_auto_reconnect`, unresolved
  `_send_authenticate()` ERR_BUSY). Each: fix opportunistically when a
  session touches the same file.
- Upstream-able engine issue: native `WSLPeer` drops pre-close queued packets
  (documented on #70); consider filing against godotengine/godot.
