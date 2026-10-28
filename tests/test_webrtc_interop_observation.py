"""Keep live-drill driver timeouts distinct from engine failures."""

import argparse
import hashlib
import http.client
import importlib.util
import io
import json
import socket
import subprocess
import tempfile
import threading
import unittest
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from pathlib import Path
from typing import ClassVar, cast
from unittest.mock import MagicMock, Mock, patch

from playwright.sync_api import Page, Request

SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "check-webrtc-interop.py"
SPEC = importlib.util.spec_from_file_location("webrtc_interop", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
drill = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(drill)


class RelayObservationTests(unittest.TestCase):
    def test_http_backend_requires_the_observed_choice(self) -> None:
        for requested in (False, True):
            for observed in (None, False, True, 1, 0, "true", "false"):
                with self.subTest(requested=requested, observed=observed):
                    output = (
                        "WEBRTC_INTEROP_PROGRESS "
                        + json.dumps({"web_http_fetch": observed})
                        + "\nWEBRTC_INTEROP_PASS seat=1"
                    )
                    result = drill.seat_evidence(output, 1, require_web_http_fetch=requested)
                    self.assertEqual(result["passed"], observed is requested)
            result = drill.seat_evidence(
                "WEBRTC_INTEROP_PASS seat=1", 1, require_web_http_fetch=requested
            )
            self.assertFalse(result["passed"])
        self.assertTrue(drill.seat_evidence("WEBRTC_INTEROP_PASS seat=1", 1)["passed"])

    def test_http_backend_cli_defaults_to_fetch_and_keeps_explicit_controls(self) -> None:
        for flags, expected in (
            ([], True),
            (["--web-http-fetch"], True),
            (["--web-http-request"], False),
        ):
            with self.subTest(flags=flags), tempfile.TemporaryDirectory() as temporary:
                with (
                    patch(
                        "sys.argv",
                        [
                            str(SCRIPT),
                            "--native-extension",
                            temporary,
                            "--output",
                            str(Path(temporary) / "assessment"),
                            *flags,
                        ],
                    ),
                    patch.object(drill, "run") as run,
                ):
                    drill.main()
                self.assertEqual(run.call_count, 1)
                self.assertIs(run.call_args.args[0].web_http_fetch, expected)

    def test_http_backend_cli_rejects_conflicting_controls_before_preparation(self) -> None:
        for flags in (
            ["--web-http-fetch", "--web-http-request"],
            ["--web-http-request", "--web-http-fetch"],
        ):
            with (
                self.subTest(flags=flags),
                patch("sys.argv", [str(SCRIPT), "--native-extension", "/missing", *flags]),
                patch("sys.stderr", new_callable=io.StringIO),
                patch.object(drill, "run") as run,
            ):
                with self.assertRaises(SystemExit) as error:
                    drill.main()
                self.assertEqual(error.exception.code, 2)
                run.assert_not_called()

    def test_relay_reuses_connection_for_markers_and_static_assets(self) -> None:
        class Handler(drill.RelayHandler):  # type: ignore[name-defined,misc]
            queues: ClassVar[list[list[object]]] = [[], []]
            lock = threading.Lock()
            observation = drill.RelayObservation()
            nodelay: ClassVar[list[int]] = []

            def setup(self) -> None:
                super().setup()
                self.nodelay.append(
                    self.connection.getsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY)
                )

        with tempfile.TemporaryDirectory() as temporary:
            Path(temporary, "asset.js").write_text("exact asset")
            server = drill.RelayServer(("127.0.0.1", 0), partial(Handler, directory=temporary))
            thread = threading.Thread(target=server.serve_forever)
            thread.start()
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
            try:
                connection.request("POST", "/signal/1", body='{"marker":"credit"}')
                connected = connection.sock
                response = connection.getresponse()
                self.assertFalse(response.will_close)
                self.assertEqual(response.read(), b"{}")
                self.assertIsNotNone(connected)
                for path, expected in (
                    ("/signal/1", b'[{"marker": "credit"}]'),
                    ("/asset.js", b"exact asset"),
                    ("/signal/1", b"[]"),
                ):
                    connection.request("GET", path)
                    self.assertIs(connection.sock, connected)
                    response = connection.getresponse()
                    self.assertEqual(response.status, 200)
                    self.assertFalse(response.will_close)
                    self.assertEqual(response.read(), expected)
                self.assertEqual(Handler.nodelay, [1])
            finally:
                connection.close()
                server.shutdown()
                server.server_close()
                thread.join()

    def test_setup_failure_retains_process_exit_and_engine_error_separately(self) -> None:
        for code, output, engine_error in (
            (-11, b"normal output", False),
            (0, b"SCRIPT ERROR: broken", True),
            (7, b"", False),
        ):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as temporary:
                log = Path(temporary) / "import.log"
                with (
                    patch.object(
                        drill.subprocess,
                        "run",
                        return_value=subprocess.CompletedProcess(["engine"], code, stdout=output),
                    ),
                    self.assertRaisesRegex(
                        RuntimeError, f"exit={code}, engine_error={engine_error}"
                    ),
                ):
                    drill.checked(["engine"], log)
                self.assertEqual(log.read_bytes(), output)
                evidence = json.loads(log.with_suffix(".process.json").read_text())
                self.assertEqual(evidence["returncode"], code)
                self.assertEqual(evidence["engine_error"], engine_error)
                self.assertEqual(evidence["status"], "exited")
                self.assertIn("disk_free_bytes", evidence["before"])
                self.assertIn("disk_free_bytes", evidence["after"])

    def test_setup_timeout_keeps_partial_output_and_resources(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "import.log"
            with (
                patch.object(
                    drill.subprocess,
                    "run",
                    side_effect=subprocess.TimeoutExpired(
                        ["engine"], 120, output=b"partial output"
                    ),
                ),
                self.assertRaises(subprocess.TimeoutExpired),
            ):
                drill.checked(["engine"], log)
            self.assertEqual(log.read_bytes(), b"partial output")
            evidence = json.loads(log.with_suffix(".process.json").read_text())
            self.assertEqual(evidence["status"], "timeout")
            self.assertIsNone(evidence["returncode"])
            self.assertEqual(evidence["timeout_seconds"], 120)
            self.assertIn("before", evidence)
            self.assertIn("after", evidence)

    def test_setup_failure_hashes_files_without_python311_helpers(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            project = Path(temporary)
            engine = project / "godot"
            engine.write_bytes(b"engine binary")
            extension = project / "addons/webrtc/lib"
            extension.mkdir(parents=True)
            library = extension / "native.so"
            library_bytes = bytes(range(256)) * 1025
            library.write_bytes(library_bytes)
            (extension / "unrelated.gd").write_text("ignored")
            log = project / "import.log"
            with (
                patch.dict(drill.hashlib.__dict__),
                patch.object(
                    drill.subprocess,
                    "run",
                    return_value=subprocess.CompletedProcess([str(engine)], -11, stdout=b"crashed"),
                ),
                self.assertRaisesRegex(RuntimeError, "exit=-11"),
            ):
                drill.hashlib.__dict__.pop("file_digest", None)
                drill.checked([str(engine), "--path", str(project)], log)
            evidence = json.loads(log.with_suffix(".process.json").read_text())
            self.assertEqual(log.read_bytes(), b"crashed")
            self.assertEqual(evidence["returncode"], -11)
            self.assertEqual(evidence["status"], "exited")
            self.assertEqual(
                evidence["failure_file_sha256"],
                {
                    str(engine): hashlib.sha256(b"engine binary").hexdigest(),
                    str(library): hashlib.sha256(library_bytes).hexdigest(),
                },
            )

    def test_setup_launch_failure_retains_unavailable_observations(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            log = Path(temporary) / "import.log"
            with (
                patch.object(drill.subprocess, "run", side_effect=FileNotFoundError("no engine")),
                patch.object(drill.shutil, "disk_usage", side_effect=OSError),
                patch.object(drill.os, "getloadavg", side_effect=OSError, create=True),
                patch.object(Path, "read_text", side_effect=OSError),
                self.assertRaises(FileNotFoundError),
            ):
                drill.checked([str(Path(temporary) / "missing-engine")], log)
            evidence = json.loads(log.with_suffix(".process.json").read_text())
            self.assertEqual(evidence["status"], "launch_failed")
            self.assertIsNone(evidence["returncode"])
            self.assertIn("no engine", evidence["launch_error"])
            self.assertEqual(evidence["before"], evidence["after"])
            self.assertTrue(all(value is None for value in evidence["before"].values()))
            self.assertTrue(
                all(value is None for value in evidence["failure_file_sha256"].values())
            )
            self.assertEqual(log.read_bytes(), b"")

    def test_marker_timing_distinguishes_queued_from_dequeued(self) -> None:
        observation = drill.RelayObservation()
        first = {"marker": "consumed-1-2-8"}
        second = {"marker": "consumed-1-2-16"}
        with patch.object(drill.time, "monotonic", return_value=10):
            observation.enqueue(0, first)
            observation.enqueue(0, second)
        with patch.object(drill.time, "monotonic", return_value=11.25):
            observation.dequeue(0, [first])
        with patch.object(drill.time, "monotonic", return_value=12):
            report = observation.snapshot()
        self.assertEqual(report["enqueued_markers"], 2)
        self.assertEqual(report["dequeued_markers"], 1)
        self.assertEqual(report["queued_markers"], 1)
        self.assertEqual(
            report["pending_markers"],
            [{"seat": 0, "marker": "consumed-1-2-16", "age_ms": 2000}],
        )
        self.assertEqual(
            report["recent_dequeues"],
            [{"seat": 0, "marker": "consumed-1-2-8", "queue_ms": 1250, "age_ms": 750}],
        )

    def test_duplicate_markers_keep_separate_queue_times(self) -> None:
        observation = drill.RelayObservation()
        messages = [{"marker": "ready"}, {"marker": "ready"}]
        with patch.object(drill.time, "monotonic", side_effect=[1, 2, 3, 4]):
            observation.enqueue(0, messages[0])
            observation.enqueue(1, messages[1])
            observation.dequeue(1, [messages[1]])
            observation.dequeue(0, [messages[0]])
        records = observation.snapshot()["recent_dequeues"]
        self.assertEqual(
            [(item["seat"], item["queue_ms"]) for item in records], [(1, 1000), (0, 3000)]
        )

    def test_bounded_history_reports_eviction_without_losing_total_counts(self) -> None:
        observation = drill.RelayObservation()
        messages = [{"marker": str(index)} for index in range(200)]
        for message in messages:
            observation.enqueue(1, message)
        queued = observation.snapshot()
        self.assertEqual(queued["queued_markers"], 200)
        self.assertEqual(queued["evicted_pending_records"], 72)
        self.assertEqual(len(queued["pending_markers"]), 128)
        observation.dequeue(1, messages[:1])
        self.assertIsNone(observation.snapshot()["recent_dequeues"][0]["queue_ms"])
        observation.dequeue(1, messages[1:])
        result = observation.snapshot()
        self.assertEqual(result["enqueued_markers"], 200)
        self.assertEqual(result["dequeued_markers"], 200)
        self.assertEqual(result["queued_markers"], 0)
        self.assertEqual(result["pending_markers"], [])
        self.assertEqual(len(result["recent_dequeues"]), 128)
        self.assertEqual(result["recent_dequeues"][0]["marker"], "72")

    def test_concurrent_snapshots_keep_marker_counts_consistent(self) -> None:
        observation = drill.RelayObservation()

        def exchange(seat: int) -> None:
            for count in range(200):
                message = {"marker": f"{seat}-{count}"}
                observation.enqueue(seat, message)
                snapshot = observation.snapshot()
                self.assertEqual(
                    snapshot["enqueued_markers"] - snapshot["dequeued_markers"],
                    snapshot["queued_markers"],
                )
                observation.dequeue(seat, [message])

        with ThreadPoolExecutor(max_workers=3) as executor:
            list(executor.map(exchange, range(3)))
        snapshot = observation.snapshot()
        self.assertEqual(snapshot["enqueued_markers"], 600)
        self.assertEqual(snapshot["dequeued_markers"], 600)
        self.assertEqual(snapshot["queued_markers"], 0)
        self.assertEqual(snapshot["pending_markers"], [])

    def test_http_relay_keeps_payloads_unchanged_and_observes_only_markers(self) -> None:
        class Handler(drill.RelayHandler):  # type: ignore[name-defined,misc]
            queues: ClassVar[list[list[object]]] = [[], []]
            lock = threading.Lock()
            observation = drill.RelayObservation()

        server = drill.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
        messages = [{"marker": "consumed-1-0-8"}, {"payload": {"Offer": "example"}}]
        try:
            for message in messages:
                connection.request("POST", "/signal/1", body=json.dumps(message))
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                response.read()
            self.assertEqual(Handler.observation.snapshot()["queued_markers"], 1)
            connection.request("GET", "/signal/0")
            self.assertEqual(json.loads(connection.getresponse().read()), [])
            self.assertEqual(Handler.observation.snapshot()["queued_markers"], 1)
            connection.request("GET", "/signal/1")
            self.assertEqual(json.loads(connection.getresponse().read()), messages)
            report = Handler.observation.snapshot()
            self.assertEqual(report["enqueued_markers"], 1)
            self.assertEqual(report["dequeued_markers"], 1)
            self.assertEqual(report["queued_markers"], 0)
            self.assertEqual(report["recent_dequeues"][0]["marker"], "consumed-1-0-8")
            self.assertNotIn("example", json.dumps(report))
        finally:
            connection.close()
            server.shutdown()
            server.server_close()
            thread.join()


class LifetimeContractTests(unittest.TestCase):
    def test_finite_property_gate_covers_all_peers_and_channels(self) -> None:
        channels = [
            {
                "id": index + 1,
                "label": label,
                "negotiated": True,
                "ordered": index != 2,
                "max_packet_life_time": -1 if index == 0 else 1,
                "max_retransmits": -1,
            }
            for index, label in enumerate(["reliable", "ordered", "unreliable"])
        ]
        contract = {"peers": [{"channels": channels}]}
        output = "WEBRTC_INTEROP_PASS seat=0\nWEBRTC_CHANNEL_CONTRACT " + json.dumps(contract)
        self.assertTrue(drill.seat_evidence(output, 0, require_finite_lifetimes=True)["passed"])
        self.assertFalse(drill.finite_lifetimes([]))
        self.assertFalse(drill.finite_lifetimes([{"peers": []}]))
        for index in range(3):
            for field, value in [
                ("max_packet_life_time", -1 if index else 1),
                ("max_retransmits", 0),
                ("ordered", index == 2),
            ]:
                with self.subTest(index=index, field=field):
                    changed = json.loads(json.dumps(contract))
                    changed["peers"][0]["channels"][index][field] = value
                    self.assertFalse(drill.finite_lifetimes([contract, changed]))
        web_contract = json.loads(json.dumps(contract))
        for index, channel in enumerate(web_contract["peers"][0]["channels"]):
            channel["max_retransmits"] = 0
            if index == 0:
                channel["max_packet_life_time"] = 0
        self.assertTrue(drill.finite_lifetimes([web_contract], unset=0))
        self.assertFalse(drill.finite_lifetimes([web_contract]))
        changed = json.loads(json.dumps(contract))
        changed["peers"].append({"channels": []})
        self.assertFalse(drill.finite_lifetimes([changed]))


class PostDelayTests(unittest.TestCase):
    def test_post_hold_selects_one_phase_sender_destination_and_starts_once(self) -> None:
        selected = {"from": 0, "marker": "consumed-1-0-8"}
        for seat, message in (
            (0, selected),
            (2, selected),
            (1, {"from": 2, "marker": "consumed-1-0-8"}),
            (1, {"from": False, "marker": "consumed-1-0-8"}),
            (1, {"from": 0.0, "marker": "consumed-1-0-8"}),
            (1, {"from": 0, "marker": "consumed-2-0-8"}),
            (1, {"from": 0, "marker": "consumed-1-0-16"}),
            (1, {"payload": {"Offer": "example"}}),
            (1, None),
        ):
            with self.subTest(seat=seat, message=message):
                delay = drill.PostDelay(6000)
                self.assertFalse(delay.begin(seat, message))
                self.assertIsNone(delay.started)
        self.assertFalse(drill.PostDelay().begin(1, selected))
        delay = drill.PostDelay(6000)
        with patch.object(drill.time, "monotonic", return_value=10):
            self.assertTrue(delay.begin(1, selected))
        with patch.object(drill.time, "monotonic", return_value=12):
            self.assertFalse(delay.begin(1, selected))
        self.assertEqual(delay.started, 10)
        delay.released = 16
        self.assertFalse(delay.begin(1, selected))

    def test_final_credits_require_both_directions_during_completed_hold(self) -> None:
        final = [
            (2, {"from": 0, "marker": "consumed-1-0-64"}),
            (0, {"from": 2, "marker": "consumed-1-2-64"}),
        ]
        for credit_time, release_time, expected in (
            (9, 16, False),
            (10, 16, True),
            (12, 15.9, False),
            (12, 16, True),
            (16, 16, False),
            (17, 16, False),
        ):
            with self.subTest(credit_time=credit_time, release_time=release_time):
                delay = drill.PostDelay(6000)
                for seat, message in final:
                    delay.record(seat, message)
                self.assertEqual(delay.credits, {})
                with patch.object(drill.time, "monotonic", return_value=10):
                    delay.begin(1, {"from": 0, "marker": "consumed-1-0-8"})
                with patch.object(drill.time, "monotonic", return_value=credit_time):
                    delay.record(*final[0])
                    self.assertFalse(delay.proven())
                    delay.record(*final[1])
                self.assertFalse(delay.proven())
                delay.released = release_time
                self.assertIs(delay.proven(), expected)
                self.assertIs(delay.snapshot()["independent_final_credits_while_held"], expected)

    def test_wrong_or_repeated_credits_cannot_supply_missing_direction(self) -> None:
        delay = drill.PostDelay(6000)
        with patch.object(drill.time, "monotonic", return_value=10):
            delay.begin(1, {"from": 0, "marker": "consumed-1-0-8"})
        with patch.object(drill.time, "monotonic", return_value=12):
            for seat, message in (
                (1, {"from": 0, "marker": "consumed-1-0-64"}),
                (2, {"from": 1, "marker": "consumed-1-0-64"}),
                (2, {"from": False, "marker": "consumed-1-0-64"}),
                (2, {"from": 0.0, "marker": "consumed-1-0-64"}),
                (2, {"from": 0, "marker": "consumed-2-0-64"}),
                (2, {"from": 0, "marker": "consumed-1-0-56"}),
                (0, None),
            ):
                delay.record(seat, message)
            self.assertEqual(delay.credits, {})
            delay.record(2, {"from": 0, "marker": "consumed-1-0-64"})
        with patch.object(drill.time, "monotonic", return_value=13):
            delay.record(2, {"from": 0, "marker": "consumed-1-0-64"})
        delay.released = 16
        self.assertFalse(delay.proven())
        self.assertEqual(delay.credits, {"consumed-1-0-64": 12})
        self.assertEqual(delay.snapshot()["final_credit_after_start_ms"], {"consumed-1-0-64": 2000})

    def test_delayed_post_response_keeps_other_destinations_and_gets_live(self) -> None:
        class Handler(drill.RelayHandler):  # type: ignore[name-defined,misc]
            queues: ClassVar[list[list[object]]] = [[], [], []]
            lock = threading.Lock()
            observation = drill.RelayObservation()
            credit_delay = drill.CreditDelay()
            post_delay = drill.PostDelay(6000)

        entered, release = threading.Event(), threading.Event()
        clock = [10.0]

        def hold(seconds: float) -> None:
            self.assertEqual(seconds, 6)
            entered.set()
            if not release.wait(5):
                raise RuntimeError("test did not release the POST response")

        server = drill.RelayServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        held = {"from": 0, "marker": "consumed-1-0-8"}
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)

        def delayed_post() -> bytes:
            client = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
            try:
                client.request("POST", "/signal/1", body=json.dumps(held))
                return client.getresponse().read()
            finally:
                client.close()

        try:
            with (
                patch.object(drill.time, "monotonic", side_effect=lambda: clock[0]),
                patch.object(drill.time, "sleep", side_effect=hold),
                ThreadPoolExecutor(max_workers=1) as pool,
            ):
                future = pool.submit(delayed_post)
                try:
                    self.assertTrue(entered.wait(5))
                    self.assertFalse(future.done())
                    connection.request("GET", "/signal/1")
                    self.assertEqual(json.loads(connection.getresponse().read()), [held])
                    clock[0] = 12
                    for seat, sender in ((2, 0), (0, 2)):
                        credit = {"from": sender, "marker": f"consumed-1-{sender}-64"}
                        connection.request("POST", f"/signal/{seat}", body=json.dumps(credit))
                        self.assertEqual(connection.getresponse().read(), b"{}")
                        connection.request("GET", f"/signal/{seat}")
                        self.assertEqual(json.loads(connection.getresponse().read()), [credit])
                    self.assertFalse(future.done())
                    self.assertFalse(Handler.post_delay.proven())
                    clock[0] = 16.1
                finally:
                    release.set()
                self.assertEqual(future.result(timeout=5), b"{}")
                self.assertTrue(Handler.post_delay.proven())
                self.assertEqual(Handler.post_delay.snapshot()["held_ms"], 6100)
        finally:
            release.set()
            connection.close()
            server.shutdown()
            server.server_close()
            thread.join()


class CreditDelayTests(unittest.TestCase):
    def test_hold_only_the_selected_credit_and_release_once(self) -> None:
        delay = drill.CreditDelay(6000)
        marker = {"marker": "consumed-1-1-8"}
        with patch.object(drill.time, "monotonic", return_value=10):
            self.assertFalse(delay.hold(1, marker))
            self.assertFalse(delay.hold(0, {"marker": "consumed-1-2-8"}))
            self.assertFalse(delay.hold(0, {"payload": {"Offer": "example"}}))
            self.assertTrue(delay.hold(0, marker))
        with patch.object(drill.time, "monotonic", return_value=15.999):
            self.assertTrue(delay.hold(0, marker))
        with patch.object(drill.time, "monotonic", return_value=16.1):
            self.assertFalse(delay.hold(0, marker))
        with patch.object(drill.time, "monotonic", return_value=20):
            self.assertFalse(delay.hold(0, marker))
        self.assertEqual(delay.snapshot()["held_ms"], 6100)
        self.assertTrue(delay.snapshot()["released"])
        self.assertFalse(drill.CreditDelay().hold(0, marker))

    def test_delay_verdict_requires_release_and_independent_gameplay(self) -> None:
        delay = drill.CreditDelay(6000)
        proof = {
            "sent": {"1": 8},
            "acknowledged": {"1": 0, "2": 64},
            "received": {"2": [32, 32, 64]},
        }
        self.assertFalse(delay.proven(proof))
        with patch.object(drill.time, "monotonic", return_value=10):
            delay.hold(0, {"marker": "consumed-1-1-8"})
        self.assertFalse(delay.proven(proof))
        with patch.object(drill.time, "monotonic", return_value=12):
            delay.record_proof(2, {"from": 0, "marker": "credit-hold-proof-1-0"})
        with patch.object(drill.time, "monotonic", return_value=16.1):
            delay.hold(0, {"marker": "consumed-1-1-8"})
        self.assertTrue(delay.proven(proof))
        self.assertEqual(delay.snapshot()["proof_after_hold_start_ms"], 2000)
        for field, key, value in [
            ("sent", "1", 9),
            ("acknowledged", "1", 8),
            ("acknowledged", "2", 56),
            ("received", "2", [32, 31, 64]),
        ]:
            changed = json.loads(json.dumps(proof))
            changed[field][key] = value
            self.assertFalse(delay.proven(changed))
        self.assertFalse(delay.proven({}))

    def test_late_proof_cannot_claim_gameplay_completed_during_hold(self) -> None:
        for proof_time in [None, 9, 16, 17]:
            with self.subTest(proof_time=proof_time):
                delay = drill.CreditDelay(6000)
                with patch.object(drill.time, "monotonic", return_value=10):
                    delay.hold(0, {"marker": "consumed-1-1-8"})
                if proof_time is not None:
                    with patch.object(drill.time, "monotonic", return_value=proof_time):
                        delay.record_proof(2, {"from": 0, "marker": "credit-hold-proof-1-0"})
                with patch.object(drill.time, "monotonic", return_value=18):
                    delay.hold(0, {"marker": "consumed-1-1-8"})
                self.assertFalse(delay.proof_during_hold())
        delay = drill.CreditDelay(6000)
        delay.record_proof(1, {"from": 0, "marker": "credit-hold-proof-1-0"})
        delay.record_proof(2, {"from": 1, "marker": "credit-hold-proof-1-0"})
        delay.record_proof(2, {"from": 0, "marker": "other"})
        self.assertIsNone(delay.proof_received)

    def test_held_credit_does_not_block_other_markers_or_signaling(self) -> None:
        class Handler(drill.RelayHandler):  # type: ignore[name-defined,misc]
            queues: ClassVar[list[list[object]]] = [[], [], []]
            lock = threading.Lock()
            observation = drill.RelayObservation()
            credit_delay = drill.CreditDelay(6000)

        server = drill.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever)
        thread.start()
        connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
        held = {"marker": "consumed-1-1-8"}
        other = [{"marker": "consumed-1-2-8"}, {"payload": {"Offer": "example"}}]
        try:
            for message in [held, *other]:
                connection.request("POST", "/signal/0", body=json.dumps(message))
                self.assertEqual(connection.getresponse().read(), b"{}")
            with patch.object(drill.time, "monotonic", return_value=10):
                connection.request("GET", "/signal/0")
                self.assertEqual(json.loads(connection.getresponse().read()), other)
            self.assertEqual(Handler.observation.snapshot()["queued_markers"], 1)
            with patch.object(drill.time, "monotonic", return_value=12):
                connection.request(
                    "POST",
                    "/signal/2",
                    body=json.dumps({"from": 0, "marker": "credit-hold-proof-1-0"}),
                )
                self.assertEqual(connection.getresponse().read(), b"{}")
                connection.request("GET", "/signal/2")
                connection.getresponse().read()
            self.assertTrue(Handler.credit_delay.proof_during_hold())
            with patch.object(drill.time, "monotonic", return_value=16.1):
                connection.request("GET", "/signal/0")
                self.assertEqual(json.loads(connection.getresponse().read()), [held])
            self.assertEqual(Handler.observation.snapshot()["queued_markers"], 0)
            connection.request("GET", "/signal/0")
            self.assertEqual(json.loads(connection.getresponse().read()), [])
        finally:
            connection.close()
            server.shutdown()
            server.server_close()
            thread.join()

    def test_lifetime_control_missing_or_failed_cannot_pass(self) -> None:
        for control, passed in [(None, False), ({"valid": False}, False), ({"valid": True}, True)]:
            output = "WEBRTC_INTEROP_PASS seat=0"
            if control is not None:
                output += "\nWEBRTC_LIFETIME_CONTROLS " + json.dumps(control)
            result = drill.seat_evidence(output, 0, require_lifetime_controls=True)
            self.assertEqual(result["passed"], passed)


class ObservationTests(unittest.TestCase):
    def test_credit_packet_report_matches_exact_peer_count_and_local_phase(self) -> None:
        for transport in ("http", "webrtc"):
            with self.subTest(transport=transport):
                issued = {"direction": "issued", "seat": 0, "count": 8, "tick_ms": 110, "error": 0}
                received = {
                    "direction": "received",
                    "seat": 2,
                    "count": 8,
                    "tick_ms": 9010,
                    "error": 0,
                }
                source = {
                    "phase": 1,
                    "credit_transport": transport,
                    "sent_by_target": {"2": 16},
                    "acknowledged_by_target": {"2": 8},
                    "credit_events": [received],
                }
                receiver = {
                    "phase": 1,
                    "credit_events": [
                        {**issued, "seat": 1},
                        {**issued, "count": 24},
                        issued,
                    ],
                }
                seats = [
                    {"seat": 0, "last_progress": source},
                    {"seat": 2, "last_progress": receiver},
                ]
                packets = drill.multi_peer_credit_diagnostics(seats, {})[0]["credit_packets"]
                self.assertEqual(
                    packets,
                    [
                        {"count": 8, "receiver_issue": issued, "sender_receipt": received},
                        {"count": 16, "receiver_issue": None, "sender_receipt": None},
                    ],
                )
                failed = {**issued, "count": 16, "error": 1}
                cast(list[dict[str, object]], receiver["credit_events"]).append(failed)
                packets = drill.multi_peer_credit_diagnostics(seats, {})[0]["credit_packets"]
                self.assertEqual(packets[1]["receiver_issue"], failed)
                self.assertIsNone(packets[1]["sender_receipt"])
                receiver["phase"] = 2
                packets = drill.multi_peer_credit_diagnostics(seats, {})[0]["credit_packets"]
                self.assertTrue(all(item["receiver_issue"] is None for item in packets))

    def test_credit_packet_report_keeps_missing_traces_unknown_and_bounded(self) -> None:
        for sent in (None, 0, 7, 8, 1000000):
            with self.subTest(sent=sent):
                seats = [
                    {
                        "seat": 0,
                        "last_progress": {
                            "phase": 1,
                            "sent_by_target": {"2": sent},
                            "credit_events": None,
                        },
                    }
                ]
                packets = drill.multi_peer_credit_diagnostics(seats, {})[0]["credit_packets"]
                self.assertEqual(len(packets), min(sent // 8, 8) if type(sent) is int else 0)
                self.assertTrue(all(item["receiver_issue"] is None for item in packets))
                self.assertTrue(all(item["sender_receipt"] is None for item in packets))

    def test_credit_report_joins_each_directed_window_without_guessing_missing_stages(self) -> None:
        sender = {
            "phase": 1,
            "tick_ms": 15000,
            "credit_transport": "http",
            "sent_by_target": {"2": 64},
            "acknowledged_by_target": {"2": 56},
            "credits_received_by_target": {"2": 7},
            "credit_wait_age_ms_by_target": {"2": 1200},
            "markers": [],
        }
        receiver = {
            "phase": 1,
            "tick_ms": 14300,
            "received_by_seat_and_mode": {"0": [32, 32, 64]},
            "credits_sent_by_target": {"0": 8},
            "sending_marker": "consumed-1-2-64",
            "sending_to": 0,
            "send_inflight_ms": 700,
        }
        seats = [{"seat": 0, "diagnostic": sender}, {"seat": 2, "last_progress": receiver}]
        row = drill.multi_peer_credit_diagnostics(seats, {})[0]
        self.assertEqual(row["receiver_consumed_chunks"], 64)
        self.assertEqual(row["receiver_credits_sent"], 8)
        self.assertEqual(row["sender_credits_received"], 7)
        self.assertEqual(row["window_wait_ms"], 1200)
        self.assertEqual(row["sender_tick_ms"], 15000)
        self.assertEqual(row["receiver_tick_ms"], 14300)
        self.assertEqual(
            row["http_credit"],
            {
                "marker": "consumed-1-2-64",
                "post": None,
                "post_inflight_ms": 700,
                "relay_pending_age_ms": None,
                "relay_dequeue_queue_ms": None,
                "relay_dequeue_age_ms": None,
                "sender_marker_observed": False,
            },
        )
        post = {"marker": "consumed-1-2-64", "to": 0, "elapsed_ms": 90, "http_code": 200}
        receiver.update(marker_posts=[post], sending_marker="other", sending_to=1)
        for relay, expected in (
            (
                {"pending_markers": [{"marker": "consumed-1-2-64", "seat": 0, "age_ms": 500}]},
                {"relay_pending_age_ms": 500, "relay_dequeue_queue_ms": None},
            ),
            (
                {
                    "recent_dequeues": [
                        {"marker": "consumed-1-2-64", "seat": 0, "queue_ms": 100, "age_ms": 400},
                        {"marker": "consumed-1-2-64", "seat": 1, "queue_ms": 999, "age_ms": 1},
                    ]
                },
                {"relay_pending_age_ms": None, "relay_dequeue_queue_ms": 100},
            ),
        ):
            with self.subTest(relay=relay):
                credit = drill.multi_peer_credit_diagnostics(seats, relay)[0]["http_credit"]
                self.assertEqual(credit["post"], post)
                self.assertIsNone(credit["post_inflight_ms"])
                for key, value in expected.items():
                    self.assertEqual(credit[key], value)

    def test_credit_report_keeps_phases_and_transports_separate(self) -> None:
        phase = {
            "phase": 1,
            "credit_transport": "webrtc",
            "sent_by_target": {"2": 8},
            "acknowledged_by_target": {"2": 0},
        }
        seats = [
            {"seat": 0, "last_progress": phase},
            {
                "seat": 2,
                "last_progress": {
                    "phase": 2,
                    "received_by_seat_and_mode": {"0": [32, 32, 64]},
                    "credits_sent_by_target": {"0": 8},
                },
            },
        ]
        row = drill.multi_peer_credit_diagnostics(seats, {})[0]
        self.assertEqual(row["transport"], "webrtc")
        self.assertNotIn("http_credit", row)
        self.assertIsNone(row["receiver_consumed_chunks"])
        self.assertIsNone(row["receiver_credits_sent"])
        phase["credit_transport"] = "http"
        phase["acknowledged_by_target"] = {"2": 8}
        self.assertNotIn("http_credit", drill.multi_peer_credit_diagnostics(seats, {})[0])
        self.assertEqual(drill.multi_peer_credit_diagnostics([{"seat": 0}], {}), [])

    def test_credit_report_uses_latest_local_tick_without_comparing_seat_clocks(self) -> None:
        def snapshot(tick: int, count: int) -> dict[str, object]:
            return {
                "phase": 1,
                "tick_ms": tick,
                "sent_by_target": {"2": count},
                "acknowledged_by_target": {"2": count},
            }

        seats = [
            {
                "seat": 0,
                "multi_peer_phases": [snapshot(1000, 64)],
                "last_progress": snapshot(900, 56),
                "diagnostic": snapshot(950, 56),
            },
            {
                "seat": 2,
                "last_progress": {
                    "phase": 1,
                    "tick_ms": 100,
                    "received_by_seat_and_mode": {"0": [32, 32, 64]},
                },
            },
        ]
        row = drill.multi_peer_credit_diagnostics(seats, {})[0]
        self.assertEqual(row["sent_chunks"], 64)
        self.assertEqual(row["receiver_consumed_chunks"], 64)
        self.assertEqual(row["sender_tick_ms"], 1000)
        self.assertEqual(row["receiver_tick_ms"], 100)

    def test_browser_terminals(self) -> None:
        for terminal in (
            "WEBRTC_INTEROP_PASS seat=1",
            'WEBRTC_INTEROP_FAIL {"stage":"peer channels open"}',
            "PAGE_ERROR WebAssembly trap",
            "BROWSER_CRASH",
            "SCRIPT ERROR: receiver aborted",
            "ERROR: Buffer full! Dropping data.",
        ):
            with self.subTest(terminal=terminal):
                page = Mock()
                process = Mock()
                messages: list[str] = []
                page.wait_for_timeout.side_effect = partial(
                    lambda output, marker, _: output.append(marker), messages, terminal
                )
                self.assertEqual(drill.observe_browser(cast(Page, page), process, messages), "")
                process.poll.assert_not_called()

    def test_second_browser_requires_its_own_terminal(self) -> None:
        page = Mock()
        process = Mock()
        process.poll.return_value = 0
        messages = ["WEBRTC_INTEROP_PASS seat=1"]
        with patch.object(drill.time, "monotonic", side_effect=[0, 0, 60]):
            self.assertIn(
                "timed out", drill.observe_browser(cast(Page, page), process, messages, seat=2)
            )
        messages.append("WEBRTC_INTEROP_PASS seat=2")
        self.assertEqual(drill.observe_browser(cast(Page, page), process, messages, seat=2), "")
        result = drill.seat_evidence("\n".join(messages[:-1]), 2)
        self.assertFalse(result["passed"])

    def test_multi_peer_history_keeps_per_sender_counts_before_stall(self) -> None:
        phase = {
            "phase": 1,
            "received_by_seat_and_mode": {"0": [32, 32, 64], "2": [32, 32, 64]},
            "reader_paused": True,
            "sent_by_target": {"0": 8, "2": 8},
            "acknowledged_by_target": {"0": 0, "2": 0},
            "credit_wait_age_ms_by_target": {"0": 1200, "2": 1200},
        }
        output = (
            "WEBRTC_MULTIPEER_PHASE "
            + drill.json.dumps(phase)
            + '\nWEBRTC_MULTIPEER_PHASE {"phase":2'
        )
        result = drill.seat_evidence(output, 1)
        self.assertEqual(result["multi_peer_phases"], [phase])
        self.assertFalse(result["passed"])

    def test_interruption_evidence_survives_later_stall(self) -> None:
        interruption = {
            "phase": 2,
            "seat": 0,
            "interrupted_snapshot": {
                "queued_before_close": 48,
                "queued_after_close": 24,
                "consumed_by_sender_and_mode": {"2": [8, 8, 8]},
                "selected_before_close": {"peer": 17, "mode": 2, "channel": 0},
                "selected_after_close": {"peer": 23, "mode": 2, "channel": 0},
            },
        }
        output = (
            "WEBRTC_MULTIPEER_INTERRUPTION "
            + drill.json.dumps(interruption)
            + '\nWEBRTC_MULTIPEER_INTERRUPTION {"phase":3'
            + '\nWEBRTC_INTEROP_FAIL {"stage":"fresh triangle notifications"}'
        )
        evidence = drill.seat_evidence(output, 0)
        self.assertEqual(evidence["multi_peer_interruptions"], [interruption])
        self.assertEqual(evidence["diagnostic"]["stage"], "fresh triangle notifications")
        self.assertFalse(evidence["passed"])

    def test_startup_requires_both_loaded_seats_and_reports_missing_engine(self) -> None:
        page = Mock()
        outputs = [(1, ["WEBRTC_MULTIPEER_LOADED seat=1"]), (2, [])]
        with (
            patch.object(drill.time, "monotonic", side_effect=[0, 0, 60]),
            self.assertRaisesRegex(RuntimeError, r"missing seats: \[2\]"),
        ):
            drill.wait_web_startup(cast(Page, page), outputs)
        outputs[1][1].append("WEBRTC_MULTIPEER_LOADED seat=2")
        drill.wait_web_startup(cast(Page, page), outputs)
        outputs[1][1].append("SCRIPT ERROR: startup aborted")
        with self.assertRaisesRegex(RuntimeError, "seat 2 failed during engine startup"):
            drill.wait_web_startup(cast(Page, page), outputs)

    def test_deadline_keeps_nonterminal_console_and_native_success(self) -> None:
        page = Mock()
        process = Mock()
        process.poll.return_value = 0
        messages = ["loading WEBRTC_INTEROP_scene", "WEBRTC_INTEROP_PASS seat=0"]
        with patch.object(drill.time, "monotonic", side_effect=[0, 0, 59, 60]):
            reason = drill.observe_browser(cast(Page, page), process, messages)
        self.assertEqual(reason, "browser observation timed out after 60 seconds")
        self.assertEqual(page.wait_for_timeout.call_count, 2)
        self.assertEqual(messages[-1], "WEBRTC_INTEROP_PASS seat=0")

    def test_longer_workload_keeps_a_bounded_driver_deadline(self) -> None:
        process = Mock()
        process.poll.return_value = 0
        page = Mock()
        with patch.object(drill.time, "monotonic", side_effect=[0, 0, 70, 120]):
            reason = drill.observe_browser(cast(Page, page), process, [], timeout_seconds=120)
        self.assertEqual(reason, "browser observation timed out after 120 seconds")
        self.assertEqual(page.wait_for_timeout.call_count, 2)

    def test_native_failure_reports_driver_stop(self) -> None:
        process = Mock()
        process.poll.return_value = 1
        reason = drill.observe_browser(cast(Page, Mock()), process, [])
        self.assertEqual(reason, "native seat exited before browser completion")

    def test_missing_native_exit_is_still_observed(self) -> None:
        process = Mock(spec=subprocess.Popen)
        process.poll.return_value = None
        with patch.object(drill.time, "monotonic", side_effect=[0, 0, 60]):
            reason = drill.observe_browser(cast(Page, Mock()), process, [])
        self.assertIn("timed out", reason)
        process.poll.assert_called_once()

    def test_failure_snapshot_preserves_counts_and_invalid_output(self) -> None:
        for body, expected in (
            (
                '{"stream_waiting_ack":"stream-6-192","burst_received":92}',
                {"stream_waiting_ack": "stream-6-192", "burst_received": 92},
            ),
            ("incomplete json", None),
        ):
            with self.subTest(body=body):
                output = "WEBRTC_INTEROP_FAIL " + body
                result = drill.seat_evidence(output, 0)
                self.assertFalse(result["passed"])
                self.assertEqual(result["failure"], output)
                self.assertEqual(result["diagnostic"], expected)

    def test_last_progress_survives_missing_terminal_and_truncated_line(self) -> None:
        output = "\n".join(
            [
                'WEBRTC_INTEROP_PROGRESS {"burst_received":32}',
                'WEBRTC_INTEROP_PROGRESS {"burst_received":64,"send_inflight_ms":250}',
                'WEBRTC_INTEROP_PROGRESS {"burst_received":',
            ]
        )
        result = drill.seat_evidence(output, 1)
        self.assertFalse(result["passed"])
        self.assertIsNone(result["diagnostic"])
        self.assertEqual(result["last_progress"], {"burst_received": 64, "send_inflight_ms": 250})

    def test_rpc_recovery_history_survives_later_failure(self) -> None:
        phase = {"phase": 1, "partial_received": 4, "retired_received": 0, "disconnected": 1}
        output = "\n".join(
            [
                'WEBRTC_RPC_RECOVERY_PHASE {"phase":1,"partial_received":4,"retired_received":0,"disconnected":1}',
                'WEBRTC_INTEROP_PROGRESS {"phase":2,"rpc_polling":false,"rpc_polls":142}',
                'WEBRTC_RPC_RECOVERY_PHASE {"phase":',
                'WEBRTC_INTEROP_FAIL {"stage":"recovery RPC disconnect notification"}',
            ]
        )
        evidence = drill.seat_evidence(output, 0)
        self.assertFalse(evidence["passed"])
        self.assertEqual(evidence["rpc_recovery_phases"], [phase])
        self.assertEqual(evidence["last_progress"]["rpc_polls"], 142)
        self.assertEqual(evidence["diagnostic"]["stage"], "recovery RPC disconnect notification")

    def test_engine_banner_records_actual_export_version(self) -> None:
        result = drill.seat_evidence(
            "Loading page\nGodot Engine v4.4.1.stable.official.49a5bc7b6\nWEBRTC_INTEROP_PASS seat=1",
            1,
        )
        self.assertEqual(result["engine_banner"], "Godot Engine v4.4.1.stable.official.49a5bc7b6")

    def test_evidence_keeps_last_completed_stage(self) -> None:
        output = "\n".join(
            [
                "interop ready: seat=1 phase=2 stage=remote ready marker elapsed_ms=12",
                "interop stage: seat=1 phase=2 stage=peer channels open",
            ]
        )
        result = drill.seat_evidence(output, 1)
        self.assertFalse(result["passed"])
        self.assertIn("peer channels open", result["last_stage"])
        self.assertIn("remote ready marker", result["last_ready"])


class RetirementMatrixTests(unittest.TestCase):
    def test_retirement_arguments_only_reach_multi_peer_scene(self) -> None:
        for multi_peer, fetch in (
            (False, None),
            (False, False),
            (False, True),
            (True, None),
            (True, False),
            (True, True),
        ):
            with (
                self.subTest(multi_peer=multi_peer, fetch=fetch),
                tempfile.TemporaryDirectory() as temporary,
            ):
                args = argparse.Namespace(
                    godot="godot",
                    web_godot=None,
                    chromium=None,
                    multi_peer=multi_peer,
                    mixed_traffic=False,
                    rpc_traffic=True,
                    rpc_recovery=False,
                    rpc_plan_recovery=False,
                    metadata_probe=False,
                    channel_receive=False,
                    safe_receive=False,
                    slow_receiver=False,
                    credit_transport="webrtc" if multi_peer else "http",
                    http_credit_delay_ms=0,
                    require_finite_lifetimes=False,
                )
                if fetch is not None:
                    args.web_http_fetch = fetch
                browser = MagicMock(version="154-test")
                playwright = MagicMock()
                playwright.__enter__.return_value.chromium.launch.return_value = browser
                process = Mock(returncode=0)
                process.poll.return_value = 0
                server = Mock(server_port=12345)
                with (
                    patch.object(drill, "RelayServer", return_value=server),
                    patch.object(drill.threading, "Thread"),
                    patch.object(drill, "sync_playwright", return_value=playwright),
                    patch.object(drill, "wait_web_startup"),
                    patch.object(drill, "observe_browser", return_value=""),
                    patch.object(drill.subprocess, "Popen", return_value=process) as popen,
                    patch.object(drill, "seat_evidence", wraps=drill.seat_evidence) as evidence,
                    self.assertRaisesRegex(RuntimeError, "Interoperability drill failed"),
                ):
                    drill.run_seats(
                        args,
                        Path(temporary) / "trial",
                        Path("native"),
                        Path("web"),
                        retirement_case=7,
                    )
                command = popen.call_args.args[0]
                self.assertIn("--rpc-traffic", command)
                self.assertEqual("--retirement-case=7" in command, multi_peer)
                self.assertEqual("--credit-transport=webrtc" in command, multi_peer)
                urls = [call.args[0] for call in browser.new_page.return_value.goto.call_args_list]
                self.assertEqual(len(urls), 2 if multi_peer else 1)
                expected_fetch = fetch is not False
                for url in urls:
                    self.assertEqual(url.count("http_fetch="), 1)
                    self.assertIn(f"http_fetch={int(expected_fetch)}", url)
                self.assertEqual(evidence.call_count, 3 if multi_peer else 2)
                for seat, call in enumerate(evidence.call_args_list):
                    self.assertEqual(call.args[1], seat)
                    self.assertIs(
                        call.kwargs.get("require_web_http_fetch"),
                        False if seat == 0 else expected_fetch,
                    )
                self.assertTrue(all("rpc_traffic=1" in url for url in urls))
                self.assertTrue(all(("retirement_case=7" in url) == multi_peer for url in urls))
                self.assertTrue(
                    all(("credit_transport=webrtc" in url) == multi_peer for url in urls)
                )

    def test_terminal_requires_all_phases_and_the_requested_case(self) -> None:
        phases = [
            "WEBRTC_MULTIPEER_PHASE " + drill.json.dumps({"phase": phase, "retirement_case": 7})
            for phase in (1, 2, 3)
        ]
        interruption = 'WEBRTC_MULTIPEER_INTERRUPTION {"retirement_case":7}'
        terminal = "WEBRTC_INTEROP_PASS seat=2"
        for records, expected_case, complete in (
            ([*phases, interruption, terminal], 7, True),
            ([*phases, interruption, terminal], 0, False),
            ([*phases, terminal], 7, False),
            ([*phases[:2], interruption, terminal], 7, False),
            ([terminal], 7, False),
        ):
            with self.subTest(records=records, expected_case=expected_case):
                evidence = drill.seat_evidence("\n".join(records), 2, retirement_case=expected_case)
                self.assertEqual(evidence["passed"], complete)
                self.assertEqual(evidence["scenario_complete"], complete)

    def test_credit_trial_requires_selected_transport_and_full_per_peer_credit(self) -> None:
        for transport in ("http", "webrtc"):
            for field, value in (
                (None, None),
                ("credit_transport", "other"),
                ("credits_sent_by_target", {"0": 8, "2": 7}),
                ("credits_received_by_target", {"0": 7, "2": 8}),
                ("credits_received_by_target", {"0": 8}),
                ("credits_sent_by_target", None),
                ("directed_targets", []),
            ):
                phases: list[dict[str, object]] = [
                    {
                        "phase": phase,
                        "retirement_case": 0,
                        "credit_transport": transport,
                        "directed_targets": [0, 2],
                        "credits_sent_by_target": {"0": 8, "2": 8},
                        "credits_received_by_target": {"0": 8, "2": 8},
                    }
                    for phase in (1, 2, 3)
                ]
                if field:
                    phases[1][field] = value
                lines = ["WEBRTC_MULTIPEER_PHASE " + json.dumps(phase) for phase in phases]
                lines += [
                    'WEBRTC_MULTIPEER_INTERRUPTION {"retirement_case":0}',
                    "WEBRTC_INTEROP_PASS seat=1",
                ]
                with self.subTest(transport=transport, field=field, value=value):
                    evidence = drill.seat_evidence(
                        "\n".join(lines), 1, retirement_case=0, credit_transport=transport
                    )
                    self.assertEqual(evidence["passed"], field is None)

    def test_rpc_trial_rejects_raw_only_or_incomplete_rpc_evidence(self) -> None:
        for missing in (None, "rpc_traffic", "same_safe_receiver", "rpc_service_poll_count", "rpc"):
            phases = [
                {
                    "phase": phase,
                    "retirement_case": 0,
                    "rpc_traffic": True,
                    "same_safe_receiver": True,
                    "rpc_service_poll_count": 10,
                    "rpc": {"failure": ""},
                }
                for phase in (1, 2, 3)
            ]
            if missing:
                del phases[1][missing]
            lines = ["WEBRTC_MULTIPEER_PHASE " + json.dumps(phase) for phase in phases]
            lines += [
                'WEBRTC_MULTIPEER_INTERRUPTION {"retirement_case":0}',
                "WEBRTC_INTEROP_PASS seat=1",
            ]
            evidence = drill.seat_evidence(
                "\n".join(lines), 1, retirement_case=0, require_multi_rpc=True
            )
            self.assertEqual(evidence["passed"], missing is None)

    def test_matrix_keeps_all_cases_after_failure_and_compares_both_addons(self) -> None:
        args = Mock(repeat=1, retirement_matrix=True, baseline=Path("/baseline"))
        visited: list[tuple[str, int]] = []

        def run_case(
            args: Mock, logs: Path, native: Path, web: Path, *, retirement_case: int
        ) -> None:
            visited.append((logs.parent.name, retirement_case))
            if retirement_case == 7 and logs.parent.name == "current":
                raise RuntimeError("queued survivor lost")

        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(drill, "prepare_pair", return_value=(Path("native"), Path("web"))),
            patch.object(drill, "run_seats", side_effect=run_case),
        ):
            directory = Path(temporary)
            with self.assertRaisesRegex(RuntimeError, "Interoperability trial failed"):
                drill.run(args, directory)
            results = drill.json.loads((directory / "summary.json").read_text())
        self.assertEqual(
            visited, [(name, case) for name in ("current", "baseline") for case in range(18)]
        )
        self.assertEqual(len(results), 36)
        self.assertEqual([item["retirement_case"] for item in results if not item["passed"]], [7])
        self.assertIn("queued survivor lost", results[7]["error"])
        self.assertEqual(len({item["logs"] for item in results}), 36)

    def test_default_runs_one_case_and_reverses_comparison_order(self) -> None:
        args = Mock(repeat=2, retirement_matrix=False, baseline=Path("/baseline"))
        with (
            tempfile.TemporaryDirectory() as temporary,
            patch.object(drill, "prepare_pair", return_value=(Path("native"), Path("web"))),
            patch.object(drill, "run_seats") as run_seats,
        ):
            drill.run(args, Path(temporary))
        self.assertEqual(
            [call.args[1].name for call in run_seats.call_args_list],
            ["current", "baseline", "baseline", "current"],
        )
        self.assertTrue(
            all(call.kwargs["retirement_case"] == 0 for call in run_seats.call_args_list)
        )


class BrowserObservationTests(unittest.TestCase):
    def test_browser_request_timings_survive_missing_engine_terminal(self) -> None:
        observation = drill.BrowserObservation("http://drill.test")
        request = Mock(spec=Request, url="http://drill.test/signal/1", method="GET")
        post = Mock(spec=Request, url="http://drill.test/signal/0", method="POST")
        with patch.object(drill.time, "monotonic", return_value=1):
            observation.started(request)
            observation.started(post)
            observation.console('WEBRTC_INTEROP_PROGRESS {"burst_sent":64}')
        with patch.object(drill.time, "monotonic", return_value=1.25):
            observation.finished(request)
        with patch.object(drill.time, "monotonic", return_value=3):
            result = observation.snapshot()
        self.assertEqual(result["completed_requests"], 1)
        self.assertEqual(result["failed_requests"], 0)
        self.assertEqual(result["last_progress_age_ms"], 2000)
        self.assertEqual(
            result["inflight_requests"],
            [{"method": "POST", "seat": "0", "marker": None, "age_ms": 2000}],
        )
        self.assertEqual(result["recent_requests"][0]["elapsed_ms"], 250)

    def test_credit_marker_stays_with_inflight_and_completed_request(self) -> None:
        observation = drill.BrowserObservation("http://drill.test")
        request = Mock(
            spec=Request,
            url="http://drill.test/signal/0",
            method="POST",
            post_data='{"to":0,"from":2,"marker":"consumed-1-2-64"}',
        )
        observation.started(request)
        self.assertEqual(
            observation.snapshot()["inflight_requests"][0]["marker"], "consumed-1-2-64"
        )
        observation.finished(request, failed=True)
        self.assertEqual(observation.snapshot()["recent_requests"][0]["marker"], "consumed-1-2-64")
        self.assertEqual(observation.markers, {})
        for body in ('{"payload":{"candidate":"sample"}}', "[]", "incomplete", '{"marker":3}'):
            request = Mock(
                spec=Request, url="http://drill.test/signal/1", method="POST", post_data=body
            )
            observation.started(request)
            observation.finished(request)
            self.assertIsNone(observation.snapshot()["recent_requests"][-1]["marker"])

    def test_request_history_is_bounded_and_scoped_to_signaling(self) -> None:
        observation = drill.BrowserObservation("http://drill.test")
        unrelated = Mock(spec=Request, url="http://drill.test/index.wasm", method="GET")
        observation.started(unrelated)
        observation.finished(unrelated)
        for _ in range(40):
            request = Mock(spec=Request, url="http://drill.test/signal/1", method="GET")
            observation.started(request)
            observation.finished(request, failed=True)
        result = observation.snapshot()
        self.assertEqual(result["failed_requests"], 40)
        self.assertEqual(result["completed_requests"], 0)
        self.assertEqual(len(result["recent_requests"]), 16)
        self.assertEqual(result["inflight_requests"], [])
        self.assertIsNone(result["last_progress_age_ms"])

    def test_stats_history_survives_missing_engine_progress(self) -> None:
        observation = drill.BrowserObservation("http://drill.test")
        with patch.object(drill.time, "monotonic", return_value=1):
            observation.console('WEBRTC_INTEROP_PROGRESS {"burst_received":32}')
        for count in range(20):
            with patch.object(drill.time, "monotonic", return_value=2 + count):
                observation.console(f'WEBRTC_BROWSER_STATS {{"created":{count}}}')
        for invalid in ("incomplete", "null", "[]", "42"):
            observation.console("WEBRTC_BROWSER_STATS " + invalid)
        with patch.object(drill.time, "monotonic", return_value=22):
            result = observation.snapshot()
        self.assertEqual(result["last_progress_age_ms"], 21000)
        self.assertEqual(result["last_stats_age_ms"], 1000)
        self.assertEqual(len(result["webrtc_stats"]), 16)
        self.assertEqual(result["webrtc_stats"][0], {"age_ms": 16000, "sample": {"created": 4}})
        self.assertEqual(result["webrtc_stats"][-1], {"age_ms": 1000, "sample": {"created": 19}})

    def test_engine_error_detection_keeps_normal_console_text(self) -> None:
        for output, failed in (
            ("ERROR: invalid packet", True),
            ("USER ERROR: invalid spawn", True),
            ("SCRIPT ERROR: bad call", True),
            ('interop stage: {"error":"ERROR: sample"}', False),
            ("Godot Engine ready", False),
        ):
            with self.subTest(output=output):
                self.assertEqual(drill.engine_failed(output), failed)

    def test_engine_error_or_crash_cannot_pass_despite_success_marker(self) -> None:
        for failure in ("BROWSER_CRASH", "ERROR: Invalid packet", "USER ERROR: Invalid spawn"):
            with self.subTest(failure=failure):
                result = drill.seat_evidence("WEBRTC_INTEROP_PASS seat=1\n" + failure, 1)
                self.assertFalse(result["passed"])


if __name__ == "__main__":
    unittest.main()
