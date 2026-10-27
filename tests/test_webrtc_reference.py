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
                {"marker": "heartbeat:1:reference:0", "probe_us": 14000, "callback_ms": 365}
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
        }
        result = reference.heartbeat_diagnostics(
            {"heartbeat_timings": [{"sequence": 0, "receive_ms": 900000, "echo_ms": 900001}]}, phase
        )
        self.assertEqual(result["matched_samples"]["native_rtt_ms"], 1)
        self.assertEqual(result["max_ms"]["native_rtt_ms"], 4)
        self.assertEqual(result["max_ms"]["bridge_queue_ms"], 200)
        self.assertEqual(result["max_ms"]["application_rtt_ms"], 280)
        self.assertEqual(result["max_ms"]["godot_echo_ms"], 1)
        self.assertEqual(result["packets"][1]["native_rtt_ms"], None)
        self.assertEqual(result["packets"][1]["application_rtt_ms"], None)

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
        report = {
            "driver_error": "TimeoutError: reference completion",
            "godot_evidence": {
                "last_progress": {
                    "phase": 1,
                    "max_stage_frame_gap_ms": 107,
                    "reference": {"snapshot_acknowledged": 56, "credit_wait_age_ms": 890},
                }
            },
        }
        result = reference.gameplay_diagnostics(report, "")
        self.assertIsNone(result["godot_failure"]["reason"])
        self.assertEqual(result["godot_progress"]["max_stage_frame_gap_ms"], 107)
        self.assertEqual(result["godot_queue"]["snapshot_acknowledged"], 56)
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
        for capacity in (4128, 8256, 16512, 28896, 33024):
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
                        "--snapshot-window-bytes",
                        str(capacity),
                    ],
                ),
                patch.object(
                    reference, "assess", return_value={"assessment_complete": True}
                ) as assess,
                patch("builtins.print"),
            ):
                reference.main()
                self.assertEqual(assess.call_count, 1)
                self.assertEqual(assess.call_args.args[0].snapshot_window_bytes, capacity)

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

    def test_native_gameplay_keeps_reliable_delivery_strict(self) -> None:
        phase = {
            "sent": True,
            "received": ["reliable"],
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
                )
                with patch.object(reference.interop, "checked") as checked:
                    project = reference.prepare(args, Path(temporary), web=True)
                content = (project / "project.godot").read_text()
                if capacity:
                    self.assertIn(f"limits/webrtc/max_channel_in_buffer_kb={capacity}", content)
                else:
                    self.assertNotIn("limits/webrtc/max_channel_in_buffer_kb=", content)
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
                self.assertEqual(
                    [record["stage"] for record in records],
                    ["command", "output", "output", "reply"],
                )
                self.assertEqual([records[i]["id"] for i in (0, 2, 3)], [1, 1, 1])
                self.assertEqual([records[i]["line"] for i in (1, 2)], [1, 2])
                times = [record["us"] for record in records]
                self.assertEqual(times, sorted(times))
                self.assertNotIn("opaque-body", json.dumps(snapshot))
                self.assertNotIn("AP8=", json.dumps(snapshot))
                for _ in range(10010):
                    bridge._trace("test")
                self.assertEqual(len(bridge.timing_snapshot()["records"]), 10000)
                self.assertEqual(bridge.timing_snapshot()["dropped"], 14)
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
