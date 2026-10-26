"""Reference assessments distinguish unsupported gameplay from incomplete evidence."""

import argparse
import importlib.util
import json
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path
from typing import ClassVar, cast
from unittest.mock import Mock, patch

from playwright.sync_api import Page

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/check-webrtc-reference.py"
SPEC = importlib.util.spec_from_file_location("webrtc_reference", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
reference = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reference)


class ReferenceEvidenceTests(unittest.TestCase):
    def test_service_rejoin_requires_same_room_receiver_and_new_generation(self) -> None:
        godot = [
            {
                "phase": phase,
                "room_id": "room",
                "generation": f"generation-{phase}",
                "player_id": "godot",
                "peer_id": "reference",
                "signals_sent": 3,
                "signals_received": 4,
                "left": phase == 2,
                "receiver_retired": True,
                "same_receiver": phase == 2,
                "peer_departed": phase == 1,
                "reference_epoch": phase,
            }
            for phase in (1, 2)
        ]
        remote = [
            {
                **phase,
                "player_id": "reference",
                "peer_id": "godot",
                "signals_sent": 4,
                "signals_received": 3,
                "left": True,
                "departure_stage": "selected_packet" if phase["phase"] == 1 else "teardown",
            }
            for phase in godot
        ]
        self.assertTrue(reference.service_session_passed(godot, remote, rejoin=True))
        self.assertFalse(reference.service_session_passed(godot, remote))
        self.assertFalse(
            reference.service_session_passed(
                godot, [{**remote[0], "departure_stage": "teardown"}, remote[1]], rejoin=True
            )
        )
        for remote_epoch in (None, True, 1.0, 2):
            with self.subTest(remote_epoch=remote_epoch):
                self.assertFalse(
                    reference.service_session_passed(
                        godot,
                        [{**remote[0], "reference_epoch": remote_epoch}, remote[1]],
                        rejoin=True,
                    )
                )
        for index, key, value in (
            (0, "peer_departed", False),
            (0, "left", True),
            (1, "same_receiver", False),
            (1, "receiver_retired", False),
            (1, "room_id", "new-room"),
            (1, "generation", "generation-1"),
            (1, "player_id", "new-godot"),
            (1, "peer_id", "new-reference"),
            (1, "reference_epoch", 1),
            (1, "reference_epoch", 0),
            (1, "reference_epoch", True),
        ):
            with self.subTest(key=key):
                local = [dict(phase) for phase in godot]
                other = [dict(phase) for phase in remote]
                local[index][key] = value
                if key in ("room_id", "generation", "reference_epoch"):
                    other[index][key] = value
                if key == "player_id":
                    other[index]["peer_id"] = value
                if key == "peer_id":
                    other[index]["player_id"] = value
                self.assertFalse(reference.service_session_passed(local, other, rejoin=True))

    def test_service_sessions_require_matching_ids_signaling_and_fresh_rooms(self) -> None:
        godot = [
            {
                "phase": phase,
                "room_id": f"room-{phase}",
                "generation": f"generation-{phase}",
                "player_id": "godot",
                "peer_id": "reference",
                "signals_sent": 3,
                "signals_received": 4,
                "left": True,
                "receiver_retired": True,
            }
            for phase in (1, 2)
        ]
        remote = [
            {
                **phase,
                "player_id": "reference",
                "peer_id": "godot",
                "signals_sent": 4,
                "signals_received": 3,
            }
            for phase in godot
        ]
        self.assertTrue(reference.service_session_passed(godot, remote))
        for records in (godot, remote):
            for key, value in (
                ("phase", 1),
                ("room_id", "wrong-room"),
                ("generation", "wrong-generation"),
                ("player_id", "wrong-player"),
                ("peer_id", "wrong-peer"),
                ("signals_sent", 0),
                ("signals_received", 0),
                ("left", False),
                ("signals_sent", True),
                ("signals_received", 3.0),
            ):
                changed = [records[0], {**records[1], key: value}]
                with self.subTest(side=records is godot, key=key, value=value):
                    self.assertFalse(
                        reference.service_session_passed(
                            changed if records is godot else godot,
                            changed if records is remote else remote,
                        )
                    )
        self.assertFalse(reference.service_session_passed(godot[:1], remote))
        self.assertFalse(reference.service_session_passed(godot, remote[:1]))
        self.assertFalse(
            reference.service_session_passed(
                [godot[0], {**godot[1], "receiver_retired": False}], remote
            )
        )
        for key in ("room_id", "generation"):
            reused_godot = [godot[0], {**godot[1], key: godot[0][key]}]
            reused_remote = [remote[0], {**remote[1], key: remote[0][key]}]
            self.assertFalse(reference.service_session_passed(reused_godot, reused_remote))

    def test_service_wire_uses_real_signal_envelopes_and_fences_other_sessions(self) -> None:
        harness = r"""
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
const source = readFileSync(0, "utf8").replace("export function", "function");
const fault = process.argv[1];
const rejoin = fault === "rejoin";
let socket, clock = 0, phase = 0;
const sent = [];
const frame = (type, data) => socket.onmessage({data: JSON.stringify({type, data})});
class Socket {
  static OPEN = 1;
  readyState = 1;
  constructor() {
    socket = this;
    setImmediate(() => this.onopen());
  }
  send(text) {
    const message = JSON.parse(text); sent.push(message);
    if (message.type === "Authenticate") {
      frame("Authenticated", {}); frame("ProtocolInfo", {protocol_version: 3});
    }
    if (message.type === "JoinRoom") {
      phase++;
      if (!message.data.join_only || message.data.room_code !== "CODE")
        throw new Error("room admission differs");
      frame("RoomJoined", {room_id: `room-${phase}`, player_id: "reference",
        current_players: [{id: "reference", epoch: phase}]});
      if (rejoin && phase === 2)
        frame("SessionPlan", {transport: "webrtc", generation: `generation-${phase}`,
          peers: [{player_id: "godot", initiate: true}]});
    }
    if (message.type === "PlayerReady") {
      if (rejoin && phase === 2) throw new Error("rejoin must keep the running game");
      frame("GameStarting", {});
      frame("SessionPlan", {transport: "webrtc", generation: `generation-${phase}`,
        peers: [{player_id: "godot", initiate: true}], ice_servers: []});
    }
    if (message.type === "LeaveRoom") {
      if (fault.startsWith("late")) frame("Signal", {
        from: fault === "late-peer" ? "other" : "godot",
        generation: fault === "late-generation" ? "old" : `generation-${phase}`,
        signal: {IceCandidate: "late-candidate"}});
      frame("RoomLeft");
    }
  }
  close() { this.readyState = 3; }
}
const context = {
  window: {}, WebSocket: Socket,
  performance: {now: () => clock},
  setTimeout: (resolve) => setImmediate(() => { clock += 20; resolve(); }),
  console: {log() {}},
  fetch: async () => ({ok: true, json: async () => [
    {marker: `service-room-${phase + 1}`, game_name: "game", room_code: "CODE", player_id: "godot"}
  ]}),
};
runInNewContext(source, context);
context.configureReferenceService("ws://service/v3/ws", "app", rejoin);
let error = "";
try {
  for (let round = 1; round <= 2; round++) {
    const service = await context.window.referenceService.begin(round, 0);
    service.send({Offer: "offer-text"});
    const outbound = sent.at(-1);
    if (JSON.stringify(outbound) !== JSON.stringify({type: "Signal", data: {
      to: "godot", generation: `generation-${round}`, signal: {Offer: "offer-text"}
    }})) throw new Error("Signal wire shape differs");
    frame("Signal", {from: fault === "peer" ? "other" : "godot",
      generation: fault === "generation" ? "old" : `generation-${round}`,
      signal: {Answer: "answer-text"}});
    const messages = service.drain();
    if (messages.length !== 1 || messages[0].payload.Answer !== "answer-text")
      throw new Error("Signal payload changed");
    if (rejoin && round === 1) await service.leave("selected_packet");
    await service.leave();
    const sentAtDeparture = sent.length;
    service.send({IceCandidate: "after-departure"});
    if (sent.length !== sentAtDeparture) throw new Error("departed membership sent ICE");
    if (sent.filter(message => message.type === "LeaveRoom").length !== round)
      throw new Error("room departure repeated");
  }
} catch (caught) { error = String(caught); }
context.window.referenceService.close();
console.log(JSON.stringify({error, evidence: context.window.referenceServiceEvidence, closed: socket.readyState === 3}));
"""
        source = (SCRIPT.parents[1] / "tests/smoke/webrtc_reference_service.js").read_text()
        for fault in (
            "none",
            "rejoin",
            "late",
            "peer",
            "generation",
            "late-peer",
            "late-generation",
        ):
            with self.subTest(fault=fault):
                result = subprocess.run(  # noqa: S603
                    ["node", "--input-type=module", "-e", harness, fault],  # noqa: S607
                    input=source,
                    text=True,
                    capture_output=True,
                    check=True,
                    timeout=5,
                )
                proof = json.loads(result.stdout)
                self.assertTrue(proof["closed"])
                if fault in ("none", "rejoin", "late"):
                    self.assertEqual(proof["error"], "")
                    self.assertEqual([phase["phase"] for phase in proof["evidence"]], [1, 2])
                    for phase in proof["evidence"]:
                        self.assertTrue(phase["left"])
                        self.assertEqual(phase["signals_sent"], 1)
                        self.assertEqual(phase["signals_received"], 2 if fault == "late" else 1)
                    if fault == "rejoin":
                        self.assertEqual(proof["evidence"][0]["departure_stage"], "selected_packet")
                else:
                    self.assertIn("signal identity differs", proof["error"])
                    self.assertFalse(proof["evidence"][0]["left"])

    def test_snapshot_verdict_requires_complete_stream_and_partial_transfer(self) -> None:
        phase = {
            "mixed_traffic": False,
            "credit_transport": "http",
            "snapshot_acknowledged": 128,
            "positions_sent": 0,
            "positions_received": 0,
            "peak_outstanding": 32,
            "sent": True,
            "remote_closed": True,
            "received": ["unreliable", "reliable"],
            "snapshot_sent": 128,
            "snapshot_received": 128,
            "partial_sent": 4,
            "partial_received": 4,
        }
        self.assertTrue(reference.gameplay_phase_passed(phase))
        self.assertFalse(reference.gameplay_phase_passed(phase, slow_receiver=True))
        for field, total in (
            ("snapshot_sent", 128),
            ("snapshot_received", 128),
            ("partial_sent", 4),
            ("partial_received", 4),
        ):
            for value in (0, total - 1, total + 1):
                with self.subTest(field=field, value=value):
                    self.assertFalse(reference.gameplay_phase_passed({**phase, field: value}))
        for transport in ("http", "webrtc"):
            mixed = {
                **phase,
                "mixed_traffic": True,
                "credit_transport": transport,
                "positions_sent": 32,
                "positions_received": 32,
            }
            self.assertTrue(
                reference.gameplay_phase_passed(
                    mixed, mixed_traffic=True, credit_transport=transport
                )
            )
            for field, mixed_value in (
                ("positions_sent", 31),
                ("positions_received", 31),
                ("snapshot_acknowledged", 120),
                ("peak_outstanding", 33),
                ("peak_outstanding", 0),
                ("credit_transport", "other"),
                ("mixed_traffic", False),
            ):
                with self.subTest(transport=transport, field=field):
                    self.assertFalse(
                        reference.gameplay_phase_passed(
                            {**mixed, field: mixed_value},
                            mixed_traffic=True,
                            credit_transport=transport,
                        )
                    )
        self.assertFalse(reference.gameplay_phase_passed({**phase, "remote_closed": False}))
        self.assertFalse(reference.gameplay_phase_passed({}))
        self.assertFalse(reference.gameplay_phase_passed({**phase, "received": ["reliable"]}))

    def test_retirement_requires_selected_packet_discard_and_physical_closure(self) -> None:
        for seat, channels in (
            ("godot", ("reliable", "ordered", "unreliable")),
            ("reference", ("reliable", "unreliable")),
        ):
            for channel in channels:
                proof = {
                    "seat": seat,
                    "channel": channel,
                    "selected": True,
                    "queued": 1,
                    "discarded": True,
                    "peer_removed": True,
                    "channel_closed": True,
                }
                other = {
                    "seat": seat,
                    "channel": channel,
                    "closed_labels": ["reliable" if channel == "ordered" else channel],
                }
                self.assertTrue(
                    reference.retirement_passed(
                        {"retirement": proof}, {"retirement": other}, channel, seat
                    )
                )
                self.assertTrue(
                    reference.retirement_passed(
                        {"retirement": {**proof, "selected": False}},
                        {"retirement": other},
                        channel,
                        seat,
                        False,
                    )
                )
                for field, value in (
                    ("seat", "wrong"),
                    ("channel", "wrong"),
                    ("selected", False),
                    ("queued", 0),
                    ("queued", True),
                    ("discarded", False),
                    ("peer_removed", False),
                ):
                    with self.subTest(seat=seat, channel=channel, field=field):
                        self.assertFalse(
                            reference.retirement_passed(
                                {"retirement": {**proof, field: value}},
                                {"retirement": other},
                                channel,
                                seat,
                            )
                        )
                for other_field, other_value in (
                    ("seat", "wrong"),
                    ("channel", "wrong"),
                    ("closed_labels", []),
                    ("closed_labels", ["other"]),
                ):
                    self.assertFalse(
                        reference.retirement_passed(
                            {"retirement": proof},
                            {"retirement": {**other, other_field: other_value}},
                            channel,
                            seat,
                        )
                    )
                if seat == "godot":
                    self.assertFalse(
                        reference.retirement_passed(
                            {"retirement": {**proof, "channel_closed": False}},
                            {"retirement": other},
                            channel,
                            seat,
                        )
                    )
        self.assertFalse(reference.retirement_passed({}, {}, "reliable", "godot"))

    def test_godot_close_can_report_a_different_reference_channel_first(self) -> None:
        proof = {
            "seat": "godot",
            "channel": "unreliable",
            "selected": True,
            "queued": 1,
            "discarded": True,
            "peer_removed": True,
            "channel_closed": True,
        }
        other = {"seat": "godot", "channel": "unreliable", "closed_labels": ["reliable"]}
        self.assertTrue(
            reference.retirement_passed(
                {"retirement": proof}, {"retirement": other}, "unreliable", "godot"
            )
        )
        self.assertFalse(
            reference.retirement_passed(
                {"retirement": {**proof, "seat": "reference"}},
                {"retirement": {**other, "seat": "reference"}},
                "unreliable",
                "reference",
            )
        )

    def test_retirement_matrix_keeps_failed_cases_and_runs_the_remaining_cases(self) -> None:
        calls: list[tuple[str, str]] = []
        with tempfile.TemporaryDirectory() as temp:
            output = Path(temp) / "assessment"

            def assess(
                args: argparse.Namespace, directory: Path, *, web: bool
            ) -> dict[str, object]:
                self.assertTrue(web)
                case = (args.closing_seat, args.closing_channel)
                calls.append(case)
                if len(calls) == 3:
                    raise OSError("project preparation failed")
                failed = len(calls) == 2
                report: dict[str, object] = {
                    "assessment_complete": not failed,
                    "gameplay_passed": not failed,
                }
                directory.mkdir(parents=True)
                (directory / "assessment.json").write_text(json.dumps(report))
                if failed:
                    raise RuntimeError("captured incomplete assessment")
                return report

            with (
                patch(
                    "sys.argv",
                    [
                        str(SCRIPT),
                        "--native-extension",
                        temp,
                        "--reference-assets",
                        temp,
                        "--reference-revision",
                        "revision",
                        "--runtime",
                        "web",
                        "--offerer",
                        "reference",
                        "--retirement-matrix",
                        "--output",
                        str(output),
                    ],
                ),
                patch.object(reference, "assess", side_effect=assess),
                patch("builtins.print"),
            ):
                with self.assertRaisesRegex(RuntimeError, "Incomplete reference assessment"):
                    reference.main()
                with self.assertRaisesRegex(FileExistsError, "output already exists"):
                    reference.main()
            self.assertEqual(
                calls,
                [
                    ("godot", "reliable"),
                    ("godot", "ordered"),
                    ("godot", "unreliable"),
                    ("reference", "reliable"),
                    ("reference", "unreliable"),
                ],
            )
            results = json.loads((output / "summary.json").read_text())
            self.assertEqual(len(results), 5)
            self.assertFalse(results[1]["assessment_complete"])
            self.assertIn("project preparation failed", results[2]["driver_error"])
            self.assertEqual(results[2]["closing_channel"], "unreliable")
            self.assertTrue(results[-1]["gameplay_passed"])

    def test_reference_phase_waits_for_engine_startup_without_consuming_its_marker(self) -> None:
        page = Mock()
        markers: list[str] = []
        page.wait_for_timeout.side_effect = lambda _: markers.append("ready-1")
        with patch.object(reference.time, "monotonic", side_effect=[0, 0, 20, 20]):
            elapsed = reference.wait_for_godot_ready(
                cast(Page, page), lambda: "ready-1" in markers, []
            )
        self.assertEqual(elapsed, 20000)
        self.assertEqual(markers, ["ready-1"])
        page.wait_for_timeout.assert_called_once_with(100)
        with (
            patch.object(reference.time, "monotonic", side_effect=[0, 60]),
            self.assertRaisesRegex(TimeoutError, "60-second startup"),
        ):
            reference.wait_for_godot_ready(cast(Page, page), lambda: False, [])
        for error in ("PAGE_ERROR load failed", "SCRIPT ERROR: bad engine"):
            with self.assertRaisesRegex(RuntimeError, "during reference assessment startup"):
                reference.wait_for_godot_ready(cast(Page, page), lambda: True, [error])

    def test_slow_reader_requires_a_real_pause_and_queued_mixed_packets(self) -> None:
        proof = {
            "resumed": True,
            "elapsed_ms": 1500,
            "received": 8,
            "received_at_resume": 8,
            "queued_reliable": 32,
            "queued_unreliable": 8,
        }
        self.assertTrue(reference.slow_receiver_passed(proof, True))
        for field, value in (
            ("resumed", False),
            ("elapsed_ms", 1499),
            ("elapsed_ms", None),
            ("received", 0),
            ("received", 128),
            ("received_at_resume", 9),
            ("queued_reliable", 23),
            ("queued_unreliable", 0),
        ):
            with self.subTest(field=field, value=value):
                self.assertFalse(reference.slow_receiver_passed({**proof, field: value}, True))
        for missing in (None, {}, {"resumed": True}):
            self.assertFalse(reference.slow_receiver_passed(missing, True))
        self.assertTrue(reference.slow_receiver_passed({**proof, "queued_unreliable": 0}, False))

    def test_reference_pause_requires_frozen_consumption_and_new_echoes(self) -> None:
        proof = {
            "resumed": True,
            "elapsed_ms": 1510,
            "received": 8,
            "received_at_resume": 8,
            "queued_snapshots": 32,
            "queued_positions": 8,
            "peak_queued": 40,
            "heartbeat_sent": 3,
            "heartbeat_received": 2,
            "heartbeat_sent_at_resume": 18,
            "heartbeat_received_at_resume": 17,
        }
        phase = {
            "slow_reference_receiver": True,
            "receive_pause": proof,
            "queued_application_packets": 0,
        }
        self.assertTrue(reference.reference_receive_pause_passed(phase, True))
        for field, value in (
            ("resumed", False),
            ("elapsed_ms", 1499),
            ("received", 0),
            ("received_at_resume", 9),
            ("queued_snapshots", 23),
            ("queued_snapshots", 33),
            ("queued_positions", 0),
            ("queued_positions", 33),
            ("peak_queued", 39),
            ("heartbeat_received", 4),
            ("heartbeat_sent", -1),
            ("heartbeat_received_at_resume", 3),
            ("heartbeat_received_at_resume", 19),
            ("heartbeat_sent_at_resume", 129),
            ("elapsed_ms", True),
        ):
            with self.subTest(field=field, value=value):
                self.assertFalse(
                    reference.reference_receive_pause_passed(
                        {**phase, "receive_pause": {**proof, field: value}}, True
                    )
                )
        for field in proof:
            self.assertFalse(
                reference.reference_receive_pause_passed(
                    {**phase, "receive_pause": {k: v for k, v in proof.items() if k != field}}, True
                )
            )
        self.assertFalse(reference.reference_receive_pause_passed(phase, False))
        self.assertFalse(
            reference.reference_receive_pause_passed(
                {**phase, "queued_application_packets": 1}, True
            )
        )
        self.assertFalse(reference.reference_receive_pause_passed({}, True))
        self.assertTrue(
            reference.reference_receive_pause_passed({"slow_reference_receiver": False}, False)
        )

    def test_reference_queued_bytes_and_labels_are_checked_after_resume(self) -> None:
        harness = r"""
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
const source = readFileSync(0, "utf8").split("\n").slice(1).join("\n");
const fault = process.argv[1];
let clock = 1, hooks, fed = false, ready = false;
const context = {
  window: {}, AbortController,
  performance: { now: () => clock },
  console: { log() {}, error() {} },
  setTimeout: (resolve) => setImmediate(() => {
    clock += 20;
    if (!fed && hooks) {
      fed = true;
      for (let i = 0; i < (fault === "overflow" ? 41 : 40); i++) {
        let text = `snapshot:1:godot:${i}:` + "0123456789abcdef".repeat(64);
        if (fault === "bytes" && i === 20) text += "changed";
        hooks.onChannelMessage("godot", "generation", fault === "mode" && i === 20 ? "unreliable" : "reliable", text);
        if (i % 4 === 3) hooks.onChannelMessage("godot", "generation", "unreliable",
          `position:1:godot:${Math.floor(i / 4)}:` + "0123456789abcdef".repeat(4));
      }
    }
    resolve();
  }),
  Engine: class {
    constructor(_native, callbacks) { hooks = callbacks; }
    async pairWith() { return null; }
    channel() { return { readyState: "open", send(text) {
      if (text.startsWith("heartbeat:"))
        queueMicrotask(() => hooks.onChannelMessage("godot", "generation", "reliable", text));
    }}; }
    diagnosticSnapshot() { return {}; }
    removePeer() {}
  },
  fetch: async (_url, options) => ({ ok: true, json: async () => {
    if (options.method === "POST" || ready) return [];
    ready = true;
    return [{ marker: "ready-1" }];
  }}),
};
runInNewContext(source, context);
await context.window.runReference(1, false, true, "webrtc", true);
console.log(JSON.stringify({error:context.window.referenceError, ...context.window.referenceProgress()}));
"""
        source = (SCRIPT.parents[1] / "tests/smoke/webrtc_reference.js").read_text()
        for fault in ("none", "bytes", "mode", "overflow"):
            with self.subTest(fault=fault):
                result = subprocess.run(  # noqa: S603
                    ["node", "--input-type=module", "-e", harness, fault],  # noqa: S607
                    input=source,
                    text=True,
                    capture_output=True,
                    check=True,
                    timeout=5,
                )
                evidence = json.loads(result.stdout)
                proof = evidence["receive_pause"]
                if fault == "overflow":
                    self.assertIn("queue exceeded", evidence["error"])
                    self.assertFalse(proof["resumed"])
                    self.assertLessEqual(evidence["queued_application_packets"], 64)
                else:
                    self.assertTrue(reference.reference_receive_pause_passed(evidence, True))
                    if fault == "none":
                        self.assertEqual(evidence["snapshot_received"], 40)
                        self.assertEqual(evidence["positions_received"], 10)
                        self.assertIn("missing Godot teardown", evidence["error"])
                    else:
                        self.assertEqual(evidence["snapshot_received"], 20)
                        self.assertIn("bytes or", evidence["error"])

    def test_credit_arriving_between_queue_locks_cannot_bypass_the_hold(self) -> None:
        credit = {"marker": "snapshot-ack-1-32"}
        mutex = threading.Lock()

        class ArrivingCredit:
            injected = False

            def __enter__(self) -> None:
                mutex.acquire()

            def __exit__(self, *_args: object) -> None:
                if not self.injected:
                    self.injected = True
                    Handler.queues[0].append(credit)
                    Handler.observation.enqueue(0, credit)
                mutex.release()

        class Handler(reference.CreditDelayRelay):  # type: ignore[name-defined,misc]
            credit_delay_ms = 4000
            credit_seat = 0
            credit_delayed = threading.Event()
            lock = ArrivingCredit()
            queues: ClassVar[list[list[object]]] = [[], []]
            observation = reference.interop.RelayObservation()

        handler = object.__new__(Handler)
        handler.path = "/signal/0"
        handler.command = "GET"
        replies: list[object] = []
        holds: list[float] = []

        def sleep(seconds: float) -> None:
            self.assertTrue(mutex.acquire(blocking=False))
            mutex.release()
            self.assertTrue(Handler.credit_hold_active.is_set())
            holds.append(seconds)

        def reply(_handler: object, body: bytes) -> None:
            messages = json.loads(body)
            if credit in messages:
                self.assertEqual(holds, [4])
                self.assertTrue(Handler.credit_delayed.is_set())
            replies.extend(messages)

        with (
            patch.object(reference.time, "sleep", side_effect=sleep),
            patch.object(reference.interop.RelayHandler, "reply", autospec=True, side_effect=reply),
        ):
            handler.do_GET()
            handler.do_GET()
            Handler.queues[0].append(credit)
            handler.do_GET()
        self.assertEqual(replies, [credit, credit])
        self.assertEqual(holds, [4])
        self.assertFalse(Handler.credit_hold_active.is_set())

    def test_held_signaling_requires_new_gameplay_round_trip(self) -> None:
        before = {
            "phase": 1,
            "signaling_pending": True,
            "heartbeat_sent": 4,
            "heartbeat_received": 4,
            "snapshot_acknowledged": 24,
        }
        during = {**before, "heartbeat_sent": 14, "heartbeat_received": 13}
        proof = {"before": before, "during": during, "elapsed_ms": 1000}
        self.assertTrue(reference.signaling_hold_passed(proof))
        for field, value in (
            ("heartbeat_sent", 4),
            ("heartbeat_received", 4),
            ("heartbeat_received", 15),
            ("heartbeat_received", None),
            ("signaling_pending", False),
            ("phase", 2),
            ("snapshot_acknowledged", 32),
        ):
            with self.subTest(field=field, value=value):
                self.assertFalse(
                    reference.signaling_hold_passed({**proof, "during": {**during, field: value}})
                )
        for invalid in ({}, {"before": before}, {**proof, "elapsed_ms": 999}):
            self.assertFalse(reference.signaling_hold_passed(invalid))

    def test_heartbeat_verdict_requires_exact_echo_totals_on_both_seats(self) -> None:
        for mixed, count in ((False, 0), (True, 12)):
            godot = {"heartbeat_received": count}
            ref = {"heartbeat_sent": count, "heartbeat_received": count}
            self.assertTrue(reference.heartbeat_phase_passed(godot, ref, mixed))
            for changed in (None, count + 1, count - 1, True):
                self.assertFalse(
                    reference.heartbeat_phase_passed({"heartbeat_received": changed}, ref, mixed)
                )
                self.assertFalse(
                    reference.heartbeat_phase_passed(
                        godot, {**ref, "heartbeat_received": changed}, mixed
                    )
                )
        for invalid_count in (0, 129, None, True):
            self.assertFalse(
                reference.heartbeat_phase_passed(
                    {"heartbeat_received": invalid_count},
                    {"heartbeat_sent": invalid_count, "heartbeat_received": invalid_count},
                    True,
                )
            )

    def test_phase_timeout_keeps_its_reason_and_genuine_signaling_errors(self) -> None:
        harness = r"""
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
const source = readFileSync(0, "utf8").split("\n").slice(1).join("\n");
const failure = process.argv[1];
let clock = 0;
const context = {
  window: {}, AbortController, DOMException,
  performance: { now: () => clock },
  console: { log() {}, error() {} },
  setTimeout: (resolve) => setImmediate(() => { clock = 14000; resolve(); }),
  Engine: class {
    channel() { return null; }
    diagnosticSnapshot() { return {}; }
    removePeer() {}
  },
  fetch: (_url, { signal }) => new Promise((_resolve, reject) => {
    if (failure === "relay") reject(new Error("relay GET 503"));
    else if (failure === "external-abort") reject(new DOMException("external cancellation", "AbortError"));
    else signal.addEventListener("abort", () => reject(new DOMException("cleanup cancellation", "AbortError")));
  }),
};
runInNewContext(source, context);
await context.window.runReference(1, false, false, "http");
console.log(JSON.stringify(context.window.referenceError));
"""
        source = (SCRIPT.parents[1] / "tests/smoke/webrtc_reference.js").read_text()
        for case, expected in (
            ("timeout", "Error: phase 1 missing Godot teardown"),
            ("relay", "Error: relay GET 503"),
            ("external-abort", "AbortError: external cancellation"),
        ):
            with self.subTest(case=case):
                result = subprocess.run(  # noqa: S603
                    ["node", "--input-type=module", "-e", harness, case],  # noqa: S607
                    input=source,
                    text=True,
                    capture_output=True,
                    check=True,
                    timeout=5,
                )
                self.assertEqual(json.loads(result.stdout), expected)

    def test_page_listeners_keep_errors_and_crashes(self) -> None:
        page = Mock()
        messages: list[str] = []
        reference.watch_page(cast(Page, page), messages)
        listeners = {call.args[0]: call.args[1] for call in page.on.call_args_list}
        listeners["console"](Mock(type="log", text="ready"))
        listeners["console"](Mock(type="error", text="ICE failed"))
        listeners["pageerror"]("WebAssembly trap")
        listeners["crash"](page)
        self.assertEqual(
            messages,
            ["ready", "CONSOLE_ERROR ICE failed", "PAGE_ERROR WebAssembly trap", "BROWSER_CRASH"],
        )

    def test_observer_installed_before_navigation_keeps_requests_and_stats(self) -> None:
        page = Mock()
        observer = reference.observe_page(cast(Page, page), "http://drill.test")
        listeners = {call.args[0]: call.args[1] for call in page.on.call_args_list}
        request = Mock(url="http://drill.test/signal/1", method="GET")
        listeners["request"](request)
        listeners["requestfailed"](request)
        listeners["console"](Mock(text='WEBRTC_BROWSER_STATS {"peers":[]}'))
        listeners["console"](Mock(text='WEBRTC_INTEROP_PROGRESS {"phase":1}'))
        snapshot = observer.snapshot()
        self.assertEqual(snapshot["failed_requests"], 1)
        self.assertEqual(snapshot["inflight_requests"], [])
        self.assertIsNotNone(snapshot["last_stats_age_ms"])
        self.assertIsNotNone(snapshot["last_progress_age_ms"])
        page.add_init_script.assert_called_once_with(
            path=reference.ROOT / "scripts/webrtc-browser-observation.js"
        )

    def test_delayed_web_completion_waits_for_actual_terminal(self) -> None:
        page = Mock()
        messages: list[str] = []

        def advance(_milliseconds: int) -> None:
            messages.append(
                "WEBRTC_INTEROP_PASS seat=1" if len(messages) == 7 else "engine still running"
            )

        page.wait_for_timeout.side_effect = advance
        self.assertEqual(reference.wait_for_godot(cast(Page, page), messages), "")
        self.assertEqual(page.wait_for_timeout.call_count, 8)

    def test_missing_web_terminal_is_a_driver_timeout(self) -> None:
        with patch.object(reference.time, "monotonic", side_effect=[0, 0, 15]):
            reason = reference.wait_for_godot(cast(Page, Mock()), ["loading"])
        self.assertIn("observation timed out", reason)

    def test_reference_errors_cannot_be_called_unsupported_gameplay(self) -> None:
        for message in (
            "CONSOLE_ERROR browser rejected buffered ICE candidate",
            "PAGE_ERROR module import failed",
            "BROWSER_CRASH",
        ):
            with self.subTest(message=message):
                self.assertTrue(reference.page_failed([message]))
                page = Mock()
                self.assertEqual(reference.wait_for_godot(cast(Page, page), [message]), "")
                page.wait_for_timeout.assert_not_called()
        self.assertFalse(reference.page_failed(["channel closed", "WEBRTC_INTEROP_PASS seat=1"]))

    def test_partial_phase_evidence_survives_truncated_output(self) -> None:
        self.assertEqual(
            reference.phase_evidence(
                'WEBRTC_REFERENCE_PHASE {"phase":1,"received":[]}\n'
                'WEBRTC_REFERENCE_PHASE {"phase":2'
            ),
            [{"phase": 1, "received": []}],
        )


if __name__ == "__main__":
    unittest.main()
