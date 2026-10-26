"""JSONL control bridge for the opt-in native reference Engine drill."""

import json
import subprocess
import threading
from pathlib import Path
from typing import cast


class NativeReference:
    def __init__(self, binary: Path, directory: Path) -> None:
        self.condition = threading.Condition()
        self.command_lock = threading.Lock()
        self.events: list[dict[str, object]] = []
        self.replies: dict[int, dict[str, object]] = {}
        self.next_id = 0
        self.error = ""
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

    def _read(self) -> None:
        if self.process.stdout is None:
            raise RuntimeError("native probe output pipe missing")
        try:
            for line in self.process.stdout:
                value: dict[str, object] = json.loads(line)
                self.log.write(line)
                self.log.flush()
                with self.condition:
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
        with self.command_lock, self.condition:
            self.next_id += 1
            command_id = self.next_id
            if self.process.stdin is None:
                raise RuntimeError("native probe input pipe missing")
            self.process.stdin.write(json.dumps({**value, "id": command_id}) + "\n")
            self.process.stdin.flush()
            if not self.condition.wait_for(
                lambda: command_id in self.replies or bool(self.error), timeout=10
            ):
                raise RuntimeError("native probe command timed out")
            if command_id not in self.replies:
                raise RuntimeError(self.error)
            reply = self.replies.pop(command_id)
            if "error" in reply:
                raise RuntimeError(str(reply["error"]))
            return reply["result"]

    def drain(self) -> list[dict[str, object]]:
        with self.condition:
            if self.error:
                raise RuntimeError(self.error)
            events, self.events = self.events, []
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
