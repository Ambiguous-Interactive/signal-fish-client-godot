#!/usr/bin/env python3
"""Assess browser reference Engine channels against native and Web Godot (#355)."""

import argparse
import functools
import hashlib
import importlib.util
import json
import math
import re
import shutil
import subprocess
import threading
import time
from collections.abc import Callable
from itertools import groupby
from pathlib import Path
from typing import ClassVar, Protocol, cast

from playwright.sync_api import Page, sync_playwright

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "webrtc_interop", ROOT / "scripts/check-webrtc-interop.py"
)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Could not load interoperability driver")
interop = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(interop)
NATIVE_SPEC = importlib.util.spec_from_file_location(
    "webrtc_native_reference", ROOT / "scripts/webrtc_native_reference.py"
)
if NATIVE_SPEC is None or NATIVE_SPEC.loader is None:
    raise RuntimeError("Could not load native reference bridge")
native_reference = importlib.util.module_from_spec(NATIVE_SPEC)
NATIVE_SPEC.loader.exec_module(native_reference)


class CreditDelayRelay(interop.RelayHandler):  # type: ignore[name-defined,misc]
    credit_delay_ms: ClassVar[int] = 0
    credit_seat: ClassVar[int] = 0
    credit_delayed = threading.Event()
    credit_hold_active = threading.Event()

    def reply(self, body: bytes) -> None:
        hold = False
        if (
            self.credit_delay_ms
            and self.command == "GET"
            and self.path == f"/signal/{self.credit_seat}"
        ):
            with self.lock:
                hold = not self.credit_delayed.is_set() and any(
                    isinstance(message, dict) and message.get("marker") == "snapshot-ack-1-32"
                    for message in json.loads(body)
                )
                if hold:
                    self.credit_delayed.set()
            if hold:
                self.credit_hold_active.set()
                try:
                    time.sleep(self.credit_delay_ms / 1000)
                finally:
                    self.credit_hold_active.clear()
        super().reply(body)


def page_failed(messages: list[str]) -> bool:
    return any(
        line.startswith(("PAGE_ERROR ", "CONSOLE_ERROR ", "BROWSER_CRASH")) for line in messages
    )


def watch_page(page: Page, messages: list[str]) -> None:
    page.on(
        "console",
        lambda message: messages.append(
            ("CONSOLE_ERROR " if message.type == "error" else "") + message.text
        ),
    )
    page.on("pageerror", lambda error: messages.append("PAGE_ERROR " + str(error)))
    page.on("crash", lambda _: messages.append("BROWSER_CRASH"))


class Observation(Protocol):
    def snapshot(self) -> dict[str, object]: ...


def observe_page(page: Page, url: str) -> Observation:
    observer = interop.BrowserObservation(url)
    page.on("console", lambda message: observer.console(message.text))
    page.on("request", observer.started)
    page.on("requestfinished", observer.finished)
    page.on("requestfailed", lambda request: observer.finished(request, failed=True))
    page.add_init_script(path=ROOT / "scripts/webrtc-browser-observation.js")
    return cast(Observation, observer)


def phase_evidence(output: str) -> list[object]:
    phases: list[object] = []
    for line in output.splitlines():
        if line.startswith("WEBRTC_REFERENCE_PHASE "):
            try:
                phases.append(json.loads(line.removeprefix("WEBRTC_REFERENCE_PHASE ")))
            except json.JSONDecodeError:
                continue
    return phases


def diagnostic_records(value: object) -> list[dict[str, object]]:
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, dict)]


def diagnostic_mapping(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def diagnostic_interval(start: object, end: object, scale: int = 1) -> float | None:
    if (
        type(start) not in (int, float)
        or type(end) not in (int, float)
        or not math.isfinite(cast(float, start))
        or not math.isfinite(cast(float, end))
        or cast(float, end) < cast(float, start)
    ):
        return None
    return round((cast(float, end) - cast(float, start)) / scale, 3)


def timing_distribution(rows: list[dict[str, object]], key: str) -> dict[str, object]:
    samples = sorted(
        (cast(float, row[key]), cast(int, row["sequence"]))
        for row in rows
        if row.get(key) is not None
    )
    count = len(samples)
    return {
        "count": count,
        "min_ms": samples[0][0] if samples else None,
        "p50_ms": samples[math.ceil(count * 0.5) - 1][0] if samples else None,
        "p95_ms": samples[math.ceil(count * 0.95) - 1][0] if samples else None,
        "max_ms": samples[-1][0] if samples else None,
        "max_sequence": samples[-1][1] if samples else None,
    }


def heartbeat_pause_diagnostics(
    rows: list[dict[str, object]], pause: dict[str, object], metrics: tuple[str, ...]
) -> dict[str, object] | None:
    values = [
        pause.get(key)
        for key in (
            "heartbeat_sent",
            "heartbeat_received",
            "heartbeat_sent_at_resume",
            "heartbeat_received_at_resume",
        )
    ]
    if not all(type(value) is int for value in values):
        return None
    sent, received, resumed_sent, resumed_received = cast(list[int], values)
    if (
        not 0 <= received <= sent <= resumed_sent <= 128
        or not received <= resumed_received <= resumed_sent
    ):
        return None
    return {
        "pre_pause_backlog": sent - received,
        "pre_pause_backlog_remaining_at_resume": max(0, sent - resumed_received),
        "sent_during_pause": resumed_sent - sent,
        "new_echoes_at_resume": max(0, resumed_received - sent),
        "new_echo_sequences_at_resume": list(range(sent, resumed_received)),
        "interval_scope": "Sequence cohorts use pause counters. Completed intervals may end after resume.",
        "intervals_ms": {
            cohort: {
                key: timing_distribution(
                    [row for row in rows if low <= cast(int, row["sequence"]) < high], key
                )
                for key in metrics
            }
            for cohort, low, high in (
                ("pre_pause_backlog", received, sent),
                ("sent_during_pause", sent, resumed_sent),
            )
        },
    }


def native_bridge_packet_diagnostics(timing: dict[str, object]) -> dict[str, object]:
    records = diagnostic_records(timing.get("records"))
    commands = {row.get("id"): row for row in records if row.get("stage") == "command"}
    written = {row.get("id"): row for row in records if row.get("stage") == "written"}
    replies = {row.get("id"): row for row in records if row.get("stage") == "reply"}
    outputs: dict[object, list[dict[str, object]]] = {}
    delivered: dict[object, list[dict[str, object]]] = {}
    for row in records:
        if row.get("stage") == "output":
            outputs.setdefault(row.get("marker"), []).append(row)
        elif row.get("stage") == "delivery" and row.get("event") in ("message", "binary"):
            delivered.setdefault(row.get("marker"), []).append(row)
    packets = []
    for command_id, command in commands.items():
        for packet in diagnostic_records(command.get("markers")):
            marker = packet.get("marker")
            output = outputs.get(marker, [])
            sends = [row for row in output if row.get("event") == "sent"]
            receives = [row for row in output if row.get("event") in ("message", "binary")]
            deliveries = delivered.get(marker, [])
            receipt = receives[0] if len(receives) == 1 else {}
            delivery = deliveries[0] if len(deliveries) == 1 else {}
            packets.append(
                {
                    **packet,
                    "command_id": command_id,
                    "pipe_write_ms": diagnostic_interval(
                        command.get("us"), written.get(command_id, {}).get("us"), 1000
                    ),
                    "command_reply_ms": diagnostic_interval(
                        command.get("us"), replies.get(command_id, {}).get("us"), 1000
                    ),
                    "reader_to_delivery_ms": diagnostic_interval(
                        receipt.get("us"), delivery.get("us"), 1000
                    ),
                    "native_send_outputs": sends,
                    "native_receive_outputs": receives,
                    "deliveries": deliveries,
                }
            )
    return {
        "packets": packets,
        "trace_overflow": timing.get("dropped"),
        "limits": "Intervals use only the bridge host clock. Delivery ends at HTTP event collection, before browser dispatch. Command replies can cover a packet batch. Missing or duplicate receive observations have no queue interval. Native enqueue is separate from SCTP transmission.",
    }


def heartbeat_diagnostics(
    godot: dict[str, object],
    reference: dict[str, object],
    bridge: dict[str, object] | None = None,
) -> dict[str, object]:
    phase = reference.get("phase")
    snapshot = diagnostic_mapping(reference.get("snapshot"))
    indexes = {
        key: {item.get("marker"): item for item in diagnostic_records(snapshot.get(key))}
        for key in ("packet_timings", "native_sent", "native_heartbeat_received")
    }
    echoes = {
        item.get("sequence"): item for item in diagnostic_records(godot.get("heartbeat_timings"))
    }
    consumer = {
        item.get("packet"): item for item in diagnostic_records(reference.get("receive_timings"))
    }
    rows: list[dict[str, object]] = []
    for timing in diagnostic_records(reference.get("heartbeat_timings"))[:128]:
        sequence = timing.get("sequence")
        if type(sequence) is not int or not 0 <= sequence < 128:
            continue
        marker = f"heartbeat:{phase}:reference:{sequence}"
        command = indexes["packet_timings"].get(marker, {})
        sent = indexes["native_sent"].get(marker, {})
        received = indexes["native_heartbeat_received"].get(marker, {})
        echo = echoes.get(sequence, {})
        consumed = consumer.get(marker, {})
        stages = {
            "application_enqueue": timing.get("enqueue_ms"),
            "bridge_dispatch": command.get("dispatch_ms"),
            "command_complete": command.get("complete_ms"),
            "native_send": sent.get("probe_us"),
            "godot_receive": echo.get("receive_ms"),
            "godot_echo": echo.get("echo_ms"),
            "native_receive": received.get("probe_us"),
            "native_channel_receive": received.get("received_us"),
            "reference_callback": consumed.get("callback_ms"),
            "reference_drain": consumed.get("drain_ms"),
            "application_echo": timing.get("echo_ms"),
        }
        rows.append(
            {
                "sequence": sequence,
                "observed_stages": [
                    key
                    for key, value in stages.items()
                    if diagnostic_interval(value, value) is not None
                ],
                "unobserved_stages": [
                    key
                    for key, value in stages.items()
                    if diagnostic_interval(value, value) is None
                ],
                "application_rtt_ms": diagnostic_interval(
                    timing.get("enqueue_ms"), timing.get("echo_ms")
                ),
                "bridge_queue_ms": diagnostic_interval(
                    command.get("enqueue_ms"), command.get("dispatch_ms")
                ),
                "command_ms": diagnostic_interval(
                    command.get("dispatch_ms"), command.get("complete_ms")
                ),
                "native_rtt_ms": diagnostic_interval(
                    sent.get("probe_us"), received.get("probe_us"), 1000
                ),
                "native_event_queue_ms": diagnostic_interval(
                    received.get("received_us"), received.get("probe_us"), 1000
                ),
                "native_channel_rtt_ms": diagnostic_interval(
                    sent.get("probe_us"), received.get("received_us"), 1000
                ),
                "godot_echo_ms": diagnostic_interval(echo.get("receive_ms"), echo.get("echo_ms")),
                "native_callback_rtt_ms": diagnostic_interval(
                    sent.get("callback_ms"), received.get("callback_ms")
                ),
                "reference_consumer_ms": diagnostic_interval(
                    consumed.get("callback_ms"), consumed.get("drain_ms")
                ),
                "command_failed": "failed_ms" in command,
            }
        )
    metrics = (
        "application_rtt_ms",
        "bridge_queue_ms",
        "command_ms",
        "native_rtt_ms",
        "native_event_queue_ms",
        "native_channel_rtt_ms",
        "godot_echo_ms",
        "native_callback_rtt_ms",
        "reference_consumer_ms",
    )
    return {
        "phase": phase,
        "heartbeat_sent": reference.get("heartbeat_sent"),
        "heartbeat_received": reference.get("heartbeat_received"),
        "pause": reference.get("receive_pause"),
        "trace_overflow": {
            key: snapshot.get(key)
            for key in (
                "timings_dropped",
                "native_sent_dropped",
                "native_heartbeat_received_dropped",
            )
        },
        "matched_samples": {key: sum(row[key] is not None for row in rows) for key in metrics},
        "max_ms": {
            key: max((cast(float, row[key]) for row in rows if row[key] is not None), default=None)
            for key in metrics
        },
        "intervals_ms": {key: timing_distribution(rows, key) for key in metrics},
        "pause_heartbeats": heartbeat_pause_diagnostics(
            rows, diagnostic_mapping(reference.get("receive_pause")), metrics
        ),
        "packets": rows,
        "bridge_packets": [
            packet
            for packet in diagnostic_records((bridge or {}).get("packets"))
            if isinstance(packet.get("marker"), str)
            and cast(str, packet["marker"]).startswith(f"heartbeat:{phase}:reference:")
        ],
    }


def snapshot_receive_diagnostics(
    godot: dict[str, object], callbacks: list[dict[str, object]], phase: object
) -> dict[str, object]:
    prefix = f"snapshot:{phase}:reference:"
    reads = diagnostic_records(godot.get("receive_timings"))

    def packets(records: list[dict[str, object]]) -> dict[int, dict[str, object]]:
        result: dict[int, dict[str, object]] = {}
        for record in records:
            identity = record.get("packet")
            if not isinstance(identity, str) or not identity.startswith(prefix):
                continue
            suffix = identity.removeprefix(prefix)
            if suffix.isascii() and suffix.isdecimal() and 0 <= int(suffix) < 128:
                result[int(suffix)] = record
        return result

    browser = packets(
        [record for channel in callbacks for record in diagnostic_records(channel.get("callbacks"))]
    )
    script = packets(reads)
    unread = sorted(browser.keys() - script.keys())
    validated = godot.get("snapshot_received")
    return {
        "phase": phase,
        "validated_prefix_packets": validated,
        "browser_callback_sequences": sorted(browser),
        "script_read_sequences": sorted(script),
        "callback_not_read_sequences": unread,
        "first_callback_not_read": unread[0] if unread else None,
        "first_read_after_gap": next(
            (
                sequence
                for sequence in sorted(script)
                if type(validated) is int and sequence > validated
            ),
            None,
        ),
        "browser_callback_snapshot_bytes": sum(
            cast(int, record["bytes"])
            for record in browser.values()
            if type(record.get("bytes")) is int
        ),
        "script_read_snapshot_bytes": sum(
            cast(int, record["bytes"])
            for record in script.values()
            if type(record.get("bytes")) is int
        ),
        "callback_trace_dropped": sum(
            cast(int, channel["dropped"])
            for channel in callbacks
            if type(channel.get("dropped")) is int
        ),
        "script_trace_dropped": godot.get("receive_timings_dropped"),
        "limits": "Callbacks and reads use separate clocks. Unread callbacks can be queued, cached, or dropped. Missing traces do not establish loss.",
    }


def reliable_backlog_diagnostics(
    browser: dict[str, list[dict[str, object]]],
    script: dict[str, list[dict[str, object]]],
    rejected: set[str],
    complete: bool,
) -> dict[str, object]:
    if not complete:
        return {
            "available": False,
            "peak": None,
            "terminal": None,
            "rejections": [],
            "heartbeats": [],
        }
    events: list[tuple[float, int, str]] = []
    for marker, rows in browser.items():
        events.append((cast(float, rows[0]["ms"]), 0, marker))
        if script.get(marker):
            events.append((cast(float, script[marker][0]["browser_ms"]), 1, marker))
    pending: dict[str, int] = {}
    peak: dict[str, object] | None = None
    rejections: list[dict[str, object]] = []
    heartbeats: dict[str, dict[str, object]] = {}

    def snapshot(at: float) -> dict[str, object]:
        kinds: dict[str, dict[str, int]] = {}
        for marker, size in pending.items():
            kind = marker.split(":", 1)[0]
            totals = kinds.setdefault(kind, {"packets": 0, "bytes": 0})
            totals["packets"] += 1
            totals["bytes"] += size
        return {
            "browser_ms": at,
            "packets": len(pending),
            "bytes": sum(pending.values()),
            "kinds": kinds,
        }

    events.sort()
    for (at, read), group in groupby(events, key=lambda event: event[:2]):
        markers = [marker for _, _, marker in group]
        for marker in markers:
            if read:
                pending.pop(marker)
            elif marker not in rejected:
                pending[marker] = cast(int, browser[marker][0]["bytes"])
        state = snapshot(at)
        state["boundary"] = "after_reads" if read else "after_callbacks"
        state["simultaneous_events"] = len(markers)
        if peak is None or cast(int, state["bytes"]) > cast(int, peak["bytes"]):
            peak = state
        for marker in markers:
            if not read and marker in rejected:
                rejections.append(
                    {"packet": marker, "bytes": browser[marker][0]["bytes"], "backlog": state}
                )
            if marker.startswith("heartbeat:"):
                heartbeat = heartbeats.setdefault(
                    marker, {"packet": marker, "rejected": marker in rejected, "at_read": None}
                )
                heartbeat["at_read" if read else "at_callback"] = state
    return {
        "available": True,
        "peak": peak,
        "terminal": snapshot(events[-1][0]) if events else None,
        "rejections": rejections,
        "heartbeats": list(heartbeats.values()),
    }


def browser_read_diagnostics(
    godot: dict[str, object],
    callbacks: list[dict[str, object]],
    phase: object,
    drops: dict[str, object] | None = None,
    pause: dict[str, object] | None = None,
) -> dict[str, object]:
    pattern = re.compile(
        rf"(?:snapshot|partial|heartbeat|startup):{phase}:reference:[0-9]+"
        rf"|(?:credit|partial-credit|startup-credit):{phase}:reference:godot:[0-9]+"
        rf"|reference:{phase}:reliable"
    )

    def index(records: list[dict[str, object]]) -> dict[str, list[dict[str, object]]]:
        result: dict[str, list[dict[str, object]]] = {}
        for row in records:
            marker = row.get("packet")
            if isinstance(marker, str) and pattern.fullmatch(marker):
                result.setdefault(marker, []).append(row)
        return result

    browser = index(
        [
            {
                **row,
                "peer": channel.get("peer"),
                "id": channel.get("id"),
                "label": channel.get("label"),
            }
            for channel in callbacks
            for row in diagnostic_records(channel.get("callbacks"))
        ]
    )
    script = index(diagnostic_records(godot.get("receive_timings")))
    invalid = []
    events: list[tuple[float, int]] = []
    latencies: dict[str, list[dict[str, object]]] = {
        kind: []
        for kind in (
            "snapshot",
            "partial",
            "heartbeat",
            "startup",
            "credit",
            "partial-credit",
            "startup-credit",
            "reference",
        )
    }
    for marker, rows in browser.items():
        callback = rows[0]
        read_rows = script.get(marker, [])
        size = callback.get("bytes")
        at = callback.get("ms")
        if (
            len(rows) != 1
            or callback.get("label") != "reliable"
            or len(read_rows) > 1
            or type(size) is not int
            or size < 0
            or diagnostic_interval(at, at) is None
        ):
            invalid.append(marker)
            continue
        events.append((cast(float, at), size))
        if not read_rows:
            continue
        read = read_rows[0]
        latency = diagnostic_interval(at, read.get("browser_ms"))
        if (
            latency is None
            or type(read.get("bytes")) is not int
            or read["bytes"] != size
            or type(read.get("mode")) is not int
            or read["mode"] != 2
        ):
            invalid.append(marker)
            continue
        events.append((cast(float, read["browser_ms"]), -size))
        kind = marker.split(":")[0]
        echo_latency = diagnostic_interval(read.get("browser_ms"), read.get("echo_browser_ms"))
        sample: dict[str, object] = {
            "sequence": 0 if kind == "reference" else int(marker.split(":")[-1]),
            "callback_to_read_ms": latency,
            "read_to_echo_ms": echo_latency,
            "callback_to_echo_ms": diagnostic_interval(at, read.get("echo_browser_ms"))
            if echo_latency is not None
            else None,
        }
        latencies[kind].append(sample)
    unmatched = sorted(script.keys() - browser.keys())
    dropped = sum(
        cast(int, channel["dropped"])
        for channel in callbacks
        if type(channel.get("dropped")) is int
    )
    script_dropped = godot.get("receive_timings_dropped")
    occupancy_valid = (
        bool(browser)
        and type(script_dropped) is int
        and script_dropped == 0
        and all(
            type(channel.get("dropped")) is int and channel["dropped"] == 0 for channel in callbacks
        )
        and not (invalid or unmatched)
    )
    first_drop = next(
        (
            drop
            for drop in diagnostic_records((drops or {}).get("records"))
            if isinstance(diagnostic_mapping(drop.get("preceding_callback")).get("packet"), str)
            and pattern.fullmatch(
                cast(str, diagnostic_mapping(drop.get("preceding_callback"))["packet"])
            )
            and diagnostic_interval(drop.get("ms"), drop.get("ms")) is not None
        ),
        None,
    )
    raw_drop_records = (drops or {}).get("records")
    drop_records = diagnostic_records(raw_drop_records)
    read_records = godot.get("receive_timings")
    receipt_trace_complete = (
        isinstance(read_records, list)
        and all(isinstance(row, dict) for row in read_records)
        and all(
            isinstance(channel.get("callbacks"), list)
            and all(isinstance(row, dict) for row in cast(list[object], channel["callbacks"]))
            for channel in callbacks
        )
    )
    matching_drops: dict[str, list[dict[str, object]]] = {}
    unresolved_drops = []
    for drop in drop_records:
        preceding = diagnostic_mapping(drop.get("preceding_callback"))
        drop_marker = preceding.get("packet")
        if not isinstance(drop_marker, str):
            unresolved_drops.append(drop)
            continue
        if not pattern.fullmatch(drop_marker):
            continue
        rows = browser.get(drop_marker, [])
        callback = rows[0] if len(rows) == 1 else {}
        peer = callback.get("peer")
        if (
            not occupancy_valid
            or not receipt_trace_complete
            or drop.get("callback_scope") != "engine_onmessage"
            or not callback
            or script.get(drop_marker)
            or type(peer) is not int
            or peer <= 0
            or type(preceding.get("peer")) is not int
            or type(callback.get("id")) is not int
            or cast(int, callback["id"]) < 0
            or type(preceding.get("id")) is not int
            or type(preceding.get("bytes")) is not int
            or any(
                preceding.get(key) != callback.get(key)
                for key in ("peer", "id", "label", "packet", "ms", "bytes")
            )
            or diagnostic_interval(preceding.get("ms"), drop.get("ms")) is None
        ):
            unresolved_drops.append(drop)
            continue
        matching_drops.setdefault(drop_marker, []).append(drop)
    for marker in list(matching_drops):
        if len(matching_drops[marker]) != 1:
            unresolved_drops.extend(matching_drops.pop(marker))
    drop_adjusted_valid = (
        occupancy_valid
        and receipt_trace_complete
        and isinstance(raw_drop_records, list)
        and all(isinstance(row, dict) for row in raw_drop_records)
        and type((drops or {}).get("dropped")) is int
        and (drops or {})["dropped"] == 0
        and not unresolved_drops
    )
    adjusted_events = list(events)
    for marker in matching_drops:
        callback = browser[marker][0]
        adjusted_events.remove((cast(float, callback["ms"]), cast(int, callback["bytes"])))
    adjusted_pending = adjusted_peak = 0
    for _, delta in sorted(adjusted_events, key=lambda event: (event[0], -event[1])):
        adjusted_pending += delta
        adjusted_peak = max(adjusted_peak, adjusted_pending)
    at_drop = None
    if first_drop is not None and occupancy_valid:
        at_drop = sum(delta for at, delta in events if at <= cast(float, first_drop["ms"]))
    pending = peak = 0
    # Equal timestamps keep arrivals before reads, giving the conservative peak.
    for _, delta in sorted(events, key=lambda event: (event[0], -event[1])):
        pending += delta
        peak = max(peak, pending)
    return {
        "phase": phase,
        "available": bool(browser),
        "clock": "browser performance.now; script read timestamps are sampled after get_packet",
        "latency_ms": {
            kind: timing_distribution(rows, "callback_to_read_ms")
            for kind, rows in latencies.items()
        },
        "pause_heartbeats": heartbeat_pause_diagnostics(
            latencies["heartbeat"],
            pause or {},
            ("callback_to_read_ms", "read_to_echo_ms", "callback_to_echo_ms"),
        ),
        "heartbeat_echo_latency_ms": {
            key: timing_distribution(latencies["heartbeat"], key)
            for key in ("read_to_echo_ms", "callback_to_echo_ms")
        },
        "reliable_backlog": reliable_backlog_diagnostics(
            browser, script, set(matching_drops), drop_adjusted_valid
        ),
        "unread_packets": sorted(browser.keys() - script.keys()),
        "matched_buffer_drop_packets": sorted(matching_drops),
        "unread_without_matched_drop_packets": sorted(
            browser.keys() - script.keys() - matching_drops.keys()
        ),
        "unresolved_buffer_drop_records": unresolved_drops,
        "peak_tracked_unread_payload_bytes_excluding_matched_drops": adjusted_peak
        if drop_adjusted_valid
        else None,
        "terminal_tracked_unread_payload_bytes_excluding_matched_drops": adjusted_pending
        if drop_adjusted_valid
        else None,
        "unmatched_script_packets": unmatched,
        "invalid_intervals": sorted(invalid),
        "peak_tracked_unread_payload_bytes": peak if occupancy_valid else None,
        "terminal_tracked_unread_payload_bytes": pending if occupancy_valid else None,
        "first_tracked_buffer_drop": first_drop,
        "drop_trace_dropped": (drops or {}).get("dropped"),
        "tracked_unread_payload_bytes_at_first_drop": at_drop,
        "callback_trace_dropped": dropped
        if all(type(channel.get("dropped")) is int for channel in callbacks)
        else None,
        "script_trace_dropped": script_dropped,
        "channel_in_buffer_kb": godot.get("channel_in_buffer_kb"),
        "limits": "Tracks reliable snapshot, partial, startup, initial probe, heartbeat and credit payloads only. Unread bytes can be queued, cached or dropped. Adjusted totals remove only unique peer/label/packet/time/size-matched buffer-drop observations with complete traces and no script receipt. Unresolved drop records keep adjusted totals unavailable. Backlog snapshots group retained payloads by kind at peak, rejection and heartbeat callback/read boundaries. Snapshots cover whole tied callback or read groups; callbacks precede reads conservatively. At-read backlog excludes that heartbeat and all other reads at that timestamp. This is not engine ring occupancy; framing, physical prefetch timing and other packets are excluded. Instrumentation reads the browser clock after script reads and heartbeat echo sends. Echo send completion does not prove remote receipt.",
    }


def packet_delivery_diagnostics(
    godot: dict[str, object],
    reference: dict[str, object],
    callbacks: list[dict[str, object]],
    phase: object,
) -> dict[str, object]:
    pattern = re.compile(
        rf"(?:snapshot|partial|heartbeat|startup|position|ordered):{phase}:reference:[0-9]+"
        rf"|reference:{phase}:(?:reliable|unreliable)"
        rf"|retirement:{phase}:(?:reliable|unreliable|tail)"
    )
    snapshot = diagnostic_mapping(reference.get("snapshot"))
    stages: dict[str, dict[str, list[dict[str, object]]]] = {}
    sources = {
        "command": diagnostic_records(snapshot.get("packet_timings")),
        "native_send": diagnostic_records(snapshot.get("native_sent")),
        "browser_callback": [
            {**row, "label": channel.get("label"), "peer": channel.get("peer")}
            for channel in callbacks
            for row in diagnostic_records(channel.get("callbacks"))
        ],
        "script_read": diagnostic_records(godot.get("receive_timings")),
    }
    for stage, records in sources.items():
        for row in records:
            marker = row.get("marker" if stage in ("command", "native_send") else "packet")
            if isinstance(marker, str) and pattern.fullmatch(marker):
                stages.setdefault(marker, {}).setdefault(stage, []).append(row)
    for label in ("reliable", "unreliable"):
        stages.setdefault(f"reference:{phase}:{label}", {})
    packets = []
    for marker, evidence in sorted(stages.items()):
        kind = marker.split(":")[0]
        label = (
            marker.split(":")[-1]
            if kind in ("reference", "retirement") and not marker.endswith(":tail")
            else {"retirement": "unreliable", "position": "unreliable", "ordered": "ordered"}.get(
                kind, "reliable"
            )
        )
        mode = {"unreliable": 0, "ordered": 1, "reliable": 2}[label]
        mismatches = [
            stage
            for stage, rows in evidence.items()
            if any(
                (type(row.get("mode")) is not int or row["mode"] != mode)
                if stage == "script_read"
                else row.get("label") != label
                for row in rows
            )
        ]
        packets.append(
            {
                "packet": marker,
                "kind": "initial_probe" if kind == "reference" else kind,
                "expected_label": label,
                "expected_mode": mode,
                "stages": evidence,
                "unobserved_stages": [stage for stage in sources if stage not in evidence],
                "duplicate_stages": [stage for stage, rows in evidence.items() if len(rows) > 1],
                "metadata_mismatch_stages": mismatches,
            }
        )
    return {
        "phase": phase,
        "packets": packets,
        "sent_not_read": [
            row["packet"]
            for row in packets
            if "native_send" in diagnostic_mapping(row["stages"])
            and "script_read" not in diagnostic_mapping(row["stages"])
        ],
        "callback_not_read": [
            row["packet"]
            for row in packets
            if "browser_callback" in diagnostic_mapping(row["stages"])
            and "script_read" not in diagnostic_mapping(row["stages"])
        ],
        "trace_overflow": {
            "command": snapshot.get("timings_dropped"),
            "native_send": snapshot.get("native_sent_dropped"),
            "script_read": godot.get("receive_timings_dropped"),
            "browser_channels": [
                {
                    "peer": channel.get("peer"),
                    "label": channel.get("label"),
                    "dropped": channel.get("dropped"),
                }
                for channel in callbacks
            ],
        },
        "limits": "Stages have separate clocks. Native send is an enqueue observation, not SCTP transmission or acknowledgement. Unobserved stages and sent packets without reads do not prove loss or expiry. Duplicates and metadata mismatches remain explicit. Payload validation and strict gameplay verdicts remain separate.",
    }


def unique_send_boundary(
    before: dict[str, object], after: dict[str, object], label: str, stream: int
) -> bool:
    previous_stats = diagnostic_mapping(before.get("sctp"))
    current_stats = diagnostic_mapping(after.get("sctp"))
    previous = diagnostic_mapping(previous_stats.get("last_enqueued_message"))
    current = diagnostic_mapping(current_stats.get("last_enqueued_message"))
    previous_id, current_id = previous.get("message_id"), current.get("message_id")
    if "last_enqueued_message" not in previous_stats or type(current_id) is not int:
        return False
    if previous_stats["last_enqueued_message"] is None:
        if current_id != 0:
            return False
    elif type(previous_id) is not int or previous_id < 0 or current_id != previous_id + 1:
        return False
    counts = []
    for snapshot in (before, after):
        channels = snapshot.get("transport_channels")
        if not isinstance(channels, list) or not channels:
            return False
        values: dict[tuple[str, int], int] = {}
        for row in channels:
            if (
                not isinstance(row, dict)
                or not isinstance(row.get("label"), str)
                or type(row.get("stream_id")) is not int
                or type(row.get("messages_sent")) is not int
                or row["messages_sent"] < 0
            ):
                return False
            key = (row["label"], row["stream_id"])
            if key in values:
                return False
            values[key] = row["messages_sent"]
        counts.append(values)
    first, last = counts
    target = (label, stream)
    return (
        target in first
        and first.keys() == last.keys()
        and all(last[key] == value + (key == target) for key, value in first.items())
    )


def sender_sample_trace_complete(value: object) -> bool:
    if not isinstance(value, list):
        return False
    for row in value:
        if not isinstance(row, dict):
            return False
        snapshot = row.get("snapshot")
        terminal = row.get("stage") in ("close", "snapshot")
        if (
            row.get("stage") not in ("send", "receive", "close", "snapshot")
            or type(row.get("generation")) is not int
            or row["generation"] <= 0
            or type(row.get("probe_us")) is not int
            or row["probe_us"] < 0
            or not isinstance(snapshot, dict)
            or type(snapshot.get("generation")) is not int
            or snapshot["generation"] != row["generation"]
            or "sctp_error" not in snapshot
            or (
                snapshot["sctp_error"] is not None
                and not (terminal and isinstance(snapshot["sctp_error"], str))
            )
            or "sctp" not in snapshot
            or (
                not isinstance(snapshot["sctp"], dict)
                and not (terminal and snapshot["sctp"] is None)
            )
            or (
                row["stage"] == "send"
                and any(
                    not isinstance(row.get(key), str) or not row[key] for key in ("marker", "label")
                )
            )
        ):
            return False
    return True


def packet_sender_diagnostics(
    reference: dict[str, object],
    evidence: dict[str, object],
    marker: str,
    label: str,
    stream: int,
    received: bool | None,
) -> dict[str, object]:
    samples = diagnostic_records(evidence.get("samples"))
    identity_fields = ("message_id", "stream_id", "stream_generation", "sequence_number")
    enqueues = [
        row for row in samples if row.get("stage") == "send" and row.get("marker") == marker
    ]
    identity: dict[str, object] = {}
    matches = []
    if len(enqueues) == 1 and sender_sample_trace_complete(evidence.get("samples")):
        enqueue = enqueues[0]
        snapshot = diagnostic_mapping(enqueue.get("snapshot"))
        candidate = diagnostic_mapping(
            diagnostic_mapping(snapshot.get("sctp")).get("last_enqueued_message")
        )
        generation, at = enqueue.get("generation"), enqueue.get("probe_us")
        before = diagnostic_mapping(enqueue.get("before_snapshot"))
        native_generation = diagnostic_mapping(reference.get("snapshot")).get("generation")
        valid = (
            type(evidence.get("dropped")) is int
            and evidence["dropped"] == 0
            and type(native_generation) is int
            and native_generation == generation
            and type(generation) is int
            and generation > 0
            and type(snapshot.get("generation")) is int
            and snapshot["generation"] == generation
            and "sctp_error" in snapshot
            and snapshot["sctp_error"] is None
            and type(before.get("generation")) is int
            and before["generation"] == generation
            and "sctp_error" in before
            and before["sctp_error"] is None
            and unique_send_boundary(before, snapshot, label, stream)
            and type(at) is int
            and at >= 0
            and enqueue.get("label") == label
            and all(
                type(candidate.get(key)) is int and cast(int, candidate[key]) >= 0
                for key in identity_fields
            )
            and candidate.get("stream_id") == stream
            and candidate.get("unordered") is (label == "unreliable")
            and candidate.get("reliability") == ("reliable" if label == "reliable" else "lifetime")
        )
        if valid:
            identity = candidate
            for row in samples:
                later = diagnostic_mapping(row.get("snapshot"))
                if (
                    type(row.get("generation")) is not int
                    or row["generation"] != generation
                    or type(later.get("generation")) is not int
                    or later["generation"] != generation
                    or "sctp_error" not in later
                    or later["sctp_error"] is not None
                    or type(row.get("probe_us")) is not int
                    or cast(int, row["probe_us"]) < cast(int, at)
                ):
                    continue
                stats = diagnostic_mapping(later.get("sctp"))
                for field in ("first_abandoned_message", "last_abandoned_message"):
                    abandoned = diagnostic_mapping(stats.get(field))
                    if (
                        all(
                            type(abandoned.get(key)) is int and abandoned[key] == identity[key]
                            for key in identity_fields
                        )
                        and abandoned.get("unordered") is identity["unordered"]
                        and abandoned.get("reliability") == identity["reliability"]
                        and type(abandoned.get("transmission_selected")) is bool
                    ):
                        matches.append(
                            {
                                "line": row.get("line"),
                                "stage": row.get("stage"),
                                "probe_us": row["probe_us"],
                                "field": field,
                                "transmission_selected": abandoned["transmission_selected"],
                            }
                        )
    selected = {match["transmission_selected"] for match in matches}
    result = "receipt_observed" if received else "unresolved"
    if matches:
        if received or len(selected) != 1 or label == "reliable":
            result = "conflicting_evidence"
        else:
            result = "abandoned_after_selection" if True in selected else "expired_before_selection"
    return {
        "packet": marker,
        "received": received,
        "enqueue_observations": len(enqueues),
        "generation": enqueues[0].get("generation") if len(enqueues) == 1 else None,
        "identity": identity or None,
        "abandonment_matches": matches,
        "sender_result": result,
    }


def initial_probe_diagnostics(
    godot: dict[str, object],
    reference: dict[str, object],
    evidence: dict[str, object],
    phase: object,
) -> dict[str, object]:
    receipts = godot.get("received")
    probes = [
        packet_sender_diagnostics(
            reference,
            evidence,
            f"reference:{phase}:{label}",
            label,
            stream,
            label in receipts if isinstance(receipts, list) else None,
        )
        for stream, label in ((1, "reliable"), (3, "unreliable"))
    ]
    return {
        "phase": phase,
        "strict_initial_probes_passed": initial_probes_passed(godot)
        and initial_probes_passed(reference),
        "godot_to_native_received": reference.get("received"),
        "native_to_godot": probes,
        "samples_dropped": evidence.get("dropped"),
        "limits": "Only unique before/after enqueue increments and matching association, stream incarnation and message identities establish abandonment. Older after-only probes remain unresolved. False transmission_selected proves no fragment selection. True does not prove emission or receipt. First/last samples omit intermediate abandonments; absent matches remain unresolved. Strict receipt checks stay separate.",
    }


def retirement_delivery_diagnostics(
    godot: dict[str, object],
    reference: dict[str, object],
    evidence: dict[str, object],
    callbacks: list[dict[str, object]],
    phase: object,
) -> dict[str, object]:
    packets = []
    for suffix, label in (
        ("unreliable", "unreliable"),
        ("reliable", "reliable"),
        ("tail", "unreliable"),
    ):
        marker = f"retirement:{phase}:{suffix}"
        arrivals = [
            {
                **row,
                "peer": channel.get("peer"),
                "id": channel.get("id"),
                "label": channel.get("label"),
            }
            for channel in callbacks
            for row in diagnostic_records(channel.get("callbacks"))
            if row.get("packet") == marker
        ]
        sender = packet_sender_diagnostics(
            reference,
            evidence,
            marker,
            label,
            1 if label == "reliable" else 3,
            True if arrivals else None,
        )
        packets.append(
            {
                **sender,
                "browser_callbacks": arrivals,
                "callback_metadata_mismatch": any(
                    row.get("label") != label or row.get("bytes") != len(marker) for row in arrivals
                ),
            }
        )
    return {
        "phase": phase,
        "packets": packets,
        "queued_arrival": diagnostic_mapping(godot.get("retirement")).get("queued_arrival"),
        "samples_dropped": evidence.get("dropped"),
        "limits": "A browser callback proves JavaScript arrival only. Cached retirement packets can remain unread by design. Missing callbacks do not prove loss; native runs have no browser callback trace. Sender abandonment needs unique before/after enqueue boundaries. Strict queued-retirement checks stay separate.",
    }


def http_request_diagnostics(
    state: dict[str, object], resources: dict[str, object]
) -> dict[str, object]:
    entries = diagnostic_records(resources.get("records"))
    clients: dict[str, object] = {}
    for name in ("http_inbox", "http_outbox"):
        evidence = diagnostic_mapping(state.get(name))
        requests = []
        for record in diagnostic_records(evidence.get("marker_requests")):
            started = diagnostic_mapping(record.get("started"))
            completed = diagnostic_mapping(record.get("completed"))
            start = started.get("browser_ms")
            end = completed.get("browser_ms")
            matches = [
                entry
                for entry in entries
                if entry.get("seat") == record.get("seat")
                and diagnostic_interval(start, entry.get("start_ms")) is not None
                and diagnostic_interval(entry.get("start_ms"), entry.get("response_end_ms"))
                is not None
                and diagnostic_interval(entry.get("response_end_ms"), end) is not None
            ]
            resource = matches[0] if len(matches) == 1 else {}
            requests.append(
                {
                    **record,
                    "resource_matches": len(matches),
                    "resource": resource,
                    "submit_ms": diagnostic_interval(start, resource.get("start_ms")),
                    "response_ms": diagnostic_interval(
                        resource.get("start_ms"), resource.get("response_end_ms")
                    ),
                    "completion_ms": diagnostic_interval(resource.get("response_end_ms"), end),
                    "total_ms": diagnostic_interval(start, end),
                    "frames": diagnostic_interval(started.get("frame"), completed.get("frame")),
                }
            )
        clients[name] = {
            "completed": evidence.get("completed"),
            "active": evidence.get("active"),
            "marker_overflow": evidence.get("marker_overflow"),
            "history_included": evidence.get("history_included"),
            "history_source": evidence.get("history_source", "snapshot"),
            "requests": requests,
        }
    return {
        "clients": clients,
        "resources_dropped": resources.get("dropped"),
        "limits": "Intervals use the Godot page's browser clock. Unique resource matches only. "
        "Resource timing does not locate SCTP loss. Native requests have no browser intervals.",
    }


def gameplay_diagnostics(report: dict[str, object], output: str) -> dict[str, object]:
    bridge = native_bridge_packet_diagnostics(diagnostic_mapping(report.get("native_timing")))
    evidence = diagnostic_mapping(report.get("godot_evidence"))
    failure = diagnostic_mapping(evidence.get("diagnostic"))
    progress = diagnostic_mapping(evidence.get("last_progress"))
    godot_phases = diagnostic_records(report.get("godot_phases"))
    ref = diagnostic_mapping(report.get("reference"))
    reference_phases = diagnostic_records(ref.get("phases"))
    terminal = diagnostic_mapping(report.get("reference_terminal"))
    if terminal and not any(
        item.get("phase") == terminal.get("phase") for item in reference_phases
    ):
        reference_phases = [*reference_phases, terminal]
    local = {item.get("phase"): item for item in godot_phases}
    completed_phases = set(local)
    for item in (progress, failure):
        if (
            item
            and item.get("phase") not in completed_phases
            and isinstance(item.get("reference"), dict)
        ):
            local[item.get("phase")] = diagnostic_mapping(item["reference"])
    state_fields = (
        "phase",
        "reason",
        "stage",
        "max_stage_frame_gap_ms",
        "receive_inflight_ms",
        "pending_signals",
        "queued_packets",
        "last_marker_sent",
        "last_marker_received",
        "peers",
    )
    state = failure or progress
    http_state = state
    http_events: dict[str, list[dict[str, object]]] = {"http_inbox": [], "http_outbox": []}
    for line in output.splitlines():
        if line.startswith("WEBRTC_HTTP_REQUEST "):
            try:
                event = diagnostic_mapping(json.loads(line.removeprefix("WEBRTC_HTTP_REQUEST ")))
            except json.JSONDecodeError:
                continue
            if event.get("method") in (0, 2):
                http_events["http_inbox" if event["method"] == 0 else "http_outbox"].append(event)
        if line.startswith("WEBRTC_HTTP_EVIDENCE "):
            try:
                http_state = diagnostic_mapping(
                    json.loads(line.removeprefix("WEBRTC_HTTP_EVIDENCE "))
                )
            except json.JSONDecodeError:
                continue
    http_state = dict(http_state)
    for name, events in http_events.items():
        client = diagnostic_mapping(http_state.get(name))
        if events and client.get("history_included") is not True:
            http_state[name] = {
                **client,
                "marker_requests": events,
                "history_source": "request_events",
            }
    queue_fields = (
        "startup_sent",
        "startup_received",
        "startup_credit",
        "startup_acknowledged",
        "snapshot_startup_credit",
        "positions_sent",
        "position_interval_ms",
        "position_timings",
        "snapshot_sent",
        "snapshot_received",
        "snapshot_acknowledged",
        "partial_sent",
        "partial_received",
        "partial_acknowledged",
        "partial_credit_wait_age_ms",
        "outstanding_partial_bytes",
        "peak_outstanding_partial_bytes",
        "peak_outstanding_snapshot_bytes",
        "outstanding_snapshot_bytes",
        "channel_in_buffer_kb",
        "channel_queues",
        "credit_wait_age_ms",
        "receive_schedule",
    )
    queue = diagnostic_mapping(state.get("reference"))
    return {
        "godot_failure": {key: failure.get(key) for key in state_fields},
        "godot_progress": {key: progress.get(key) for key in state_fields},
        "last_stage": evidence.get("last_stage"),
        "last_ready": evidence.get("last_ready"),
        "godot_queue": {key: queue.get(key) for key in queue_fields},
        "http_requests": http_request_diagnostics(
            http_state, diagnostic_mapping(report.get("godot_http_resources"))
        ),
        "godot_buffer_drop_messages": output.count("Buffer full! Dropping data."),
        "reference_error": ref.get("error"),
        "driver_error": report.get("driver_error"),
        "snapshot_receive_phases": [
            snapshot_receive_diagnostics(
                item, diagnostic_records(report.get("godot_browser_callbacks")), phase
            )
            for phase, item in local.items()
        ],
        "browser_read_phases": [
            browser_read_diagnostics(
                item,
                diagnostic_records(report.get("godot_browser_callbacks")),
                phase,
                diagnostic_mapping(report.get("godot_browser_drops")),
                next(
                    (
                        diagnostic_mapping(ref.get("receive_pause"))
                        for ref in reference_phases
                        if ref.get("phase") == phase
                    ),
                    {},
                ),
            )
            for phase, item in local.items()
        ],
        "heartbeat_phases": [
            heartbeat_diagnostics(local.get(item.get("phase"), {}), item, bridge)
            for item in reference_phases
        ],
        "native_bridge_packets": bridge,
        "initial_probe_phases": [
            initial_probe_diagnostics(
                local.get(item.get("phase"), {}),
                item,
                diagnostic_mapping(
                    diagnostic_mapping(report.get("native_timing")).get("sender_evidence")
                ),
                item.get("phase"),
            )
            for item in reference_phases
        ],
        "retirement_delivery_phases": [
            retirement_delivery_diagnostics(
                item,
                next((ref for ref in reference_phases if ref.get("phase") == phase), {}),
                diagnostic_mapping(
                    diagnostic_mapping(report.get("native_timing")).get("sender_evidence")
                ),
                diagnostic_records(report.get("godot_browser_callbacks")),
                phase,
            )
            for phase, item in local.items()
        ],
        "packet_delivery_phases": [
            packet_delivery_diagnostics(
                item,
                next((ref for ref in reference_phases if ref.get("phase") == phase), {}),
                diagnostic_records(report.get("godot_browser_callbacks")),
                phase,
            )
            for phase, item in local.items()
        ],
        "limits": "Intervals use one clock each. Missing samples are null. Buffer messages establish local drops; queue counts and completed sends do not prove receipt or a root cause.",
    }


def binary_payloads(
    *, empty: bool = False, receive_empty: bool = False
) -> dict[str, dict[str, list[list[list[int]]]]]:
    result: dict[str, dict[str, list[list[list[int]]]]] = {}
    for phase in (1, 2):
        result[str(phase)] = {}
        for sender in ("godot", "reference"):
            modes = []
            for label in ("reliable", "ordered", "unreliable"):
                prefix = f"binary:{phase}:{sender}:{label}:".encode()
                packets = [
                    b""
                    if empty or (receive_empty and sender == "reference")
                    else prefix + b"empty-body",
                    prefix + b"utf8",
                    prefix + b"\x00",
                    prefix + bytes(range(256)),
                    prefix + b"\xff\xfe\xc0\x80",
                    prefix + b"\xf0\x28\x8c\x28",
                    prefix + bytes(range(256)) * 4,
                    prefix + b"tail\x00\xff",
                ]
                modes.append([list(packet) for packet in packets])
            result[str(phase)][sender] = modes
    return result


def startup_phase_passed(
    godot: dict[str, object], ref: dict[str, object], requested: bool, window_bytes: int = 0
) -> bool:
    credited = requested and window_bytes > 0
    return all(
        phase.get("startup_burst", False) is requested
        and phase.get("startup_credit", False) is credited
        and (
            not credited
            or all(
                type(phase.get(key)) is int and phase[key] == 32
                for key in ("startup_acknowledged", "snapshot_startup_credit")
            )
        )
        and (
            not requested
            or all(
                type(phase.get(key)) is int and phase[key] == 32
                for key in ("startup_sent", "startup_received")
            )
        )
        for phase in (godot, ref)
    )


def binary_phase_passed(
    phase: dict[str, object], requested: bool, *, require_empty: bool = False
) -> bool:
    if phase.get("binary_traffic", False) is not requested:
        return False
    if not requested:
        return not require_empty
    sent = phase.get("binary_sent")
    received = phase.get("binary_sequences")
    if (
        not isinstance(sent, list)
        or len(sent) != 3
        or any(type(count) is not int or count != 8 for count in sent)
        or not isinstance(received, list)
        or len(received) != 3
    ):
        return False
    for mode, sequences in enumerate(received):
        if (
            not isinstance(sequences, list)
            or not sequences
            or (require_empty and 0 not in sequences)
            or not any(type(seq) is int and seq > 0 for seq in sequences)
            or any(type(seq) is not int or not 0 <= seq < 8 for seq in sequences)
            or len(sequences) != len(set(sequences))
            or (mode != 2 and sequences != sorted(sequences))
            or (mode == 0 and sequences != list(range(8)))
        ):
            return False
    return True


def initial_probes_passed(phase: dict[str, object]) -> bool:
    return phase.get("received") in (["reliable", "unreliable"], ["unreliable", "reliable"])


def gameplay_phase_passed(
    phase: dict[str, object],
    *,
    mixed_traffic: bool = False,
    credit_transport: str = "http",
    slow_receiver: bool = False,
    native_profile: bool = False,
    minimum_queued: int = 24,
) -> bool:
    return (
        phase.get("sent") is True
        and initial_probes_passed(phase)
        and phase.get("snapshot_sent") == 128
        and phase.get("snapshot_received") == 128
        and phase.get("partial_sent") == 4
        and phase.get("partial_received") == 4
        and phase.get("remote_closed") is True
        and phase.get("mixed_traffic") is mixed_traffic
        and phase.get("credit_transport") == credit_transport
        and (
            not slow_receiver
            or slow_receiver_passed(phase.get("receive_pause"), mixed_traffic, minimum_queued)
        )
        and phase.get("snapshot_acknowledged") == 128
        and phase.get("positions_sent") == (32 if mixed_traffic else 0)
        and (
            native_delivery_passed(phase, mixed_traffic)
            if native_profile
            else phase.get("positions_received") == (32 if mixed_traffic else 0)
        )
        and type(phase.get("peak_outstanding")) is int
        and 0 < cast(int, phase["peak_outstanding"]) <= 32
    )


def snapshot_flow_passed(phase: dict[str, object], body_bytes: int, window_bytes: int) -> bool:
    peak = phase.get("peak_outstanding_snapshot_bytes")
    return (
        type(phase.get("snapshot_body_bytes")) is int
        and phase["snapshot_body_bytes"] == body_bytes
        and type(phase.get("snapshot_window_bytes")) is int
        and phase["snapshot_window_bytes"] == window_bytes
        and type(phase.get("outstanding_snapshot_bytes")) is int
        and phase["outstanding_snapshot_bytes"] == 0
        and type(peak) is int
        and body_bytes < peak <= 32 * (body_bytes + 32)
        and (not window_bytes or peak <= window_bytes)
    )


def partial_flow_passed(phase: dict[str, object], body_bytes: int, window_bytes: int) -> bool:
    peak = phase.get("peak_outstanding_partial_bytes")
    return (
        type(phase.get("partial_acknowledged")) is int
        and phase["partial_acknowledged"] == 4
        and type(phase.get("outstanding_partial_bytes")) is int
        and phase["outstanding_partial_bytes"] == 0
        and type(peak) is int
        and body_bytes < peak <= 4 * (body_bytes + 32)
        and (not window_bytes or peak <= window_bytes)
    )


def native_delivery_passed(phase: dict[str, object], mixed: bool) -> bool:
    ordered = phase.get("ordered_sequences")
    positions = phase.get("position_sequences")
    if not isinstance(ordered, list) or not isinstance(positions, list):
        return False
    return (
        phase.get("native_profile") is True
        and phase.get("ordered_sent") == 8
        and 0 < len(ordered) <= 8
        and all(type(seq) is int and 0 <= seq < 8 for seq in ordered)
        and ordered == sorted(set(ordered))
        and type(phase.get("positions_received")) is int
        and len(positions) == phase.get("positions_received")
        and all(type(seq) is int and 0 <= seq < 32 for seq in positions)
        and len(set(positions)) == len(positions)
        and (0 < len(positions) <= 32 if mixed else not positions)
    )


def native_channel_contracts_passed(phases: list[dict[str, object]]) -> bool:
    if len(phases) != 2:
        return False
    generations = []
    for phase in phases:
        snapshot = phase.get("snapshot")
        if not isinstance(snapshot, dict) or snapshot.get("backend") != "native":
            return False
        generation = snapshot.get("generation")
        if type(generation) is not int or generation <= 0:
            return False
        generations.append(generation)
        channels = snapshot.get("channels")
        if not isinstance(channels, dict) or set(channels) != {"reliable", "ordered", "unreliable"}:
            return False
        internal_ids = []
        for label in ("reliable", "ordered", "unreliable"):
            properties = channels[label]
            if (
                not isinstance(properties, dict)
                or not {"internal_id", "negotiated", "ordered", "lifetime", "retransmits"}.issubset(
                    properties
                )
                or type(properties.get("internal_id")) is not int
                or properties["internal_id"] < 0
                or properties.get("negotiated") is not True
                or properties.get("ordered") is not (label != "unreliable")
                or (
                    properties.get("lifetime") is not None
                    if label == "reliable"
                    else type(properties.get("lifetime")) is not int or properties["lifetime"] != 1
                )
                or properties.get("retransmits") is not None
            ):
                return False
            internal_ids.append(properties["internal_id"])
        if len(set(internal_ids)) != 3:
            return False
    return generations[0] != generations[1]


def godot_native_contracts_passed(phases: list[dict[str, object]], web: bool) -> bool:
    if len(phases) != 2:
        return False
    unset = 0 if web else -1
    for phase in phases:
        channels = phase.get("channels")
        if not isinstance(channels, list) or len(channels) != 3:
            return False
        for index, label in enumerate(("reliable", "ordered", "unreliable"), 1):
            channel = channels[index - 1]
            if not isinstance(channel, dict):
                return False
            if (
                type(channel.get("id")) is not int
                or channel["id"] != index
                or channel.get("label") != label
                or channel.get("negotiated") is not True
                or channel.get("ordered") is not (label != "unreliable")
                or type(channel.get("lifetime")) is not int
                or channel["lifetime"] not in ((unset,) if label == "reliable" else (unset, 1))
                or type(channel.get("retransmits")) is not int
                or channel["retransmits"] != unset
                or type(channel.get("state")) is not int
                or channel.get("state") != 1
            ):
                return False
    return True


def retirement_passed(
    godot: dict[str, object],
    ref: dict[str, object],
    channel: str,
    seat: str,
    safe_receive: bool = True,
    native_profile: bool = False,
) -> bool:
    proof = godot.get("retirement")
    other = ref.get("retirement")
    if not isinstance(proof, dict) or not isinstance(other, dict):
        return False
    return (
        proof.get("channel") == other.get("channel") == channel
        and proof.get("seat") == other.get("seat") == seat
        and proof.get("selected") is safe_receive
        and type(proof.get("queued")) is int
        and proof["queued"] > 0
        and proof.get("discarded") is True
        and proof.get("peer_removed") is True
        and isinstance(other.get("closed_labels"), list)
        and any(
            label
            in (
                ("reliable", "ordered", "unreliable")
                if native_profile
                else ("reliable", "unreliable")
            )
            for label in other["closed_labels"]
        )
        and (seat == "godot" or channel in other["closed_labels"])
        and (seat != "godot" or proof.get("channel_closed") is True)
    )


def queued_retirement_passed(
    godot: dict[str, object], ref: dict[str, object], requested: bool
) -> bool:
    local = godot.get("retirement")
    remote = ref.get("retirement")
    if not isinstance(local, dict) or not isinstance(remote, dict):
        return False
    if remote.get("queued_retirement") is not requested:
        return False
    if not requested:
        return True
    proof = local.get("queued_arrival")
    return (
        remote.get("late_sent") is True
        and isinstance(proof, dict)
        and proof.get("preserved") is True
        and type(proof.get("queued_before_read")) is int
        and proof["queued_before_read"] == 3
        and type(proof.get("queued_after_read")) is int
        and proof["queued_after_read"] == local.get("queued") == 2
    )


def slow_receiver_passed(value: object, mixed_traffic: bool, minimum_queued: int = 24) -> bool:
    if not isinstance(value, dict):
        return False
    return (
        value.get("resumed") is True
        and type(value.get("elapsed_ms")) is int
        and value["elapsed_ms"] >= 1500
        and type(value.get("received")) is int
        and 8 <= value["received"] < 128
        and value.get("received_at_resume") == value["received"]
        and type(value.get("queued_reliable")) is int
        and value["queued_reliable"] >= minimum_queued
        and (
            not mixed_traffic
            or (type(value.get("queued_unreliable")) is int and value["queued_unreliable"] > 0)
        )
    )


def reference_receive_pause_passed(
    phase: dict[str, object], requested: bool, minimum_queued: int = 24
) -> bool:
    if phase.get("slow_reference_receiver") is not requested:
        return False
    if not requested:
        return True
    proof = phase.get("receive_pause")
    if not isinstance(proof, dict):
        return False
    fields = (
        "elapsed_ms",
        "received",
        "received_at_resume",
        "queued_snapshots",
        "queued_positions",
        "peak_queued",
        "heartbeat_sent",
        "heartbeat_received",
        "heartbeat_sent_at_resume",
        "heartbeat_received_at_resume",
    )
    if any(type(proof.get(field)) is not int for field in fields):
        return False
    return (
        proof.get("resumed") is True
        and proof["elapsed_ms"] >= 1500
        and proof["received"] == proof["received_at_resume"] == 8
        and minimum_queued <= proof["queued_snapshots"] <= 32
        and 0 < proof["queued_positions"] <= 32
        and proof["peak_queued"] == proof["queued_snapshots"] + proof["queued_positions"]
        and 0 <= proof["heartbeat_received"] <= proof["heartbeat_sent"]
        and proof["heartbeat_sent"]
        < proof["heartbeat_received_at_resume"]
        <= proof["heartbeat_sent_at_resume"]
        <= 128
        and phase.get("queued_application_packets") == 0
    )


def heartbeat_phase_passed(godot: dict[str, object], ref: dict[str, object], mixed: bool) -> bool:
    count = ref.get("heartbeat_sent")
    return (
        type(count) is int
        and (0 < count <= 128 if mixed else count == 0)
        and type(ref.get("heartbeat_received")) is int
        and type(godot.get("heartbeat_received")) is int
        and ref.get("heartbeat_received") == count
        and godot.get("heartbeat_received") == count
    )


def signaling_hold_passed(proof: dict[str, object]) -> bool:
    before, during = proof.get("before"), proof.get("during")
    if not isinstance(before, dict) or not isinstance(during, dict):
        return False
    elapsed = proof.get("elapsed_ms")
    return (
        type(elapsed) is int
        and elapsed >= 1000
        and before.get("phase") == during.get("phase") == 1
        and before.get("signaling_pending") is True
        and during.get("signaling_pending") is True
        and type(before.get("heartbeat_sent")) is int
        and type(during.get("heartbeat_sent")) is int
        and type(during.get("heartbeat_received")) is int
        and during["heartbeat_sent"] > before["heartbeat_sent"]
        and before["heartbeat_sent"] < during["heartbeat_received"] <= during["heartbeat_sent"]
        and type(before.get("snapshot_acknowledged")) is int
        and 0 <= before["snapshot_acknowledged"] < 128
        and before["snapshot_acknowledged"] == during.get("snapshot_acknowledged")
    )


def wait_for_godot(page: Page, messages: list[str]) -> str:
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if any(
            line == "WEBRTC_INTEROP_PASS seat=1" or line.startswith("WEBRTC_INTEROP_FAIL ")
            for line in messages
        ) or page_failed(messages):
            return ""
        page.wait_for_timeout(100)
    return "Godot Web completion observation timed out after 15 seconds"


def wait_for_godot_ready(page: Page, ready: Callable[[], bool], messages: list[str]) -> int:
    started = time.monotonic()
    while time.monotonic() - started < 60:
        if page_failed(messages) or any(
            line.startswith("WEBRTC_INTEROP_FAIL ") or interop.engine_failed(line)
            for line in messages
        ):
            raise RuntimeError("Godot failed during reference assessment startup")
        if ready():
            return round((time.monotonic() - started) * 1000)
        page.wait_for_timeout(100)
    raise TimeoutError("Godot ready marker was not received during 60-second startup")


def service_evidence(output: str) -> list[dict[str, object]]:
    return [
        json.loads(line.removeprefix("WEBRTC_REFERENCE_SERVICE "))
        for line in output.splitlines()
        if line.startswith("WEBRTC_REFERENCE_SERVICE ")
    ]


def service_session_passed(
    godot: list[dict[str, object]],
    ref: list[dict[str, object]],
    *,
    rejoin: bool = False,
    godot_offer: bool = False,
) -> bool:
    if [phase.get("phase") for phase in godot] != [1, 2] or [
        phase.get("phase") for phase in ref
    ] != [1, 2]:
        return False
    for local, remote in zip(godot, ref, strict=True):
        if (
            type(local.get("initiate")) is not bool
            or type(remote.get("initiate")) is not bool
            or local["initiate"] == remote["initiate"]
            or ((not rejoin or local is godot[0]) and local["initiate"] != godot_offer)
        ):
            return False
        for key in ("room_id", "generation"):
            if (
                not isinstance(local.get(key), str)
                or not local[key]
                or local[key] != remote.get(key)
            ):
                return False
        if (
            not local.get("player_id")
            or local.get("player_id") == local.get("peer_id")
            or local.get("player_id") != remote.get("peer_id")
            or remote.get("player_id") != local.get("peer_id")
        ):
            return False
        for phase in (local, remote):
            expected_left = not (rejoin and phase is godot[0])
            if phase.get("left") is not expected_left:
                return False
            for key in ("signals_sent", "signals_received"):
                if type(phase.get(key)) is not int or cast(int, phase[key]) <= 0:
                    return False
        if (
            local["signals_sent"] != remote["signals_received"]
            or remote["signals_sent"] != local["signals_received"]
        ):
            return False
    if rejoin:
        if any(
            type(local.get("reference_epoch")) is not int
            or type(remote.get("reference_epoch")) is not int
            or cast(int, local["reference_epoch"]) <= 0
            or local["reference_epoch"] != remote.get("reference_epoch")
            for local, remote in zip(godot, ref, strict=True)
        ):
            return False
        return (
            godot[0]["room_id"] == godot[1]["room_id"]
            and godot[0]["generation"] != godot[1]["generation"]
            and godot[0]["player_id"] == godot[1]["player_id"]
            and godot[0]["peer_id"] == godot[1]["peer_id"]
            and godot[0].get("peer_departed") is True
            and ref[0].get("departure_stage") == "selected_packet"
            and godot[1].get("same_receiver") is True
            and godot[1].get("receiver_retired") is True
            and cast(int, godot[1]["reference_epoch"]) > cast(int, godot[0]["reference_epoch"])
        )
    return godot[1].get("receiver_retired") is True and all(
        godot[0][key] != godot[1][key] for key in ("room_id", "generation")
    )


def service_source(source: str) -> str:
    fragment = (ROOT / "tests/smoke/webrtc_reference_service.gd.inc").read_text()
    variables, methods = fragment.split("\n\nfunc _service_setup", 1)
    source = source.replace("func _ready() -> void:", variables + "\n\nfunc _ready() -> void:", 1)
    start = source.index("\t_client._player_id = PLAYERS[_seat]")
    end = source.index("\t_mesh = MeshScript.new()", start)
    source = source[:start] + "\tif not _service_setup():\n\t\treturn\n" + source[end:]
    start = source.index(
        "\tvar plan := SessionScript.SessionPlanInfo.new()", source.index("func _run_phase")
    )
    end = source.index('\t_pending.append({"marker": "ready-%d" % phase})', start)
    source = (
        source[:start] + "\tif not await _service_begin(phase):\n\t\treturn false\n" + source[end:]
    )
    source = source.replace("\tif remote.initiate:\n\t\t_mesh._apply_plan(plan)\n", "")
    start = source.index(
        "\tvar relay := SessionScript.SessionPlanInfo.new()", source.index("func _run_phase")
    )
    end = source.index('\t_pending.append({"marker": "retired-%d" % phase})', start)
    source = source[:start] + source[end:]
    source = source.replace(
        'return await _wait_until(\n\t\t"reference teardown",',
        'var retired := await _wait_until(\n\t\t"reference teardown",',
        1,
    )
    source = source.replace(
        "\n\nfunc _reference_gameplay_complete",
        "\n\treturn retired and await _service_end(phase)\n\n\nfunc _reference_gameplay_complete",
        1,
    )
    source = source.replace(
        "\t\tif phase == 1:\n\t\t\t_reference_receiver = receiver\n\t\telif receiver != _reference_receiver:",
        "\t\tif not _service_receiver_matches(phase, receiver):",
        1,
    )
    source = source.replace(
        '\t\t\t_fail("reference recovery replaced the safe receiver")\n\t\t\treturn false',
        '\t\t\t_fail("service receiver identity differs")\n\t\t\treturn false\n\t\t_reference_receiver = receiver',
        1,
    )
    source = source.replace("PLAYERS[1 - _seat]", "_signal_players[1 - _seat]")
    source = source.replace(
        "\tvar now := Time.get_ticks_msec()\n",
        "\t_client.poll()\n\tvar now := Time.get_ticks_msec()\n",
        1,
    )
    source = source.replace(
        "\tvar relay: Callable",
        "\tvar service := false\n\tvar service_signals_sent := 0\n\tvar relay: Callable",
        1,
    )
    source = source.replace(
        "\t\trelay.call(generation, payload)",
        "\t\tif service:\n\t\t\tvar result := super.send_signal(_to, generation, payload)\n\t\t\tif result == OK:\n\t\t\t\tservice_signals_sent += 1\n\t\t\treturn result\n\t\trelay.call(generation, payload)",
        1,
    )
    source = source.replace(
        "\t\tstatuses.append(up)\n\t\treturn OK",
        "\t\tstatuses.append(up)\n\t\treturn super.send_transport_status(_kind, up) if service else OK",
        1,
    )
    return source + "\n\nfunc _service_setup" + methods


def prepare(args: argparse.Namespace, directory: Path, *, web: bool) -> Path:
    project = directory / "project"
    interop.prepare(project, None if web else args.native_extension, ROOT)
    capacity = getattr(args, "channel_in_buffer_kb", 0)
    if capacity:
        settings = project / "project.godot"
        settings.write_text(
            settings.read_text()
            + f"\n[network]\nlimits/webrtc/max_channel_in_buffer_kb={capacity}\n"
        )
    script = project / "tests/smoke/webrtc_interop_drill.gd"
    source = script.read_text()
    fetch = "true" if getattr(args, "web_http_fetch", True) else "false"
    source = source.replace("\t_setup_http()", f"\t_setup_http({fetch})", 1)
    fragment = (ROOT / "tests/smoke/webrtc_reference_phase.gd.inc").read_text()
    variables, methods = fragment.split("\n\nfunc _run_phase", 1)
    start = source.index("func _run_phase(phase: int) -> bool:")
    end = source.index("\n\nfunc _probe_packet_metadata", start)
    ready = source.index("func _ready() -> void:")
    source = source[:start] + "func _run_phase" + methods + source[end:]
    source = source[:ready] + variables + "\n\n" + source[ready:]
    if source.count('"peers": []') != 1:
        raise ValueError("Reference diagnostic insertion point changed")
    source = source.replace('"peers": []', '"reference": _reference_evidence(), "peers": []')
    if getattr(args, "service_url", ""):
        source = service_source(source)
    script.write_text(source)
    (project / "reference-options.json").write_text(
        json.dumps(
            {
                "service_url": getattr(args, "service_url", ""),
                "service_rejoin": getattr(args, "service_rejoin", False),
                "queued_retirement": getattr(args, "queued_retirement", False),
                "service_app_id": getattr(args, "service_app_id", "godot-reference"),
                "native_profile": bool(getattr(args, "native_reference_probe", None)),
                "startup_burst": getattr(args, "startup_burst", False),
                "position_interval_ms": getattr(args, "position_interval_ms", 0),
                "snapshot_body_bytes": getattr(args, "snapshot_body_bytes", 1024),
                "snapshot_window_bytes": getattr(args, "snapshot_window_bytes", 0),
                "receive_batch_packets": getattr(args, "receive_batch_packets", 32),
                "receive_interval_ms": getattr(args, "receive_interval_ms", 0),
                "receive_empty_binary": getattr(args, "receive_empty_binary", False),
                "binary_traffic": getattr(args, "binary_traffic", False),
                "binary_payloads": binary_payloads(
                    empty=getattr(args, "empty_binary", False),
                    receive_empty=getattr(args, "receive_empty_binary", False),
                ),
                "godot_offer": args.godot_offer,
                "safe_receive": args.safe_receive,
                "mixed_traffic": args.mixed_traffic,
                "credit_transport": args.credit_transport,
                "slow_receiver": getattr(args, "slow_receiver", False),
                "closing_channel": getattr(args, "closing_channel", "reliable"),
                "closing_seat": getattr(args, "closing_seat", "reference"),
            }
        )
    )
    preset = project / "export_presets.cfg"
    preset.write_text(
        preset.read_text().replace('include_filter=""', 'include_filter="reference-options.json"')
    )
    interop.checked(
        [
            getattr(args, "import_godot", None) or args.godot,
            "--headless",
            "--path",
            str(project),
            "--editor",
            "--import",
        ],
        directory / "import.log",
    )
    if web:
        interop.checked(
            [args.godot, "--headless", "--path", str(project), "--export-debug", "Web"],
            directory / "export.log",
        )
    return project


def receive_schedule_passed(
    phase: dict[str, object], batch: int, interval: int, *, required: bool = False
) -> bool:
    if not required and batch == 32 and interval == 0:
        return True
    schedule = diagnostic_mapping(phase.get("receive_schedule"))
    raw_drains = schedule.get("drains")
    if not isinstance(raw_drains, list):
        return False
    drains = diagnostic_records(raw_drains)
    previous = None
    if (
        schedule.get("batch_packets") != batch
        or schedule.get("interval_ms") != interval
        or type(schedule.get("dropped")) is not int
        or schedule["dropped"] != 0
        or not drains
        or len(drains) != len(raw_drains)
    ):
        return False
    for drain in drains:
        at, reads = drain.get("ms"), drain.get("reads")
        if (
            type(at) is not int
            or type(reads) is not int
            or not 0 <= reads <= batch
            or at < 0
            or (previous is not None and at - previous < interval)
        ):
            return False
        previous = at
    return True


def reference_receive_schedule_passed(phase: dict[str, object], batch: int, interval: int) -> bool:
    if batch == 0:
        return True
    schedule = diagnostic_mapping(phase.get("receive_schedule"))
    raw_timings = phase.get("receive_timings")
    timings = diagnostic_records(raw_timings)
    if (
        not receive_schedule_passed(phase, batch, interval, required=True)
        or any(
            type(schedule.get(key)) is not int or schedule[key] != 0
            for key in ("queued_packets", "queued_bytes")
        )
        or type(phase.get("receive_timings_dropped")) is not int
        or phase["receive_timings_dropped"] != 0
        or not isinstance(raw_timings, list)
        or not timings
        or len(timings) != len(raw_timings)
        or sum(cast(int, item["reads"]) for item in diagnostic_records(schedule.get("drains")))
        != len(timings)
    ):
        return False
    previous = None
    for item in timings:
        callback, consumed = item.get("callback_ms"), item.get("drain_ms")
        if (
            type(callback) is not int
            or type(consumed) is not int
            or not 0 <= callback <= consumed
            or (previous is not None and consumed < previous)
        ):
            return False
        previous = consumed
    return True


def position_schedule_passed(phase: dict[str, object], interval: int, mixed: bool) -> bool:
    if (
        type(phase.get("position_interval_ms", 0)) is not int
        or phase.get("position_interval_ms", 0) != interval
    ):
        return False
    samples = phase.get("position_timings", [])
    if not isinstance(samples, list):
        return False
    if not interval:
        return samples == []
    count = 32 if mixed else 0
    if (
        len(samples) != count
        or type(phase.get("positions_sent")) is not int
        or phase["positions_sent"] != count
    ):
        return False
    previous = None
    for sequence, row in enumerate(samples):
        if not isinstance(row, dict) or any(
            type(row.get(key)) is not int
            for key in ("sequence", "enqueue_ms", "snapshot_sent", "snapshot_acknowledged")
        ):
            return False
        if (
            row["sequence"] != sequence
            or row["enqueue_ms"] < 0
            or not 0 <= row["snapshot_acknowledged"] <= row["snapshot_sent"] <= 128
            or (previous is not None and row["enqueue_ms"] - previous < interval)
        ):
            return False
        previous = row["enqueue_ms"]
    return True


def gameplay_phase_checks(
    godot: dict[str, object],
    ref: dict[str, object],
    args: argparse.Namespace,
    minimum_queued: int,
    native_profile: bool,
    *,
    web: bool = False,
) -> dict[str, bool]:
    return {
        "http_backend": godot.get("web_http_fetch")
        is (web and getattr(args, "web_http_fetch", True)),
        "initial_probes": initial_probes_passed(godot) and initial_probes_passed(ref),
        "godot_gameplay": gameplay_phase_passed(
            godot,
            mixed_traffic=args.mixed_traffic,
            credit_transport=args.credit_transport,
            slow_receiver=getattr(args, "slow_receiver", False),
            minimum_queued=minimum_queued,
            native_profile=native_profile,
        ),
        "reference_gameplay": gameplay_phase_passed(
            ref,
            mixed_traffic=args.mixed_traffic,
            credit_transport=args.credit_transport,
            native_profile=native_profile,
        ),
        "snapshot_flow": all(
            snapshot_flow_passed(
                phase,
                getattr(args, "snapshot_body_bytes", 1024),
                getattr(args, "snapshot_window_bytes", 0),
            )
            for phase in (godot, ref)
        ),
        "partial_flow": all(
            partial_flow_passed(
                phase,
                getattr(args, "snapshot_body_bytes", 1024),
                getattr(args, "snapshot_window_bytes", 0),
            )
            for phase in (godot, ref)
        ),
        "startup": startup_phase_passed(
            godot,
            ref,
            getattr(args, "startup_burst", False),
            getattr(args, "snapshot_window_bytes", 0),
        ),
        "godot_binary": binary_phase_passed(
            godot,
            getattr(args, "binary_traffic", False),
            require_empty=getattr(args, "receive_empty_binary", False),
        ),
        "reference_binary": binary_phase_passed(ref, getattr(args, "binary_traffic", False)),
        "receive_capacity": (
            not getattr(args, "channel_in_buffer_kb", 0)
            or godot.get("channel_in_buffer_kb") == args.channel_in_buffer_kb
        ),
        "receive_schedule": receive_schedule_passed(
            godot,
            getattr(args, "receive_batch_packets", 32),
            getattr(args, "receive_interval_ms", 0),
        ),
        "reference_receive_schedule": reference_receive_schedule_passed(
            ref,
            getattr(args, "reference_receive_batch_packets", 0),
            getattr(args, "reference_receive_interval_ms", 0),
        ),
        "position_schedule": all(
            position_schedule_passed(
                phase, getattr(args, "position_interval_ms", 0), args.mixed_traffic
            )
            for phase in (godot, ref)
        ),
        "heartbeat_totals": heartbeat_phase_passed(godot, ref, args.mixed_traffic),
        "retirement": retirement_passed(
            godot,
            ref,
            getattr(args, "closing_channel", "reliable"),
            getattr(args, "closing_seat", "reference"),
            args.safe_receive,
            native_profile=native_profile,
        ),
        "queued_retirement": queued_retirement_passed(
            godot, ref, getattr(args, "queued_retirement", False)
        ),
        "reference_pause": reference_receive_pause_passed(
            ref, getattr(args, "slow_reference_receiver", False), minimum_queued
        ),
        "receiver_identity": (not args.safe_receive or godot.get("same_receiver") is True),
    }


def assess(args: argparse.Namespace, directory: Path, *, web: bool) -> dict[str, object]:
    directory.mkdir(parents=True)
    project = prepare(args, directory, web=web)
    assets = directory / "assets"
    assets.mkdir()
    probe = getattr(args, "native_reference_probe", None)
    if probe:
        frozen_probe = directory / ("native-reference-probe" + probe.suffix)
        shutil.copy2(probe, frozen_probe)
        probe = frozen_probe
    backend = None
    if probe:
        (assets / "reference").mkdir()
        shutil.copy2(
            ROOT / "tests/smoke/webrtc_native_reference.js", assets / "reference/engine.js"
        )
    else:
        shutil.copytree(args.reference_assets, assets / "reference")
    shutil.copy2(ROOT / "tests/smoke/webrtc_reference.js", assets / "assess.js")
    shutil.copy2(ROOT / "tests/smoke/webrtc_reference_service.js", assets / "service.js")
    (assets / "index.html").write_text(
        '<link rel="icon" href="data:,">'
        '<script type="module">import {configureReferenceService} from "/service.js";'
        "window.configureReferenceService = configureReferenceService;</script>"
        '<script type="module" src="/assess.js"></script>'
    )
    if web:
        shutil.copytree(project / "build/web", assets / "godot")

    class Handler(CreditDelayRelay):
        queues: ClassVar[list[list[object]]] = [[], []]
        lock = threading.Lock()
        observation = interop.RelayObservation()
        credit_delayed = threading.Event()
        credit_hold_active = threading.Event()
        credit_delay_ms = getattr(args, "http_credit_delay_ms", 0)
        credit_seat = 0 if web else 1

        rejected_http_signals = 0

        def native_reply(self, command: bool) -> None:
            if backend is None:
                raise RuntimeError("Native backend unavailable")
            try:
                result = (
                    backend.command(
                        json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                    )
                    if command
                    else backend.drain()
                )
                self.reply(json.dumps({"result": result}).encode())
            except Exception as exc:
                body = json.dumps({"error": str(exc)}).encode()
                self.send_response(500)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

        def do_GET(self) -> None:
            if backend and self.path == "/native/events":
                self.native_reply(False)
                return
            super().do_GET()

        def do_POST(self) -> None:
            if backend and self.path == "/native/command":
                self.native_reply(True)
                return
            if not getattr(args, "service_url", ""):
                super().do_POST()
                return
            if self.path not in ("/signal/0", "/signal/1"):
                self.send_error(404)
                return
            message = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if (
                not isinstance(message, dict)
                or not isinstance(message.get("marker"), str)
                or "payload" in message
            ):
                type(self).rejected_http_signals += 1
                self.send_error(400, "Service mode uses HTTP for markers only")
                return
            with self.lock:
                seat = int(self.path[-1])
                self.queues[seat].append(message)
                self.observation.enqueue(seat, message)
            self.reply(b"{}")

    server = interop.RelayServer(
        ("127.0.0.1", 0), functools.partial(Handler, directory=str(assets))
    )
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_port}"
    messages: list[str] = []
    reference_messages: list[str] = []
    native = None
    observations: dict[str, Observation] = {}
    report: dict[str, object] = {
        "service_url": getattr(args, "service_url", ""),
        "service_rejoin": getattr(args, "service_rejoin", False),
        "assessment_complete": False,
        "driver_error": "",
        "runtime": "web" if web else "native",
        "web_http_fetch": web and getattr(args, "web_http_fetch", True),
        "safe_receive": args.safe_receive,
        "godot_offer": args.godot_offer,
        "mixed_traffic": args.mixed_traffic,
        "credit_transport": args.credit_transport,
        "slow_receiver": getattr(args, "slow_receiver", False),
        "slow_reference_receiver": getattr(args, "slow_reference_receiver", False),
        "http_credit_delay_ms": getattr(args, "http_credit_delay_ms", 0),
        "closing_channel": getattr(args, "closing_channel", "reliable"),
        "closing_seat": getattr(args, "closing_seat", "reference"),
        "godot": args.godot,
        "import_godot": getattr(args, "import_godot", None) or args.godot,
        "reference_revision": args.reference_revision,
        "reference_backend": "native" if probe else "browser",
        "reference_engine_sha256": hashlib.sha256(
            (probe if probe else assets / "reference/engine.js").read_bytes()
        ).hexdigest(),
        "startup_burst": getattr(args, "startup_burst", False),
        "position_interval_ms": getattr(args, "position_interval_ms", 0),
        "snapshot_body_bytes": getattr(args, "snapshot_body_bytes", 1024),
        "snapshot_window_bytes": getattr(args, "snapshot_window_bytes", 0),
        "channel_in_buffer_kb": getattr(args, "channel_in_buffer_kb", 0),
        "receive_batch_packets": getattr(args, "receive_batch_packets", 32),
        "receive_interval_ms": getattr(args, "receive_interval_ms", 0),
        "reference_receive_batch_packets": getattr(args, "reference_receive_batch_packets", 0),
        "reference_receive_interval_ms": getattr(args, "reference_receive_interval_ms", 0),
        "receive_empty_binary": getattr(args, "receive_empty_binary", False),
        "binary_traffic": getattr(args, "binary_traffic", False),
        "empty_binary": getattr(args, "empty_binary", False),
        "binary_payloads": binary_payloads(
            empty=getattr(args, "empty_binary", False),
            receive_empty=getattr(args, "receive_empty_binary", False),
        )
        if getattr(args, "binary_traffic", False)
        else {},
    }
    try:
        with (directory / "godot.log").open("w") as log, sync_playwright() as playwright:
            if probe:
                backend = native_reference.NativeReference(probe, directory)
            browser = playwright.chromium.launch(
                headless=True,
                executable_path=args.chromium,
                args=["--no-sandbox", "--enable-unsafe-swiftshader"],
            )
            reference: Page | None = None
            page: Page | None = None
            try:
                reference = browser.new_page()
                watch_page(reference, reference_messages)
                reference_observation = observe_page(reference, url)
                observations["reference"] = reference_observation
                reference.goto(url)
                reference.wait_for_function("typeof window.runReference === 'function'")
                if web:
                    page = browser.new_page()
                    watch_page(page, messages)
                    observations["godot"] = observe_page(page, url)
                    page.goto(url + "/godot/index.html")
                else:
                    native = subprocess.Popen(  # noqa: S603
                        [args.godot, "--headless", "--path", str(project), "--", url],
                        stdout=log,
                        stderr=subprocess.STDOUT,
                    )

                def godot_ready() -> bool:
                    if native is not None and native.poll() is not None:
                        raise RuntimeError("Native Godot exited before its ready marker")
                    with Handler.lock:
                        return any(
                            isinstance(message, dict)
                            and message.get("marker")
                            == ("service-room-1" if getattr(args, "service_url", "") else "ready-1")
                            for message in Handler.queues[0 if web else 1]
                        )

                report["startup_ms"] = wait_for_godot_ready(reference, godot_ready, messages)
                report["reference_started_after_godot_ready"] = True
                if getattr(args, "service_url", ""):
                    reference.evaluate(
                        "([url, app, rejoin, offer]) => window.configureReferenceService(url, app, rejoin, offer)",
                        [
                            args.service_url,
                            args.service_app_id,
                            getattr(args, "service_rejoin", False),
                            args.godot_offer,
                        ],
                    )
                reference.evaluate(
                    "([seat, offer, mixed, credit, slow, channel, closer, queued, binary, startup, bodyBytes, windowBytes, refBatch, refInterval, positionInterval]) => { void window.runReference(seat, offer, mixed, credit, slow, channel, closer, queued, binary, startup, bodyBytes, windowBytes, refBatch, refInterval, positionInterval); }",
                    [
                        1 if web else 0,
                        args.godot_offer,
                        args.mixed_traffic,
                        args.credit_transport,
                        getattr(args, "slow_reference_receiver", False),
                        getattr(args, "closing_channel", "reliable"),
                        getattr(args, "closing_seat", "reference"),
                        getattr(args, "queued_retirement", False),
                        binary_payloads(
                            empty=getattr(args, "empty_binary", False),
                            receive_empty=getattr(args, "receive_empty_binary", False),
                        )
                        if getattr(args, "binary_traffic", False)
                        else None,
                        getattr(args, "startup_burst", False),
                        getattr(args, "snapshot_body_bytes", 1024),
                        getattr(args, "snapshot_window_bytes", 0),
                        getattr(args, "reference_receive_batch_packets", 0),
                        getattr(args, "reference_receive_interval_ms", 0),
                        getattr(args, "position_interval_ms", 0),
                    ],
                )
                hold_proof: dict[str, object] = {}
                report["signaling_hold_progress"] = hold_proof
                hold_started = 0.0
                deadline = time.monotonic() + 40
                while not reference.evaluate("window.referenceSettled === true"):
                    if time.monotonic() >= deadline:
                        raise TimeoutError(
                            "Reference completion observation timed out after 40 seconds"
                        )
                    if Handler.credit_hold_active.is_set() and args.mixed_traffic:
                        progress = reference.evaluate("window.referenceProgress()")
                        if not Handler.credit_hold_active.is_set():
                            continue
                        if not hold_proof:
                            hold_proof["before"] = progress
                            hold_started = time.monotonic()
                        elif "during" not in hold_proof and time.monotonic() - hold_started >= 1:
                            hold_proof["during"] = progress
                            hold_proof["elapsed_ms"] = round(
                                (time.monotonic() - hold_started) * 1000
                            )
                    reference.wait_for_timeout(100)
                result = reference.evaluate(
                    "({phases:window.referenceResults, error:window.referenceError, cleanup_error:window.referenceCleanupError ?? null, done:window.referenceDone === true})"
                )
                report["reference"] = result
                driver_error = ""
                if native:
                    if result["error"]:
                        native.terminate()
                    native.wait(timeout=10)
                    log.flush()
                    output = (directory / "godot.log").read_text()
                else:
                    if page is None:
                        raise RuntimeError("Godot browser page was not created")
                    driver_error = wait_for_godot(page, messages)
                    output = "\n".join(messages)
                    log.write(output)
                phases = [
                    json.loads(line.removeprefix("WEBRTC_REFERENCE_PHASE "))
                    for line in output.splitlines()
                    if line.startswith("WEBRTC_REFERENCE_PHASE ")
                ]
                service_godot = service_evidence(output)
                service_ref = reference.evaluate("window.referenceServiceEvidence ?? []")
                service_passed = not getattr(args, "service_url", "") or (
                    Handler.rejected_http_signals == 0
                    and service_session_passed(
                        service_godot,
                        service_ref,
                        rejoin=getattr(args, "service_rejoin", False),
                        godot_offer=args.godot_offer,
                    )
                )
                complete = (
                    service_passed
                    and (
                        not backend
                        or (
                            native_channel_contracts_passed(result["phases"])
                            and godot_native_contracts_passed(phases, web)
                        )
                    )
                    and result["done"]
                    and not result["error"]
                    and [phase["phase"] for phase in phases] == [1, 2]
                    and [phase["phase"] for phase in result["phases"]] == [1, 2]
                    and interop.seat_evidence(output, 1 if web else 0)["passed"]
                    and (native is None or native.returncode == 0)
                    and not page_failed(reference_messages)
                    and not page_failed(messages)
                    and not driver_error
                )
                body_bytes = getattr(args, "snapshot_body_bytes", 1024)
                window_bytes = getattr(args, "snapshot_window_bytes", 0)
                minimum_queued = min(24, window_bytes // (body_bytes + 32)) if window_bytes else 24
                phase_checks = [
                    gameplay_phase_checks(
                        godot, ref, args, minimum_queued, backend is not None, web=web
                    )
                    for godot, ref in zip(phases, result["phases"], strict=False)
                ]
                gameplay = (
                    complete
                    and (
                        not getattr(args, "http_credit_delay_ms", 0)
                        or Handler.credit_delayed.is_set()
                    )
                    and (
                        not (
                            getattr(args, "http_credit_delay_ms", 0) >= 1500 and args.mixed_traffic
                        )
                        or signaling_hold_passed(hold_proof)
                    )
                    and all(all(checks.values()) for checks in phase_checks)
                )

                report.update(
                    {
                        "service_passed": service_passed,
                        "service_godot": service_godot,
                        "service_reference": service_ref,
                        "assessment_complete": complete,
                        "driver_error": driver_error,
                        "gameplay_passed": gameplay,
                        "phase_checks": phase_checks,
                        "browser": browser.version,
                        "godot_phases": phases,
                        "reference": result,
                    }
                )
            finally:
                if page is not None:
                    try:
                        report["godot_browser_callbacks"] = page.evaluate(
                            "window.webrtcCallbackSnapshot?.() ?? null"
                        )
                        report["godot_http_resources"] = page.evaluate(
                            "window.webrtcHttpSnapshot?.() ?? null"
                        )
                        report["godot_browser_drops"] = page.evaluate(
                            "window.webrtcDropSnapshot?.() ?? null"
                        )
                    except Exception as exc:
                        report["godot_browser_callbacks_error"] = str(exc)
                if reference is not None:
                    try:
                        report["reference_terminal"] = reference.evaluate(
                            "window.referenceTerminal ?? window.referenceProgress?.() ?? null"
                        )
                    except Exception as exc:
                        report["reference_terminal_error"] = str(exc)
                if backend and reference is not None:
                    try:
                        report["native_snapshots"] = reference.evaluate(
                            "window.nativeReferenceSnapshots ?? []"
                        )
                    except Exception as exc:
                        report["native_snapshot_error"] = str(exc)
                report["browser_observations"] = {
                    name: observer.snapshot() for name, observer in observations.items()
                }
                report["relay_observation"] = Handler.observation.snapshot()
                browser.close()
    except Exception as exc:
        report.update(
            assessment_complete=False,
            driver_error=f"{type(exc).__name__}: {exc}",
        )
    finally:
        if native is not None and native.poll() is None:
            native.kill()
            native.wait(timeout=10)
        report["rejected_http_signals"] = Handler.rejected_http_signals
        report["http_credit_delay_applied"] = Handler.credit_delayed.is_set()
        server.shutdown()
        server.server_close()
        if backend:
            backend.close()
            native_timing = backend.timing_snapshot()
            report["native_timing"] = native_timing
            if native_timing.get("receive_failure"):
                report.update(assessment_complete=False, gameplay_passed=False)
        if "relay_observation" not in report:
            report["relay_observation"] = Handler.observation.snapshot()
        if web:
            (directory / "godot.log").write_text("\n".join(messages))
        output = (directory / "godot.log").read_text()
        report["godot_evidence"] = interop.seat_evidence(output, 1 if web else 0)
        report["godot_phases"] = phase_evidence(output)
        report["reference_phases"] = phase_evidence("\n".join(reference_messages))
        report["engine_banner"] = next(
            (line for line in output.splitlines() if line.startswith("Godot Engine")), ""
        )
        report["godot_errors"] = [line for line in messages if page_failed([line])]
        report["reference_errors"] = [line for line in reference_messages if page_failed([line])]
        report["diagnostics"] = gameplay_diagnostics(report, output)
        (directory / "reference.log").write_text("\n".join(reference_messages))
        (directory / "assessment.json").write_text(json.dumps(report, indent=2) + "\n")
    if not report.get("assessment_complete"):
        raise RuntimeError(f"Incomplete reference assessment; see {directory}")
    return report


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument(
        "--import-godot", help="Editor binary for importing a native template build"
    )
    http_backend = parser.add_mutually_exclusive_group()
    http_backend.add_argument(
        "--web-http-fetch",
        action="store_true",
        help="Use browser fetch for Web drill HTTP markers (default); native keeps HTTPRequest",
    )
    http_backend.add_argument(
        "--web-http-request",
        action="store_false",
        dest="web_http_fetch",
        help="Use Godot HTTPRequest for the Web drill's historical HTTP polling control",
    )
    parser.set_defaults(web_http_fetch=True)
    parser.add_argument("--service-url", default="", help="Use real v3 service rooms and signaling")
    parser.add_argument("--service-app-id", default="godot-reference")
    parser.add_argument(
        "--channel-in-buffer-kb",
        type=int,
        default=0,
        help="Override Godot channel receive capacity in the prepared project (0 keeps engine defaults)",
    )
    parser.add_argument(
        "--service-rejoin", action="store_true", help="Rejoin the same running service room"
    )
    parser.add_argument("--native-extension", type=Path, required=True)
    sources = parser.add_mutually_exclusive_group(required=True)
    sources.add_argument(
        "--native-reference-probe", type=Path, help="Built native Engine qualification probe"
    )
    sources.add_argument(
        "--reference-assets",
        type=Path,
        help="Directory containing engine.js and its imports",
    )
    parser.add_argument(
        "--reference-revision", required=True, help="Source commit used to build the Engine modules"
    )
    parser.add_argument(
        "--runtime",
        choices=("all", "native", "web"),
        default="all",
        help="Select Godot runtimes to assess",
    )
    parser.add_argument(
        "--offerer",
        choices=("both", "godot", "reference"),
        default="both",
        help="Select the offer role to assess",
    )
    parser.add_argument(
        "--binary-traffic",
        action="store_true",
        help="Check exact opaque native-profile packets in all three modes",
    )
    parser.add_argument(
        "--empty-binary",
        action="store_true",
        help="Include zero-byte wire packets in binary qualification",
    )
    parser.add_argument(
        "--startup-burst",
        action="store_true",
        help="Send 32 reliable packets at native channel open and Godot readiness",
    )
    parser.add_argument(
        "--receive-empty-binary",
        action="store_true",
        help="Require zero-byte packets from native reference to Godot in all modes",
    )
    parser.add_argument(
        "--snapshot-body-bytes",
        type=int,
        default=1024,
        help="Snapshot and partial body size, 16-16384 bytes in multiples of 16",
    )
    parser.add_argument(
        "--snapshot-window-bytes",
        type=int,
        default=49152,
        help="Outstanding snapshot/partial byte limit (default 49152); 0 reproduces packet-only pacing",
    )
    parser.add_argument(
        "--receive-batch-packets",
        type=int,
        default=32,
        help="Maximum Godot gameplay packets read per drain, 1-256",
    )
    parser.add_argument(
        "--receive-interval-ms",
        type=int,
        default=0,
        help="Minimum interval between Godot gameplay drains, 0-1000 ms; signaling keeps polling",
    )
    parser.add_argument(
        "--reference-receive-batch-packets",
        type=int,
        default=0,
        help="Reference application packets per drain, 1-256; 0 keeps immediate callbacks",
    )
    parser.add_argument(
        "--reference-receive-interval-ms",
        type=int,
        default=0,
        help="Minimum reference application drain interval, 0-1000 ms; transport keeps polling",
    )
    parser.add_argument(
        "--position-interval-ms",
        type=int,
        default=0,
        help="Send 32 positions on an independent 20-200 ms cadence; 0 keeps every-four-snapshots pacing",
    )
    parser.add_argument("--chromium")
    parser.add_argument(
        "--safe-receive", action="store_true", help="Read through the RPC-safe peer"
    )
    parser.add_argument(
        "--queued-retirement",
        action="store_true",
        help="Preserve an unreliable selection across late reliable arrivals before teardown",
    )
    parser.add_argument(
        "--mixed-traffic",
        action="store_true",
        help="Interleave exact position samples with snapshots",
    )
    parser.add_argument(
        "--credit-transport",
        choices=("http", "webrtc"),
        default="http",
        help="Return consumption credit over HTTP markers or reliable data-channel packets",
    )
    parser.add_argument(
        "--slow-receiver",
        action="store_true",
        help="Pause Godot reads for 1500 ms and require queued snapshot recovery",
    )
    parser.add_argument(
        "--slow-reference-receiver",
        action="store_true",
        help="Pause reference snapshot consumption for 1500 ms while heartbeats continue",
    )
    parser.add_argument(
        "--http-credit-delay-ms",
        type=int,
        default=0,
        help="Hold reference credit after 32 chunks for 0-8000 ms",
    )
    parser.add_argument(
        "--closing-channel", choices=("reliable", "ordered", "unreliable"), default="reliable"
    )
    parser.add_argument("--closing-seat", choices=("godot", "reference"), default="reference")
    parser.add_argument(
        "--retirement-matrix",
        action="store_true",
        help="Close each required channel from each seat",
    )
    parser.add_argument("--output", type=Path)
    parser.add_argument(
        "--require-gameplay",
        action="store_true",
        help="Fail when any pairing lacks exact probes and snapshots in both generations",
    )
    parser.add_argument("--keep-artifacts", action="store_true", help="Pin managed scratch output")
    args = parser.parse_args()
    if args.import_godot is not None and args.runtime != "native":
        parser.error("--import-godot is only supported for native template builds")
    if args.position_interval_ms and not (
        20 <= args.position_interval_ms <= 200 and args.mixed_traffic
    ):
        parser.error("--position-interval-ms requires --mixed-traffic and 20-200 ms, or 0")
    if not 1 <= args.receive_batch_packets <= 256:
        parser.error("--receive-batch-packets must be 1-256")
    if not 0 <= args.receive_interval_ms <= 1000:
        parser.error("--receive-interval-ms must be 0-1000")
    if not 0 <= args.reference_receive_batch_packets <= 256:
        parser.error("--reference-receive-batch-packets must be 0-256")
    if not 0 <= args.reference_receive_interval_ms <= 1000:
        parser.error("--reference-receive-interval-ms must be 0-1000")
    if args.reference_receive_interval_ms and not args.reference_receive_batch_packets:
        parser.error("--reference-receive-interval-ms needs --reference-receive-batch-packets")
    if args.channel_in_buffer_kb < 0 or args.channel_in_buffer_kb > 16384:
        parser.error("--channel-in-buffer-kb must be 0-16384")
    if not 16 <= args.snapshot_body_bytes <= 16384 or args.snapshot_body_bytes % 16:
        parser.error("--snapshot-body-bytes must be 16-16384 and a multiple of 16")
    if args.snapshot_window_bytes < 0 or (
        args.snapshot_window_bytes and args.snapshot_window_bytes < args.snapshot_body_bytes + 32
    ):
        parser.error("--snapshot-window-bytes must be 0 or hold one chunk including its header")
    if args.queued_retirement and not args.safe_receive:
        parser.error("--queued-retirement requires --safe-receive")
    if args.service_rejoin and (not args.service_url or not args.safe_receive):
        parser.error("--service-rejoin requires --service-url and --safe-receive")
    if args.service_rejoin and (
        args.retirement_matrix
        or args.closing_seat != "reference"
        or args.closing_channel != "reliable"
    ):
        parser.error(
            "--service-rejoin uses room departure, then reference reliable-channel closure"
        )
    if args.slow_reference_receiver and (not args.mixed_traffic or args.slow_receiver):
        parser.error("--slow-reference-receiver needs --mixed-traffic and an active Godot reader")
    if not 0 <= args.http_credit_delay_ms <= 8000:
        parser.error("--http-credit-delay-ms must be between 0 and 8000")
    if args.http_credit_delay_ms and args.credit_transport != "http":
        parser.error("--http-credit-delay-ms needs --credit-transport http")
    if (
        not args.retirement_matrix
        and not args.native_reference_probe
        and args.closing_seat == "reference"
        and args.closing_channel == "ordered"
    ):
        parser.error("the reference Engine has no ordered channel; use --closing-seat godot")
    if args.startup_burst and not args.native_reference_probe:
        parser.error("--startup-burst requires --native-reference-probe")
    if args.receive_empty_binary and (not args.binary_traffic or args.empty_binary):
        parser.error("--receive-empty-binary requires --binary-traffic and excludes --empty-binary")
    if args.empty_binary and not args.binary_traffic:
        parser.error("--empty-binary requires --binary-traffic")
    if args.binary_traffic and not args.native_reference_probe:
        parser.error("--binary-traffic requires --native-reference-probe")
    if args.native_reference_probe and not args.mixed_traffic:
        parser.error("--native-reference-probe requires --mixed-traffic")
    with interop.storage.managed_output(args.output, keep=args.keep_artifacts) as directory:
        results = []
        runtimes = (False, True) if args.runtime == "all" else (args.runtime == "web",)
        offers = (True, False) if args.offerer == "both" else (args.offerer == "godot",)
        cases = (
            [
                (seat, channel)
                for seat in ("godot", "reference")
                for channel in (
                    ("reliable", "ordered", "unreliable")
                    if seat == "godot" or args.native_reference_probe
                    else ("reliable", "unreliable")
                )
            ]
            if args.retirement_matrix
            else [(args.closing_seat, args.closing_channel)]
        )
        for web in runtimes:
            for godot_offer in offers:
                args.godot_offer = godot_offer
                for seat, channel in cases:
                    args.closing_seat, args.closing_channel = seat, channel
                    name = ("web" if web else "native") + (
                        "-godot-offer" if godot_offer else "-reference-offer"
                    )
                    if args.retirement_matrix:
                        name += f"-{seat}-{channel}"
                    folder = directory / name
                    if folder.exists():
                        raise FileExistsError(f"Assessment output already exists: {folder}")
                    try:
                        result = assess(args, folder, web=web)
                    except Exception as exc:
                        report_path = folder / "assessment.json"
                        if report_path.exists():
                            result = json.loads(report_path.read_text())
                        else:
                            result = {
                                "assessment_complete": False,
                                "driver_error": f"{type(exc).__name__}: {exc}",
                                "runtime": "web" if web else "native",
                                "godot_offer": godot_offer,
                                "closing_seat": seat,
                                "closing_channel": channel,
                            }
                            result["diagnostics"] = gameplay_diagnostics(result, "")
                            folder.mkdir(parents=True, exist_ok=True)
                            report_path.write_text(json.dumps(result, indent=2) + "\n")
                    results.append(result)
                    (directory / "summary.json").write_text(json.dumps(results, indent=2) + "\n")
                    print(
                        f"{name}: complete={result['assessment_complete']}; gameplay={result.get('gameplay_passed', False)}",
                        flush=True,
                    )
        if not all(result["assessment_complete"] for result in results):
            raise RuntimeError(f"Incomplete reference assessment; see {directory}")
        if args.require_gameplay and not all(result["gameplay_passed"] for result in results):
            raise RuntimeError(
                f"Reference gameplay is unsupported for one or more pairings; see {directory}"
            )


if __name__ == "__main__":
    main()
