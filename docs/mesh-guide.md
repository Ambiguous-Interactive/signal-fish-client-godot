---
description: "SFWebRTCMesh: opt-in v3 session plans, WebRTC signaling handled for you, and a WebRTCMultiplayerPeer mesh."
---

# Mesh (v3)

`SFWebRTCMesh` is an opt-in layer that turns negotiated v3 session plans
into a working `WebRTCMultiplayerPeer` mesh. The core server-relayed client
stays zero-native; relay-only users pay nothing.

## Opt in through config capabilities

Set the v3 capability fields on `SignalFishConfig`:

- `protocol_version`: set to `3`.
- `supported_transports`: transports you can handle.
- `supported_topologies`: topologies you can handle.
- `requested_capabilities`: extra capability tokens.

These fields are omitted when unset, so v2 wire bytes stay identical.

## Using the mesh

```gdscript
var mesh := SFWebRTCMesh.new()
add_child(mesh)
mesh.attach(client)
# Once a webrtc plan lands, run RPCs over the mesh:
multiplayer.multiplayer_peer = mesh.get_safe_multiplayer_peer()
```

`attach(client)` subscribes the mesh to the client's signals and returns
`Error`. `detach()` unsubscribes.

`get_safe_multiplayer_peer()` returns an opt-in `MultiplayerPeerExtension`
for RPCs. It keeps received bytes, sender, channel and transfer mode together
when channels overlap (#403). It uses the existing three negotiated channels
and delegates sends to Godot. Use it as the sole receiver. The original
`get_multiplayer_peer()` still returns the engine peer.

Assign the safe peer after a WebRTC plan creates the mesh. It discovers
already-connected peers on its first poll. When a plan replaces the engine
peer, assign the new safe peer to `multiplayer.multiplayer_peer`. Old adapters
stay disconnected after teardown. Closing the adapter tears down its mesh.
Room plans and player-left events can replace links while the same safe
peer stays assigned. Lifecycle callbacks may change other links or poll
again; closed links are excluded and each incarnation is announced once.
Only the three default channels are supported. Godot's GDScript packet hook
reports empty datagrams and read errors as `ERR_UNAVAILABLE`; use
`receive_packet()` when your raw protocol needs those distinctions.

## How the mesh behaves

- It consumes `session_plan` and `signal_received` and answers with
  `send_signal`.
- The server decides who offers. The `new_peer(peer_id, you_initiate)`
  signal carries that decision; roles are never computed locally.
- It applies `ice_servers` by replacing the previous list, never merging.
  An empty list is authoritative. The server pre-gathers ICE servers on
  `RoomJoined`/`Reconnected` (`RoomJoinedInfo.ice_servers`).
- It rebuilds retained peers on a generation or role change, and drops
  peers absent from the latest plan.
- It tears down on `room_joined` (a fresh baseline), `spectator_joined`, `room_left`,
  `disconnected`, `connection_failed`, `authentication_error`, `reconnected`,
  and node exit. A replayed plan inside `missed_events` cannot revive an old mesh.
  `player_left` only drops the leaving peer; the rest of the mesh
  survives.
- A fresh `player_joined` or `player_reconnected` epoch closes that peer's
  old link and waits for a new plan generation. Duplicate known epochs keep
  the link. Missing epochs cause the link to close and wait for a new plan.
- Spectators never open mesh links. Public `game_starting` events leave
  viewing on the relay.
- It calls `send_transport_status` on the client only at the aggregate
  0<->1 connected-peer boundaries.
- A signaling relay refused by backpressure or rate-limited by the server
  is re-queued and redelivered in order (retries wait out one interval
  each) instead of being lost, so congestion cannot stall negotiation
  silently.
- Offer, SDP description, and poll errors close only the failed peer and log
  the engine error. A later plan can open a fresh link. A refused ICE
  candidate logs a warning and leaves the link available for other candidates.
- Failed, disconnected, and closed connections, closed required channels, and
  engine-removed peers release their links. A later plan can retry the same peer.
- Status retry delays end when the room resets or its plan generation changes.
- Peer ids derive deterministically from player UUIDs.

## Direct plan updates

Handle each `session_plan` signal when your game owns Direct sockets.
A host can publish a replacement endpoint without a membership change.
Stop using the previous endpoint and apply the new host, endpoint, and
generation together. A Relay plan clears the endpoint and peer obligations;
switch gameplay to the server relay. `SFWebRTCMesh` drops its links on
Direct and Relay plans. It does not manage game-owned Direct sockets.

`peer_transport_status` emits reports in received wire order, including
duplicates. Consumers that cache status should replace it on each report.
Replay reports arrive in `reconnected.missed_events` for the consumer to
apply; they do not also emit as live status signals.

## Related signals

| Signal                                                     | Arguments                                               |
| ---------------------------------------------------------- | ------------------------------------------------------- |
| `session_plan(plan)`                                       | The negotiated plan (`SFSessionTypes.SessionPlanInfo`). |
| `new_peer(peer_id, you_initiate)`                          | A peer joined the mesh plan.                            |
| `signal_received(from_player, generation, signal_payload)` | Signaling payload from another peer.                    |
| `peer_transport_status(peer_id, transport, connected)`     | A peer's transport went up or down.                     |

## Platform note

Native Godot exports need a WebRTC GDExtension such as
[webrtc-native](https://github.com/godotengine/webrtc-native). Browser exports
use browser WebRTC.

Godot's mesh creates three negotiated channels: `reliable` (id 1), `ordered`
(id 2), and `unreliable` (id 3). Transport reports require all three channels
to be open. Closing any required channel reports the last connected link
down and releases the link even when its peer connection was connected. A later
plan can create a replacement link. Applications still drive their
`MultiplayerAPI` or poll the multiplayer peer to deliver gameplay packets.

Godot 4.3, 4.4.1 and 4.7.2 pass a misspelled lifetime option when creating
ordered and unreliable channels. Native and Web controls found no finite
packet lifetime. Transfer-mode labels alone do not establish transport loss
behavior. The [upstream repair](https://github.com/godotengine/godot/commit/caa386e89570d293c03ad7c723d5fbd7eb1a2717)
needs stable-engine qualification; track it in [issue #433](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/issues/433).

Every interoperability run checks direct reliable, ordered and unordered
channel controls. The finite controls request `maxPacketLifeTime: 100`;
the reliable and misspelled-option controls leave the lifetime unset.
`seats.json` retains `lifetime_controls`, per-generation `channel_contracts`
and direct `browser_channels` properties. `finite_gameplay_lifetimes` reports
the observed gameplay contract for each seat. Godot Web getters convert browser
`null` to `0`; native getters use `-1` for an unset limit. Use the direct
browser properties to distinguish these values from a configured limit.

Add `--require-finite-lifetimes` to qualify a repaired engine or backport.
This requires finite ordered and unordered gameplay channel lifetimes on
every seat and recorded generation. Existing supported stable engines fail
this check. Passing it establishes channel configuration; controlled loss
or delay is still needed to prove packet expiry. Reliable delivery, exact
packet metadata and interrupted-link recovery remain part of the drill.

Use the same Godot channel layout at both ends. The server's
[browser](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/182cb234c7aa601be3c2aad881948b3c5b853aaa/clients/browser/src/page/engine.ts)
and
[native](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/182cb234c7aa601be3c2aad881948b3c5b853aaa/clients/native/src/engine.rs)
default reference profiles create two in-band channels, `reliable` and `unreliable`.
Their responders adopt remote channel announcements. Godot's negotiated
channels do not send these announcements. Use server relay for these
pairings. The native Engine also has an opt-in Godot profile described below.
Full reference CLI sessions remain unverified.

## Native reference Godot profile

The server's [native Engine at 67725d6](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/67725d677ff0fdb662d041af9b175d8a6d08c75f/clients/native/src/engine.rs)
adds `ChannelProfile::Godot`. Both offer roles create all three negotiated
channels. Its ordered and unordered channels request a 1 ms packet lifetime.
The default reference profile keeps its existing layout. Keep this profile
experimental: two retained Godot 4.3 native-offer controls at c527219 skipped the start of
a recovered reliable stream. Native raw/admitted counters retained the gap,
with zero discarded or rejected receipts. A 4.4.1 startup control at 18cadb5
also missed reliable snapshot sequences 0 through 3. Track the unresolved cause in
[server #1244](https://github.com/Ambiguous-Interactive/signal-fish-server/issues/1244).
The 67725d6 repair initializes negotiated channels before startup DATA. Its
paired-wire regression preserves all 32 reliable packets before event polling.
The original captured incident still needs matching ingress evidence. Use server
relay until the required engine, recovery and remote-network checks pass.

Build the opt-in probe in a checkout of that server revision:

```sh
mkdir -p /path/to/server/clients/native/examples
cp tests/smoke/webrtc_native_reference.rs \
  /path/to/server/clients/native/examples/godot_qualification.rs
cargo test --manifest-path /path/to/server/clients/native/Cargo.toml \
  --example godot_qualification
cargo build --manifest-path /path/to/server/clients/native/Cargo.toml \
  --example godot_qualification
python scripts/check-webrtc-reference.py \
  --native-reference-probe /path/to/server/clients/native/target/debug/examples/godot_qualification \
  --reference-revision 67725d677ff0fdb662d041af9b175d8a6d08c75f \
  --native-extension /path/to/webrtc_native --safe-receive --mixed-traffic \
  --binary-traffic --startup-burst --retirement-matrix --require-gameplay \
  --output /tmp/native-reference
```

The browser coordinates the probe through local HTTP commands. WebRTC packets
pass through the native Rust Engine. This control bridge adds scheduling delay;
use its results to assess correctness. Adjacent packet sends share commands
of up to 256 packets. Signaling, snapshot, close and removal commands retain
their order after earlier packets. A failed batch stops at its first failed
send. One owned send task keeps running while the probe drains incoming events
or awaits channel metadata. Later commands wait until that send completes. Channel closure cancels a pending
send. Receive rejection also cancels it and retires the peer. Dropping the
pending send aborts its task. Terminal event handling waits for cancellation. The example tests cover held sends, command order,
shared native mutex waits, write errors and cancellation. `assessment.json` records the backend,
source revision and probe binary hash. `native-reference.jsonl` retains commands'
results and native callbacks. `native_snapshots` retains Engine receipt counters
before removal, including failure cleanup. The driver waits for cleanup before
closing its coordinator and keeps the original gameplay failure. Native
`internal_id` values identify local handles;
Godot's channel IDs identify the negotiated SCTP streams.

`native_timing` records command issue, output observation and reply delivery
with command IDs and native JSONL line numbers. Times use microseconds from
the bridge's monotonic clock. `probe_us` records emission time on a separate
native monotonic clock; compare intervals within each clock. Records stop at
10,000 and retain a dropped count. These timings distinguish bridge progress
from gameplay progress. They do not measure SCTP ingress or prove packet-loss
causes. `reference_terminal` retains the latest phase counters before cleanup,
including failures before the six-second observation. Partial Godot progress
also retains initial probe labels received before a later phase failure.
The original observation stays separate. Read failures include the engine error, sender, mode, channel
and byte count.

`diagnostics.native_bridge_packets` joins initial probes and heartbeats to
their command IDs, native output and HTTP event collection. `pipe_write_ms`
measures command issue to pipe flush. `command_reply_ms` ends at reply delivery.
`reader_to_delivery_ms` measures native output observation to HTTP collection;
browser dispatch happens later. Missing or duplicate receipts leave this
interval unset. Batch commands share command times. Packet markers retain
phase and sequence; packet bodies stay in the existing JSONL artifact.

The reference collector waits for actual required channel-close callbacks
within the original phase deadline before recording retirement. A remove
reply alone cannot complete this check. Native snapshots retain `native_closed`
records with generation, label, native emission time and browser dispatch time.
Delayed callbacks remain separate from missing callbacks (#461).

Set `SF_REFERENCE_TRACE` to a tracing filter when running the native probe to
retain opt-in transport logs in `native-reference.stderr`. Trace timestamps use
the same `probe_us` origin as JSONL events. Available transport detail depends
on the reference build. Keep the exact source, binary hash and any local trace
patches with the run; an enqueue trace alone cannot prove packet expiry (#458).

### Initial probe expiry

Use reliable packets for startup state that every player must receive. A
successful unreliable send can expire before transmission. Keep sequence
numbers on position updates and let later updates replace missed state.

For sender evidence, use the server-owned probe at
[`e8a2d969`](https://github.com/Ambiguous-Interactive/signal-fish-server/tree/e8a2d969a73d2870ecce41a62d103ec70aa6c914/clients/native/tests/fixtures).
It includes the ordered-expiry repair and per-message SCTP observations:

```sh
git -C /path/to/server apply /path/to/client/tests/smoke/webrtc_finite_send_trace.patch
mkdir -p /path/to/server/clients/native/examples
cp /path/to/server/clients/native/tests/fixtures/godot_reference_probe.rs \
  /path/to/server/clients/native/examples/godot_reference_probe.rs
cargo build --manifest-path /path/to/server/clients/native/Cargo.toml \
  --example godot_reference_probe
python scripts/check-webrtc-reference.py \
  --native-reference-probe /path/to/server/clients/native/target/debug/examples/godot_reference_probe \
  --reference-revision e8a2d969a73d2870ecce41a62d103ec70aa6c914 \
  --native-extension /path/to/webrtc_native --runtime all --offerer both \
  --safe-receive --mixed-traffic --startup-burst --credit-transport webrtc \
  --require-gameplay --output /tmp/reference-expiry
```

`native_timing.sender_evidence` retains up to 64 enqueue, live receipt and
closure samples, with JSONL line numbers and an overflow count. Full native
JSONL remains beside the report. `diagnostics.initial_probe_phases` joins
initial probes to those samples. A match requires the same physical generation,
message ID, stream incarnation, stream ID, ordering and reliability policy.
Sample times must follow enqueue on the same native clock. Incomplete
sample traces leave gaps unresolved. The optional patch captures transport
snapshots immediately before and after each initial or retirement send. The
message ID must advance by exactly one (the first is zero), the target channel's
send count must increase by one, and other channel counts must stay unchanged.
Both snapshots must belong to the same physical generation. Retain the patch,
compiler, source and binary hashes with each run; sampling can affect scheduling.

`expired_before_selection` requires matching lifetime abandonment with
`transmission_selected=false`. `abandoned_after_selection` requires a true
selection flag; it does not prove packet emission or remote receipt. A received
probe with matching abandonment reports `conflicting_evidence`. Missing,
duplicate or mismatched enqueue evidence leaves a gap `unresolved`. First/last
abandonment samples can omit intermediate messages. An absent match cannot exclude
expiry. Older probes can run without these fields; after-only sender evidence
leaves abandonment attribution unresolved.

The report keeps the strict initial-probe verdict separate. Every direction
and generation must receive both labels, and a missing unreliable probe still
fails `--require-gameplay`. Reliable snapshots retain every exact receipt.
This native sender evidence does not qualify stable Godot's unset lifetimes,
the historical untraced #458 packet, or remote networks (#433, #355).

Local service-rejoin controls at that reference revision pass both offer roles
on Godot 4.7.2 native/Web and loaded Godot 4.3 native. All 48 initial receipts
and 3,072 reliable snapshot receipts pass. Live native samples also retain
finite-message abandonment before selection. Those records refer to other
message IDs; these runs do not reproduce a missing initial probe. Stable
Godot still reports unset ordered/unreliable lifetimes. The new native repair
and these local controls leave repaired-engine and remote qualification open.

A later Web reference-offer service control at the same reference revision
captures an absent initial unreliable probe with matching sender evidence.
It uses 16 KiB snapshot bodies, the 48 KiB byte window, startup traffic and the
reference-consumer pause. Generation 1 enqueues message 33 on stream 3,
incarnation 2, SSN 0. A later live receive sample retains that exact lifetime
abandonment with `transmission_selected=false`. All reliable full, partial and
startup receipts finish. That older after-only capture lacks the unique enqueue
boundary now required for attribution. Its strict initial-probe verdict stays
failed; reanalysis leaves the sender result unresolved. The earlier untraced
packet and remote qualification remain open.

For packet-level SCTP controls at reference commit
`67725d677ff0fdb662d041af9b175d8a6d08c75f`, apply the optional trace patch
before building the probe:

```sh
git -C /path/to/server apply /path/to/client/tests/smoke/webrtc_sctp_trace.patch
SF_REFERENCE_TRACE=godot_packet=trace python scripts/check-webrtc-reference.py \
  --native-reference-probe /path/to/probe --native-extension /path/to/webrtc_native \
  --reference-revision 67725d677ff0fdb662d041af9b175d8a6d08c75f \
  --runtime native --offerer godot --safe-receive --mixed-traffic \
  --startup-burst --credit-transport webrtc --require-gameplay \
  --output /tmp/reference-sctp
```

The patch records packetization, transmit selection and pending/inflight
abandonment with stream, message and bounded packet identity. Transmit
selection is an SCTP boundary; it does not prove remote ingress. A loaded
Godot 4.3 service-rejoin control captured the phase-2 initial unreliable probe
being abandoned while pending, with `nsent=0`, 3.867 ms after packetization.
Its strict initial-probe check failed while all reliable receipts passed.
Enabled tracing adds scheduling and I/O overhead. This explains that captured
packet; the older #458 history still lacks a packet-level trace. Keep finite packet loss separate from reliable loss.

Add `--startup-burst` to send 32 reliable packets per seat and generation.
The native probe sends directly at reliable-channel
open, before reporting that open to the browser coordinator. Godot sends when
its mesh is ready. Both receivers require exact phase, sender, sequence, bytes
and reliable mode. `startup_sent` and `startup_received` must each be 32 on
both seats. The normal snapshots, mode checks, retirement and recovery still
run. This control qualifies immediate native sends and ready-mesh Godot sends;
it does not send from Godot before its mesh becomes ready.

With a byte window, each sender waits for exact consumption credit for all
32 startup packets before sending snapshots. Initial probes and heartbeat
sends, reads and echoes keep running during that wait. Reports require
`startup_credit=true`, `startup_acknowledged=32` and
`snapshot_startup_credit=32` on both seats in each generation. Duplicate,
wrong-mode and wrong-phase credits fail the run. Credit resets on rejoin.

This prevents the 32 KiB startup burst from overlapping a separate 48 KiB
snapshot window in the default 64 KiB Web receive buffer. Startup packets
still form one immediate burst; the receive buffer must hold that burst
plus control traffic and framing. `--snapshot-window-bytes 0` keeps the
original packet-only workload with no startup credit. Retain its verdict
separately when comparing receive loss (#442), heartbeat delays (#440) and
credit progress (#396).

Each generation sends 128 reliable snapshot chunks, four partial-transfer chunks,
32 unordered positions and eight ordered probes per seat. Every receipt must
match its bytes, sender, channel and transfer mode. Reliable snapshots require
all receipts and credits. Lifetime-limited channels require positive receipts,
unique position sequences and increasing ordered sequences. Reports retain the
exact received sequences and offered counts, including gaps. Native properties
must show negotiated channels, correct ordering, unset retransmission limits,
a reliable lifetime of `null` and two 1 ms lifetimes. Recovery must create a
new native generation. The retirement matrix closes each of the three channels
from either seat after the safe receiver selects a packet.

Stable Godot's lifetime remains unset. This makes delivery properties asymmetric
between the native profile and those engines. A missing lifetime-limited packet
alone does not prove expiry. Repaired-engine comparison, controlled loss or delay,
full service sessions and remote-network qualification remain open.

### Snapshot bytes and receive buffers

Games must bound bytes in flight as well as packet count. The default WebRTC
channel receive buffer is 64 KiB. A 32-packet window with 4 KiB bodies can hold
more than 128 KiB, before control packets. [Godot Web](https://github.com/godotengine/godot/blob/4.7.2-stable/modules/webrtc/webrtc_data_channel_js.cpp#L77)
drops incoming data when that local buffer fills, including reliable packets. Poll and drain each frame;
leave buffer space for credits, heartbeats and packet headers.

Add `--snapshot-body-bytes 4096` to the reference drill to repeat the larger
snapshot workload in #442. It keeps 128 chunks per direction and generation,
the 32-packet window, exact receipt checks and existing deadlines. Startup and
binary probes keep their own sizes. The default snapshot body remains 1024 bytes.

For a separate pacing control, add `--snapshot-window-bytes 49152`. Both seats
also cap unacknowledged snapshot bytes, including the application prefix.
The byte window must hold one chunk plus a 32-byte header allowance. For
smaller windows, consumption credits follow each 1, 2 or 4 chunks; windows
that hold eight chunks keep the existing eight-chunk cadence. The batch always
fits the window. With 4 KiB bodies, use 4128, 16512 or 28896 bytes to test
one-, four- or seven-chunk capacities. All runs still send 128 chunks in each
direction and generation. This limit covers snapshot bytes; account for other
traffic when choosing a window for your game.

Use `--slow-receiver` to pause Godot reads for 1500 ms. Use
`--slow-reference-receiver` to pause reference snapshot consumption while
heartbeats continue. Run these as separate controls. A byte-paced pause checks
the queue depth that fits its smaller window. The original packet-window
pause still requires at least 24 queued chunks. Every run still requires all
reliable chunks and credits, exact metadata, retirement and fresh-link recovery.
A paced pass does not qualify the original workload.

Godot 4.7.2 native/Web controls with 4 KiB bodies pass one-, four-, seven-
and eight-chunk WebRTC windows through fresh links. HTTP credit passes the
four-, seven- and eight-chunk controls; the one-chunk Web HTTP run reaches
the unchanged deadline without a local buffer-drop or exact-byte failure.
Treat that stop-and-wait timing limit separately from reliable packet loss.
With Chromium 156, one-chunk WebRTC service rejoin and seven-chunk HTTP credit
holds pass on both seats. Four-chunk reference-consumer pauses also pass,
including new heartbeat round trips during each pause. A one-chunk pause can
queue no position sample because positions follow each fourth snapshot;
that strict pause control remains a failure even when every snapshot and
heartbeat arrives.

Use `--channel-in-buffer-kb 256` in a separate capacity control to set
`network/limits/webrtc/max_channel_in_buffer_kb` before engine import. The
setting applies to each Godot channel. Default `0` keeps the engine default.
The report retains the requested setting and checks each phase's observed
setting. Keep payload size, packet window, reader pause and deadlines fixed
when comparing capacities. Retain the original-capacity failure and its first
missing sequence separately. Size a game's receive capacity for its outstanding
bytes and control traffic, or bound that backlog with consumption credits.

Local Linux arm64 controls with webrtc-native 1.2.2-stable and Chromium 149
preserved every 4 KiB snapshot through service rejoin with the 48 KiB window
on native and Web Godot 4.3, 4.4.1 and 4.7.2. The Godot reader paused for
1500 ms in each generation. Peak outstanding snapshot data was 45,331 bytes.
The 4.7.2 Web packet-window control dropped 17 chunks during that pause;
sequence 23 was expected when sequence 40 arrived. Its active-reader control
passed. A matched Chromium 154 Godot-offer Web control reproduced the same
17 drops and first missing sequence. With only the buffer raised to 256 KiB,
native/Web Godot 4.7.2 preserved every snapshot through rejoin in both offer
roles, with the same 4 KiB bodies, 32-packet window and 1500 ms reader pause.
The original #442 history used Chromium 156 and remains open.

A fresh Chromium 156 active-reader service control passes both generations.
Its paused-reader control reproduces 17 local drops and the sequence 23-to-40
hole. A four-chunk byte window preserves every snapshot, position queue proof,
retirement and service rejoin with the same reader pause. The queue proof
counts the safe reader's selected unread packet; omitting it caused a false
failure in the earlier four-chunk control.

A later Chromium 156 active-reader service run, with Godot offering, logged
five buffer drops. The reliable reader expected sequence 107 and read 112.
Browser callbacks contain all five missing chunks with complete traces.
Callbacks 92-111 delivered 82,420 snapshot bytes within 11 ms to the default
64 KiB channel buffer. The largest Godot frame gap was 127 ms. Byte limits
also apply to games that drain every frame. The original nine-drop history
still needs its own attribution.

Phase records include `snapshot_body_bytes`, `snapshot_window_bytes`,
`outstanding_snapshot_bytes` and `peak_outstanding_snapshot_bytes`. A pass must
match the requested sizes, stay within the window and finish with zero
outstanding bytes. A snapshot failure records the expected and received
sequence, received byte count and transfer mode. Godot progress retains the
configured receive-buffer size, channel queue counts and outgoing buffered
bytes. `buffered_amount` measures pending sends; it does not measure the
receive queue.

Browser stats include per-channel callback counts, bytes and up to 1024
callback timestamps. Godot retains up to 1024 packet-read timestamps per phase,
with byte counts and modes. Each trace reports overflow. The browser's
callback bytes can include data later dropped by the engine buffer. Compare
those callbacks with Godot reads and the first missing sequence.

Native bridge snapshots retain packet enqueue, HTTP dispatch and command
completion times in `packet_timings`. `native_sent` records completed native
send calls and their later browser callback delivery. `native_heartbeat_received`
records each heartbeat marker's native receipt `probe_us` and browser delivery
`callback_ms`. It caps each phase at 128 entries and reports overflow.
Match send and receipt `probe_us` values for a native round trip; browser
command and callback delays use browser timestamps. Heartbeat records join
these stages by phase and sequence. Godot records receive times; the reference
records enqueue and echo times. Browser and Godot timestamps use milliseconds
on separate clocks. Native `probe_us` uses microseconds on another clock.
Compare intervals within each clock. Command completion bounds send completion;
it does not prove remote receipt. These traces help investigate #440 while
preserving its new-round-trip-during-pause requirement.

### Read a failed reference assessment

Both gameplay drivers reuse HTTP connections for relay markers and native
commands. Their local server allows 128 pending connections and sends small
replies without Nagle delays. This reduces connection pressure when several
seats poll at once. It does not establish the cause of an earlier timeout or
change any gameplay deadline, byte check or pause requirement.

`assessment.json` includes `diagnostics` even when the driver fails. Start with
`godot_failure.reason`, `last_stage` and `last_ready`. `godot_progress` keeps
the last observed frame gap and polling state when a driver timeout leaves
no Godot failure. Setup errors retain the process exit code and engine-error
flag with the import or export log path. `godot_queue` retains
snapshot progress, unacknowledged bytes, channel queue counts and configured
receive capacity at failure. `godot_buffer_drop_messages` counts the engine's
local receive-buffer drop messages in the Godot log. A snapshot sequence gap
and a local drop are separate observations; retain both with the full log.

Web assessments retain `godot_browser_callbacks` through channel closure.
Each of at most 32 channels keeps 1024 callback times, byte counts and known
snapshot, heartbeat, startup, position, ordered, initial probe, retirement and
credit identities. `dropped` counts omitted trace records. Opaque
packets keep a null identity. `diagnostics.snapshot_receive_phases` matches
snapshot sequences against Godot's bounded `receive_timings`, including the
packet that failed validation. Compare `first_callback_not_read` with
`first_read_after_gap` and the validated prefix. A callback proves delivery
to browser JavaScript. An unread callback can still be queued or cached;
combine a sequence hole with the engine drop log before locating local loss.
Native assessments have no browser callback evidence.

`diagnostics.browser_read_phases` joins the Web callback and Godot read traces
on `performance.now()`. Each script read samples this browser clock just after
`get_packet`. Latency summaries separate snapshots, partial chunks, heartbeats
and credits. `pause_heartbeats` separates the old heartbeat backlog from packets
sent during the reference pause. Completed read intervals may end after resume.
They measure callback to script delivery, including any cached packet wait. The synchronous clock read adds probe overhead.

`heartbeat_echo_latency_ms` separates read-to-echo from callback-to-echo time
on the same browser clock. The echo timestamp follows a successful send call;
it does not prove remote receipt. The pause summary includes these intervals.

`peak_tracked_unread_payload_bytes` and `terminal_tracked_unread_payload_bytes`
count tracked reliable payload bytes with no script read yet, including startup
packets and the initial reliable probe. These include
queued, cached and dropped bytes; other packets and engine framing are excluded.
They do not measure ring occupancy. Compare the raw callback and read timelines
with `channel_in_buffer_kb` and the first sequence gap. Duplicate identities,
wrong transfer modes, byte mismatches, missing clocks or callback/read trace overflow leave
backlog totals `null`. `invalid_intervals` and `unmatched_script_packets` keep
incomplete evidence visible. Native reports set `available` to false.

`reliable_backlog` groups tracked unread payload bytes and packet counts by
kind at the peak, each matched rejection, and each heartbeat callback/read.
Startup, snapshots, partial chunks and credits remain separate. A rejected
arrival has its own byte count and is excluded from these backlog totals.
Add that size to its `backlog.bytes` to inspect the offered arrival boundary.
These are observed payload totals; cached packets, physical prefetch timing,
framing and untracked traffic prevent an exact engine ring occupancy claim.

Heartbeat `at_callback` includes the heartbeat when no rejection was observed;
`at_read` excludes the consumed heartbeat. Missing reads stay null. `boundary`
and `simultaneous_events` identify whole callback or read groups at the same
timestamp. Tied callbacks are grouped before tied reads; an `after_reads`
snapshot excludes every read in that group.
Incomplete, ambiguous or truncated traces set `available=false` and leave
peak/terminal totals null. Compare this breakdown with heartbeat latency and
the native/command stages before attributing a delay to bulk traffic.

`godot_browser_drops` retains up to 128 engine buffer-drop console errors on
the browser clock. Each stores the preceding channel callback; the error
still reaches the original console handler. `first_tracked_buffer_drop` is
the first retained error whose preceding callback identifies a tracked packet
in that phase. `tracked_unread_payload_bytes_at_first_drop` gives the tracked
backlog at that instant. Later callbacks can raise the terminal backlog after
validation has stopped. `drop_trace_dropped` counts omitted error records.
The preceding callback alone does not prove which engine write failed.

`diagnostics.packet_delivery_phases` retains command, native send enqueue,
browser callback and script read records for each known incoming packet.
Initial reliable and unreliable probes remain listed when every stage is absent.
Use `sent_not_read`, `callback_not_read`, `duplicate_stages` and
`metadata_mismatch_stages` to separate a missing initial probe from snapshot,
position or ordered traffic (#458). Trace overflow and unobserved stages remain
explicit. Native enqueue does not prove SCTP transmission or expiry. The stage
clocks differ; compare intervals only within one clock. Exact payload and
gameplay checks still determine the verdict.

`diagnostics.retirement_delivery_phases` lists the cached unreliable packet,
later reliable packet and finite tail separately (#471). Each keeps its native
enqueue identity, matching abandonment observations and browser callbacks.
`queued_arrival` retains the strict selected-packet proof. Missing callbacks
alone leave receipt unknown. Retirement packets can remain cached or queued by
design, so the trace does not require script reads to infer arrival. A callback
with matching sender abandonment reports conflicting evidence. Missing send
boundaries, multiple new messages or trace overflow leave attribution unresolved.
This evidence keeps finite expiry separate from reliable receive-buffer drops.

New local service controls with the patched probe complete both generations on
Godot 4.7.2 native and loaded Godot 4.3 native. The Web 4.7.2 control completes
reliable traffic, retirement and service rejoin, but misses the phase-1 initial
unreliable probe. Unique before/after boundaries identify message 1 on stream 3,
incarnation 2; a matching abandonment has `transmission_selected=false`. The
strict gameplay verdict remains failed. Both Web retirement generations retain
all three exact callbacks and preserve the selected packet. An earlier baseline
Web control passes. These controls explain this new initial-probe expiry;
they leave the historical initial packet and finite tail open. Instrumentation
and a different probe compiler limit timing comparisons (#458, #471, #355).

A later fixed 4 KiB/48 KiB Web control captures a missing phase-2 retirement
tail with unique enqueue boundaries (#471). Message 226 on stream 3,
incarnation 2, is abandoned with `transmission_selected=false`. The cached
unreliable packet 224 and reliable packet 225 have exact browser callbacks;
the tail has none. Phase 1 preserves all three retirement packets. The strict
phase-2 queued-arrival check still fails. This explains the new tail's sender
expiry; the historical phase-1 tail and remote networks remain open.

`phase_checks.initial_probes` requires both initial labels on both seats,
including the native reference profile. A missing unreliable probe fails final
qualification even when snapshots and later position packets arrive. The
native drill can still finish reliable traffic and teardown to retain that
evidence. Finite traffic gaps remain separate from reliable loss.

Each import or export log has a `.process.json` file beside it. It records
exit status, elapsed time, timeout limit and host disk, load and memory samples
before and after setup. Timeouts keep partial engine output. Failed setup also
records the engine and native extension file SHA-256 values measured after
the command. Missing resource data or unreadable files use `null`. These host
samples do not show a process peak or prove a resource cause. Retain a crash
report or backtrace separately when the engine crashes (#447).

`phase_checks` names each gameplay check for completed phase pairs. Every
check runs even if an earlier check fails. A false `reference_pause` with true
`heartbeat_totals` means final receipts alone did not prove a new round trip
within the pause. Overall completion and gameplay verdicts remain strict.
Missing phases still fail the assessment.

`diagnostics.heartbeat_phases` joins heartbeat records by phase and sequence.
Each entry includes per-packet intervals, matched sample counts, maxima and
trace overflow. `bridge_queue_ms` measures enqueue to HTTP dispatch;
`command_ms` measures dispatch to command completion; `native_rtt_ms` measures
native send to receipt emission. `native_channel_rtt_ms` ends at the Engine's
channel read; `native_event_queue_ms` measures channel read to probe emission.
Both use the native clock and `received_us` from the JSONL packet event.
They separate event-loop delay from the channel round trip. Rebuild the probe
to collect these fields. `application_rtt_ms` measures reference enqueue
to echo handling. `godot_echo_ms` measures Godot receive to echo submission.
`native_callback_rtt_ms` spans browser delivery of the native send and receipt
events. It includes bridge scheduling. Each interval uses one clock.

`intervals_ms` adds minimum, p50, p95 and maximum latency with the worst
sequence. Per-packet `observed_stages` and `unobserved_stages` identify missing
boundary evidence. Missing stages can reflect an unavailable backend or trace
limit. `pause_heartbeats` separates the old backlog from packets sent during
the receive pause. Only `new_echoes_at_resume` counts new round trips completed
by resume. Cohort latency summaries can include echoes completed later.

Missing, nonfinite or reversed timestamps produce `null`. Compare sample
counts and overflow before comparing maxima. A short measured native round
trip with a long command interval can help locate a probe delay. These
measurements do not identify the cause of an uncaptured failure. Keep the
original #396, #440 and #442 histories separate from induced controls.

### Exact binary gameplay

The probe targets the native Engine binary event API at 67725d6. Build it
from the same source as the Engine. It handles `ChannelBinaryMessage` and
keeps the physical generation, channel label and bytes in standard-base64
`data_base64` output. Text and binary events retain their receive permit until
the probe flushes output. The bridge requires a binary callback and checks
its generation before delivery. Existing declared text probes use strict UTF-8
decoding; opaque packets stay byte arrays.

Add `--binary-traffic` to offer eight binary packets per transfer mode,
per seat and generation, beside the snapshot workload. Payloads include a
small empty-body envelope, UTF-8, embedded NULs, all 256 byte values, malformed
UTF-8 and a larger all-byte block. Nonempty payloads identify their phase,
sender and mode. Every reliable packet must arrive in order. Ordered and
unordered lifetime-limited channels require distinct exact nonempty receipts;
ordered receipts must increase. `binary_sequences` retains every received
sequence and gap. `binary_sent` records the offered counts. Closure and fresh
physical generations retain these checks.

A zero-byte wire packet needs a separate control. Godot's
[`PacketPeer.put_packet_buffer`](https://github.com/godotengine/godot/blob/4.3-stable/core/io/packet_peer.cpp)
returns `OK` for an empty byte array before it calls the transport. The same
branch exists in 4.4.1 and 4.7.2 and applies to native and Web scripts.
Use a nonempty application envelope when its body is empty. Add
`--empty-binary` to the binary command to retain a strict zero-byte wire
qualification attempt. The Godot 4.3 native control fails when the first
reliable receipt is sequence 1; the outgoing empty sequence 0 never reaches
the native callback. This limit is tracked in
[issue #437](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/issues/437).
Nonempty binary delivery does not qualify zero-byte wire packets.

Use `--receive-empty-binary` with `--binary-traffic` to test inbound empty
packets independently. The native reference sends zero bytes in each mode;
Godot keeps its outgoing envelope. Every mode must receive sequence 0 plus
exact nonempty controls. This flag excludes `--empty-binary`. Use the raw
`receive_packet()` path first. The safe RPC peer's GDScript hook reports an
empty result as `ERR_UNAVAILABLE`, so that strict control remains a failure.
Godot 4.3 raw native/Web controls passed both offer roles and fresh
generations with empty receipts in all three modes. The strict native safe-peer
control failed at a zero-byte read with `ERR_UNAVAILABLE`.
Do not infer send support from a successful receive control.

Run the engine boundary alone, without a network or extension:

```bash
godot --headless --path . --script tests/smoke/packet_peer_empty_probe.gd
```

The probe sends empty and nonempty arrays through a scripted
`MultiplayerPeerExtension`, then reads an empty packet followed by a nonempty
packet. `PACKET_PEER_EMPTY` reports send callback counts and receive errors.
It exits 1 while either empty-packet boundary fails. Native Godot 4.3, 4.4.1
and 4.7.2 return `OK` with zero empty-send callbacks and consume the empty
receive with `ERR_UNAVAILABLE`; the nonempty controls pass. This isolates the
script API boundary in #437. It does not qualify WebRTC delivery.

## ICE candidate formats

The mesh accepts raw candidate lines and JSON-encoded `RTCIceCandidateInit`
strings inside `IceCandidate`. Raw lines stay unchanged. Envelopes supply
`candidate`, `sdpMid`, and `sdpMLineIndex` to Godot's `add_ice_candidate()`.
Missing or null media/index fields use Godot's existing defaults: `""` and
`0`. Godot's API has no `usernameFragment` argument.

The server's
[native Engine](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/b264ec739400b299182eaa918dd6828fd611f3b9/clients/native/src/engine.rs)
(`LocalCandidate`, `handle_remote_candidate`) and
[browser Engine](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/b264ec739400b299182eaa918dd6828fd611f3b9/clients/browser/src/page/engine.ts)
(`onicecandidate`, `handleRemoteCandidate`) emit envelopes and accept raw-line
fallbacks. The Godot mesh emits raw lines. Candidate parsing preserves these
formats; it does not change data-channel negotiation.

## Browser reference engine assessment

A local check relayed signaling between `SFWebRTCMesh` and the server's
[browser Engine at b264ec7](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/b264ec739400b299182eaa918dd6828fd611f3b9/clients/browser/src/page/engine.ts).
It used Godot 4.3, Linux arm64 with webrtc-native 1.2.2-stable for native
Godot, and Chromium 154. Each engine kept its outgoing signaling format.

| Offerer          | Godot runtime  | Result                                              |
| ---------------- | -------------- | --------------------------------------------------- |
| Godot            | Native and Web | SCTP connected; reference gameplay channels absent. |
| Reference Engine | Native         | Reference channels closed; Godot released the link. |
| Reference Engine | Web            | Reliable and unreliable probes passed both ways.    |

After the ICE envelope fix (#405), all four pairings were repeated with the
same tools and reference commit. All had zero candidate errors; the channel
and gameplay results in the table were unchanged. Godot's local transport
report can be up when the reference Engine has no channels. Keep mixed
reference-client rooms on the server relay. The Web responder probes cover
two channels; ordered traffic and full reference-client sessions still need
validation.

### Repeat the browser Engine assessment

Run the opt-in assessment against a compiled browser Engine module:

```bash
python scripts/check-webrtc-reference.py \
  --native-extension /path/to/webrtc-native \
  --reference-assets /path/to/reference-modules \
  --reference-revision b264ec739400b299182eaa918dd6828fd611f3b9 \
  --output /tmp/reference-assessment
```

The module directory must contain `engine.js` and its imported modules.
From a server checkout at the supplied revision, build the module:

```bash
npx --yes --package esbuild@0.25.12 esbuild \
  /path/to/server/clients/browser/src/page/engine.ts \
  --bundle --format=esm --platform=browser \
  --outfile=/tmp/reference-modules/engine.js
```

The report records the supplied source revision and module SHA256.

The runner checks native and Web Godot with both offer roles. Each pairing
rebuilds its link for a second generation and checks reliable and unreliable
probe bytes in both directions. Each seat then streams 128 reliable snapshot
chunks of about 1 KiB. Each chunk carries its generation, sender and sequence;
receivers compare its exact UTF-8 bytes. A 32-packet acknowledgment window and
a default 48 KiB outstanding-byte window bound the stream. The byte window counts each full encoded snapshot chunk.
Consumption credit releases bytes after exact validation. Four partial chunks
use the same byte limit and return one reliable consumption credit per chunk.
Both directions must return all partial credit before channel retirement.
Both seats start a second snapshot with four chunks before
the reference seat closes its reliable channel after sending one more packet.
Godot must remove the link before its local reset. The next generation must
pass the same checks with fresh bytes.

`assessment_complete` means both generations were observed and torn down.
`gameplay_passed` requires every probe, all 128 snapshot chunks, the four
partial-transfer chunks, and remote channel closure in both generations.
Add `--safe-receive` to select the RPC-safe peer's packet API. It must keep
the retirement packet selected until remote closure, then discard its cached
bytes. The default checks raw channel reads. Add `--require-gameplay` to fail when
any selected pairing lacks those probes. Use `--runtime native|web` and
`--offerer godot|reference` to select one pairing; both default to all pairings.
Local Engine assessments keep one adapter through both generations and
record `same_receiver`. A relay plan retires each generation's links.
Reference phase totals are refreshed at teardown. The `observation` field
keeps the earlier six-second snapshot, including transfers still in progress.
Keep mixed reference-client rooms on server relay until their pairing passes.
Use the service mode below to check real room plans and signaling.

Each assessment retains `browser_observations` for the reference page and,
when used, the Godot Web page. Each page records signaling request timings,
progress ages, and the last 16 WebRTC transport samples. Reference progress
includes snapshot send, receive and acknowledgment counts, partial-transfer
counts, and channel-close stages. Compare an old progress record with fresh
transport samples and an aging HTTP request to locate a signaling wait.
These diagnostics also remain in an incomplete assessment.

The Web responder passed the safe-receiver checks on Godot 4.3, 4.4.1 and
4.7.2 with Chromium 154 and reference b264ec7. Both generations passed remote
closure, selected-packet discard and exact snapshot recovery. The other
three pairings in each engine assessment remained unsupported.

### Reference channel retirement

Add `--retirement-matrix` to close each available required channel from each
seat. Godot closes `reliable`, `ordered` and `unreliable`. The reference Engine
closes `reliable` and `unreliable`; it has no `ordered` channel. Each of these
five cases runs two generations with the same byte and metadata checks.

```bash
python scripts/check-webrtc-reference.py --runtime web --offerer reference \
  --safe-receive --mixed-traffic --credit-transport webrtc --retirement-matrix \
  --native-extension /path/to/webrtc-native \
  --reference-assets /path/to/reference-assets --reference-revision COMMIT \
  --require-gameplay --output /tmp/reference-retirement
```

Use `--closing-seat godot --closing-channel unreliable` for one case.
The default closes the reference reliable channel. Each case completes a
snapshot and starts a second snapshot, then queues a Godot packet
before closure. The safe reader selects that packet and checks its metadata. Closure must remove the peer and discard selected bytes.
The next generation must restore exact gameplay through the same safe receiver.
Use a separate run without `--safe-receive` to check the raw channel reader.

Phase `retirement` records the closing seat and channel, selected queue count,
packet discard, peer removal and observed reference channel closures. Godot
closure also records the final physical channel state. The ordered-channel
case observes reference required-channel closure when Godot releases the link.
The driver waits up to 60 seconds for Godot's ready marker before starting
the reference phase. Reports retain `startup_ms` and the startup barrier result.
Each case has its own directory. `summary.json` retains failed cases while
later cases run. Network deadlines remain unchanged.

### Concurrent positions and consumption credit

Add `--mixed-traffic` to interleave 32 unreliable position samples with each
128-chunk snapshot in both directions. Each sample contains its generation,
sender and sequence. The local assessment requires every sample, exact bytes,
and matching channel metadata. It does not simulate packet loss.

The default `--credit-transport http` returns consumption credit through the
signaling relay. Use `--credit-transport webrtc` to return the same credit over
the reliable gameplay channel. Both keep the same 32-chunk and 48 KiB limits,
snapshot bytes, position cadence and generation/closure checks. Partial-transfer
credit always uses the reliable gameplay channel. For example:

```bash
python scripts/check-webrtc-reference.py --safe-receive --mixed-traffic \
  --credit-transport webrtc --native-extension /path/to/webrtc-native \
  --reference-assets /path/to/reference-modules \
  --reference-revision b264ec739400b299182eaa918dd6828fd611f3b9 \
  --output /tmp/reference-mixed-webrtc
```

Phase and progress records retain `credit_transport`, `snapshot_acknowledged`,
`positions_sent`, `positions_received`, `peak_outstanding`,
`credit_wait_age_ms` and `transfer_ms`. Transfer time starts at the first
probe send and ends when both full snapshots and outgoing snapshot credit
are complete; it excludes partial snapshots, closure and recovery barriers.
`assessment.json.godot_evidence` keeps the last progress and failure snapshot,
including the same counts under `reference`.

Per-channel queued counts include the safe reader's selected unread packet.
Reading diagnostics can select a packet without consuming it. These logical
counts cover both the engine queue and that selected packet; they do not
measure raw engine buffer occupancy. `buffered_amount` measures outgoing bytes.

Compare repeated HTTP and WebRTC credit runs with the same engine and receiver.
Fresh gameplay progress during an HTTP credit wait helps isolate relay or HTTP
scheduling. A credit-transport timing difference alone cannot prove the cause
of the intermittent stall in #396. Full reference CLI sessions and
remote-network qualification remain open.

### Paused Godot reader

Add `--slow-receiver` to pause Godot packet reads for 1,500 ms after
eight snapshot chunks arrive. Engine polling, signaling and sends continue.
The browser reference sender keeps its 32-chunk credit window. Use
`--mixed-traffic` to queue unreliable positions alongside reliable chunks.
Run both HTTP and WebRTC credit controls with the same receiver and engine.

```bash
python scripts/check-webrtc-reference.py --runtime web --offerer reference \
  --safe-receive --mixed-traffic --slow-receiver --require-gameplay \
  --credit-transport webrtc --native-extension /path/to/webrtc-native \
  --reference-assets /path/to/reference-modules \
  --reference-revision b264ec739400b299182eaa918dd6828fd611f3b9 \
  --output /tmp/reference-slow-reader
```

Godot phase and progress records retain `receive_pause`: elapsed pause time,
consumed chunks, queued reliable and unreliable packet counts, and resume
state. A gameplay pass requires unchanged consumption during the pause, at
least the configured window's required queued reliable packets, and queued
unreliable packets when mixed traffic is requested. All bytes, metadata, final
credit, partial transfers,
remote closure and next-generation recovery must still pass. Reference records
retain `max_credit_wait_ms` to compare the known reader pause with HTTP waits.
Add `--credit-transport http --http-credit-delay-ms 4000` to hold one
first-generation reference credit GET after 32 chunks for four seconds. The report records
whether the hold occurred. The hold consumes the phase deadline. The six-second `observation` remains a snapshot;
Godot keeps an active transfer running until all chunks and credit complete
within the existing deadline. This catches premature teardown during a
progressing HTTP wait.

With `--mixed-traffic`, the reference sends a sequenced reliable heartbeat
every 100 ms while snapshots run, up to 128 per phase. Godot checks its exact
bytes, sender, channel and mode before echoing it. The reference checks each
echo in order. Both seats must report matching heartbeat totals before remote
closure. Queued reliable packet counts include these heartbeats.

The reference runs one HTTP receive task and one FIFO send task beside the
gameplay loop. A held credit POST leaves the opposite credit receive path
active. A held GET leaves outgoing markers and gameplay sends active.
`signaling_receive_pending`, `signaling_send_pending` and `outgoing_signals`
record the two tasks and queued sends. With mixed traffic and an HTTP
hold of at least 1,500 ms, `signaling_hold_progress` must show new heartbeat
echoes across a one-second interval while the held request stays active and
snapshot credit stays fixed. Echoes must include a heartbeat sent after the
first sample. This separates fresh WebRTC gameplay from HTTP credit progress.
Requests are canceled and settled before the next generation starts.

A local Godot 4.7.2 native/Web control held one credit POST response for four
seconds. The old shared exchange paused opposite-direction snapshot sends for
about four seconds. Independent tasks kept the largest observed gap below
74 ms native and 214 ms Web. Both controls retained every reliable chunk.
Historical stall and heartbeat histories still need their own reproduction.

These opt-in local controls keep the existing deadlines. They do not simulate
WebRTC network delay or establish the cause of #396.

### Reliable callback drops

`diagnostics.browser_read_phases` separates `matched_buffer_drop_packets`
from `unread_without_matched_drop_packets`. A match needs a unique physical
peer, channel ID, label, packet marker, timestamp and byte count. The buffer
error must occur inside the engine's synchronous `onmessage` handler. Errors
outside that handler keep a null callback identity. Duplicate, missing and
truncated evidence leaves adjusted byte totals unavailable.

`peak_tracked_unread_payload_bytes_excluding_matched_drops` and its terminal
counterpart remove matched rejected arrivals. Godot's Web adapter rejects a
packet before adding it to its receive ring when space is insufficient.
The observer follows the synchronous handler in
[Godot 4.7.2's Web bridge](https://github.com/godotengine/godot/blob/4.7.2-stable/modules/webrtc/library_godot_webrtc.js#L48)
and the rejection in
[its channel reader](https://github.com/godotengine/godot/blob/4.7.2-stable/modules/webrtc/webrtc_data_channel_js.cpp#L67).
These totals cover tracked payloads; framing, cached packets and untracked
traffic prevent an exact ring occupancy claim. An unread callback without a
matched error can still be queued. Every reliable receipt remains required.

A fresh 4 KiB packet-only Web service control at Godot 4.7.2 matched five
rejections to snapshots 115-119. The next script read was snapshot 120. A
100 ms reader control matched two other rejections. Both runs failed their
original receipt checks. A 48 KiB window control with the same reader interval
received all 128 snapshots in each direction and completed its heartbeat pause
proof, then failed during queued-packet retirement (#471). The matching native control
completed both generations and service rejoin. This locates those Web reliable
gaps at engine ingress (#442); retirement, historical heartbeat failures (#440)
and remote-network qualification (#355) remain open.

New loopback controls use 4 KiB bodies, 100 ms Godot drains and independent
100 ms positions. The packet-only Web workloads, with and without startup,
each retain ten scoped rejections and the first reliable hole at snapshot 15.
At the first rejection, tracked unread payload is 61,924 bytes and the rejected
snapshot is 4,120 bytes. The 48 KiB no-startup control passes both generations;
its tracked unread peaks are 41,393 and 45,444 bytes. Startup byte credit also
preserves all reliable data in the captured phase, then that run fails the
finite-tail retirement check. Its uniquely enqueued stream-3 message 260 is
abandoned before transmission selection, with no Web callback (#471).

The matched HTTP/startup Web control preserves both reliable generations but
fails its initial finite-probe check: uniquely enqueued message 33 expires
before selection (#458). Both native startup offer roles pass every strict
check. A 256 KiB capacity control with the original packet-only startup
workload preserves every reliable packet in both Web offer roles. The
Godot-offer run passes all checks; the reference-offer run fails on uniquely
expired initial message 33. These finite failures remain failed overall
qualifications. Larger receive capacity does not prevent sender expiry.

During the deliberate reference pause, Godot bulk sends/credit stay at 19/8
for 1.19-1.45 seconds while 11-15 position sends and 11-14 heartbeat reads
continue. Web heartbeat callback-to-read maxima are 103-167 ms in the paced
controls. This separates a bulk credit plateau from real-time progress in
these controls (#396, #440). It leaves the historical failures and
remote-network qualification open. These controls use Godot
4.7.2, Chromium 156, native reference `e8a2d969` and Linux ARM64. Native
gameplay uses the opt-in repaired extension described below. Other local
checks overlapped parts of this shared-host cohort.

### Service receive-budget controls

Use a real service with same-room leave/rejoin to check the byte budget across
player epochs. Start with this Web reference-offer control. Set the paths to
the pinned native reference probe, extension, Godot and Chromium binaries:

```sh
python scripts/check-webrtc-reference.py \
  --native-reference-probe /path/to/probe \
  --reference-revision e8a2d969a73d2870ecce41a62d103ec70aa6c914 \
  --native-extension /path/to/webrtc_native \
  --godot /path/to/godot --chromium /path/to/chromium \
  --service-url ws://127.0.0.1:3537/v3/ws --service-rejoin \
  --runtime web --offerer reference --safe-receive --mixed-traffic \
  --snapshot-body-bytes 4096 --snapshot-window-bytes 49152 \
  --receive-interval-ms 100 --position-interval-ms 100 \
  --slow-reference-receiver --queued-retirement \
  --credit-transport webrtc --require-gameplay \
  --output /tmp/service-byte-budget
```

Use a fresh output directory for each comparison. Keep the 128 snapshots,
four partial chunks, 1500 ms reference pause and original deadlines fixed.
Use `--snapshot-window-bytes 0` for packet-only credit. Add `--startup-burst`
to check 32 immediate reliable packets. For the HTTP credit hold, replace
`--credit-transport webrtc` with `--credit-transport http
--http-credit-delay-ms 1500`. Check the hold evidence before accepting that
control. Compare native runs with `--runtime native --offerer both`.
For the capacity control, set
`--snapshot-window-bytes 0 --startup-burst --channel-in-buffer-kb 256`.
Omit `--channel-in-buffer-kb` to keep the engine default.

The first eight session451 service histories at client `fd19955` use official
Godot 4.7.2, Chromium 156.0.8078.4, the reference above and Linux ARM64. The retained service
binary has SHA-256 `cb29f6a667a308663fba635a3f100e2b81946fb342f450f6bbf43c066ba2b138`;
its build revision is unverified. The native gameplay seats use the opt-in
repaired extension described below. All attempts are retained locally under
`/tmp/session451-service-*`; their independent audit and binary hashes are in
`progress/session451-artifacts/`. These paths are local evidence.
The table records only these eight new histories. Earlier service and loopback
failures above remain retained.

| Control                                                 | Observed result                                                                                                                    |
| ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| Web, 48 KiB window                                      | Both generations pass every strict check.                                                                                          |
| Web, packet-only window                                 | Ten scoped reliable rejections; expected snapshot 15, read 20. The run fails before rejoin.                                        |
| Web, 48 KiB plus startup, reference offers              | All reliable data and rejoin pass. Initial unreliable message 33 expires before SCTP selection in phase 1; overall gameplay fails. |
| Web, 48 KiB plus startup, Godot offers                  | Both generations pass every strict check.                                                                                          |
| Native, 48 KiB plus startup, both offer roles           | Both histories pass every strict check.                                                                                            |
| Web, 48 KiB plus held HTTP credit                       | Both generations pass, including heartbeat progress during the hold.                                                               |
| Web, packet-only plus startup, 256 KiB receive capacity | Both generations pass. This changes local capacity.                                                                                |

The completed histories preserve every full, partial and startup reliable
receipt. During the HTTP hold, snapshot sends/credit stay at 35/24 for 1060 ms
while positions advance from 5 to 16 and heartbeat echoes from 4 to 14.
Queued retirement preserves all three arrivals in both generations, including
the Web history with the failed initial probe. The service changes generation
and reference epoch while retaining the room and retiring the old receiver.

Eight separate runs repeat the cases above with a fresh
`cargo build --locked --bin signal-fish-server`
from server `67725d677ff0fdb662d041af9b175d8a6d08c75f`. Its executable SHA-256 is
`f91ef59d71e108612749f07a5297078c121bb2ff06b321012cc9671724f11b1b`.
They retain the original captures and use a separate service port and output
directories under `/tmp/session451-pinned-service-*`. Five pass every strict
check. Three fail on the following reliable or finite-probe checks.
The packet-only Web run rejects six reliable snapshots and fails expected
sequence 15/read 16. Startup byte credit preserves all reliable data.
Initial message 33 expires before SCTP selection in phase 2. The held-HTTP control
preserves both reliable generations and heartbeat progress. Its phase-1
initial unreliable probe expires before selection. Both finite-probe histories
remain failed overall. During that HTTP hold, sends/credit stay at 35/24 for
1090 ms while positions advance from 5 to 16 and heartbeat echoes from 4 to 15.

Bound bulk bytes and keep polling gameplay while credits wait (#442, #396, #440).
Use reliable channels for required initialization and budget their receive bytes.
A receive-capacity change cannot prevent a sender's finite-lifetime
expiry (#458, #471). The failed initial probe remains a failed qualification.
These shared-host loopback service controls leave the historical failures and
remote-network qualification open.

### Active Godot reader budgets

Use `--receive-batch-packets 1` to limit each Godot gameplay drain to one
packet. Use `--receive-interval-ms 250` to allow drains every 250 ms or later.
The defaults remain 32 packets per drain and no extra interval. These controls
keep engine polling, signaling and outgoing sends active. They apply to all
incoming gameplay packets, including heartbeats and consumption credits.
They model application read scheduling; they do not delay the network or block
the Godot main thread.

Add these flags to the reference command above. Compare the same schedule with
`--snapshot-body-bytes 4096` and then with
`--snapshot-window-bytes 16512`. Use a fresh output directory for each run.
Repeat with `--credit-transport http` and `webrtc`. The default bulk window is
49,152 bytes, leaving space beside bulk traffic in Godot's default 64 KiB
channel buffer. The 32-packet cap still applies. This is application pacing;
it does not enlarge the engine buffer. Add `--snapshot-window-bytes 0` to
reproduce the earlier packet-only workload. Keep that failure separate from
the paced result. Add
`--slow-reference-receiver` to check fresh heartbeat round trips during a
reference consumer pause while the Godot reader keeps its chosen schedule.
Keep `--require-gameplay` enabled. A control that loses a reliable chunk or
misses the heartbeat pause proof must fail.

Each Godot phase and failure record retains `receive_schedule`: requested
batch size and interval, skipped drain calls, the largest observed drain gap,
and up to 1024 drain start times with actual packet counts. Custom schedules
require complete evidence with no drain above the packet budget and no start
earlier than the requested interval. The original deadlines and exact receipt
requirements still apply. A small byte window can reduce throughput enough to
hit a deadline with a slow reader; choose controls that expose that outcome.

Use `--reference-receive-batch-packets 32` and
`--reference-receive-interval-ms 250` to match the reference application drain
to the Godot example. The reference default remains immediate callback
consumption. Set either seat's budget independently. The reference queue sits
after Engine callbacks; it measures application scheduling after transport
receipt. It does not change native Engine reads or the Godot channel buffer.
All application packets share its FIFO, including binary packets, heartbeats
and credits. Signaling and transport callbacks remain active.

Reference `receive_schedule` records each drain, current and peak queued bytes
and packets. `receive_timings` records callback and scheduled drain times on the
same clock. Heartbeat diagnostics include `reference_consumer_ms` to separate
this queue delay from the native round trip and command bridge. The separate
1500 ms pause still defers snapshot validation after scheduled reads.
Qualification requires an empty scheduled queue, complete timing records and
the requested drain budget. The queue fails above 256 packets. Each generation starts fresh.

One-second application drains on both seats passed native/Web service rejoin
under four CPU workers. Native heartbeat round trips reached about one second
and reference queue waits reached 661 ms. Each pause still proved 4-7 new
echoes. Use the sent-after-pause sequence cohort to assess that proof.

A slow active reader can fill the engine receive buffer even when it never
uses the explicit 1500 ms pause. Budget gameplay bytes against receive capacity
and measured drain cadence. Passing a paced control establishes that control's
behavior; the historical active-reader loss (#442), delayed echoes (#440), and
three-seat credit stall (#396) each need their own matched reproduction.

A 16 KiB body control also exposed unpaced partial chunks: all full snapshots
completed, then four partial chunks overflowed the Web channel buffer. Partial
chunks now wait for exact consumption credit within the chosen byte window.
Phase records include `partial_sent`, `partial_received`,
`partial_acknowledged`, `outstanding_partial_bytes`,
`peak_outstanding_partial_bytes` and `partial_credit_wait_age_ms`. A successful
phase requires four acknowledged partial chunks, zero remaining bytes, and a
peak within the byte window. The interrupted transfer and fresh-link checks
still follow that partial exchange. No receive assertion or deadline changes.

The 48 KiB window holds two 16 KiB chunks. A Web HTTP-credit control with
that body size reached the unchanged deadline with zero receive-buffer drops:
Godot consumed all 128 incoming chunks, sent 118, and received credit for 116.
Marker POSTs took about 100 ms each. The matched WebRTC-credit control completed
both generations. Treat this as a credit-turnover limit; pacing preserves
bytes but does not promise completion within a chosen deadline. Keep larger
HTTP workloads as explicit qualification controls.

Web reference and native/browser drills use browser fetch for HTTP markers
and signaling by default. Native seats keep Godot HTTPRequest. This avoids
per-frame HTTPRequest state transitions in the Web credit path (#396).
`--web-http-fetch` remains an explicit selector for the default.

Use `--web-http-request` to reproduce the historical Web HTTPRequest path.
The two selectors are mutually exclusive. Keep each backend's runs in separate
output directories with the same packet bodies, byte window, receive schedule
and deadlines. `web_http_fetch` records the observed backend; qualification
requires it to match the selected backend on every seat. Fetch errors and
non-200 responses still fail. Cancellation suppresses late responses.

These controls separate HTTP credit turnover from WebRTC gameplay and
heartbeat progress (#396, #440). Compare request durations, relay queue dwell
and marker observation times. Keep the historical HTTPRequest verdict. The
backend choice does not add receive capacity or qualify reliable loss (#442).
Run packet-only and byte-window histories separately.

Reference assessments include `diagnostics.http_requests`. Each marker request
records its HTTPClient states, process frames and browser-clock start and
completion. A unique matching browser resource splits that duration into
`submit_ms`, `response_ms` and `completion_ms`. Missing or ambiguous matches
keep null intervals. Native requests keep their state and frame evidence.
`marker_overflow`, `states_omitted` and `resources_dropped` expose trace limits.
Periodic progress omits the full history; terminal and failure records retain it.
Bounded `WEBRTC_HTTP_REQUEST` events preserve completed marker requests if the
driver stops before Godot reports failure. `history_source: request_events`
marks that fallback; it can contain a partial history.

Godot's [HTTPRequest update](https://github.com/godotengine/godot/blob/ed1daf0bf/scene/main/http_request.cpp#L550)
runs once per process frame. Its [Web HTTPClient](https://github.com/godotengine/godot/blob/ed1daf0bf/platform/web/http_client_web.cpp#L210)
advances connection, request and body states through later polls. A short
browser response can therefore take several more frames to reach script code.
Compare those intervals with heartbeat and credit progress before attributing
a bulk timeout to WebRTC delivery. Resource timing measures the HTTP path;
it does not identify SCTP loss or prove a remote gameplay receipt.

Fresh Web service controls with the same 16 KiB workload show a median six
process frames per HTTPRequest marker. Median resource response intervals
are 2-5 ms; median script completion follows about 64-71 ms later. Both roles
reach the bulk deadline with zero channel-buffer drop messages. Both fetch
roles complete every strict check. The HTTPRequest pauses still prove fresh
heartbeat round trips and queued position updates. These local controls narrow
credit-turnover delay in #396 and #440; their historical failures and #355
remote-network qualification remain open.

For game code, count encoded bytes per destination and channel. Reserve buffer
space for control traffic and packet framing. Release credit only after the
receiver validates and consumes a chunk. Keep reading and echoing heartbeats
while bulk sends wait for credit; outbound `buffered_amount` alone cannot show
remote receive capacity. Reset all credit with the physical link. A receipt
from an earlier generation must never release the new link's bytes. The
reference sender is a runnable example of this application-owned contract.

### Independent position updates

Use `--mixed-traffic --position-interval-ms 100` to send the same 32 exact
unreliable positions on a separate cadence. Both seats send at most one update
per loop, wait at least the requested interval, and finish position sends
before partial exchange and teardown. Choose 20-200 ms. The default `0` keeps
the original schedule: one position after every four snapshots.

This is an explicit workload control. A 48 KiB window holds two 16 KiB chunks;
the original schedule can stop positions while snapshot credit is withheld.
The independent cadence lets the consumer-pause check measure position and
heartbeat progress during that bulk wait (#396, #440). It keeps the same
snapshot counts, exact bytes, metadata, deadlines, pause requirements and
fresh-link checks (#355). Use a separate output directory for each schedule.

Phase records include `position_interval_ms` and at most 32 `position_timings`.
Each send records its sequence, enqueue time, snapshots sent and snapshots
acknowledged. Times use each sender's own clock. Qualification requires all
32 ordered timing records, the requested minimum spacing and valid credit
counts. A send record alone does not prove transport delivery. Finite-loss
and strict initial-probe verdicts still apply.

The new controls use Linux ARM64, Chromium 156.0.8078.4, webrtc-native
1.2.2-stable and native reference `e8a2d969`.

Matched local service controls with 16 KiB bodies, the 48 KiB window, startup
traffic and the 1500 ms reference pause pass both offer roles on Godot 4.7.2
native/Web and Godot 4.3 native with the 100 ms cadence. Every full/partial
receipt, pause proof and service rejoin passes. The original snapshot-coupled
Web control still fails its pause proof with zero queued positions.

The independent Web HTTPRequest control still times out: Godot consumes all
128 incoming snapshots but sends 116, with credit through 114. Both seats send
and receive all 32 positions, and the reference receives all 128 heartbeat
echoes. Its pause queues 14 positions and proves 14 new heartbeat round trips.
Changing only to browser fetch completes both generations and every strict
check, with the same pause progress. These controls isolate bulk credit
turnover from real-time progress. They leave the historical stall (#396),
delayed echoes (#440) and remote-network qualification open.

For game code, schedule real-time state updates independently of bulk snapshot
credit. Bound both workloads and reserve receive capacity for control traffic.
Keep application consumption credit tied to bytes actually consumed.

### Slow browser reference consumer

Use `--slow-reference-receiver --mixed-traffic` with the Web/reference-offer
pairing to pause the reference application's snapshot and position consumption
for 1500 ms after eight chunks. The reference keeps heartbeat echoes and
reverse-direction consumption credits active during this pause. Choose either
HTTP or WebRTC credit with the same Godot reader for a matched comparison.

```bash
python scripts/check-webrtc-reference.py --runtime web --offerer reference \
  --safe-receive --mixed-traffic --slow-reference-receiver \
  --credit-transport webrtc --native-extension /path/to/webrtc-native \
  --reference-assets /path/to/reference-modules \
  --reference-revision b264ec739400b299182eaa918dd6828fd611f3b9 \
  --require-gameplay --output /tmp/reference-consumer-pause
```

The application queue retains each packet's original text and channel label.
It holds at most 32 snapshot chunks and 32 position samples. Consumption credit
is sent only after a chunk is checked and consumed. On resume, the reference
checks the buffered bytes, sequence and channel before sending more credit.

Each generation's reference `receive_pause` must show consumption fixed at
eight chunks, at least 24 queued snapshot chunks, queued positions, and a new
heartbeat echo from a heartbeat sent during the pause. Reports retain the
pause duration, queue peak and heartbeat counts. All queued application packets
must drain, both full snapshots and partial transfers must finish, and remote
closure plus fresh-link recovery must pass.

This option pauses application consumption after Engine callbacks. Browser
network delivery and the page event loop keep running. It isolates application
backlog in #396; it does not reproduce a frozen page or establish the captured
stall's cause. Use `--slow-receiver` in a separate run to pause Godot reads.
The two pause options cannot be combined. Full reference CLI sessions and
remote-network recovery remain open in #355.

### Reference gameplay through a local service

Add `--service-url ws://127.0.0.1:3537/v3/ws --service-app-id godot-reference`
to the Web/reference-offer command above. Run a local Signal Fish server with
`session.enable_webrtc` enabled, `session.enable_direct` disabled, and
`session.default_topology` set to `host`. The service must accept the app ID.
The browser Engine modules and service used for this assessment are pinned to
`b264ec739400b299182eaa918dd6828fd611f3b9`.

Use the native reference Godot profile to assess native and Web Godot seats
through the same service. Build the probe above, then run:

```bash
python scripts/check-webrtc-reference.py --runtime all --offerer reference \
  --native-reference-probe /path/to/server/clients/native/target/debug/examples/godot_qualification \
  --reference-revision 67725d677ff0fdb662d041af9b175d8a6d08c75f \
  --native-extension /path/to/webrtc_native --safe-receive --mixed-traffic \
  --binary-traffic --startup-burst --queued-retirement --service-rejoin \
  --service-url ws://127.0.0.1:3537/v3/ws --service-app-id godot-reference \
  --require-gameplay --output /tmp/native-reference-service
```

The coordinator still runs in a browser; the reference Engine and native Godot
seat use separate native processes. Each runtime gets its own room session.
Use `--runtime native` or `--runtime web` for a single Godot seat. The service
assigns the offer role. Use `--offerer reference`, `--offerer godot`, or
`--offerer both` to assess each role in separate sessions. With Godot offering,
the reference requests authority and starts the game after both seats are ready.
This extends the [pinned upstream service control](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/4676e4c6f61000383fcc068536852591a20bfb62/clients/native/tests/fixtures/godot-service-offer.patch).
The browser reference profile cannot exchange gameplay with native Godot's
negotiated channels; changing the signaling route does not repair that pairing.

The portable native probe forwards the plan's ICE server settings to its
Engine. A receive-rejection event retires its physical link and fails the
assessment with the channel and generation. The probe retains that failure
across retirement, even when the browser has yet to read the event. Later
control commands must also fail. Finite-mode receipt gaps cannot hide a
rejected receive queue. Local controls use empty ICE server lists;
TURN and remote-network operation still need qualification.

The production Godot client creates a two-player room. The reference seat
joins that room through its own WebSocket. Both seats become ready, and the
selected host starts the game. The server assigns each peer's offer role.
Both seats use the real session generation and relay SDP and ICE through the
service. The `/signal/` HTTP relay carries workload markers only and rejects
SDP and ICE. The native probe's separate local HTTP bridge carries Engine
commands and callbacks, including signaling applied or generated by that Engine.
The bridge reads native events while writing packet batches. Command writes
stay in FIFO order. A full command pipe must leave event reads active so
snapshot credits and heartbeat callbacks can keep moving. Each command records
its start, completed stdin write and reply times on the bridge clock.
The write interval includes JSON encoding and pipe backpressure.

Two fresh rooms run the unchanged mixed snapshot workload and channel closure
checks. Leaving each room must invalidate its safe receiver. A fresh receiver must
work after the next server plan. A service pass requires matching room, generation and player IDs, matching nonzero
signaling counts, complementary offer roles, confirmed room departure, and
distinct rooms and generations. Early service signals retain their original
sender and generation until the reference peer is paired. Both fields must
match the current plan before delivery. Counts start at phase entry.
`service_godot` and `service_reference` retain this evidence in `assessment.json`.
Use the existing HTTP/WebRTC credit and reader-pause controls to compare
service signaling with gameplay progress. Per-stage service waits retain their
failure stage in the Godot log.

Add `--service-rejoin --safe-receive` to keep Godot in the same running room.
In the first phase, the reference player leaves while Godot has a reliable
packet selected. The service departure must remove the link and discard those
bytes. The same reference player then joins that room again. Its new server
plan must restore exact mixed snapshots and positions through the same Godot
safe receiver. The second phase closes the reference reliable channel and
both seats leave the room.

The report requires unchanged room and player IDs, a distinct plan generation,
an increased reference membership epoch, confirmed peer departure and
`same_receiver` in the second service record. Both seats must report the same
`reference_epoch` in each phase.
The first reference record must retain `departure_stage: "selected_packet"`.
Each record's `initiate` belongs to the gameplay generation, even when departure
has already published a replacement plan. Host departure can change the next
plan's offer role. The driver follows that plan and checks complementary roles
again. A Godot-offer run therefore qualifies the initial offer and the role
selected after host departure separately.
Use matched HTTP and WebRTC credit runs, then the reader-pause controls, to
compare membership recovery and application waits. This option requires service
mode and the safe receiver; it runs separately from `--retirement-matrix` and
custom channel-closure cases.

Add `--queued-retirement --safe-receive` to test a late reliable arrival while
an unreliable packet is selected. After full mixed snapshots finish, Godot
selects an unreliable retirement packet and keeps it unread. The reference then
sends a reliable packet and another unreliable packet. Godot must report three
queued packets and return the original unreliable bytes with their original
sender, mode and channel. It then selects the reliable packet, leaving two
packets unread for channel closure or service departure.

Both unread packets must disappear at teardown. With `--service-rejoin`, the
same safe receiver must complete the second generation after the player rejoins.
Each phase reports `retirement.queued_arrival` with `preserved`,
`queued_before_read` (3), `queued_after_read` (2) and `arrival_wait_ms`. Progress
snapshots retain the arrival wait while the packets are pending. The reference reports
`queued_retirement` and `late_sent`. Missing proof fails the requested scenario.
This option also works with the channel retirement matrix. Use the HTTP/WebRTC
credit and reader-pause controls for matched workload comparisons (#396).

HTTP localhost exports can connect to a local `ws://` service. HTTPS exports
require `wss://`. This assessment covers the browser reference Engine with a
small service driver; full reference CLI sessions, the native reference Engine,
and remote networks still need qualification.

## Native reference engine assessment

A local check paired the native
[Engine at b264ec7](https://github.com/Ambiguous-Interactive/signal-fish-server/blob/b264ec739400b299182eaa918dd6828fd611f3b9/clients/native/src/engine.rs)
with Godot 4.3, Linux arm64 with webrtc-native 1.2.2-stable, and Chromium 154.
It used `EngineSettings::default()`, relayed each engine's outgoing signaling
unchanged, and observed each link for 12 seconds before the Godot snapshot.

| Offerer          | Godot runtime  | Result                                                                |
| ---------------- | -------------- | --------------------------------------------------------------------- |
| Godot            | Native and Web | Godot reported up; reference gameplay channels were absent.           |
| Native reference | Native         | Godot released the link after a stream-id collision warning.          |
| Native reference | Web            | Godot reported up; reference open callbacks and gameplay were absent. |

After the ICE envelope fix (#405), all four pairings were repeated with the
same tools and reference commit. Both Godot runtimes and the native reference
reported zero candidate errors. All four still had zero gameplay receipts;
the channel observations in the table were unchanged. Removing the reference
peer cleared its pairing in every run.

A fresh Godot 4.3 control confirmed negotiated IDs 1, 2 and 3. With the
native reference offering, its channel-open messages reached IDs 1 and 3
already reserved by Godot. The native Godot stack warned about both used
streams and released the link. With Godot offering, the reference received
no channel announcements. Both roles retained zero gameplay receipts.

The setup contracts differ in two places:

- Godot's [channel setup](https://github.com/godotengine/godot/blob/4.3/modules/webrtc/webrtc_multiplayer_peer.cpp)
  creates three negotiated channels before either offer or answer.
- The pinned native Engine's `pair_with` creates two in-band channels only
  for the offerer. Its responder uses `on_data_channel` to adopt announcements.

A native Engine profile compatible with this mesh would need matching
negotiated IDs, delivery settings and all three required channels in both
roles. It must also register and poll those channels without waiting for
remote announcements. Renaming channels cannot resolve the stream collision.
Any future profile needs exact bytes and modes, mixed traffic, required-channel
closure and fresh-link recovery checks before a pairing can be supported.
Track the profile in [server #1240](https://github.com/Ambiguous-Interactive/signal-fish-server/issues/1240).

A connected peer connection or a local transport-up report cannot prove
cross-client gameplay. Keep these pairings on the server relay. This check
uses the native Engine API with local signaling; full service sessions and
remote-network pairings remain open in #355.

## Demo

`demo/p2p.tscn` is the working example. It connects with a v3 config,
attaches the mesh, and chats over mesh RPCs once a session plan lands. Run
two instances joining the same room to see the peer connection form.

## Live channel drill

Run `godot --path . tests/smoke/webrtc_channel_drill.tscn` with a native
WebRTC extension installed. For Web, export that scene as the main scene
with `tests/smoke/webrtc_channel_drill.gd` included in a temporary export
preset. The default Web preset excludes tests.

The drill creates two real loopback peers, sends gameplay packets, closes
each required channel while the peer connection stays connected, and checks
transport reports before and after multiplayer polling. Each new generation
must restore gameplay, and a Relay plan must remove old links.

The drill also queues real packets before fresh `PlayerJoined` and
`PlayerReconnected` epochs. It checks packets visible through the multiplayer
peer and packets waiting in the data channel before multiplayer polling.
Fresh membership removes both queues from the mesh. Duplicate epochs keep
the live peer. Delayed old-generation work stays fenced until a new plan
restores gameplay. Packets already read by the application remain under
application control.

Godot 4.3 passed these controls on Linux arm64 with webrtc-native
1.2.2-stable and in Chrome 154. A reference-style responder reached SCTP
connection with zero in-band channel announcements from the Godot offerer.
This checks the channel-layout boundary; it does not run either full
reference client. Cross-client gameplay with the reference engines remains
unverified.

Success prints `WEBRTC_CHANNEL_DRILL_PASS`. This drill uses local signaling;
live Signal Fish server delivery and remote-channel resource limits require
separate acceptance.

## Native and browser interoperability

Run the opt-in cross-runtime drill with the installed native extension:

```bash
python scripts/check-webrtc-interop.py --native-extension /path/to/webrtc_native
```

Install the matching Godot Web export templates and
`requirements-docs-accessibility.txt`, then run `playwright install chromium`.
Use `--godot` or `--chromium` to select local executables. `--output` selects
the directory for the isolated projects and logs. The runner exports a
temporary Web project, starts a native seat and Chromium, and relays local
signaling over HTTP. Gameplay flows over real WebRTC channels.

Both seats send and receive reliable, ordered-unreliable, and unreliable
packets. The drill checks payloads, sender ids, transfer modes, negotiated
channel labels and ids. Each seat also streams 256 directed reliable
binary packets, from 1 to 1200 bytes, in batches of four per frame. The
receiver checks exact bytes, sequence, sender, transfer mode, and channel.
With `--mixed-traffic`, each seat sends 32 position updates on each unreliable
mode. Receivers check exact bytes and metadata, reject duplicate sequences,
and require increasing sequences for ordered updates. Gaps are allowed;
each mode must deliver at least one sample in this local drill.
This strict optional scenario can fail on Godot 4.3 due to the packet
metadata limitation below. The default drill sends its transfer modes
separately.
Each generation also sends a MessagePack snapshot of 1,024 players in
1,200-byte reliable chunks. The receiver checks each chunk, reassembles the
snapshot, and compares its exact bytes and decoded values. Chunking belongs
to this drill's application code; the mesh sends packets unchanged.
Seven generations alternate the offerer. In the first six, each seat closes
each required channel once during a second, incomplete snapshot. Each seat
sends 12 chunks, consumes eight and leaves four queued. Both seats must
release those queued packets with the link and report it down before the
next generation restores gameplay. The final generation uses
a Relay plan to remove the link. Each generation must produce one up report
and one down report per seat. Final detach removes the multiplayer peer.

The stream allows at most 32 packets without a receiver acknowledgment.
This bounds queued traffic when one runtime polls more slowly. An earlier
unpaced run filled the browser receive buffer and dropped reliable packets
while the browser waited for a signaling marker. Games should drain incoming
packets each frame and pace sustained sends for their receiver's capacity.

Godot 4.3 on Linux arm64 with webrtc-native 1.2.2-stable and Chromium 154
passed this native-to-browser drill. This covers local connectivity; TURN,
wide-area networking and the server reference engines need separate drills.
Success requires `WEBRTC_INTEROP_PASS` from both seats and a zero native
exit code. The runner retains native and browser logs with the projects.
A failed browser seat still allows the native seat to finish its diagnostic.
Each trial writes `seats.json` with both verdicts, the last stage, the last
completed wait, any failure
snapshot, the native exit code, and any driver error. `diagnostic` stores the
parsed failure snapshot beside its raw log line. The report also records the
browser version and receive scenario. Partial-transfer
failures include sent, received and queued chunk counts plus the received
and expected snapshot byte counts.
The driver reports its 60-second browser observation timeout separately
from the engine's per-stage timeout. Only a browser completion or failure
marker ends browser observation; unrelated console text keeps it running.

To investigate intermittent failures, use `--repeat 3` and retain `--output`.
Add `--baseline /path/to/baseline-checkout` to compare that checkout's addon
with the current addon. Both use the current drill, export settings, engine,
extension, and browser. Trials alternate which version runs first. Each
trial starts fresh seats and signaling queues. `summary.json` records each
result, elapsed time, and log directory. A failed trial keeps the remaining
comparisons running and makes the final command fail. Per-seat logs include
the failure stage and its elapsed time, channel states, sent and received
packet counts, and peak queued packets. Successful stage timings are also
retained. These queue peaks describe the drill workload.

A paired three-trial run captured a baseline stall on 2026-10-25. Current
addon e3c075f passed 3/3; baseline eadc00e passed 2/3. Both used Godot 4.3,
webrtc-native 1.2.2-stable, Chromium 154, and the same drill. The failed
baseline native seat timed out in phase 6 while streaming reliable gameplay:
92 packets received, 192 sent, zero queued, and all three channels open.
The browser seat stopped logging in that stage and had no failure snapshot.
A Rust build ran concurrently during the failed trial. These observations
do not establish whether load, browser scheduling, or transport caused the
stall. Keep the timeout policy unchanged while tracing #396.

Failure snapshots now include the pending stream acknowledgment marker,
per-channel queued packets and buffered bytes, and the largest observed
frame gap in the current wait. Use these to separate an acknowledgment wait
from a receive backlog or stalled frame loop.

Each running seat also logs `WEBRTC_INTEROP_PROGRESS` about once per second.
`seats.json` retains its last valid snapshot as `last_progress`, including
when the seat produces no terminal snapshot. Compare `tick_ms`, stage elapsed
time, packet counts, pending acknowledgment and frame gaps across progress
lines. Signaling counters, last sent/received markers and in-flight HTTP
request ages help distinguish a quiet data channel from delayed signaling.
Progress records contain the same channel state as terminal diagnostics.
A missing terminal record leaves that seat failed.

`browser_observation` records request timings outside the engine loop: completed
and failed signaling requests, current request ages, the last 16 completions,
and ages of the last console message and progress record. Compare these with
`last_progress` to separate delayed HTTP delivery from missing engine progress.
Renderer crashes and engine error output fail the trial.

Use `--safe-receive --metadata-probe` to check metadata through the RPC adapter's
packet API. Use `--safe-receive --mixed-traffic --rpc-traffic` to add actual
`SceneMultiplayer` RPCs: unreliable positions, ordered positions, and a reliable
byte-exact snapshot of 1,024 players in each generation. Both seats release
the RPC receiver before the raw packet checks resume. `--safe-receive` and
`--channel-receive` select separate receive paths; choose one. Baselines used
with the new scenarios must provide `get_safe_multiplayer_peer()`.

Use `--safe-receive --rpc-recovery` to keep one `SceneMultiplayer` and RPC
node across seven link generations. Each generation checks a full snapshot,
unreliable positions and ordered positions, then starts a second snapshot
with four exact chunks. Both seats pause RPC polling, send one more RPC and
select its queued packet. Closing a required channel must discard that packet
and emit one RPC peer-disconnected signal. The same API receives the next
generation through its replacement safe peer. Each channel closes from each
seat in the first six generations; the seventh repeats reliable closure.
This scenario replaces `--rpc-traffic` and the raw stream workload.

`WEBRTC_RPC_RECOVERY_PHASE` records completed generations in both logs and
`seats.json` (`rpc_recovery_phases`). Progress and failure snapshots record
RPC poll counts, polling state, connection/disconnection counts, selected-packet
state and partial snapshot counts. These distinguish a paused receiver from
a missing disconnect callback or stalled snapshot. The original intermittent
stall in #396 still needs a captured root cause.

Use `--safe-receive --rpc-plan-recovery` to keep the same assigned RPC peer
and API through seven generations. Relay plans, empty replacement generations
and player-left events retire links with an RPC selected. Each retirement must
discard selected bytes and emit one disconnect before the next generation
restores exact snapshots and positions. Phase records include `retirement`
and `same_rpc_peer`; failure snapshots include `rpc_retirement`. This scenario
injects service events locally. Full reference service sessions remain open.

Use `--multi-peer` for one native seat and two independent Web seats. It uses
one safe receiver per seat. Both Web engines must report startup within 60
seconds before the native seat starts and the driver releases gameplay. Each
network wait keeps its 15-second deadline. Each peer sends 64 exact 1,200-byte reliable chunks
and 32 exact samples on each unreliable mode to each connected peer. The local
qualification requires every sample, including its sender, destination, mode,
channel and sequence. It does not model network loss.

Before closing the link between seats 0 and 1, the drill queues eight
snapshot chunks and eight samples per unreliable mode on every directed link.
Seats 0 and 1 select a packet from the link that will close. Seat 2 selects a
packet from a surviving link. All seats wait for their 48 queued packets.
Closure must discard the retired sender's selected packet and remaining queue.
Every surviving sender must retain all eight exact packets per mode, its
connection identity and its metadata. Seat 2 must keep its selected packet.
Traffic continues through seat 2. A fresh generation restores the triangle
through the same safe receivers, then relay plans release all links.

Add `--retirement-matrix` to `--multi-peer` to run 18 independent cases.
Each seat closes each required channel toward each other seat. Each case
checks queued mixed-mode snapshots, surviving connection identity and exact
packets, hub traffic, and a fresh triangle through the same safe receivers.
Cases include Web-to-Web links and closure by both offerers and responders.
The three required channels keep their existing negotiation and labels.

Reports live under `trial-NNN/current/case-NN/` (or `baseline`). `summary.json`
records every case, including failures; later cases still run. A seat must
report all gameplay phases and the requested case to pass. Seat progress,
failure and interruption records include `retirement_case`, `closing_seat`,
`remote_seat`, `closing_channel` and `hub_seat`. Channel indices are `0`
(reliable), `1` (ordered) and `2` (unreliable). Each case keeps the usual
startup and network deadlines.

With `--slow-receiver`, full triangles still prove delayed-reader independence.
Hub traffic uses that pause only when the independent native/Web-2 pair
remains connected. Other hub cases keep every reader active; their records
set `delayed_reader_active` to false.

On peer disconnection, discard that peer's partial snapshot assembly in your
game. Keep other peers' assemblies and consumption windows separate. A fresh
link needs a fresh snapshot and a new consumption window.
Native plus two Web seats passed on Godot 4.3, 4.4.1 and 4.7.2 with
webrtc-native 1.2.2-stable and Chromium 154 on Linux arm64. This covers local
Godot mesh pairings. Full reference service sessions remain open.

`WEBRTC_MULTIPEER_PHASE` and `seats.json.multi_peer_phases` retain completed
phases. Progress and failure records include counts per sender and mode,
directed targets and the last packet's metadata.
`WEBRTC_MULTIPEER_INTERRUPTION` and `seats.json.multi_peer_interruptions` retain
completed interruption checks. Their `interrupted_snapshot` includes queue
counts before and after closure, selected metadata at both boundaries and
consumption counts per surviving sender and mode. Progress and failure records
carry the same fields, so a missing arrival, retirement failure or later
recovery stall can be traced separately.
Channel diagnostics include the Godot peer id. `browser_2_observation` and
`browser-2.log` retain the second Web seat's HTTP and transport evidence.
Every seat must complete; a missing terminal or engine error fails the trial.

Keep snapshot sends bounded while receivers poll. The three-seat drill limits
each sender to eight unacknowledged reliable chunks per recipient. Each
recipient acknowledges consumed chunks through the drill's signaling relay by
default. An
unbounded 64-chunk burst on native/Web Godot 4.3 filled the Web receive buffer:
its WebRTC stats recorded all 64 messages, while Godot emitted `Buffer full!
Dropping data.` and the byte checks failed after 55 chunks. Reliable transport
delivery alone does not prove that the game consumed each chunk. Applications
should acknowledge consumed chunks and limit outstanding bytes per recipient.

Add `--slow-receiver` to `--multi-peer` to delay reads on Web seat 1.
Seats 0 and 2 must finish their directed snapshots and position updates before
seat 1 resumes reading. Its queued packets must then pass the same byte,
sender, channel and mode checks. This repeats after selective link retirement
and after the triangle is rebuilt. Each destination has its own credit window;
a delayed recipient leaves the other pair free to finish. The independent
pair and delayed-reader catch-up have separate bounded waits. Each keeps
the existing per-stage limit.

`independent_pair_proof` retains sent, consumed and acknowledged counts when
the fast pair finishes. Seat 1 records `reader_resumed`. Phase reports also
retain `sent_by_target`, `acknowledged_by_target`,
`peak_outstanding_by_target` and `credit_wait_age_ms_by_target`. A rising
credit-wait age with fresh engine progress and browser transport samples
identifies an application waiting for consumption credit. These counts describe
the drill's application pacing; the mesh sends packets unchanged.

Add `--credit-transport webrtc` to carry the raw snapshot credits through
reliable data channels. This keeps the same snapshot sizes, per-peer window,
paused-reader check, exact transfer modes and recovery steps:

```bash
python scripts/check-webrtc-interop.py --multi-peer --slow-receiver \
  --credit-transport webrtc --retirement-matrix \
  --native-extension /path/to/webrtc-native \
  --output /tmp/multi-peer-data-credit
```

Repeat with `--credit-transport http` for the signaling-credit control. Phase
reports record `credit_transport`, `credits_sent_by_target` and
`credits_received_by_target`. Each active directed pair must exchange eight
credits per phase. The driver rejects a report from the wrong credit path or
with missing per-peer credits. HTTP still carries setup and phase barriers.
The selected credit path applies to raw traffic; RPC traffic keeps its own
reliable RPC credits.

Use `--http-credit-delay-ms 6000` with HTTP credit to hold the first
Web-1 consumption credit to native for six seconds. Other markers and
signaling continue. The driver requires the native/Web-2 pair to complete
its exact snapshots and all transfer modes while native has eight chunks
outstanding and zero credit from Web-1. It then requires all credits,
selective link retirement and fresh-triangle recovery to complete.

```bash
python scripts/check-webrtc-interop.py --multi-peer --rpc-traffic \
  --http-credit-delay-ms 6000 --native-extension /path/to/webrtc-native \
  --output /tmp/multi-peer-held-credit
```

`http_credit_delay` records the marker, destination, actual hold time and
independent-pair verdict. The relay must receive `credit-hold-proof-1-0`
from native before the hold deadline. Late proof fails the control. Native
phase records retain `http_credit_hold_proof`
with sent, acknowledged and received counts. Compare a matched run without
the delay, then use `--credit-transport webrtc` for the data-channel control.
The delay accepts at most 10,000 ms and runs separately from `--slow-receiver`.
A short hold that does not establish independence fails the control. These
runs isolate a known HTTP credit delay; the original intermittent timeout
still needs a causal capture (#396).

The drill sends HTTP messages through one outbox per destination. Each outbox
keeps its own FIFO. A pending response from one player allows credit and
signaling requests to the other player to continue.

Use `--http-post-delay-ms 6000` with `--multi-peer` and HTTP credit to hold
the response to native's first eight-chunk consumption credit to Web-1.
The relay queues that credit before holding the response. It requires both
final 64-chunk credits between native and Web-2 during the hold, followed by
all exact receipts, transfer modes, retirement and fresh-link recovery.

```bash
python scripts/check-webrtc-interop.py --multi-peer \
  --http-post-delay-ms 6000 --native-extension /path/to/webrtc-native \
  --output /tmp/multi-peer-held-post
```

`seats.json.http_post_delay` retains the held marker, actual hold duration
and each independent final-credit time. Missing or late proof fails even
when gameplay eventually completes. This control accepts at most 10,000 ms
and runs separately from the GET credit hold and RPC workload. Compare an
undelayed HTTP run and a WebRTC-credit run. The captured historical timeout
and remote-network qualification remain open (#396, #355, #403).

One Godot 4.7.2 HTTP retirement-matrix case completed all exact traffic and
recovery checks, then logged a native SCTP failure near final teardown (#474).
The strict verdict retains that failure. Matching old/current single-case
comparisons pass; the cause remains open.

Use `--multi-peer --slow-receiver --retirement-case 16` to run the captured
case alone. Cases 0 through 17 use the same directed-link and channel mapping
as `--retirement-matrix`. The two options are mutually exclusive. Logs keep
the selected case number. Preserve the original credit transport and tool
versions when comparing an earlier failure.

Each three-seat run prints `WEBRTC_LIFECYCLE` records for physical connection
and channel instances, state changes, barrier receipts and explicit close
boundaries. Removed peers retain their last observed identity and state.
`lifecycle` in progress and phase snapshots keeps up to 256 records and
reports omitted records. The observer keeps copied values only.

`driver-timeline.json` places native pipe lines and browser console messages
on one driver monotonic clock. It retains lifecycle, phase, stage and error
observations, including errors after a PASS marker. Its 4096-event limit and
line truncation counts are explicit. Raw seat logs retain the complete output.
These times describe when the driver read a line or received a console event.
They do not establish a native SCTP callback time or cross-seat causal order.
Join each seat's physical identities, local `tick_us` boundaries and barrier
markers before classifying a failure as final closure or an active-link fault.

For native callback evidence (#474), build the optional trace extension from
[webrtc-native 1.2.2-stable](https://github.com/godotengine/webrtc-native/tree/62135fc034cbdc5aee177136e526e3ead3cc563a).
Its pinned libdatachannel revision is `6b1e2e620f1e37f0eafeee702eaea0043cb305fd`.
Initialize all submodules before applying the combined patch from the clone root:

```bash
git submodule update --init --recursive
git apply /path/to/client/tests/smoke/webrtc_native_lifecycle_trace.patch
scons platform=linux arch=arm64 target=template_debug build_profile=build_profile.json -j4
SF_NATIVE_LIFECYCLE=1 python /path/to/client/scripts/check-webrtc-interop.py \
  --multi-peer --slow-receiver --retirement-case 0 --credit-transport webrtc \
  --native-extension bin/extension/addons/webrtc_native \
  --godot /path/to/godot --output /tmp/native-lifecycle-case0
```

Use the build tools and platform options required by the extension. The patch
leaves gameplay and engine error handling in place. Set `SF_NATIVE_LIFECYCLE=1`
to emit records; the patched build also supports a trace-disabled control.
Compare the original extension with matching tools, source and workload. Keep
all failures and record source, patch and binary hashes.

`native-lifecycle.json` retains native records and joins unique peer and SCTP
transport IDs to Godot connection instances. Channel bindings retain instance
and stream IDs. `script_connection_instance` and the records' `script_*`
fields preserve Godot's signed 64-bit script view of native unsigned object
IDs. Use those fields when joining script lifecycle records. Notifications retain the SCTP association ID, notification
state/error and prior transport state. Explicit local peer/channel closures,
remote-close callbacks and lower-transport disconnects have separate records.
Native records use one bounded output write to keep concurrent stdout from
splitting their fields. The driver reports malformed lines, sequence gaps,
conflicting identities, unbound transports and omitted records. The parser
recovers a complete native record after a Godot log prefix and retains its
line number in `interleaved_line_numbers` (#481). Malformed or combined native
records still fail validation. The surrounding Godot progress line can remain
split. Raw `native.log` retains all output.
Missing trace records provide no native callback evidence.

`native_entry_us` samples the process steady clock at the trace call;
`native_us` samples it under the trace output mutex. Their difference includes
instrumentation contention. Arguments such as prior state are sampled before
the call. These times describe instrumentation inside the native function.
They do not measure OS notification arrival or establish order with browser
clocks. A later notification after local close does not establish its cause.
Keep the strict engine-error verdict and exact gameplay checks.

Two traced HTTP cases identify native errors on a retiring first-generation
link during a concurrent lower-transport disconnect (#474). All exact gameplay
checks complete; the strict runs still fail. Native terminal-state handling
needs upstream assessment.

### Experimental native terminal handling

Issue #474 has an opt-in native repair and a deterministic control. Use the
pinned, built trace extension source above as the control's input:

```bash
python scripts/check-webrtc-sctp-terminal.py \
  --source /path/to/built-trace-extension \
  --output /tmp/sctp-terminal-control
```

The output directory must be new. The runner rejects source edits beyond the
pinned lifecycle trace patch. It copies the native sources,
compiles the original and repaired SCTP callbacks, and links the pinned build's
libraries. Use a Linux build with `g++` and bundled MbedTLS. It retains commands,
process results, source hashes and per-case results. Controlled thread barriers
place a lower disconnect before notification classification and after state
selection. Other cases check genuine failures, duplicate shutdowns, early close,
connection success during close and delayed connection callbacks. The original
must reproduce the race; every repaired case must pass.

The control injects notifications into real transport objects. Startup cases
leave the first-write flag unset. They require a lower EOF, local close and
genuine failure to release pending reads; DATA still waits for a successful
local write. Thread barriers force close/failure between the wait predicate
check and sleep. A reentrant state callback must also finish without a blocked
read. Startup controls also replay buffered lower DATA and EOF, close before
start, and close from the Connecting callback. The original misses wakeups
and can block before local INIT or reopen a cancelled startup.

The experimental repair initiates local SCTP before registering the lower
receive callback, so buffered DATA can replay after the local write. Chosen
close barriers before the state transition and before binding require zero
late INIT writes and zero false failure errors. The transport can briefly
report Connecting before the raced close reaches Failed.
The repair handles EOF before the INIT wait and publishes wait cancellation
under a separate mutex before terminal callbacks. A local
write uses that same mutex to publish readiness. Transport callbacks and writes
run outside it. Cancelled INIT waits release pending reads without feeding
SCTP. A lower disconnect while Connecting becomes Failed; genuine establishment
failures still report errors. Other concurrent native API calls and remote
networks still need qualification.

For a live comparison, copy the traced extension source and apply
`tests/smoke/webrtc_sctp_terminal.patch` after the lifecycle trace patch.
Build that copy, then use its extension with the same three-seat HTTP and
WebRTC-credit retirement matrices. Keep the original extension and all failed
attempts. For an existing Linux ARM64 build, apply the incremental-build patch
below or rebuild the nested library before relinking the extension:

```bash
cmake --build bin/thirdparty/libdatachannel/linux/arm64 --target datachannel-static -j4
scons platform=linux arch=arm64 target=template_debug build_profile=build_profile.json -j4
```

Use the build directory and platform options for your target. Verify the rebuilt
extension hash; an unpatched SCons build can reuse a cached nested library.
The repair makes terminal handling idempotent and serializes state callbacks. A genuine connection failure still reports an error. This patch is
experimental; upstream acceptance and remote-network qualification remain open.
It does not establish the cause of the historical snapshot stalls (#396) or
complete reference-client qualification (#355).

WebRTC credits carry the phase, sender, destination and cumulative consumed
count. Reads check exact bytes, reliable mode, channel zero, the next eight-chunk
boundary and the sender's outstanding count. Credits share the reliable channel
with snapshot chunks. These bytes belong to the drill workload; applications
choose their own gameplay message format. Compare the two credit paths before
attributing a snapshot wait to data-channel delivery (#396). This comparison
keeps the engine deadlines and channel negotiation unchanged.

### Native incremental builds

Nested native source edits can leave the old archive and extension in place
when SCons decides the CMake target is current (#479). The pinned CMake tool
tracks its top-level build file and declared dependencies. It delegates no
check of nested source files to CMake on that path.

The opt-in `tests/smoke/webrtc_native_incremental_build.patch` runs CMake's
incremental check on every build. It prevents SCons cache reads for those
outputs and preserves CMake-owned files so unchanged objects and archives
can be reused. Apply it to the pinned webrtc-native
`62135fc034cbdc5aee177136e526e3ead3cc563a` source before building a repair.
Run the compiled control on Linux ARM64 or x86-64 with SCons, CMake and a C++
compiler available. Use executable paths without spaces:

```bash
python scripts/check-webrtc-native-build.py \
  --source /path/to/webrtc-native \
  --output /tmp/native-incremental-control
```

The control uses the actual pinned CMake tool with a small native library and
loaded extension. It checks nested source, header and build-file edits, plus a
top-level build-file edit, a no-op build and build failure/recovery. A SCons
cache stays enabled during the control. Reports retain source, archive and
extension hashes and the value returned by the loaded extension. The original
tool must reproduce stale nested builds. The repair must rebuild changed code
and preserve unchanged output hashes and modification times. This isolates the
build boundary; live gameplay still needs the rebuilt WebRTC extension.

Add `--rpc-traffic` to `--multi-peer` to run actual `SceneMultiplayer` RPCs
after each raw-packet phase:

```bash
python scripts/check-webrtc-interop.py --multi-peer --rpc-traffic --slow-receiver \
  --native-extension /path/to/webrtc-native \
  --output /tmp/multi-peer-rpc
```

One assigned RPC API and safe peer stay in place through selective link loss
and the fresh triangle. Each directed pair exchanges 64 snapshot chunks and
32 positions per unreliable mode. RPC handlers check sender, destination,
generation, sequence and exact bytes. This local check requires every sample;
it does not simulate packet loss. Combine it with `--retirement-matrix` to
repeat the RPC stages for every required-channel closure. The driver allows
120 seconds per Web seat for this added workload. Each engine wait still
uses its existing 15-second deadline.

The RPC workload returns credit through reliable gameplay RPCs. Each target
has an eight-chunk window. With `--slow-receiver`, seat 1 pauses RPC polling
while seats 0 and 2 finish their own exchanges. Their
`rpc_independent_pair_proof` must show zero credit and eight outstanding chunks
for seat 1. The paused reader then catches up. A failed or disconnected peer's
assembly and credit are cleared before the next phase; surviving links keep
the same connections.

Phase reports include `rpc.received_by_peer_and_mode`, sent and acknowledged
counts, peak outstanding chunks, and `credit_round_trip_us_by_peer`. These
round trips include receiver scheduling and consumption. They are application
measurements. `rpc_service_poll_count`, `rpc_service_poll_total_us` and
`rpc_service_poll_max_us` measure the explicit RPC polls inside the transfer
wait, including dispatch and acknowledgment work. They exclude setup, barriers
and the raw-packet stage. Use repeated runs on an idle machine to compare
costs; these live measurements are outside the deterministic gate.

The raw stage uses the selected credit transport (HTTP by default). The RPC
stage uses HTTP for
readiness and completion barriers. Comparing the two stages helps separate
HTTP credit delays from WebRTC gameplay progress (#396). Keep their workloads
and timing scopes in view; a faster RPC stage alone cannot identify an earlier
timeout's cause.

`--web-godot /path/to/godot` selects a separate engine for Web import and
export. `--godot` still selects the native engine. Install the Web engine's
matching export templates. Each seat report retains its actual engine banner.
Native and Web Godot 4.4.1 passed the safe metadata probe and seven generations
of safe-peer RPCs, mixed traffic, exact snapshots and interrupted-link recovery
with webrtc-native 1.2.2-stable and Chromium 154 on Linux arm64. The engine-only
metadata control failed on both seats. Godot 4.7.2 passed the safe metadata
probe and the persistent RPC recovery scenario on both native and Web with the same extension and browser. The raw
engine metadata probe failed on both seats.

Godot 4.4.1 and 4.7.2 also pass all 18 three-seat directed channel-closure
cases with raw mixed traffic, RPCs, paused readers and fresh-link recovery.
All three supported engines pass the six-second HTTP credit hold with RPCs
and independent-link proof. These runs use local links; remote networks still
need live qualification.

`browser_observation.webrtc_stats` retains the last 16 browser transport
samples, with sample ages and per-connection ids. Samples include channel
message/byte counts, ICE/SCTP/DTLS state, nominated candidate-pair byte counts
and round-trip time from the
[WebRTC statistics API](https://www.w3.org/TR/webrtc-stats/#dom-rtcdatachannelstats).
Closed connections leave the observer. A stats request that takes over 750 ms
records an error; other peers and state samples continue. The observer waits
for that request to finish before requesting its stats again.

Signaling request records include the drill `marker` when present. Match a
pending `consumed-PHASE-SEAT-COUNT` marker to the sender's credit wait to
trace delayed consumption acknowledgements. Other signaling records leave
`marker` null.

`relay_observation` records server queue timing for markers in both the mesh
drill and reference assessment. `pending_markers` shows markers waiting for a
destination GET. `recent_dequeues` records their `queue_ms` until that GET
removed them. This measures server queue dwell; the receiving engine may
process the response later. Match each marker and destination with the Web
request timings and the receiving seat's last marker.

Each Godot progress/failure snapshot also retains the last 16 `marker_posts`,
with destination, request result, HTTP code and duration through the engine's
completion callback. A long callback duration with short browser request and
relay queue times points to engine scheduling or HTTP polling. Long queue dwell
points to delayed destination polling. Compare fresh frame/transport samples
before attributing a delay. These timings alone do not prove marker consumption.
Relay histories retain at most 128 pending markers and 128 dequeues. Totals
cover the full trial; `evicted_pending_records` reports missing detail, and
`queue_ms` is null when its enqueue record was evicted.

Three-seat `seats.json.credit_diagnostics` joins the latest observation for
each phase and directed link. It compares sent and acknowledged chunks with
the receiver's consumed chunks and credit counts. A full HTTP credit window
also records the expected consumption marker, matching completed or inflight
POST, relay queue/dequeue timing and sender marker observation. WebRTC credit
rows keep their own counts without HTTP attribution. `credit_packets` matches
each eight-chunk credit with the receiver's issue record and the sender's
receipt record. WebRTC issue records include the `put_packet` error; HTTP
issue records show queue submission. A successful issue does not prove receipt.
Both seats retain at most 32 events per phase. Missing history is null.
Seat tick values use separate clocks and observation times; do not subtract
them or treat a later receiver observation as proof of what the sender knew
at its deadline. These rows preserve evidence without assigning a cause.

These samples run outside Godot's frame loop. In a controlled stopped-frame
run, the engine heartbeat aged over 14 seconds while browser stats stayed
fresh. A held HTTP request instead aged over 2.5 seconds while engine progress
and stats continued. A paused browser main thread can stop both timers;
compare both sample ages with HTTP request ages. These controls validate the
diagnostics. The cause of the original intermittent stall remains open.

### Experimental native mesh repair

An opt-in patch targets Godot 4.6.3 source
`35e80b3a8822a9df9be390814b62f44c0a9c69e8`. It reads the channel selected
for packet metadata and refreshes selection when that peer is removed or
replaced (#403). It also backports the
[upstream lifetime-key correction](https://github.com/godotengine/godot/commit/caa386e89570d293c03ad7c723d5fbd7eb1a2717)
for default and custom channels (#433).

```sh
python scripts/repair-webrtc-mesh.py --source /path/to/godot-4.6.3 \
  --check --report /tmp/mesh-check.json
python scripts/repair-webrtc-mesh.py --source /path/to/godot-4.6.3 \
  --report /tmp/mesh-apply.json
```

Build a native engine with GDScript and WebRTC enabled. The reference drill
also needs `module_multiplayer_enabled=yes`. Start with the template build
options in [Testing](testing.md) and enable that module. The mesh patch can
coexist with the optional WebSocket repair. Keep each report in a new path.

```sh
/path/to/repaired-godot --headless --path . \
  --script tests/smoke/webrtc_mesh_engine_probe.gd
```

The engine probe checks twelve dispatch, selection, peer-retirement and
channel-configuration controls. Scripted channels report which read callback
ran; this probe cannot verify packet bytes or transport delivery. Use the
standalone metadata scene and native reference drill for those checks.

Native template qualification can use a separate editor for imports:

```sh
python scripts/check-webrtc-reference.py --runtime native \
  --godot /path/to/repaired-template --import-godot /path/to/editor \
  --native-extension /path/to/webrtc_native \
  --native-reference-probe /path/to/godot_qualification \
  --reference-revision REFERENCE_COMMIT --offerer both \
  --safe-receive --mixed-traffic --binary-traffic --require-gameplay \
  --output /tmp/mesh-reference-attempt
```

The tested Linux ARM64 build passes all twelve engine controls, nine native
lifetime controls and the two-sender exact-byte metadata scene. Native
reference sessions pass both offer roles with the engine reader and safe
adapter, across two generations each. Every generation retains all 128
reliable snapshot chunks and acknowledgements, binary payload checks,
required-channel teardown and fresh-link recovery. Gameplay lifetimes are
unset for reliable and 1 ms for ordered/unordered channels. WebSocket smoke
also passes.

One unordered binary sample is absent in a safe-adapter phase. The drill
permits unreliable gaps; these results do not identify their cause. Finite
channel configuration does not prove expiry under loss or delay. Web exports,
remote networks, other build targets and upstream adoption remain open. The
zero-byte script packet contract remains tracked in #437.

### Mixed-mode packet metadata

Godot 4.3 can return packet bytes from a different channel than the mode
reported by `WebRTCMultiplayerPeer.get_packet_mode()`. A queued unreliable
packet can keep the cached mode selected when a reliable packet arrives;
the next read then returns the reliable bytes. This was reproduced on
native Linux arm64 with webrtc-native 1.2.2-stable and Chromium 154.
The standalone `tests/smoke/webrtc_metadata_repro.tscn` reproduces the same
failure with engine APIs only. It connects two senders to one receiver, then
checks each sender across a late reliable arrival and another frame. Run it
with a native WebRTC extension installed:

```bash
godot --path . tests/smoke/webrtc_metadata_repro.tscn
```

For Web, export this scene as the main scene and include its script in the
export preset. The scene and script can also be copied into an empty Godot
project. They have no addon or service dependency. Native runs need the
WebRTC extension; Web runs use browser WebRTC.

`WEBRTC_METADATA_RESULT` retains the engine version, selected peer/mode/channel
and both packet bodies. `valid` means setup and both reads completed.
`reproduced` means unreliable metadata accompanied the reliable body;
`consistent` means each read matched its metadata, in either order.
`preserved` also requires the original unreliable selection to stay first.
The Web page stays open after its result. Native exit code 1 means the control
could not complete. Godot 4.3, 4.4.1 and 4.7.2 reproduced the mismatch on
native Linux arm64 and Chromium 154 Web exports.
See [issue #403](https://github.com/Ambiguous-Interactive/signal-fish-client-godot/issues/403).

Use `--metadata-probe` for the controlled reproduction. Both seats queue an
unreliable packet, wait for its selection, then queue a reliable packet
before reading. A mode/payload mismatch fails the drill and retains both
seat logs. Use `--mixed-traffic` for the concurrent snapshot workload.
Choose one of these options per run. Both work with `--repeat` and
`--baseline`.

The [Godot 4.3 source](https://github.com/godotengine/godot/blob/4.3/modules/webrtc/webrtc_multiplayer_peer.cpp)
caches the selected channel for metadata, then scans channels again during
the packet read. The addon exposes this engine peer directly. Concurrent
mixed-mode reads through that peer remain affected. The raw packet receive
path below avoids its cached selection. An engine-only run can pass when
packets arrive in a different order.

### Raw packet receive workaround

For manual gameplay packets, use `mesh.receive_packet()` to read bytes and
metadata from the same physical channel. It returns a `ReceivedPacket` with
`peer_id`, `transfer_mode`, `channel` (always `0`), `data`, and `error`.
An empty queue returns `null`. Empty packets remain valid when `error == OK`.
Peers and their three default channels receive turns in round-robin order.

```gdscript
func _process(_delta: float) -> void:
    mesh.poll()
    for _read in range(64):
        var packet = mesh.receive_packet()
        if packet == null:
            break
        if packet.error != OK:
            handle_read_error(packet.error)
            break
        handle_gameplay(packet.peer_id, packet.transfer_mode, packet.data)
```

Use this as the sole receive path. Keep this mesh outside `MultiplayerAPI`
and do not read packets through its `WebRTCMultiplayerPeer`. Sending still
uses that peer's `put_packet`, target, and transfer mode. Poll the mesh each
frame. The reader waits until the connection and all three channels are open;
teardown discards pending packets. It keeps the channel layout unchanged.
High-level RPCs can use `get_safe_multiplayer_peer()` to avoid that selection.

Add `--channel-receive` to `--metadata-probe` or `--mixed-traffic` to test this
path with the same byte, sender, mode, snapshot, and recovery checks.

The controlled probe and two seven-generation mixed runs passed on native
and Web Godot 4.3 with webrtc-native 1.2.2-stable and Chromium 154. The
engine-only control still failed the controlled probe. Native Godot 4.4.1
also reproduced that engine failure and passed the raw receive probe and
seven-generation mixed workload with a Web Godot 4.3 seat. Other engine/export
versions need separate live checks.

### Receive throughput benchmark

Run `godot --headless --path . --script tests/client/mesh_receive_bench.gd`
to measure the raw receiver with 1, 16, 64 and 256 simulated peers. Add
`-- --safe` to measure the safe peer's count, metadata and packet reads.
The benchmark covers dense traffic, one active sender and empty queues.
Dense raw traffic queues 200 packets per channel per peer; dense safe
traffic uses four to bound the exact-count scan workload. Sparse traffic
queues 200 per channel on the last peer. Empty-queue cases measure polling.

Compare repeated runs on the same engine and machine, with the same benchmark
file on each revision. Keep other workloads stopped during measurement.
Readiness checks run when queued bytes are found, so empty peers avoid repeated
channel-state calls. Every actual read still checks all required channels;
safe selected-packet metadata keeps its live lifecycle checks. This measures
script receive work; real network throughput requires the live drills above.
