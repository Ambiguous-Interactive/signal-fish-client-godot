"""Reference assessments distinguish unsupported gameplay from incomplete evidence."""

import argparse
import copy
import importlib.util
import io
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
    def test_position_cadence_requires_complete_independent_sends(self) -> None:
        good = {
            "position_interval_ms": 100,
            "positions_sent": 32,
            "position_timings": [
                {
                    "sequence": sequence,
                    "enqueue_ms": 500 + 100 * sequence,
                    "snapshot_sent": 2,
                    "snapshot_acknowledged": 0,
                }
                for sequence in range(32)
            ],
        }
        self.assertTrue(reference.position_schedule_passed(good, 100, True))
        self.assertTrue(reference.position_schedule_passed({}, 0, True))
        for fault in (
            "interval",
            "count",
            "missing",
            "sequence",
            "burst",
            "credit",
            "type",
            "negative",
        ):
            with self.subTest(fault=fault):
                broken = copy.deepcopy(good)
                samples = cast(list[dict[str, object]], broken["position_timings"])
                if fault == "interval":
                    broken["position_interval_ms"] = 0
                elif fault == "count":
                    broken["positions_sent"] = 31
                elif fault == "missing":
                    samples.pop()
                elif fault == "sequence":
                    samples[1]["sequence"] = 0
                elif fault == "burst":
                    samples[1]["enqueue_ms"] = 550
                elif fault == "credit":
                    samples[1]["snapshot_acknowledged"] = 3
                elif fault == "type":
                    samples[1]["sequence"] = True
                elif fault == "negative":
                    samples[0]["enqueue_ms"] = -1
                self.assertFalse(reference.position_schedule_passed(broken, 100, True))
        self.assertFalse(reference.position_schedule_passed(good, 0, True))
        self.assertFalse(reference.position_schedule_passed(good, 100, False))
        args = argparse.Namespace(
            mixed_traffic=True,
            credit_transport="webrtc",
            safe_receive=True,
            position_interval_ms=100,
        )
        self.assertTrue(
            reference.gameplay_phase_checks(good, good, args, 2, True)["position_schedule"]
        )
        self.assertFalse(
            reference.gameplay_phase_checks(good, {}, args, 2, True)["position_schedule"]
        )
        self.assertFalse(
            reference.gameplay_phase_checks({}, good, args, 2, True)["position_schedule"]
        )

    def test_initial_expiry_requires_same_association_message_and_live_evidence(self) -> None:
        identity = {
            "message_id": 33,
            "stream_id": 3,
            "stream_generation": 2,
            "sequence_number": 0,
            "unordered": True,
            "reliability": "lifetime",
            "transmission_selected": False,
        }
        sent: dict[str, object] = {
            "stage": "send",
            "generation": 2,
            "probe_us": 10,
            "marker": "reference:1:unreliable",
            "label": "unreliable",
            "snapshot": {
                "generation": 2,
                "sctp_error": None,
                "sctp": {"last_enqueued_message": identity},
            },
        }
        sampled: dict[str, object] = {
            "stage": "receive",
            "generation": 2,
            "probe_us": 20,
            "snapshot": {
                "generation": 2,
                "sctp_error": None,
                "sctp": {"first_abandoned_message": identity},
            },
        }
        for fault in (
            "none",
            "selected",
            "generation",
            "snapshot_generation",
            "message_id",
            "stream_id",
            "stream_generation",
            "policy",
            "missing",
            "duplicate",
            "before_enqueue",
            "received",
            "boolean_id",
            "sampling_error",
            "overflow",
            "reference_generation",
            "selection_conflict",
        ):
            with self.subTest(fault=fault):
                enqueue, later = copy.deepcopy(sent), copy.deepcopy(sampled)
                samples = [enqueue, later]
                received = ["reliable"]
                later_snapshot = cast(dict[str, object], later["snapshot"])
                later_sctp = cast(dict[str, object], later_snapshot["sctp"])
                abandoned = cast(dict[str, object], later_sctp["first_abandoned_message"])
                if fault == "selected":
                    abandoned["transmission_selected"] = True
                elif fault == "generation":
                    later["generation"] = 3
                elif fault == "snapshot_generation":
                    later_snapshot["generation"] = 3
                elif fault in ("message_id", "stream_id", "stream_generation"):
                    abandoned[fault] = cast(int, abandoned[fault]) + 1
                elif fault == "policy":
                    abandoned["reliability"] = "reliable"
                elif fault == "missing":
                    samples.pop()
                elif fault == "duplicate":
                    samples.append(copy.deepcopy(enqueue))
                elif fault == "before_enqueue":
                    later["probe_us"] = 9
                elif fault == "received":
                    received.append("unreliable")
                elif fault == "boolean_id":
                    enqueue_snapshot = cast(dict[str, object], enqueue["snapshot"])
                    enqueue_sctp = cast(dict[str, object], enqueue_snapshot["sctp"])
                    queued = cast(dict[str, object], enqueue_sctp["last_enqueued_message"])
                    queued["message_id"] = True
                    abandoned["message_id"] = True
                elif fault == "sampling_error":
                    later_snapshot["sctp_error"] = "unavailable"
                if fault == "selection_conflict":
                    conflicting = copy.deepcopy(later)
                    other_snapshot = cast(dict[str, object], conflicting["snapshot"])
                    other_stats = cast(dict[str, object], other_snapshot["sctp"])
                    other_abandoned = cast(
                        dict[str, object], other_stats["first_abandoned_message"]
                    )
                    other_abandoned["transmission_selected"] = True
                    samples.append(conflicting)
                result = reference.initial_probe_diagnostics(
                    {"received": received},
                    {
                        "received": ["reliable", "unreliable"],
                        "snapshot": {"generation": 3 if fault == "reference_generation" else 2},
                    },
                    {"samples": samples, "dropped": 1 if fault == "overflow" else 0},
                    1,
                )
                probe = result["native_to_godot"][1]
                expected = {
                    "none": "expired_before_selection",
                    "selected": "abandoned_after_selection",
                    "received": "conflicting_evidence",
                    "selection_conflict": "conflicting_evidence",
                }.get(fault, "unresolved")
                self.assertEqual(probe["sender_result"], expected)
                self.assertEqual(probe["received"], fault == "received")
                self.assertEqual(result["strict_initial_probes_passed"], fault == "received")
                self.assertEqual(probe["enqueue_observations"], 2 if fault == "duplicate" else 1)
        self.assertFalse(
            reference.initial_probe_diagnostics({}, {}, {}, 1)["strict_initial_probes_passed"]
        )

    def test_probe_diagnostics_keep_completed_receipts_over_earlier_progress(self) -> None:
        labels = ["reliable", "unreliable"]
        report = {
            "godot_phases": [{"phase": 1, "received": labels}],
            "reference": {"phases": [{"phase": 1, "received": labels}]},
            "godot_evidence": {"last_progress": {"phase": 1, "reference": {}}},
        }
        phase = reference.gameplay_diagnostics(report, "")["initial_probe_phases"][0]
        self.assertTrue(phase["strict_initial_probes_passed"])
        self.assertTrue(
            all(p["sender_result"] == "receipt_observed" for p in phase["native_to_godot"])
        )
        unknown = reference.initial_probe_diagnostics({}, {}, {}, 1)
        self.assertTrue(
            all(
                p["received"] is None and p["sender_result"] == "unresolved"
                for p in unknown["native_to_godot"]
            )
        )

    def test_bridge_retains_bounded_sender_boundaries_without_packet_bodies(self) -> None:
        import sys

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            probe = directory / "probe"
            probe.write_text(
                "#!" + sys.executable + "\n"
                "import sys,json\n"
                "for line in sys.stdin:\n"
                " v=json.loads(line)\n"
                " boundary={'generation':2,'sctp':{'messages_abandoned':1}}\n"
                " rows=[{'event':'sent','send_boundary':boundary},"
                "{'event':'binary','receive_boundary':{'snapshot':boundary}},"
                "{'event':'closed','snapshot':boundary}]\n"
                " for i in range(70):\n"
                "  row=rows[i%3] | {'generation':2,'probe_us':i,'label':'unreliable',"
                "'marker':'reference:1:unreliable','text':'opaque-body'}\n"
                "  print(json.dumps(row),flush=True)\n"
                " print(json.dumps({'id':v['id'],'result':None}),flush=True)\n"
            )
            probe.chmod(0o700)
            bridge = reference.native_reference.NativeReference(probe, directory)
            try:
                bridge.command({"op": "snapshot"})
                evidence = bridge.timing_snapshot()["sender_evidence"]
                self.assertEqual(len(evidence["samples"]), 64)
                self.assertEqual(evidence["dropped"], 6)
                self.assertEqual(
                    {s["stage"] for s in evidence["samples"]}, {"send", "receive", "close"}
                )
                self.assertTrue(
                    all(
                        s["generation"] == s["snapshot"]["generation"] == 2
                        for s in evidence["samples"]
                    )
                )
                self.assertEqual([s["line"] for s in evidence["samples"]], list(range(1, 65)))
                self.assertNotIn("opaque-body", json.dumps(evidence))
                self.assertIn(
                    "opaque-body", directory.joinpath("native-reference.jsonl").read_text()
                )
            finally:
                bridge.close()

    def test_bridge_packet_intervals_keep_clocks_and_missing_receipts_separate(self) -> None:
        marker = "heartbeat:1:reference:3"
        records = [
            {
                "stage": "command",
                "id": 7,
                "us": 1000,
                "markers": [{"marker": marker, "label": "reliable"}],
            },
            {"stage": "written", "id": 7, "us": 4000},
            {"stage": "output", "event": "sent", "marker": marker, "probe_us": 9000000, "us": 5000},
            {"stage": "reply", "id": 7, "us": 6000},
            {
                "stage": "output",
                "event": "binary",
                "marker": marker,
                "probe_us": 9100000,
                "us": 7000,
            },
            {
                "stage": "delivery",
                "event": "binary",
                "marker": marker,
                "probe_us": 9100000,
                "us": 19000,
            },
        ]
        for fault in ("none", "missing", "duplicate", "reversed"):
            with self.subTest(fault=fault):
                changed = copy.deepcopy(records)
                if fault == "missing":
                    changed.pop()
                elif fault == "duplicate":
                    changed.append(changed[-2])
                elif fault == "reversed":
                    changed[-1]["us"] = 6500
                result = reference.native_bridge_packet_diagnostics(
                    {"records": changed, "dropped": 2}
                )
                packet = result["packets"][0]
                self.assertEqual(packet["pipe_write_ms"], 3)
                self.assertEqual(packet["command_reply_ms"], 5)
                self.assertEqual(packet["reader_to_delivery_ms"], 12 if fault == "none" else None)
                self.assertEqual(
                    len(packet["native_receive_outputs"]), 2 if fault == "duplicate" else 1
                )
                self.assertEqual(result["trace_overflow"], 2)
        self.assertEqual(reference.native_bridge_packet_diagnostics({})["packets"], [])

    def test_bridge_packet_identity_covers_text_and_binary(self) -> None:
        import base64

        marker = reference.native_reference.packet_marker
        for text in ("heartbeat:1:reference:0:body", "reference:2:unreliable"):
            expected = ":".join(text.split(":")[:4])
            self.assertEqual(marker({"text": text}), expected)
            self.assertEqual(
                marker({"data_base64": base64.b64encode(text.encode()).decode()}), expected
            )
        for value in (
            {"text": "opaque-body"},
            {"data_base64": "%%%"},
            {"text": "heartbeat:3:reference:0:body"},
        ):
            self.assertIsNone(marker(value))

    def test_bridge_batch_retains_packet_identity_through_event_delivery(self) -> None:
        import sys

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            probe = directory / "probe"
            probe.write_text(
                "#!" + sys.executable + "\n"
                "import sys,json,base64\n"
                "for line in sys.stdin:\n"
                " v=json.loads(line)\n"
                " for packet in v['packets']:\n"
                "  text=packet['text']\n"
                "  print(json.dumps({'event':'sent','generation':2,'label':packet['label'],"
                "'marker':':'.join(text.split(':')[:4]),'probe_us':1}),flush=True)\n"
                "  print(json.dumps({'event':'binary','generation':2,'label':packet['label'],"
                "'data_base64':base64.b64encode(text.encode()).decode(),'probe_us':2}),flush=True)\n"
                " print(json.dumps({'id':v['id'],'result':None}),flush=True)\n"
            )
            probe.chmod(0o700)
            bridge = reference.native_reference.NativeReference(probe, directory)
            packets = [
                {"op": "send", "label": "reliable", "text": "heartbeat:1:reference:0:opaque-body"},
                {"op": "send", "label": "unreliable", "text": "reference:1:unreliable"},
            ]
            try:
                bridge.command({"op": "send_batch", "packets": packets})
                self.assertEqual(len(bridge.drain()), 4)
                timing = bridge.timing_snapshot()
                result = reference.native_bridge_packet_diagnostics(timing)
                self.assertEqual(len(result["packets"]), 2)
                for packet, expected in zip(result["packets"], packets, strict=True):
                    self.assertEqual(packet["label"], expected["label"])
                    self.assertEqual(packet["command_id"], 1)
                    self.assertGreaterEqual(packet["pipe_write_ms"], 0)
                    self.assertGreaterEqual(packet["reader_to_delivery_ms"], 0)
                    self.assertEqual(len(packet["native_send_outputs"]), 1)
                    self.assertEqual(len(packet["native_receive_outputs"]), 1)
                    self.assertEqual(len(packet["deliveries"]), 1)
                self.assertNotIn("opaque-body", json.dumps(timing))
            finally:
                bridge.close()

    def test_reference_consumer_drains_in_order_with_an_independent_budget(self) -> None:
        harness = r"""
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
const source = readFileSync(0, "utf8").split("\n").slice(1).join("\n");
const fault = process.argv[1];
let clock = 1, hooks, fed = false, ready = false;
const context = {
  window: {}, AbortController, TextDecoder, TextEncoder,
  performance: { now: () => clock },
  console: { log() {}, error() {} },
  setTimeout: (resolve) => setImmediate(() => {
    clock += 20;
    if (!fed && hooks) {
      fed = true;
      for (let i = 0; i < (fault === "overflow" ? 257 : 12); i++) {
        const text = `snapshot:1:godot:${i}:` + "0123456789abcdef".repeat(64);
        if (i % 2) hooks.onChannelBinaryMessage("godot", "generation",
          fault === "mode" && i === 7 ? "unreliable" : "reliable", new TextEncoder().encode(text));
        else hooks.onChannelMessage("godot", "generation", "reliable",
          fault === "bytes" && i === 6 ? text + "changed" : text);
      }
    }
    resolve();
  }),
  Engine: class {
    constructor(_native, callbacks) { hooks = callbacks; }
    async pairWith() { return null; }
    channel() { return { readyState: "open", send() {} }; }
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
await context.window.runReference(1, false, false, "webrtc", false,
  "reliable", "reference", false, null, false, 1024, 49152, 4, 200);
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
                phase = json.loads(result.stdout)
                schedule = phase["receive_schedule"]
                self.assertEqual(schedule["batch_packets"], 4)
                self.assertEqual(schedule["interval_ms"], 200)
                self.assertEqual(schedule["dropped"], 0)
                self.assertTrue(all(d["reads"] <= 4 for d in schedule["drains"]))
                self.assertTrue(
                    all(
                        b["ms"] - a["ms"] >= 200
                        for a, b in zip(schedule["drains"], schedule["drains"][1:], strict=False)
                    )
                )
                if fault == "overflow":
                    self.assertIn("queue exceeded", phase["error"])
                    self.assertEqual(schedule["peak_queued_packets"], 256)
                elif fault in ("bytes", "mode"):
                    self.assertIn("bytes or", phase["error"])
                    self.assertEqual(phase["snapshot_received"], 6 if fault == "bytes" else 7)
                else:
                    self.assertEqual(phase["snapshot_received"], 12)
                    self.assertEqual(schedule["queued_packets"], 0)
                    self.assertEqual(schedule["queued_bytes"], 0)
                    self.assertEqual(len(phase["receive_timings"]), 12)
                    self.assertEqual(
                        [t["packet"] for t in phase["receive_timings"]],
                        [f"snapshot:1:godot:{i}" for i in range(12)],
                    )
                    self.assertEqual(sum(d["reads"] for d in schedule["drains"]), 12)
                    self.assertTrue(
                        any(
                            t["drain_ms"] - t["callback_ms"] >= 200
                            for t in phase["receive_timings"]
                        )
                    )

    def test_reference_consumer_evidence_requires_complete_drains_and_empty_queue(self) -> None:
        phase: dict[str, object] = {
            "receive_schedule": {
                "batch_packets": 32,
                "interval_ms": 0,
                "dropped": 0,
                "queued_packets": 0,
                "queued_bytes": 0,
                "drains": [{"ms": 20, "reads": 1}],
            },
            "receive_timings_dropped": 0,
            "receive_timings": [{"callback_ms": 10, "drain_ms": 20}],
        }
        self.assertTrue(reference.reference_receive_schedule_passed(phase, 32, 0))
        self.assertTrue(reference.reference_receive_schedule_passed({}, 0, 0))
        schedule_faults: tuple[tuple[str, object], ...] = (
            ("drains", []),
            ("drains", [{"ms": 20, "reads": 33}]),
            ("drains", [{"ms": 20, "reads": 2}]),
            ("dropped", 1),
            ("queued_packets", 1),
            ("queued_bytes", 1),
            ("queued_packets", False),
        )
        for key, value in schedule_faults:
            with self.subTest(key=key, value=value):
                broken = {
                    **phase,
                    "receive_schedule": {
                        **cast(dict[str, object], phase["receive_schedule"]),
                        key: value,
                    },
                }
                self.assertFalse(reference.reference_receive_schedule_passed(broken, 32, 0))
        timing_faults: tuple[tuple[str, object], ...] = (
            ("receive_timings_dropped", 1),
            ("receive_timings_dropped", False),
            ("receive_timings", []),
            ("receive_timings", [None]),
            ("receive_timings", [{"callback_ms": 10, "drain_ms": 20}, None]),
            ("receive_timings", [{"callback_ms": 21, "drain_ms": 20}]),
            ("receive_timings", [{"callback_ms": False, "drain_ms": 20}]),
        )
        for key, value in timing_faults:
            with self.subTest(key=key, value=value):
                self.assertFalse(
                    reference.reference_receive_schedule_passed({**phase, key: value}, 32, 0)
                )
        self.assertFalse(reference.reference_receive_schedule_passed({}, 32, 0))
        args = argparse.Namespace(
            mixed_traffic=True,
            credit_transport="webrtc",
            safe_receive=True,
            reference_receive_batch_packets=32,
            reference_receive_interval_ms=0,
        )
        self.assertFalse(
            reference.gameplay_phase_checks({}, {}, args, 4, True)["reference_receive_schedule"]
        )

    def test_receive_schedule_requires_observed_packet_budget_and_interval(self) -> None:
        schedule = {
            "batch_packets": 4,
            "interval_ms": 200,
            "dropped": 0,
            "drains": [{"ms": 10, "reads": 4}, {"ms": 210, "reads": 0}],
        }
        self.assertTrue(reference.receive_schedule_passed({"receive_schedule": schedule}, 4, 200))
        for field, value in (
            ("batch_packets", 32),
            ("interval_ms", 0),
            ("dropped", 1),
            ("dropped", False),
            ("drains", []),
            ("drains", [{"ms": 10, "reads": 5}]),
            ("drains", [{"ms": 10, "reads": -1}]),
            ("drains", [{"ms": True, "reads": 1}]),
            ("drains", [{"ms": 10, "reads": True}]),
            ("drains", [{"ms": 10, "reads": 4}, {"ms": 209, "reads": 1}]),
            ("drains", [{"ms": 10, "reads": 4}, None]),
        ):
            with self.subTest(field=field, value=value):
                self.assertFalse(
                    reference.receive_schedule_passed(
                        {"receive_schedule": {**schedule, field: value}}, 4, 200
                    )
                )
        self.assertFalse(reference.receive_schedule_passed({}, 4, 200))
        self.assertTrue(reference.receive_schedule_passed({}, 32, 0))
        args = argparse.Namespace(
            mixed_traffic=True,
            credit_transport="webrtc",
            safe_receive=True,
            receive_batch_packets=4,
            receive_interval_ms=200,
        )
        self.assertFalse(reference.gameplay_phase_checks({}, {}, args, 4, True)["receive_schedule"])

    def test_receive_schedule_cli_rejects_invalid_controls_before_preparation(self) -> None:
        base = [
            "check-webrtc-reference.py",
            "--native-extension",
            "/missing",
            "--reference-assets",
            "/missing",
            "--reference-revision",
            "test",
        ]
        for flag, value in (
            ("--receive-batch-packets", "0"),
            ("--receive-batch-packets", "257"),
            ("--receive-interval-ms", "-1"),
            ("--receive-interval-ms", "1001"),
            ("--reference-receive-batch-packets", "-1"),
            ("--reference-receive-batch-packets", "257"),
            ("--reference-receive-interval-ms", "-1"),
            ("--reference-receive-interval-ms", "1001"),
            ("--reference-receive-interval-ms", "100"),
        ):
            with (
                self.subTest(flag=flag, value=value),
                patch("sys.argv", [*base, flag, value]),
                patch("sys.stderr", new_callable=io.StringIO),
                patch.object(reference, "prepare") as prepare,
            ):
                with self.assertRaises(SystemExit) as error:
                    reference.main()
                self.assertEqual(error.exception.code, 2)
                prepare.assert_not_called()

    def test_packet_delivery_keeps_missing_probes_modes_and_duplicate_stages(self) -> None:
        probe = "reference:2:unreliable"
        position = "position:2:reference:0"
        ordered = "ordered:2:reference:1"
        callbacks = [
            {
                "peer": 2,
                "label": "unreliable",
                "dropped": 0,
                "callbacks": [{"packet": position, "ms": 30, "bytes": 90}],
            }
        ]
        godot = {
            "receive_timings_dropped": 0,
            "receive_timings": [
                {"packet": position, "mode": 0, "ms": 90000, "bytes": 90},
                {"packet": ordered, "mode": 2, "bytes": 24},
            ],
        }
        ref = {
            "snapshot": {
                "timings_dropped": 0,
                "native_sent_dropped": 0,
                "packet_timings": [
                    {"marker": probe, "label": "unreliable", "enqueue_ms": 10, "complete_ms": 20}
                ],
                "native_sent": [
                    {"marker": probe, "label": "unreliable", "probe_us": 100},
                    {"marker": ordered, "label": "ordered", "probe_us": 110},
                    {"marker": ordered, "label": "ordered", "probe_us": 120},
                    {"marker": "reference:1:unreliable", "label": "unreliable"},
                ],
            }
        }
        before = copy.deepcopy((godot, ref, callbacks))
        result = reference.packet_delivery_diagnostics(godot, ref, callbacks, 2)
        packets = {row["packet"]: row for row in result["packets"]}
        self.assertEqual(result["sent_not_read"], [probe])
        self.assertEqual(result["callback_not_read"], [])
        self.assertEqual(packets[probe]["unobserved_stages"], ["browser_callback", "script_read"])
        self.assertEqual(packets[probe]["expected_mode"], 0)
        self.assertEqual(packets[ordered]["duplicate_stages"], ["native_send"])
        self.assertEqual(packets[ordered]["metadata_mismatch_stages"], ["script_read"])
        self.assertEqual(packets[position]["metadata_mismatch_stages"], [])
        self.assertNotIn("reference:1:unreliable", packets)
        self.assertEqual((godot, ref, callbacks), before)
        missing = reference.packet_delivery_diagnostics({}, {}, [], 1)
        self.assertEqual(len(missing["packets"]), 2)
        self.assertTrue(all(len(row["unobserved_stages"]) == 4 for row in missing["packets"]))
        self.assertIsNone(missing["trace_overflow"]["native_send"])

    def test_browser_backlog_includes_startup_and_initial_reliable_probe(self) -> None:
        callbacks = [
            {
                "label": "reliable",
                "dropped": 0,
                "callbacks": [
                    {"packet": "startup:1:reference:0", "bytes": 1046, "ms": 10},
                    {"packet": "reference:1:reliable", "bytes": 20, "ms": 11},
                    {"packet": "heartbeat:1:reference:0", "bytes": 90, "ms": 12},
                ],
            }
        ]
        godot = {
            "receive_timings_dropped": 0,
            "receive_timings": [
                {
                    "packet": "heartbeat:1:reference:0",
                    "bytes": 90,
                    "mode": 2,
                    "browser_ms": 20,
                    "echo_browser_ms": 23,
                },
            ],
        }
        result = reference.browser_read_diagnostics(godot, callbacks, 1)
        self.assertEqual(result["peak_tracked_unread_payload_bytes"], 1156)
        self.assertEqual(result["terminal_tracked_unread_payload_bytes"], 1066)
        self.assertEqual(result["heartbeat_echo_latency_ms"]["read_to_echo_ms"]["max_ms"], 3)
        self.assertEqual(result["heartbeat_echo_latency_ms"]["callback_to_echo_ms"]["max_ms"], 11)
        cast(list[dict[str, object]], godot["receive_timings"])[0]["echo_browser_ms"] = 19
        result = reference.browser_read_diagnostics(godot, callbacks, 1)
        self.assertEqual(result["heartbeat_echo_latency_ms"]["read_to_echo_ms"]["count"], 0)
        self.assertEqual(result["heartbeat_echo_latency_ms"]["callback_to_echo_ms"]["count"], 0)

    def test_browser_read_boundary_uses_one_clock_and_keeps_holes(self) -> None:
        def packet(kind: str, sequence: int) -> str:
            return f"{kind}:1:reference:{sequence}"

        callbacks = [
            {
                "label": "reliable",
                "dropped": 0,
                "callbacks": [
                    {"packet": packet("snapshot", 0), "bytes": 4100, "ms": 10},
                    {"packet": packet("snapshot", 1), "bytes": 4100, "ms": 11},
                    {"packet": packet("heartbeat", 0), "bytes": 90, "ms": 12},
                    {"packet": "credit:1:reference:godot:8", "bytes": 28, "ms": 13},
                    {"packet": "snapshot:2:reference:0", "bytes": 4100, "ms": 99},
                ],
            }
        ]
        godot = {
            "receive_timings_dropped": 0,
            "receive_timings": [
                {
                    "packet": packet("snapshot", 0),
                    "bytes": 4100,
                    "mode": 2,
                    "browser_ms": 20,
                    "ms": 1000000,
                },
                {
                    "packet": packet("heartbeat", 0),
                    "bytes": 90,
                    "mode": 2,
                    "browser_ms": 21,
                    "ms": 1000001,
                },
                {"packet": "credit:1:reference:godot:8", "bytes": 28, "mode": 2, "browser_ms": 22},
            ],
        }
        before = copy.deepcopy((godot, callbacks))
        result = reference.browser_read_diagnostics(godot, callbacks, 1)
        self.assertTrue(result["available"])
        self.assertEqual(result["unread_packets"], [packet("snapshot", 1)])
        self.assertEqual(result["peak_tracked_unread_payload_bytes"], 8318)
        self.assertEqual(result["terminal_tracked_unread_payload_bytes"], 4100)
        self.assertEqual(result["latency_ms"]["snapshot"]["max_ms"], 10)
        self.assertEqual(result["latency_ms"]["heartbeat"]["max_ms"], 9)
        self.assertEqual(result["latency_ms"]["credit"]["max_ms"], 9)
        self.assertEqual(result["invalid_intervals"], [])
        self.assertEqual((godot, callbacks), before)
        drops = {
            "records": [
                {"ms": 9, "preceding_callback": {"packet": "snapshot:2:reference:0"}},
                {"ms": 12, "preceding_callback": {"packet": packet("snapshot", 1)}},
            ],
            "dropped": 0,
        }
        result = reference.browser_read_diagnostics(godot, callbacks, 1, drops)
        self.assertEqual(result["first_tracked_buffer_drop"]["ms"], 12)
        self.assertEqual(result["tracked_unread_payload_bytes_at_first_drop"], 8290)
        self.assertEqual(result["terminal_tracked_unread_payload_bytes"], 4100)
        pause = {
            "heartbeat_sent": 0,
            "heartbeat_received": 0,
            "heartbeat_sent_at_resume": 1,
            "heartbeat_received_at_resume": 1,
        }
        result = reference.browser_read_diagnostics(godot, callbacks, 1, drops, pause)
        cohort = result["pause_heartbeats"]
        self.assertEqual(cohort["new_echoes_at_resume"], 1)
        self.assertEqual(
            cohort["intervals_ms"]["sent_during_pause"]["callback_to_read_ms"]["max_ms"], 9
        )

    def test_browser_read_boundary_keeps_incomplete_evidence_explicit(self) -> None:
        self.assertFalse(reference.browser_read_diagnostics({}, [], 1)["available"])
        marker = "heartbeat:1:reference:0"
        for row in (
            {"bytes": 90},
            {"bytes": 90, "mode": 2, "browser_ms": 9},
            {"bytes": 91, "mode": 2, "browser_ms": 11},
            {"bytes": 90, "mode": 2, "browser_ms": float("nan")},
            {"bytes": 90, "mode": 2, "browser_ms": True},
        ):
            with self.subTest(row=row):
                result = reference.browser_read_diagnostics(
                    {
                        "receive_timings_dropped": 3,
                        "receive_timings": [{"packet": marker, "mode": 2, **row}],
                    },
                    [
                        {
                            "label": "reliable",
                            "dropped": 5,
                            "callbacks": [
                                {"packet": marker, "bytes": 90, "ms": 10},
                            ],
                        }
                    ],
                    1,
                )
                self.assertEqual(result["invalid_intervals"], [marker])
                self.assertEqual(result["latency_ms"]["heartbeat"]["count"], 0)
                self.assertEqual(result["callback_trace_dropped"], 5)
                self.assertEqual(result["script_trace_dropped"], 3)
                self.assertIsNone(result["peak_tracked_unread_payload_bytes"])

    def test_browser_read_boundary_rejects_ambiguous_or_incomplete_traces(self) -> None:
        marker = "snapshot:1:reference:0"
        callback = {"packet": marker, "bytes": 4100, "ms": 10}
        read = {"packet": marker, "bytes": 4100, "mode": 2, "browser_ms": 20}
        for label, rows, reads, dropped in (
            ("unreliable", [callback], [read], 0),
            ("reliable", [callback, callback], [read], 0),
            ("reliable", [callback], [read, read], 0),
            ("reliable", [callback], [{**read, "mode": 0}], 0),
            ("reliable", [callback], [read], None),
            ("reliable", [], [read], 0),
        ):
            with self.subTest(label=label, callbacks=len(rows), reads=reads, dropped=dropped):
                result = reference.browser_read_diagnostics(
                    {"receive_timings_dropped": 0, "receive_timings": reads},
                    [{"label": label, "dropped": dropped, "callbacks": rows}],
                    1,
                )
                self.assertIsNone(result["peak_tracked_unread_payload_bytes"])
                self.assertIsNone(result["terminal_tracked_unread_payload_bytes"])
                if not rows:
                    self.assertEqual(result["unmatched_script_packets"], [marker])
                elif dropped is not None:
                    self.assertEqual(result["invalid_intervals"], [marker])

    def test_snapshot_boundary_retains_callback_and_read_hole(self) -> None:
        callbacks = [
            {
                "callbacks": [
                    {"packet": f"snapshot:1:reference:{sequence}", "bytes": 4120}
                    for sequence in range(5)
                ],
                "dropped": 0,
            }
        ]
        godot = {
            "snapshot_received": 2,
            "receive_timings_dropped": 0,
            "receive_timings": [
                {"packet": f"snapshot:1:reference:{sequence}", "bytes": 4120}
                for sequence in (0, 1, 4)
            ],
        }
        before = copy.deepcopy((godot, callbacks))
        result = reference.snapshot_receive_diagnostics(godot, callbacks, 1)
        self.assertEqual(result["callback_not_read_sequences"], [2, 3])
        self.assertEqual(result["first_read_after_gap"], 4)
        self.assertEqual(result["browser_callback_snapshot_bytes"], 20600)
        self.assertEqual(result["script_read_snapshot_bytes"], 12360)
        self.assertEqual((godot, callbacks), before)
        self.assertEqual(
            reference.snapshot_receive_diagnostics(godot, callbacks, 2)[
                "browser_callback_sequences"
            ],
            [],
        )

    def test_snapshot_boundary_keeps_missing_or_truncated_evidence_explicit(self) -> None:
        result = reference.snapshot_receive_diagnostics({}, [], 1)
        self.assertIsNone(result["first_callback_not_read"])
        self.assertIsNone(result["first_read_after_gap"])
        self.assertIsNone(result["script_trace_dropped"])
        result = reference.snapshot_receive_diagnostics(
            {"receive_timings_dropped": 3},
            [
                {
                    "dropped": 5,
                    "callbacks": [
                        {"packet": "snapshot:1:reference:128"},
                        {"packet": "snapshot:1:reference:-1"},
                        {"packet": "snapshot:1:reference:²"},
                        {"packet": "heartbeat:1:reference:0"},
                    ],
                }
            ],
            1,
        )
        self.assertEqual(result["browser_callback_sequences"], [])
        self.assertEqual(result["callback_trace_dropped"], 5)
        self.assertEqual(result["script_trace_dropped"], 3)

    def test_failure_summary_retains_local_drops_and_exact_failure(self) -> None:
        failure = {
            "phase": 1,
            "reason": "reference snapshot differs: expected_sequence=23 received_sequence=40 bytes=4120 mode=2",
            "reference": {
                "snapshot_received": 23,
                "channel_in_buffer_kb": 64,
                "channel_queues": [{"label": "reliable", "available_packets": 5}],
            },
        }
        report = {
            "godot_evidence": {"diagnostic": failure, "last_stage": "reference observation"},
            "reference": {"error": "channel closed"},
            "driver_error": "",
            "assessment_complete": False,
        }
        before = copy.deepcopy(report)
        result = reference.gameplay_diagnostics(report, "Buffer full! Dropping data.\n" * 17)
        self.assertEqual(result["godot_buffer_drop_messages"], 17)
        self.assertEqual(result["godot_failure"]["reason"], failure["reason"])
        self.assertEqual(result["godot_queue"]["snapshot_received"], 23)
        self.assertEqual(result["godot_queue"]["channel_in_buffer_kb"], 64)
        self.assertEqual(report, before)

    def test_heartbeat_summary_joins_each_phase_without_crossing_clocks(self) -> None:
        snapshot = {
            "packet_timings": [
                {
                    "marker": "heartbeat:1:reference:0",
                    "enqueue_ms": 100,
                    "dispatch_ms": 300,
                    "complete_ms": 350,
                },
                {
                    "marker": "heartbeat:2:reference:0",
                    "enqueue_ms": 1,
                    "dispatch_ms": 2,
                    "complete_ms": 3,
                },
            ],
            "native_sent": [
                {"marker": "heartbeat:1:reference:0", "probe_us": 10000, "callback_ms": 355}
            ],
            "native_heartbeat_received": [
                {
                    "marker": "heartbeat:1:reference:0",
                    "probe_us": 14000,
                    "received_us": 11000,
                    "callback_ms": 365,
                }
            ],
            "timings_dropped": 0,
            "native_sent_dropped": 0,
            "native_heartbeat_received_dropped": 0,
        }
        phase = {
            "phase": 1,
            "heartbeat_sent": 2,
            "heartbeat_received": 1,
            "heartbeat_timings": [
                {"sequence": 0, "enqueue_ms": 90, "echo_ms": 370},
                {"sequence": 1, "enqueue_ms": 380},
            ],
            "snapshot": snapshot,
            "receive_timings": [
                {
                    "packet": "heartbeat:1:reference:0",
                    "callback_ms": 1000365,
                    "drain_ms": 1000430,
                },
                {"packet": "heartbeat:2:reference:0", "callback_ms": 2, "drain_ms": 3},
            ],
        }
        result = reference.heartbeat_diagnostics(
            {"heartbeat_timings": [{"sequence": 0, "receive_ms": 900000, "echo_ms": 900001}]}, phase
        )
        self.assertEqual(result["matched_samples"]["native_rtt_ms"], 1)
        self.assertEqual(result["max_ms"]["native_rtt_ms"], 4)
        self.assertEqual(result["max_ms"]["native_channel_rtt_ms"], 1)
        self.assertEqual(result["max_ms"]["native_event_queue_ms"], 3)
        self.assertIsNone(result["packets"][1]["native_event_queue_ms"])
        self.assertEqual(result["max_ms"]["bridge_queue_ms"], 200)
        self.assertEqual(result["max_ms"]["application_rtt_ms"], 280)
        self.assertEqual(result["max_ms"]["godot_echo_ms"], 1)
        self.assertEqual(result["max_ms"]["reference_consumer_ms"], 65)
        self.assertIsNone(result["packets"][1]["reference_consumer_ms"])
        self.assertEqual(result["packets"][1]["native_rtt_ms"], None)
        self.assertEqual(result["packets"][1]["application_rtt_ms"], None)

    def test_heartbeat_pause_separates_old_backlog_from_new_round_trips(self) -> None:
        pause = {
            "heartbeat_sent": 2,
            "heartbeat_received": 0,
            "heartbeat_sent_at_resume": 15,
            "heartbeat_received_at_resume": 2,
        }
        phase = {
            "phase": 1,
            "receive_pause": pause,
            "heartbeat_timings": [
                {"sequence": 0, "enqueue_ms": 0, "echo_ms": 1520},
                {"sequence": 1, "enqueue_ms": 100, "echo_ms": 1520},
                {"sequence": 2, "enqueue_ms": 200, "echo_ms": 1600},
                {"sequence": 3, "enqueue_ms": 300},
            ],
            "snapshot": {
                "packet_timings": [
                    {
                        "marker": "heartbeat:1:reference:2",
                        "enqueue_ms": 100000,
                        "dispatch_ms": 101300,
                        "complete_ms": 101320,
                    }
                ]
            },
        }
        before = copy.deepcopy(phase)
        result = reference.heartbeat_diagnostics({}, phase)
        proof = result["pause_heartbeats"]
        self.assertEqual(proof["pre_pause_backlog"], 2)
        self.assertEqual(proof["pre_pause_backlog_remaining_at_resume"], 0)
        self.assertEqual(proof["sent_during_pause"], 13)
        self.assertEqual(proof["new_echoes_at_resume"], 0)
        self.assertEqual(proof["new_echo_sequences_at_resume"], [])
        # Later final echoes do not establish an echo during the pause.
        self.assertEqual(
            proof["intervals_ms"]["sent_during_pause"]["application_rtt_ms"]["count"], 1
        )
        self.assertEqual(
            result["intervals_ms"]["bridge_queue_ms"],
            {
                "count": 1,
                "min_ms": 1300,
                "p50_ms": 1300,
                "p95_ms": 1300,
                "max_ms": 1300,
                "max_sequence": 2,
            },
        )
        packet = result["packets"][2]
        self.assertIn("bridge_dispatch", packet["observed_stages"])
        self.assertIn("native_send", packet["unobserved_stages"])
        self.assertIn("godot_receive", packet["unobserved_stages"])
        self.assertEqual(phase, before)
        pause["heartbeat_received_at_resume"] = 4
        proof = reference.heartbeat_diagnostics({}, phase)["pause_heartbeats"]
        self.assertEqual(proof["new_echoes_at_resume"], 2)
        self.assertEqual(proof["new_echo_sequences_at_resume"], [2, 3])

    def test_heartbeat_distributions_keep_nearest_rank_and_missing_samples(self) -> None:
        rows: list[dict[str, object]] = [
            {"sequence": index, "duration": index} for index in range(20)
        ]
        rows.append({"sequence": 20, "duration": None})
        self.assertEqual(
            reference.timing_distribution(rows, "duration"),
            {
                "count": 20,
                "min_ms": 0,
                "p50_ms": 9,
                "p95_ms": 18,
                "max_ms": 19,
                "max_sequence": 19,
            },
        )
        empty = reference.timing_distribution([], "duration")
        self.assertEqual(empty["count"], 0)
        for key in ("min_ms", "p50_ms", "p95_ms", "max_ms", "max_sequence"):
            self.assertIsNone(empty[key])
        for pause in (
            {},
            {
                "heartbeat_sent": True,
                "heartbeat_received": 0,
                "heartbeat_sent_at_resume": 3,
                "heartbeat_received_at_resume": 1,
            },
            {
                "heartbeat_sent": 3,
                "heartbeat_received": 4,
                "heartbeat_sent_at_resume": 5,
                "heartbeat_received_at_resume": 4,
            },
            {
                "heartbeat_sent": 2,
                "heartbeat_received": 0,
                "heartbeat_sent_at_resume": 3,
                "heartbeat_received_at_resume": 4,
            },
            {
                "heartbeat_sent": 2,
                "heartbeat_received": 1,
                "heartbeat_sent_at_resume": 3,
                "heartbeat_received_at_resume": 0,
            },
        ):
            with self.subTest(pause=pause):
                self.assertIsNone(reference.heartbeat_pause_diagnostics([], pause, ("duration",)))

    def test_incomplete_run_uses_terminal_phase_and_failure_echoes(self) -> None:
        phase = {
            "phase": 1,
            "heartbeat_sent": 1,
            "heartbeat_received": 0,
            "heartbeat_timings": [{"sequence": 0, "enqueue_ms": 7}],
        }
        report = {
            "reference": {"phases": []},
            "reference_terminal": phase,
            "godot_evidence": {
                "diagnostic": {
                    "phase": 1,
                    "reference": {
                        "heartbeat_timings": [{"sequence": 0, "receive_ms": 100, "echo_ms": 103}]
                    },
                }
            },
        }
        result = reference.gameplay_diagnostics(report, "")
        self.assertEqual(result["heartbeat_phases"][0]["max_ms"]["godot_echo_ms"], 3)
        self.assertIsNone(result["heartbeat_phases"][0]["max_ms"]["native_rtt_ms"])
        report["reference"] = {"phases": [phase]}
        self.assertEqual(len(reference.gameplay_diagnostics(report, "")["heartbeat_phases"]), 1)
        self.assertEqual(reference.gameplay_diagnostics({}, "")["heartbeat_phases"], [])

    def test_timing_summary_keeps_invalid_or_missing_samples_unknown(self) -> None:
        for start, end in (
            (None, 1),
            (True, 2),
            (1, False),
            (4, 3),
            (0, float("nan")),
            (0, float("inf")),
        ):
            with self.subTest(start=start, end=end):
                self.assertIsNone(reference.diagnostic_interval(start, end))
        self.assertEqual(reference.diagnostic_interval(0, 0), 0)
        phase = {
            "phase": 1,
            "heartbeat_timings": [{"sequence": 0}],
            "snapshot": {"timings_dropped": 4},
        }
        result = reference.heartbeat_diagnostics({}, phase)
        self.assertEqual(result["trace_overflow"]["timings_dropped"], 4)
        self.assertIsNone(result["max_ms"]["bridge_queue_ms"])

    def test_fetch_control_requires_the_observed_http_backend(self) -> None:
        args = argparse.Namespace(
            mixed_traffic=True, credit_transport="http", safe_receive=True, web_http_fetch=True
        )
        for web in (False, True):
            for observed in (None, False, True, 1, 0):
                with self.subTest(web=web, observed=observed):
                    checks = reference.gameplay_phase_checks(
                        {"web_http_fetch": observed}, {}, args, 24, True, web=web
                    )
                    self.assertEqual(checks["http_backend"], observed is web)

    def test_named_checks_report_late_failures_after_gameplay_failure(self) -> None:
        args = argparse.Namespace(mixed_traffic=True, credit_transport="webrtc", safe_receive=True)
        checks = reference.gameplay_phase_checks({}, {}, args, 24, True)
        self.assertFalse(checks["godot_gameplay"])
        self.assertFalse(checks["reference_gameplay"])
        self.assertFalse(checks["heartbeat_totals"])
        self.assertFalse(checks["retirement"])
        self.assertFalse(checks["receiver_identity"])
        self.assertFalse(all(checks.values()))

    def test_observation_timeout_retains_last_progress_without_inventing_failure(self) -> None:
        queue = {
            "snapshot_acknowledged": 56,
            "credit_wait_age_ms": 890,
            "startup_sent": 32,
            "startup_received": 32,
            "startup_credit": True,
            "startup_acknowledged": 0,
            "snapshot_startup_credit": -1,
        }
        report = {
            "driver_error": "TimeoutError: reference completion",
            "godot_evidence": {
                "last_progress": {
                    "phase": 1,
                    "max_stage_frame_gap_ms": 107,
                    "reference": queue,
                }
            },
        }
        result = reference.gameplay_diagnostics(report, "")
        self.assertIsNone(result["godot_failure"]["reason"])
        self.assertEqual(result["godot_progress"]["max_stage_frame_gap_ms"], 107)
        self.assertEqual(result["godot_queue"]["snapshot_acknowledged"], 56)
        for key, value in queue.items():
            self.assertEqual(result["godot_queue"][key], value)
        self.assertEqual(result["driver_error"], report["driver_error"])

    def test_snapshot_cli_rejects_sizes_that_cannot_return_credit(self) -> None:
        base = [
            "check-webrtc-reference.py",
            "--native-extension",
            "/missing",
            "--reference-assets",
            "/missing",
            "--reference-revision",
            "test",
        ]
        for arguments in (
            ["--snapshot-body-bytes", "0"],
            ["--snapshot-body-bytes", "17"],
            ["--snapshot-body-bytes", "16400"],
            ["--snapshot-window-bytes", "-1"],
            ["--snapshot-body-bytes", "4096", "--snapshot-window-bytes", "4127"],
        ):
            with (
                self.subTest(arguments=arguments),
                patch("sys.argv", base + arguments),
                patch("sys.stderr", new_callable=io.StringIO),
                patch.object(reference, "assess") as assess,
            ):
                with self.assertRaises(SystemExit) as error:
                    reference.main()
                self.assertEqual(error.exception.code, 2)
                assess.assert_not_called()

    def test_snapshot_cli_accepts_windows_below_eight_chunks(self) -> None:
        for capacity in (None, 0, 4128, 8256, 16512, 28896, 33024):
            with (
                self.subTest(capacity=capacity),
                tempfile.TemporaryDirectory() as folder,
                patch(
                    "sys.argv",
                    [
                        "check-webrtc-reference.py",
                        "--native-extension",
                        "/missing",
                        "--reference-assets",
                        "/missing",
                        "--reference-revision",
                        "test",
                        "--runtime",
                        "web",
                        "--offerer",
                        "reference",
                        "--output",
                        folder,
                        "--snapshot-body-bytes",
                        "4096",
                        *(
                            ["--snapshot-window-bytes", str(capacity)]
                            if capacity is not None
                            else []
                        ),
                    ],
                ),
                patch.object(
                    reference, "assess", return_value={"assessment_complete": True}
                ) as assess,
                patch("builtins.print"),
            ):
                reference.main()
                self.assertEqual(assess.call_count, 1)
                self.assertEqual(
                    assess.call_args.args[0].snapshot_window_bytes,
                    49152 if capacity is None else capacity,
                )

    def test_byte_window_requires_matched_workload_and_complete_credit(self) -> None:
        phase = {
            "snapshot_body_bytes": 4096,
            "snapshot_window_bytes": 49152,
            "outstanding_snapshot_bytes": 0,
            "peak_outstanding_snapshot_bytes": 45000,
        }
        self.assertTrue(reference.snapshot_flow_passed(phase, 4096, 49152))
        self.assertFalse(reference.snapshot_flow_passed(phase, 1024, 49152))
        self.assertFalse(reference.snapshot_flow_passed(phase, 4096, 0))
        for field, values in {
            "snapshot_body_bytes": [None, True, 4096.0, 1024],
            "snapshot_window_bytes": [None, True, 49152.0, 0],
            "outstanding_snapshot_bytes": [None, False, 0.0, -1, 1],
            "peak_outstanding_snapshot_bytes": [None, True, 45000.0, 0, 4096, 49153],
        }.items():
            for value in values:
                with self.subTest(field=field, value=value):
                    self.assertFalse(
                        reference.snapshot_flow_passed({**phase, field: value}, 4096, 49152)
                    )
            missing = dict(phase)
            del missing[field]
            self.assertFalse(reference.snapshot_flow_passed(missing, 4096, 49152))

    def test_partial_transfer_must_fit_byte_window_and_return_all_credit(self) -> None:
        phase = {
            "partial_acknowledged": 4,
            "outstanding_partial_bytes": 0,
            "peak_outstanding_partial_bytes": 32810,
        }
        self.assertTrue(reference.partial_flow_passed(phase, 16384, 49152))
        for key, values in {
            "partial_acknowledged": [None, True, 4.0, 3, 5],
            "outstanding_partial_bytes": [None, False, 0.0, -1, 1],
            "peak_outstanding_partial_bytes": [None, True, 32810.0, 16384, 49153],
        }.items():
            for value in values:
                with self.subTest(key=key, value=value):
                    self.assertFalse(
                        reference.partial_flow_passed({**phase, key: value}, 16384, 49152)
                    )
        self.assertFalse(reference.partial_flow_passed({}, 16384, 49152))

    def test_reference_partial_sender_waits_for_consumption_credit(self) -> None:
        harness = r"""
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
const source = readFileSync(0, "utf8").split("\n").slice(1).join("\n");
const fault = process.argv[1];
let clock = 1, hooks, ready = false, fed = false;
const pending = [];
const context = {
  window: {}, AbortController,
  performance: { now: () => clock },
  console: { log() {}, error() {} },
  setTimeout: (resolve) => setImmediate(() => {
    clock += 20;
    if (hooks && !fed) {
      fed = true;
      for (let i = 0; i < 128; i++)
        hooks.onChannelMessage("godot", "generation", "reliable",
          `snapshot:1:godot:${i}:` + "0123456789abcdef".repeat(1024));
    }
    while (pending.length && pending[0].at <= clock) {
      const {count} = pending.shift();
      if (fault === "missing") continue;
      hooks.onChannelMessage("godot", "generation", fault === "mode" ? "unreliable" : "reliable",
        `partial-credit:1:godot:reference:${fault === "future" ? 5 : count}`);
      if (fault === "duplicate")
        hooks.onChannelMessage("godot", "generation", "reliable",
          `partial-credit:1:godot:reference:${count}`);
    }
    resolve();
  }),
  Engine: class {
    constructor(_native, callbacks) { hooks = callbacks; }
    async pairWith() { return null; }
    channel() { return { readyState: "open", send(text) {
      const sequence = Number(text.split(":")[3]);
      if (text.startsWith("snapshot:") && (sequence + 1) % (fault === "unpaced" ? 8 : 2) === 0)
        queueMicrotask(() => hooks.onChannelMessage("godot", "generation", "reliable",
          `credit:1:godot:reference:${sequence + 1}`));
      if (text.startsWith("partial:"))
        pending.push({at: clock + 200, count: sequence + 1});
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
await context.window.runReference(1, false, false, "webrtc", false,
  "reliable", "reference", false, null, false, 16384, fault === "unpaced" ? 0 : 49152);
console.log(JSON.stringify({error: context.window.referenceError, ...context.window.referenceProgress()}));
"""
        source = (SCRIPT.parents[1] / "tests/smoke/webrtc_reference.js").read_text()
        for fault in ("none", "unpaced", "duplicate", "future", "mode", "missing"):
            with self.subTest(fault=fault):
                result = subprocess.run(  # noqa: S603
                    ["node", "--input-type=module", "-e", harness, fault],  # noqa: S607
                    input=source,
                    text=True,
                    capture_output=True,
                    check=True,
                    timeout=5,
                )
                phase = json.loads(result.stdout)
                if fault in ("duplicate", "future", "mode"):
                    self.assertIn("partial consumption credit differs", phase["error"])
                elif fault == "missing":
                    self.assertEqual(phase["partial_sent"], 2)
                    self.assertEqual(phase["partial_acknowledged"], 0)
                    self.assertGreater(phase["outstanding_partial_bytes"], 0)
                    self.assertGreater(phase["partial_credit_wait_age_ms"], 1000)
                    self.assertLessEqual(phase["peak_outstanding_partial_bytes"], 49152)
                else:
                    self.assertEqual(phase["partial_sent"], 4)
                    self.assertEqual(phase["partial_acknowledged"], 4)
                    self.assertEqual(phase["outstanding_partial_bytes"], 0)
                    self.assertEqual(
                        phase["peak_outstanding_partial_bytes"] > 49152, fault == "unpaced"
                    )

    def test_binary_evidence_requires_exact_reliable_and_distinct_mode_receipts(self) -> None:
        phase = {
            "binary_traffic": True,
            "binary_sent": [8, 8, 8],
            "binary_sequences": [list(range(8)), [0, 3, 7], [7, 2]],
        }
        self.assertTrue(reference.binary_phase_passed(phase, True))
        self.assertFalse(reference.binary_phase_passed(phase, False))
        for index, sequences in (
            (0, list(range(1, 8))),
            (0, [0, 1]),
            (1, []),
            (1, [0]),
            (2, [0]),
            (1, [2, 1]),
            (2, [1, 1]),
            (2, [True]),
            (2, [0, 1.0]),
            (2, [8]),
        ):
            with self.subTest(index=index, sequences=sequences):
                broken = copy.deepcopy(phase)
                cast(list[list[object]], broken["binary_sequences"])[index] = cast(
                    list[object], sequences
                )
                self.assertFalse(reference.binary_phase_passed(broken, True))
        for counts in (
            [],
            [8, 8],
            [8, 8, 8, 8],
            [True, 8, 8],
            [8, True, 8],
            [8, 8, True],
            [8.0, 8, 8],
            [8, 8.0, 8],
            [8, 8, 8.0],
            [8, 7, 8],
            [8, 8, 9],
        ):
            with self.subTest(sent=counts):
                self.assertFalse(
                    reference.binary_phase_passed({**phase, "binary_sent": counts}, True)
                )
        receipt_cases: tuple[list[list[int]], ...] = (
            [list(range(8)), [0], [0]],
            [list(range(8)), [], []],
            [[], [], []],
        )
        for receipts in receipt_cases:
            with self.subTest(receipts=receipts):
                self.assertFalse(
                    reference.binary_phase_passed({**phase, "binary_sequences": receipts}, True)
                )
        self.assertTrue(
            reference.binary_phase_passed(
                {**phase, "binary_sequences": [list(range(8)), [7], [3]]}, True
            )
        )
        for field in phase:
            broken = copy.deepcopy(phase)
            del broken[field]
            self.assertFalse(reference.binary_phase_passed(broken, True))
        self.assertFalse(reference.binary_phase_passed({}, True))
        self.assertTrue(reference.binary_phase_passed({}, False))

    def test_startup_proof_requires_every_packet_from_each_seat(self) -> None:
        good = {"startup_burst": True, "startup_sent": 32, "startup_received": 32}
        self.assertTrue(reference.startup_phase_passed(good, good, True))
        self.assertTrue(reference.startup_phase_passed({}, {}, False))
        for field in good:
            for value in (None, False, True, 0, 31, 33, 32.0):
                if field == "startup_burst" and value is True:
                    continue
                broken = {**good, field: value}
                self.assertFalse(reference.startup_phase_passed(broken, good, True))
                self.assertFalse(reference.startup_phase_passed(good, broken, True))
            broken = dict(good)
            del broken[field]
            self.assertFalse(reference.startup_phase_passed(broken, good, True))
        self.assertFalse(reference.startup_phase_passed(good, good, False))

    def test_paced_startup_requires_consumption_credit_before_first_snapshot(self) -> None:
        good = {
            "startup_burst": True,
            "startup_sent": 32,
            "startup_received": 32,
            "startup_credit": True,
            "startup_acknowledged": 32,
            "snapshot_startup_credit": 32,
        }
        self.assertTrue(reference.startup_phase_passed(good, good, True, 49152))
        self.assertFalse(reference.startup_phase_passed(good, good, True, 0))
        for field in ("startup_credit", "startup_acknowledged", "snapshot_startup_credit"):
            for value in (None, False, 0, 31, 33, 32.0):
                broken = {**good, field: value}
                self.assertFalse(reference.startup_phase_passed(broken, good, True, 49152))
                self.assertFalse(reference.startup_phase_passed(good, broken, True, 49152))
            broken = dict(good)
            del broken[field]
            self.assertFalse(reference.startup_phase_passed(broken, good, True, 49152))

    def test_inbound_empty_control_keeps_godot_sends_nonempty(self) -> None:
        payloads = reference.binary_payloads(receive_empty=True)
        for phase in payloads.values():
            for sender, modes in phase.items():
                for packets in modes:
                    self.assertEqual(packets[0] == [], sender == "reference")
                    self.assertTrue(all(packets[1:]))
        good = {
            "binary_traffic": True,
            "binary_sent": [8, 8, 8],
            "binary_sequences": [list(range(8)), [0, 2], [7, 0]],
        }
        self.assertTrue(reference.binary_phase_passed(good, True, require_empty=True))
        for mode in (1, 2):
            broken = copy.deepcopy(good)
            cast(list[list[int]], broken["binary_sequences"])[mode].remove(0)
            self.assertTrue(reference.binary_phase_passed(broken, True))
            self.assertFalse(reference.binary_phase_passed(broken, True, require_empty=True))

    def test_binary_vectors_keep_wire_bytes_and_mode_generation_identity(self) -> None:
        payloads = reference.binary_payloads()
        self.assertEqual(set(payloads), {"1", "2"})
        nonempty: list[bytes] = []
        for phase in payloads.values():
            for modes in phase.values():
                self.assertEqual(len(modes), 3)
                for packets in modes:
                    self.assertEqual(len(packets), 8)
                    self.assertTrue(packets[0])
                    self.assertIn(0, packets[2])
                    self.assertEqual(packets[3][-256:], list(range(256)))
                    self.assertEqual(packets[4][-4:], [255, 254, 192, 128])
                    for data in packets[4:]:
                        with self.assertRaises(UnicodeDecodeError):
                            bytes(data).decode("utf-8")
                    nonempty.extend(bytes(data) for data in packets[1:])
        self.assertEqual(len(nonempty), len(set(nonempty)))
        for phase in reference.binary_payloads(empty=True).values():
            for modes in phase.values():
                self.assertTrue(all(packets[0] == [] for packets in modes))

    def test_native_profile_checks_finite_properties_and_fresh_generation(self) -> None:
        channels = {
            label: {
                "internal_id": index,
                "negotiated": True,
                "ordered": label != "unreliable",
                "lifetime": None if label == "reliable" else 1,
                "retransmits": None,
            }
            for index, label in enumerate(("reliable", "ordered", "unreliable"))
        }
        phases = [
            {
                "snapshot": {
                    "backend": "native",
                    "generation": generation,
                    "channels": copy.deepcopy(channels),
                }
            }
            for generation in (1, 2)
        ]
        self.assertTrue(reference.native_channel_contracts_passed(phases))
        for label in channels:
            for key, value in (
                ("internal_id", -1),
                ("internal_id", True),
                ("negotiated", False),
                ("ordered", label == "unreliable"),
                ("lifetime", 0),
                ("lifetime", True),
                ("retransmits", 0),
            ):
                with self.subTest(label=label, key=key, value=value):
                    broken = json.loads(json.dumps(phases))
                    broken[1]["snapshot"]["channels"][label][key] = value
                    self.assertFalse(reference.native_channel_contracts_passed(broken))
        for label in channels:
            for key in channels[label]:
                broken = json.loads(json.dumps(phases))
                del broken[1]["snapshot"]["channels"][label][key]
                self.assertFalse(reference.native_channel_contracts_passed(broken))
        for generation in (1, 0, True, None):
            broken = json.loads(json.dumps(phases))
            broken[1]["snapshot"]["generation"] = generation
            self.assertFalse(reference.native_channel_contracts_passed(broken))
        invalid_properties: object
        for invalid_properties in (None, {}, [], "closed"):
            broken = json.loads(json.dumps(phases))
            broken[1]["snapshot"]["channels"]["ordered"] = invalid_properties
            self.assertFalse(reference.native_channel_contracts_passed(broken))

    def test_godot_native_pairing_keeps_actual_channel_layout(self) -> None:
        for web in (False, True):
            unset = 0 if web else -1
            channels = [
                {
                    "label": label,
                    "id": index,
                    "negotiated": True,
                    "ordered": label != "unreliable",
                    "lifetime": unset,
                    "retransmits": unset,
                    "state": 1,
                }
                for index, label in enumerate(("reliable", "ordered", "unreliable"), 1)
            ]
            phases = [{"channels": channels}, {"channels": channels}]
            self.assertTrue(reference.godot_native_contracts_passed(phases, web))
            for key, value in (
                ("label", "reliable"),
                ("id", 3),
                ("ordered", False),
                ("negotiated", False),
                ("lifetime", 0 if not web else -1),
                ("state", 2),
                ("retransmits", 2),
            ):
                broken = json.loads(json.dumps(phases))
                broken[1]["channels"][1][key] = value
                self.assertFalse(reference.godot_native_contracts_passed(broken, web))

    def test_native_gameplay_keeps_initial_probes_and_reliable_delivery_strict(self) -> None:
        phase = {
            "sent": True,
            "received": ["reliable", "unreliable"],
            "snapshot_sent": 128,
            "snapshot_received": 128,
            "partial_sent": 4,
            "partial_received": 4,
            "remote_closed": True,
            "mixed_traffic": True,
            "credit_transport": "http",
            "snapshot_acknowledged": 128,
            "positions_sent": 32,
            "positions_received": 2,
            "position_sequences": [0, 31],
            "native_profile": True,
            "ordered_sent": 8,
            "ordered_sequences": [0, 7],
            "peak_outstanding": 32,
        }
        self.assertTrue(
            reference.gameplay_phase_passed(phase, mixed_traffic=True, native_profile=True)
        )
        self.assertFalse(reference.gameplay_phase_passed(phase, mixed_traffic=True))
        for key, value in (
            ("snapshot_received", 127),
            ("snapshot_acknowledged", 127),
            ("partial_received", 3),
            ("received", ["unreliable"]),
            ("received", ["reliable"]),
            ("received", []),
            ("received", ["reliable", "reliable"]),
            ("remote_closed", False),
            ("positions_received", 0),
            ("ordered_sequences", []),
        ):
            with self.subTest(key=key):
                self.assertFalse(
                    reference.gameplay_phase_passed(
                        {**phase, key: value}, mixed_traffic=True, native_profile=True
                    )
                )

    def test_native_loss_contract_preserves_exact_receipt_coordinates(self) -> None:
        phase = {
            "native_profile": True,
            "ordered_sent": 8,
            "ordered_sequences": [1, 3, 7],
            "position_sequences": [31, 0, 4],
            "positions_received": 3,
        }
        self.assertTrue(reference.native_delivery_passed(phase, True))
        for key, value in (
            ("native_profile", False),
            ("ordered_sent", 7),
            ("ordered_sequences", []),
            ("ordered_sequences", [3, 1]),
            ("ordered_sequences", [1, 1]),
            ("ordered_sequences", [8]),
            ("ordered_sequences", [True]),
            ("position_sequences", [0, 0, 4]),
            ("position_sequences", [0, 4, 32]),
            ("positions_received", 2),
            ("position_sequences", []),
        ):
            with self.subTest(key=key, value=value):
                self.assertFalse(reference.native_delivery_passed({**phase, key: value}, True))
        self.assertFalse(reference.native_delivery_passed(phase, False))
        self.assertTrue(
            reference.native_delivery_passed(
                {**phase, "position_sequences": [], "positions_received": 0}, False
            )
        )

    def test_queued_retirement_requires_preserved_selection_and_both_arrivals(self) -> None:
        arrival = {"preserved": True, "queued_before_read": 3, "queued_after_read": 2}
        local = {"queued": 2, "queued_arrival": arrival}
        remote = {"queued_retirement": True, "late_sent": True}
        self.assertTrue(
            reference.queued_retirement_passed({"retirement": local}, {"retirement": remote}, True)
        )
        for key, value in (
            ("preserved", False),
            ("queued_before_read", 2),
            ("queued_before_read", 3.0),
            ("queued_after_read", 1),
            ("queued_after_read", 2.0),
        ):
            with self.subTest(key=key, value=value):
                proof = {**local, "queued_arrival": {**arrival, key: value}}
                self.assertFalse(
                    reference.queued_retirement_passed(
                        {"retirement": proof}, {"retirement": remote}, True
                    )
                )
        for local_change, remote_change in (
            ({"queued": 1}, {}),
            ({"queued_arrival": None}, {}),
            ({}, {"queued_retirement": False}),
            ({}, {"late_sent": False}),
        ):
            self.assertFalse(
                reference.queued_retirement_passed(
                    {"retirement": {**local, **local_change}},
                    {"retirement": {**remote, **remote_change}},
                    True,
                )
            )
        self.assertFalse(reference.queued_retirement_passed({}, {}, True))
        self.assertFalse(
            reference.queued_retirement_passed({"retirement": local}, {"retirement": remote}, False)
        )
        self.assertTrue(
            reference.queued_retirement_passed(
                {"retirement": {}}, {"retirement": {"queued_retirement": False}}, False
            )
        )

    def test_receive_capacity_control_is_applied_before_engine_import(self) -> None:
        for capacity in (0, 64, 256):
            with self.subTest(capacity=capacity), tempfile.TemporaryDirectory() as temporary:
                args = argparse.Namespace(
                    native_extension=Path("extension"),
                    godot="godot",
                    godot_offer=False,
                    safe_receive=True,
                    mixed_traffic=True,
                    credit_transport="webrtc",
                    channel_in_buffer_kb=capacity,
                    receive_batch_packets=4,
                    receive_interval_ms=200,
                    web_http_fetch=bool(capacity),
                )
                with patch.object(reference.interop, "checked") as checked:
                    project = reference.prepare(args, Path(temporary), web=True)
                content = (project / "project.godot").read_text()
                if capacity:
                    self.assertIn(f"limits/webrtc/max_channel_in_buffer_kb={capacity}", content)
                else:
                    self.assertNotIn("limits/webrtc/max_channel_in_buffer_kb=", content)
                options = json.loads((project / "reference-options.json").read_text())
                self.assertEqual(options["receive_batch_packets"], 4)
                self.assertEqual(options["receive_interval_ms"], 200)
                source = (project / "tests/smoke/webrtc_interop_drill.gd").read_text()
                self.assertEqual("_setup_http(true)" in source, bool(capacity))
                self.assertTrue((project / "tests/smoke/webrtc_http_request.gd").is_file())
                self.assertEqual(checked.call_count, 2)

    def test_service_rejoin_requires_same_room_receiver_and_new_generation(self) -> None:
        godot = [
            {
                "phase": phase,
                "room_id": "room",
                "generation": f"generation-{phase}",
                "initiate": False,
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
                "initiate": True,
                "signals_sent": 4,
                "signals_received": 3,
                "left": True,
                "departure_stage": "selected_packet" if phase["phase"] == 1 else "teardown",
            }
            for phase in godot
        ]
        self.assertTrue(reference.service_session_passed(godot, remote, rejoin=True))
        self.assertTrue(
            reference.service_session_passed(
                [{**godot[0], "initiate": True}, godot[1]],
                [{**remote[0], "initiate": False}, remote[1]],
                rejoin=True,
                godot_offer=True,
            )
        )
        self.assertFalse(
            reference.service_session_passed(godot, remote, rejoin=True, godot_offer=True)
        )
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
                "initiate": False,
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
                "initiate": True,
                "signals_sent": 4,
                "signals_received": 3,
            }
            for phase in godot
        ]
        self.assertTrue(reference.service_session_passed(godot, remote))
        for records in (godot, remote):
            for key, value in (
                ("phase", 1),
                ("initiate", None),
                ("initiate", 0),
                ("initiate", "true"),
                ("initiate", records is godot),
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
const rejoin = fault.includes("rejoin");
const godotOffer = fault.startsWith("godot") || fault.startsWith("early");
const initiate = () => rejoin && phase === 2 ? true : !godotOffer;
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
      if (rejoin && phase === 2) {
        if (fault === "early-rejoin") frame("Signal", {from: "godot",
          generation: `generation-${phase}`, signal: {Offer: "early-offer"}});
        frame("SessionPlan", {transport: "webrtc", generation: `generation-${phase}`,
          peers: [{player_id: "godot", initiate: initiate()}]});
      }
    }
    if (message.type === "AuthorityRequest") {
      if (!godotOffer || !message.data.become_authority) throw new Error("authority request differs");
      frame("AuthorityResponse", {granted: true});
    }
    if (message.type === "PlayerReady" && godotOffer) {
      frame("LobbyStateChanged", {all_ready: false});
      frame("LobbyStateChanged", {all_ready: true});
    }
    if (message.type === (godotOffer ? "StartGame" : "PlayerReady")) {
      if (rejoin && phase === 2) throw new Error("rejoin must keep the running game");
      if (fault.startsWith("early")) frame("Signal", {
        from: fault === "early-peer" ? "other" : "godot",
        generation: fault === "early-generation" ? "old" : `generation-${phase}`,
        signal: {Offer: "early-offer"}});
      frame("GameStarting", {});
      frame("SessionPlan", {transport: "webrtc", generation: `generation-${phase}`,
        peers: [{player_id: "godot", initiate: initiate()}], ice_servers: []});
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
context.configureReferenceService("ws://service/v3/ws", "app", rejoin, godotOffer);
let error = "";
try {
  for (let round = 1; round <= 2; round++) {
    const service = await context.window.referenceService.begin(round, 0);
    if (service.initiate !== initiate()) throw new Error("offer role differs");
    if (service.drain(false).length) throw new Error("unpaired peer received a signal");
    if (fault === "early" || fault === "early-rejoin") {
      const queued = service.drain();
      if (queued.length !== 1 || queued[0].payload.Offer !== "early-offer")
        throw new Error("early offer was lost");
    }
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
            "godot",
            "godot-rejoin",
            "early",
            "early-rejoin",
            "early-peer",
            "early-generation",
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
                if fault in (
                    "none",
                    "rejoin",
                    "late",
                    "godot",
                    "godot-rejoin",
                    "early",
                    "early-rejoin",
                ):
                    self.assertEqual(proof["error"], "")
                    self.assertEqual([phase["phase"] for phase in proof["evidence"]], [1, 2])
                    for phase in proof["evidence"]:
                        self.assertTrue(phase["left"])
                        self.assertEqual(phase["signals_sent"], 1)
                        self.assertEqual(
                            phase["signals_received"],
                            2 if fault in ("late", "early", "early-rejoin") else 1,
                        )
                    if fault == "rejoin":
                        self.assertEqual(proof["evidence"][0]["departure_stage"], "selected_packet")
                else:
                    self.assertIn("signal identity differs", proof["error"])
                    if proof.get("evidence"):
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
            self.assertEqual(results[2]["diagnostics"]["driver_error"], results[2]["driver_error"])
            self.assertEqual(results[2]["diagnostics"]["heartbeat_phases"], [])
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
        for error in (
            "PAGE_ERROR load failed",
            "SCRIPT ERROR: bad engine",
            'WEBRTC_INTEROP_FAIL {"stage":"setup","reason":"connect failed"}',
        ):
            ready = Mock(return_value=True)
            with self.assertRaisesRegex(RuntimeError, "during reference assessment startup"):
                reference.wait_for_godot_ready(cast(Page, page), ready, [error])
            ready.assert_not_called()

    def test_startup_failure_during_polling_wins_over_a_ready_marker(self) -> None:
        page = Mock()
        messages: list[str] = []
        page.wait_for_timeout.side_effect = lambda _: messages.append(
            'WEBRTC_INTEROP_FAIL {"stage":"setup","reason":"connect failed"}'
        )
        ready = Mock(side_effect=[False, True])
        with self.assertRaisesRegex(RuntimeError, "during reference assessment startup"):
            reference.wait_for_godot_ready(cast(Page, page), ready, messages)
        ready.assert_called_once_with()
        page.wait_for_timeout.assert_called_once_with(100)

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
        paced = {**proof, "queued_reliable": 11}
        self.assertFalse(reference.slow_receiver_passed(paced, True))
        self.assertTrue(reference.slow_receiver_passed(paced, True, 11))
        self.assertFalse(reference.slow_receiver_passed({**paced, "queued_reliable": 10}, True, 11))
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
        paced = {**phase, "receive_pause": {**proof, "queued_snapshots": 11, "peak_queued": 19}}
        self.assertFalse(reference.reference_receive_pause_passed(paced, True))
        self.assertTrue(reference.reference_receive_pause_passed(paced, True, 11))
        self.assertFalse(
            reference.reference_receive_pause_passed(
                {
                    **paced,
                    "receive_pause": {
                        **proof,
                        "queued_snapshots": 10,
                        "peak_queued": 18,
                    },
                },
                True,
                11,
            )
        )
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

    def test_reference_receives_credit_while_its_outgoing_post_is_held(self) -> None:
        harness = r"""
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
const source = readFileSync(0, "utf8").split("\n").slice(1).join("\n");
const failure = process.argv[1];
let rejectPost, releasePost;
let clock = 1, hooks, fed = false, ready = false, held = false, credited = false;
let sent = 0, getsWhileHeld = 0, aborted = 0;
const active = {GET: 0, POST: 0}, peak = {GET: 0, POST: 0};
const posted = [];
const context = {
  window: {}, AbortController, DOMException, TextDecoder, TextEncoder,
  performance: { now: () => clock },
  console: { log() {}, error() {} },
  setTimeout: resolve => setImmediate(() => {
    clock += 20;
    if (failure === "release" && held && clock >= 600) releasePost?.();
    if (failure === "post" && held && clock >= 600) rejectPost?.(new Error("relay POST 503"));
    if (!fed && ready) {
      fed = true;
      for (let i = 0; i < 16; i++) hooks.onChannelMessage("godot", "generation", "reliable",
        `snapshot:1:godot:${i}:` + "0123456789abcdef".repeat(64));
    }
    resolve();
  }),
  Engine: class {
    constructor(_native, callbacks) { hooks = callbacks; }
    async pairWith() { return null; }
    channel() { return { readyState: "open", send(text) {
      if (text.startsWith("snapshot:")) sent++;
    }}; }
    diagnosticSnapshot() { return {}; }
    removePeer() {}
  },
  fetch: async (_url, options) => {
    const method = options.method ?? "GET";
    peak[method] = Math.max(peak[method], ++active[method]);
    try {
      let messages = [];
      if (method === "POST") {
        const marker = JSON.parse(options.body).marker;
        posted.push(marker);
        if (marker === "snapshot-ack-1-8") {
          held = true;
          let onAbort;
          await new Promise((resolve, reject) => {
            releasePost = resolve;
            rejectPost = reject;
            onAbort = () => {
              aborted++;
              reject(new DOMException("cleanup cancellation", "AbortError"));
            };
            options.signal.addEventListener("abort", onAbort);
          }).finally(() => options.signal.removeEventListener("abort", onAbort));
        }
      } else if (!ready) {
        ready = true;
        messages = [{marker: "ready-1"}];
      } else if (held) {
        getsWhileHeld++;
        if (failure === "get" && clock >= 600) throw new Error("relay GET 503");
        if (sent === 32 && !credited) {
          credited = true;
          messages = [{marker: "snapshot-ack-1-32"}];
        }
      }
      return {ok:true, json:async () => messages};
    } finally { active[method]--; }
  },
};
runInNewContext(source, context);
await context.window.runReference(1, false, false, "http", false,
  "reliable", "reference", false, null, false, 1024, 0);
console.log(JSON.stringify({sent, credited, getsWhileHeld, aborted, active, peak, posted,
  error:context.window.referenceError, settled:context.window.referenceSettled}));
"""
        source = (SCRIPT.parents[1] / "tests/smoke/webrtc_reference.js").read_text()
        for failure in ("none", "get", "post", "release"):
            with self.subTest(failure=failure):
                result = subprocess.run(  # noqa: S603
                    ["node", "--input-type=module", "-e", harness, failure],  # noqa: S607
                    input=source,
                    text=True,
                    capture_output=True,
                    check=True,
                    timeout=5,
                )
                proof = json.loads(result.stdout)
                self.assertEqual(proof["sent"], 64)
                self.assertTrue(proof["credited"])
                self.assertGreater(proof["getsWhileHeld"], 1)
                self.assertEqual(proof["peak"], {"GET": 1, "POST": 1})
                self.assertEqual(proof["active"], {"GET": 0, "POST": 0})
                self.assertEqual(proof["aborted"], 0 if failure in ("post", "release") else 1)
                expected_posts = ["ready-1", "snapshot-ack-1-8"]
                if failure == "release":
                    expected_posts.extend(["snapshot-ack-1-16", "observed-1"])
                self.assertEqual(proof["posted"], expected_posts)
                self.assertTrue(proof["settled"])
                self.assertEqual(
                    proof["error"],
                    "Error: phase 1 missing Godot teardown"
                    if failure in ("none", "release")
                    else f"Error: relay {failure.upper()} 503",
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
console.log(JSON.stringify({error:context.window.referenceError, terminal:context.window.referenceTerminal}));
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
                proof = json.loads(result.stdout)
                self.assertEqual(proof["error"], expected)
                self.assertEqual(proof["terminal"]["phase"], 1)
                self.assertEqual(proof["terminal"]["snapshot_received"], 0)
                self.assertEqual(proof["terminal"]["snapshot_sent"], 0)
                self.assertFalse(proof["terminal"]["retired"])

    def test_reference_settles_after_delayed_cleanup_and_keeps_primary_error(self) -> None:
        harness = r"""
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import assert from "node:assert/strict";
const source = readFileSync(0, "utf8").split("\n").slice(1).join("\n");
let clock = 0;
let releaseCleanup, markStarted;
const started = new Promise(resolve => { markStarted = resolve; });
const cleanup = new Promise(resolve => { releaseCleanup = resolve; });
const context = {
  window: {}, AbortController, DOMException,
  performance: { now: () => clock },
  console: { log() {}, error() {} },
  setTimeout: resolve => setImmediate(() => { clock = 14000; resolve(); }),
  Engine: class {
    channel() { return null; }
    diagnosticSnapshot() { return {}; }
    async removePeer() { markStarted(); await cleanup; throw new Error("cleanup failed"); }
  },
  fetch: (_url, { signal }) => new Promise((_resolve, reject) => {
    signal.addEventListener("abort", () => reject(new DOMException("cleanup cancellation", "AbortError")));
  }),
};
runInNewContext(source, context);
const task = context.window.runReference(1, false, false, "http");
await started;
assert.equal(context.window.referenceSettled, false);
assert.equal(context.window.referenceError, "Error: phase 1 missing Godot teardown");
releaseCleanup();
await task;
assert.equal(context.window.referenceSettled, true);
assert.equal(context.window.referenceError, "Error: phase 1 missing Godot teardown");
assert.equal(context.window.referenceCleanupError, "Error: cleanup failed");
console.log("cleanup settled");
"""
        result = subprocess.run(  # noqa: S603
            ["node", "--input-type=module", "-e", harness],  # noqa: S607
            input=(SCRIPT.parents[1] / "tests/smoke/webrtc_reference.js").read_text(),
            text=True,
            capture_output=True,
            check=True,
            timeout=5,
        )
        self.assertEqual(result.stdout.strip(), "cleanup settled")

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

    def test_native_bridge_drains_output_while_writing_a_large_command(self) -> None:
        import sys

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            probe = directory / "probe"
            probe.write_text(
                "#!" + sys.executable + "\n"
                "import sys,json\n"
                "while first := sys.stdin.read(1):\n"
                " for sequence in range(128):\n"
                "  print(json.dumps({'event':'binary','sequence':sequence,"
                "'data_base64':'A'*8192}),flush=True)\n"
                " value=json.loads(first+sys.stdin.readline())\n"
                " print(json.dumps({'id':value['id'],'result':len(value['text'])}),flush=True)\n"
            )
            probe.chmod(0o700)
            bridge = reference.native_reference.NativeReference(probe, directory)
            results: list[object] = []

            def send() -> None:
                try:
                    for _ in range(2):
                        results.append(bridge.command({"op": "send", "text": "x" * 1048576}))
                except Exception as exc:
                    results.append(exc)

            writer = threading.Thread(target=send, daemon=True)
            writer.start()
            try:
                writer.join(timeout=5)
                self.assertFalse(writer.is_alive(), "native command and event pipes deadlocked")
                self.assertEqual(results, [1048576, 1048576])
                events = bridge.drain()
                self.assertEqual([event["sequence"] for event in events], list(range(128)) * 2)
                snapshot = bridge.timing_snapshot()
                self.assertEqual(snapshot["output_lines"], 258)
                records = cast(list[dict[str, object]], snapshot["records"])
                stages = [record["stage"] for record in records]
                self.assertLess(stages.index("output"), stages.index("written"))
            finally:
                bridge.close()
                writer.join(timeout=5)
            self.assertFalse(writer.is_alive())
            self.assertFalse(bridge.reader.is_alive())

    def test_native_bridge_timing_correlates_commands_and_output_without_payloads(self) -> None:
        import sys

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            probe = directory / "probe"
            probe.write_text(
                "#!"
                + sys.executable
                + "\nimport sys,json\nfor line in sys.stdin:\n v=json.loads(line)\n print(json.dumps({'event':'binary','generation':2,'label':'reliable','data_base64':'AP8='}),flush=True)\n print(json.dumps({'id':v['id'],'result':None}),flush=True)\n"
            )
            probe.chmod(0o700)
            bridge = reference.native_reference.NativeReference(probe, directory)
            try:
                bridge.command({"op": "send", "label": "reliable", "text": "opaque-body"})
                events = bridge.drain()
                self.assertEqual(len(events), 1)
                snapshot = bridge.timing_snapshot()
                records = cast(list[dict[str, object]], snapshot["records"])
                self.assertEqual(records[0]["stage"], "command")
                self.assertEqual(records[-1]["stage"], "reply")
                self.assertCountEqual(
                    [record["stage"] for record in records],
                    ["command", "written", "output", "output", "reply"],
                )
                self.assertEqual([r["id"] for r in records if r.get("id")], [1, 1, 1, 1])
                self.assertEqual([r["line"] for r in records if "line" in r], [1, 2])
                times = [record["us"] for record in records]
                self.assertEqual(times, sorted(times))
                self.assertNotIn("opaque-body", json.dumps(snapshot))
                self.assertNotIn("AP8=", json.dumps(snapshot))
                for _ in range(10010):
                    bridge._trace("test")
                self.assertEqual(len(bridge.timing_snapshot()["records"]), 10000)
                self.assertEqual(bridge.timing_snapshot()["dropped"], 15)
            finally:
                bridge.close()

    def test_native_rejection_survives_unconsumed_events_and_shutdown(self) -> None:
        import sys

        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            probe = directory / "probe"
            probe.write_text(
                "#!"
                + sys.executable
                + "\nimport sys,json\nfor line in sys.stdin:\n v=json.loads(line)\n print(json.dumps({'event':'receive_rejected','generation':2,'label':'unreliable'}),flush=True)\n print(json.dumps({'event':'receive_rejected','generation':3,'label':'ordered'}),flush=True)\n print(json.dumps({'id':v['id'],**({'result':True} if v['op']=='remove' else {'error':'teardown failure'})}),flush=True)\n"
            )
            probe.chmod(0o700)
            bridge = reference.native_reference.NativeReference(probe, directory)
            try:
                self.assertTrue(bridge.command({"op": "remove"}))
                with self.assertRaisesRegex(RuntimeError, "teardown failure"):
                    bridge.command({"op": "snapshot"})
            finally:
                bridge.close()
            self.assertEqual(
                bridge.timing_snapshot()["receive_failure"],
                "native receive rejected: generation=2 channel=unreliable",
            )

    def test_native_log_open_failure_does_not_spawn_probe(self) -> None:
        stderr = Mock()
        with (
            patch.object(Path, "open", side_effect=[stderr, OSError("log unavailable")]),
            patch.object(reference.native_reference.subprocess, "Popen") as spawn,
            self.assertRaisesRegex(OSError, "log unavailable"),
        ):
            reference.native_reference.NativeReference(Path("probe"), Path("output"))
        spawn.assert_not_called()
        stderr.close.assert_called_once()

    def test_native_spawn_failure_closes_both_logs(self) -> None:
        stderr, log = Mock(), Mock()
        with (
            patch.object(Path, "open", side_effect=[stderr, log]),
            patch.object(
                reference.native_reference.subprocess,
                "Popen",
                side_effect=OSError("spawn failed"),
            ),
            self.assertRaisesRegex(OSError, "spawn failed"),
        ):
            reference.native_reference.NativeReference(Path("probe"), Path("output"))
        stderr.close.assert_called_once()
        log.close.assert_called_once()

    def test_native_reader_start_failure_reaps_probe_and_closes_files(self) -> None:
        stderr, log = Mock(), Mock()
        process = Mock()
        process.poll.return_value = None
        with (
            patch.object(Path, "open", side_effect=[stderr, log]),
            patch.object(reference.native_reference.subprocess, "Popen", return_value=process),
            patch.object(threading.Thread, "start", side_effect=RuntimeError("thread failed")),
            self.assertRaisesRegex(RuntimeError, "thread failed"),
        ):
            reference.native_reference.NativeReference(Path("probe"), Path("output"))
        process.terminate.assert_called_once()
        process.wait.assert_called_once_with(timeout=5)
        process.stdin.close.assert_called_once()
        process.stdout.close.assert_called_once()
        stderr.close.assert_called_once()
        log.close.assert_called_once()

    def test_native_assessment_asset_failure_does_not_spawn_probe(self) -> None:
        args = argparse.Namespace(native_reference_probe=Path("probe"))
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "assessment"
            with (
                patch.object(reference, "prepare", return_value=Path(temporary)),
                patch.object(reference.shutil, "copy2", side_effect=OSError("copy failed")),
                patch.object(reference.native_reference, "NativeReference") as backend,
                self.assertRaisesRegex(OSError, "copy failed"),
            ):
                reference.assess(args, directory, web=False)
            backend.assert_not_called()

    def test_native_assessment_browser_failure_closes_probe_and_server(self) -> None:
        args = argparse.Namespace(
            native_reference_probe=Path("probe"),
            safe_receive=False,
            godot_offer=False,
            mixed_traffic=False,
            credit_transport="http",
            godot="godot",
            reference_revision="test",
            chromium=None,
        )
        server, backend, playwright = Mock(), Mock(), Mock()
        backend.timing_snapshot.return_value = {"records": [], "dropped": 0}
        playwright.chromium.launch.side_effect = RuntimeError("browser failed")
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary) / "assessment"
            args.native_reference_probe = Path(temporary) / "probe.exe"
            args.native_reference_probe.write_bytes(b"original probe")

            def spawn_backend(probe: Path, _directory: Path) -> Mock:
                self.assertEqual(probe, directory / "native-reference-probe.exe")
                self.assertEqual(probe.read_bytes(), b"original probe")
                args.native_reference_probe.write_bytes(b"replacement probe")
                return backend

            with (
                patch.object(reference, "prepare", return_value=Path(temporary)),
                patch.object(reference.interop, "RelayServer", return_value=server),
                patch.object(threading.Thread, "start"),
                patch.object(
                    reference.native_reference, "NativeReference", side_effect=spawn_backend
                ),
                patch.object(reference, "sync_playwright") as start_playwright,
            ):
                start_playwright.return_value.__enter__.return_value = playwright
                with self.assertRaisesRegex(RuntimeError, "Incomplete reference assessment"):
                    reference.assess(args, directory, web=False)
            report = json.loads((directory / "assessment.json").read_text())
            self.assertEqual(
                report["reference_engine_sha256"],
                reference.hashlib.sha256(b"original probe").hexdigest(),
            )
        self.assertEqual(report["driver_error"], "RuntimeError: browser failed")
        self.assertEqual(report["reference_backend"], "native")
        backend.close.assert_called_once()
        server.shutdown.assert_called_once()
        server.server_close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
