# Session 052: Text-path identifiers must be canonical UUID text (issue #151)

Session branch: `session-052-uuid-shape-ids` (from `origin/main` @ `2a7adc1`).
PR: one aggregate PR for the session's work.

## Scope

Open issues, gameplay-impact order (correctness > usability > performance):

- #151 (correctness): text-path event ids enforced non-emptiness, not UUID
  shape - `{"player_id":"not-a-uuid"}` decoded verbatim. **Fixed**, with the
  policy extended symmetrically to the outbound builders.
- #145 (performance): behavioral self-test CI wall fork-tax bound - **left
  open** (deferred in sessions 050/051; unchanged this round).

## Policy decision (recorded, not re-decided later)

Every upstream identifier (`PlayerId`, `RoomId`, `SessionGeneration`) is a
`uuid::Uuid` (server `src/protocol/types.rs` @ pinned v0.9.1 `24a5d10b`).
Accepted spelling set: **canonical lowercase hyphenated UUID text only**
(8-4-4-4-12, lowercase hex). Anchors:

- serde serializes `Uuid` as lowercase hyphenated - the only wire form a
  conforming server can emit; the server re-serializes every id it relays
  through the typed value, so no verbatim pass-through exists.
- Upstream's own text-path precedent for client-supplied UUID text,
  `canonical_room_operation_id` (server `messages.rs`), demands exactly the
  canonical form and rejects everything else.
- The binary path already enforces the 16-byte UUID and formats it to the
  same canonical string (`sf_binary_frames.gd::_uuid_string`), so one id
  decodes to one value on both paths.
- Simple/braced/urn/uppercase spellings are serde parse-acceptance only,
  never wire forms; accepting them would tolerate garbage a conforming peer
  cannot send.

## Changes

- `sf_type_utils.gd`: one shared gate, `is_canonical_uuid_text()` (length 36,
  hyphens at 8/13/18/23, lowercase hex only).
- Decode (12 sites in `sf_events.gd` + `_has_id` in `sf_types.gd`/
  `sf_session_types.gd` + `ready_players`/watermark arrays): present ids must
  be canonical; `protocol_error`, frame dropped, link stays up.
- Sentinels preserved and pinned: `AuthorityChanged` wire null -> "",
  `SpectatorLeft` null `room_id` -> "", `Signal` absent/null `generation`
  -> "", legacy Server 0.4 `SessionPlan` without `generation` -> "".
- `direct_endpoint.host` deliberately NOT UUID-gated (free-text address,
  upstream `DirectEndpoint`); pinned by its own row back in
  `protocol_hardening_tests.gd`.
- Outbound symmetric: `SFMessages.reconnect()` gates `player_id`/`room_id`;
  `peer_signal()` gates `to` and a present `generation` (`""`/null still
  omit for legacy Server 0.4); `SignalFishClient.reconnect()` refuses a
  non-UUID identity early (`ERR_INVALID_PARAMETER` + named-field
  `protocol_error`) before it can clobber the retained reconnect identity.
- Constructor (typed-view) fixtures intentionally keep placeholder ids:
  constructors coerce, decode is the gate (unchanged policy).

## Tests

- New `tests/protocol/uuid_shape_tests.gd` (moved out of
  `protocol_hardening_tests.gd` to stay under the 1450-line gdlint cap;
  registered in the runner): data-driven off-contract table - empty, garbage,
  uppercase (hex letters), braced, short (35), long (37), simple (32),
  shifted hyphens at wrong positions (36), urn generation, mixed
  `ready_players`, canonical-baseline overrides - every row asserts the
  error names the gate ("lowercase hyphenated UUID"); null-sentinel
  positives; canonical-verbatim positives; outbound builder refusals
  (uppercase/braced/placeholder reconnect, placeholder `to`, urn/int
  generation) + canonical positives + legacy `""`-omits-generation wire pin.
- `run_reconnect_tests.gd`: client `reconnect()` shape rows (uppercase,
  placeholder, braced room) with per-field message pins; error-count rows
  bumped.
- Corpus sweep: decode-path placeholder ids (`p1`, `s1`, `r1`, `gen-N`)
  re-derived to canonical UUIDs mirroring the fixture-corpus convention
  (1xxxxxxx=player, 2xxxxxxx=room, 3xxxxxxx=spectator, 4xxxxxxx=generation);
  wrong-typed tables use canonical ids so the *targeted* error still fires.
- Red-green proof: with the production change stashed, exactly the 12 new
  off-shape rows fail (old decoder accepts them); restored, green. Full
  `run-runtime-checks.sh all` green; `agent-check.ps1` green after `.llm`
  edits.

## Docs

- `.llm/skills/signal-fish-protocol.md` + `.llm/research/protocol-fixtures.md`:
  the canonical-UUID rule recorded once, with the `canonical_room_operation_id`
  anchor, so the next id question is already answered.
- `CHANGELOG.md`: Fixed entry (extends the #149 entry).

## Adversarial review rounds

- Round 1: outbound half unpinned by tests (MAJOR; one vacuous v3 row with a
  now-wrong label), decode rows only asserted "some protocol_error", the
  misplaced-hyphen row was length-only, client error unnamed the field.
- Round 2: verified the outbound rows are non-vacuous (`is_valid_message` is
  marker-key-only), every decode row discriminates the gate, counts and
  indices re-traced; found the shifted-hyphen row still missing (round-1 fix
  had silently not landed) - added.
- Round 3: delete-simulated the hyphen-position branch against the real gate,
  re-traced every `protocol_error` emission index, ran all suites - SHIP.
