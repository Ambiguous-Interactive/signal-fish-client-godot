---
description: Godot WebSocketPeer receive defects, root causes, pinned repairs, and reproductions kept in-repo (upstream reports withdrawn).
triggers: godot, websocket, receive, wslay, close reason, fragmentation, packet buffer, upstream defect
category: Research
---

# Godot WebSocketPeer Receive Defects

These are engine defects in Godot's native and Web WebSocket receive
paths. Godot does not accept AI-authored issues or pull requests, so the
upstream reports were withdrawn. This note is the durable record. Downstream
issues live in this repository (#485, #491, #492, #496, #488, #498) and the
pinned repairs live in `scripts/patches/`.

Engine revisions named below are the stable sources other sections cite:
4.3 `77dcf97d8`, 4.4.1 `49a5bc7b6`, 4.7.2 `ed1daf0bf`, master
`95c0fa5fe8a019adc29d074c16b64469b04571f7` (inspected, not runtime-tested).

## 1. Control frames enter fragmented messages (#491)

- Affected: official native 4.4.1 and 4.7.2. Official 4.3 passes this
  control.
- Symptom: a nonempty Ping/Pong inside a fragmented message appends its
  control payload to the application bytes. A 4096-byte body plus a 19-byte
  Ping yields a 4115-byte first message; all 65 messages arrive, but exact
  validation fails. No engine error is reported.
- Cause: `_wsl_recv_start_callback` keeps `pending_message.opcode` during
  control frames, and wslay invokes `_wsl_frame_recv_chunk_callback` for
  control payloads, so the `pm.opcode != 0` guard appends them to the data
  message.
- Fix: track whether the current frame is a data frame and gate data
  assembly on it.
- Repro:
  `godot --headless --path . --script tests/smoke/run_websocket_receive_boundary.gd -- --fragment-bytes=127 --fragment-control=ping --capacity=524288`
  (repeat with `pong`; a `none` control passes).

## 2. Peer reuse retains unfinished message state (#492)

- Affected: official native 4.4.1 and 4.7.2. Official 4.3 passes.
- Symptom: reusing a peer while CLOSING corrupts the first packet on the
  new connection. The fresh TEXT "fresh" arrives empty and non-string, with
  `PacketBuffer ERR_BUG (_payload.data_left() < (int)p.size)`.
- Cause: `WSLPeer::_clear` clears buffers and the old connection but keeps
  `pending_message`, whose `payload_size` is added to the new message.
- Fix: clear every pending assembly field when replacing the connection.
- Repro:
  `godot --headless --path . --script tests/smoke/run_websocket_fragment_reuse.gd`
  (expects five fresh bytes `6672657368`; `-- --replacement=handshake`
  passes).

## 3. Full buffer blocks an empty final continuation (#496)

- Affected: official native 4.4.1 and 4.7.2 stall; official 4.3 delivers the
  body but drops the following message.
- Symptom: `inbound_buffer_size=4095`, a non-final 4095-byte binary frame,
  then an empty final continuation and a separate two-byte message. The
  connection stays OPEN with zero complete packets. A one-byte tail passes
  on 4.7.2.
- Cause: `WSLPeer::_wsl_recv_callback` limits reads by
  `payload_space_left()`. Once a full unfinished body fills the ring, even
  frame headers cannot be read.
- Fix: allow one byte per read only while a full unfinished message occupies
  the queue with no complete packet queued; also track cumulative message
  length in unbuffered wslay mode so an extra payload byte closes 1009 before
  its chunk callback. A larger buffer alone only moves the boundary.
- Repro:
  `godot --headless --path . --script tests/smoke/run_websocket_fragment_limit.gd`
  (expects the 4095-byte body, type, and following `ff01`; `-- --tail-bytes=1`
  passes on 4.7.2).

## 4. Split Unicode close reasons become 1007 (#498)

- Affected: official native 4.3, 4.4.1 and 4.7.2.
- Symptom: a server close with code 3400 and UTF-8 reason `c3a9616263`
  (U+00E9 then `abc`) split into three-byte writes becomes code 1007. A
  complete-frame write returns the exact code and reason.
- Cause: bundled `thirdparty/wslay/wslay_event.c` starts close-payload UTF-8
  validation at offset 2 for every chunk, but only the first two payload
  bytes hold the status code.
- Fix:
  `i = ctx->ipayloadoff < 2 ? 2 - ctx->ipayloadoff : 0;`
- Repro:
  `godot --headless --path . --script tests/smoke/run_websocket_close_reason.gd -- --wire-chunk-bytes=3 --wire-delay-ms=10 --reason=two --origin=server`
  (drop the `--wire-*` options for the passing control; `--origin=client`
  covers the echo direction).

## 5. Web inbound buffer silently drops messages (#488)

- Affected: official Web exports of 4.3, 4.4.1 and 4.7.2.
- Symptom: a burst of 64 x 4096-byte messages plus a sentinel reaches the
  browser as 65 `onmessage` callbacks, but `WebSocketPeer` delivers 16
  (0-14 and the sentinel) and logs 49 `Buffer payload full! Dropping data`
  errors. No API exposes the loss.
- Cause: `EMWSPeer::_esws_on_message` ignores the `Error` from
  `PacketBuffer::write_packet`. On Web, delivery runs on browser callbacks,
  so slower polling cannot apply backpressure.
- Status: no engine fix is pinned. The opt-in application-ACK drill control
  is a pure-GDScript credit window (`--relay-credit-transport app-ack`) with
  no SDK-wide delivery guarantee. A 512 KiB buffer also moves the threshold
  but does not remove the failure mode.
- Repro: `python scripts/check-websocket-web-receive.py --godot ...
--chromium ... --output ...`; the paced comparison adds
  `--credit-transport app-ack --credit-bytes 32768`.

## Pinned repairs

- `scripts/patches/godot-43-websocket-receive.patch` applies to 4.3-stable
  and contains all four receive fixes. Applicator:
  `scripts/backport-websocket-43.py`.
- `scripts/patches/godot-4{4,5,6,7}-websocket-assembly.patch` apply the same
  fixes to each stable family. Applicator:
  `scripts/repair-websocket-stable.py`.
- `scripts/patches/godot-master-websocket-assembly.patch` targets master
  `95c0fa5f`; the upstream pull request carrying it was closed unmerged.
- Qualification runs, engine hashes and per-family matrices live in
  `docs/testing.md` and the issues named above.

## Upstream copy status

- Four reports (control bytes, peer reuse, full buffer, split close
  reasons) drew no comments or maintainer work and their bodies were
  cleared at the reporter's request; this note is their only record.
- The Web drop report and the master repair pull request stay readable
  because maintainers commented on them (AI-authorship policy). Do not
  submit more AI-authored content to Godot repos.
