"""JSONL control bridge for the opt-in native reference Engine drill."""

import base64
import binascii
import json
import re
import subprocess
import threading
import time
from pathlib import Path
from typing import cast


def packet_marker(value: dict[str, object]) -> str | None:
    text = value.get("marker", value.get("text"))
    if not isinstance(text, str) and isinstance(value.get("data_base64"), str):
        try:
            text = base64.b64decode(cast(str, value["data_base64"])[:160], validate=True).decode(
                "ascii", errors="replace"
            )
        except (ValueError, binascii.Error):
            return None
    if not isinstance(text, str):
        return None
    marker = ":".join(text.split(":")[:4])
    return (
        marker
        if re.fullmatch(
            r"heartbeat:[12]:reference:[0-9]+|reference:[12]:(?:reliable|unreliable)", marker
        )
        else None
    )


class NativeReference:
    def __init__(self, binary: Path, directory: Path) -> None:
        self.condition = threading.Condition()
        self.command_lock = threading.Lock()
        self.events: list[dict[str, object]] = []
        self.replies: dict[int, dict[str, object]] = {}
        self.next_id = 0
        self.started_ns = time.monotonic_ns()
        self.timings: list[dict[str, object]] = []
        self.timings_dropped = 0
        self.output_lines = 0
        self.sender_samples: list[dict[str, object]] = []
        self.sender_samples_dropped = 0
        self.error = ""
        self.receive_failure = ""
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.stderr = (directory / "native-reference.stderr").open("w")
        try:
            self.log = (directory / "native-reference.jsonl").open("w")
        except BaseException:
            self.stderr.close()
            raise
        try:
            self.process = subprocess.Popen(  # noqa: S603
                [str(binary)],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=self.stderr,
                text=True,
                bufsize=1,
            )
        except BaseException:
            self.log.close()
            self.stderr.close()
            raise
        try:
            self.reader.start()
        except BaseException:
            self.close()
            raise

    def _trace(self, stage: str, **fields: object) -> None:
        if len(self.timings) >= 10000:
            self.timings_dropped += 1
            return
        self.timings.append(
            {"stage": stage, "us": (time.monotonic_ns() - self.started_ns) // 1000, **fields}
        )

    def timing_snapshot(self) -> dict[str, object]:
        with self.condition:
            return {
                "sender_evidence": {
                    "samples": list(self.sender_samples),
                    "dropped": self.sender_samples_dropped,
                },
                "records": list(self.timings),
                "dropped": self.timings_dropped,
                "output_lines": self.output_lines,
                "reader_terminal": self.error,
                "process_returncode": self.process.poll(),
                "receive_failure": self.receive_failure,
            }

    def _read(self) -> None:
        if self.process.stdout is None:
            raise RuntimeError("native probe output pipe missing")
        try:
            for line in self.process.stdout:
                value: dict[str, object] = json.loads(line)
                self.log.write(line)
                self.log.flush()
                with self.condition:
                    self.output_lines += 1
                    boundary = value.get("send_boundary")
                    stage = "send"
                    if not isinstance(boundary, dict):
                        received = value.get("receive_boundary")
                        if isinstance(received, dict):
                            boundary = received.get("snapshot")
                            stage = "receive"
                        elif value.get("event") in ("closed", "receive_rejected"):
                            boundary = value.get("snapshot")
                            stage = "close"
                        elif isinstance(value.get("result"), dict):
                            boundary = cast(dict[str, object], value["result"])
                            stage = "snapshot"
                    if isinstance(boundary, dict) and "sctp" in boundary:
                        if len(self.sender_samples) < 64:
                            self.sender_samples.append(
                                {
                                    "stage": stage,
                                    "line": self.output_lines,
                                    "generation": value.get(
                                        "generation", boundary.get("generation")
                                    ),
                                    "marker": packet_marker(value),
                                    "label": value.get("label"),
                                    "probe_us": value.get("probe_us"),
                                    "snapshot": boundary,
                                }
                            )
                        else:
                            self.sender_samples_dropped += 1
                    if value.get("event") == "receive_rejected":
                        self.receive_failure = self.receive_failure or (
                            f"native receive rejected: generation={value.get('generation')} "
                            f"channel={value.get('label')}"
                        )
                    self._trace(
                        "output",
                        line=self.output_lines,
                        id=value.get("id"),
                        event=value.get("event"),
                        probe_us=value.get("probe_us"),
                        generation=value.get("generation"),
                        label=value.get("label"),
                        marker=packet_marker(value),
                    )
                    if "id" in value:
                        self.replies[cast(int, value["id"])] = value
                    else:
                        self.events.append(value)
                    self.condition.notify_all()
        except (ValueError, OSError) as exc:
            self.error = str(exc)
        finally:
            with self.condition:
                self.error = self.error or "native probe output closed"
                self.condition.notify_all()

    def command(self, value: dict[str, object]) -> object:
        with self.command_lock:
            with self.condition:
                self.next_id += 1
                command_id = self.next_id
                if self.process.stdin is None:
                    raise RuntimeError("native probe input pipe missing")
                self._trace(
                    "command",
                    id=command_id,
                    op=value.get("op"),
                    label=value.get("label"),
                    packets=len(cast(list[object], value["packets"]))
                    if isinstance(value.get("packets"), list)
                    else None,
                    markers=[
                        {"marker": marker, "label": packet.get("label")}
                        for packet in cast(list[dict[str, object]], value.get("packets", [value]))
                        if (marker := packet_marker(packet)) is not None
                    ],
                )
            self.process.stdin.write(json.dumps({**value, "id": command_id}) + "\n")
            self.process.stdin.flush()
            with self.condition:
                self._trace("written", id=command_id)
                if not self.condition.wait_for(
                    lambda: command_id in self.replies or bool(self.error), timeout=10
                ):
                    self._trace("timeout", id=command_id)
                    raise RuntimeError("native probe command timed out")
                if command_id not in self.replies:
                    raise RuntimeError(self.error)
                reply = self.replies.pop(command_id)
                self._trace("reply", id=command_id, failed="error" in reply)
                if "error" in reply:
                    raise RuntimeError(str(reply["error"]))
                return reply["result"]

    def drain(self) -> list[dict[str, object]]:
        with self.condition:
            if self.error:
                raise RuntimeError(self.error)
            events, self.events = self.events, []
            for event in events:
                marker = packet_marker(event)
                if marker is not None or event.get("event") == "closed":
                    self._trace(
                        "delivery",
                        event=event.get("event"),
                        generation=event.get("generation"),
                        label=event.get("label"),
                        probe_us=event.get("probe_us"),
                        marker=marker,
                    )
            return events

    def close(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
        try:
            self.process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.process.kill()
            self.process.wait(timeout=5)
        if self.reader.ident is not None:
            self.reader.join(timeout=5)
        if self.process.stdin is not None:
            self.process.stdin.close()
        if self.process.stdout is not None:
            self.process.stdout.close()
        self.log.close()
        self.stderr.close()
