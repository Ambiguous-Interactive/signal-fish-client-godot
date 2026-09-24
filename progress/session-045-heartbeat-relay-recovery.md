# Session 045 - Heartbeat backpressure deadline, relay recovery, issue debt

Date: 2026-09-24 - Branch: `heartbeat-relay-recovery` - Base: `origin/main` @
`d162a3c`

## Drift check

Local `main` mirrored `origin/main`; no open PRs; CI green. Four open issues:
#127, #128 (both from session 044's adversarial sweep), #123 (remainder), and
#125 (AI disclosure). PLAN's remaining items stay human-gated or
decision-gated, so the session drove issue debt, ordered by gameplay impact.

## #128 - A refused heartbeat beat arms the pong deadline

`_tick_heartbeat` used to skip arming `_awaiting_pong` whenever the beat send
was refused (backpressure), so a silently dead link that stayed saturated sat
`CONNECTED` forever and auto-reconnect never engaged. Upstream check: the Rust
client has no auto-heartbeat at all (`ping()` is manual), so the refused-beat
deadline is a Godot-client rule, documented as such in the method contract.

Behavior: a refused beat arms the same pong deadline and keeps retrying each
full interval; any inbound `Pong` clears it (the client already treats pongs
as unsolicited-proof-of-life), and the deadline expiring fails the link
through the normal transport-failure path. A new `_beat_in_flight` flag keeps
the delivered-beat cycle unchanged (no second ping while an answer is
outstanding). Red-green: the new backpressured-dead-link test fails 3/3
assertions on the old code and passes with the fix; the reworked
retry-quietly test pins that refused beats retry quietly, that a Pong clears
a refused-armed deadline, and that a link which drains recovers without
losing its beat cadence.

## #127 - Refused/dropped signaling relays recover

`_send_signal_to` ignored `send_signal`'s `Error`, and the mesh never
subscribed to `server_error`, so a relay refused by backpressure (`ERR_BUSY`)
or dropped server-side (`SIGNAL_RATE_LIMITED`) vanished and both peers sat in
negotiation until a new-generation plan landed. Each `_MeshPeer` now keeps an
ordered `pending_signals` queue (Offer-before-candidate order preserved) with
a `last_relayed` payload, redelivered by a drain pass in `poll()` throttled to
one attempt per `signal_retry_msec` (issue-#102 pattern; injectable for
deterministic tests). A `signal_retry_budget` of consecutive refused head
attempts drops the queue with one `SFLog` diagnostic (the initial refusal
consumes budget too); the drop is sticky until the peer's next fresh relay.
The new `server_error` handler re-queues `last_relayed` per peer on
`SIGNAL_RATE_LIMITED` - the wire Error carries no target peer, so the
freshest payload per peer is the healing probe, re-queued behind the same
throttle. Duplicate candidates are idempotent; redelivered SDP relies on the
remote tolerating reapplication, and the next plan/generation reconciles
roles. Other error codes heal nothing.

Adversarial round 1 caught three real holes in the first cut, all fixed:
the rate-limit re-queue bypassed the throttle (per-frame relay loop under a
refusing server), `push_front` + sticky-drop ordering/persistence gaps, and
doc claims that oversold the guarantees. Red-greened the throttle fix
specifically (the wait-out assertion fails against the old `due = 0` handler).

## #123 - closed (verified)

All three findings landed in #124/#130: one docs build per push (deploy
publishes the validation artifact), protocol-sync concurrency + timeouts, and
release job timeouts. Closed with a summary comment.

## #125 - AI disclosure

README and the docs landing page now carry the sibling-repo-style disclosure
(substantial Claude/Codex assistance; humans own protocol concepts, core
design, and review oversight).

## Local iteration speed (data)

Measured on this checkout: `run-runtime-checks.sh all` ~ 5 s wall (17 s CPU,
static + private-helper guard + format + lint + 7 Godot suites, parallelized),
single warm suite (`godot client`) ~ 2 s, `changed` on a clean tree 0.4 s.
The remaining per-iteration cost an agent feels is the pre-commit pwsh boot,
already shim-skipped for non-harness paths (~0.1 s, issue #112). No further
drastic win found; the loop is already sub-6 s end to end.

## Verification

`run-runtime-checks.sh all` green (format/lint/private-helpers clean after
gdformat); client suite red-greened per fix above; no new CI weight (docs
builds stay at one per push; runtime CI matrix unchanged).
