"""Bounded local TCP delay control for opt-in gameplay drills."""

from __future__ import annotations

import asyncio
import threading
import time
from typing import TypedDict


class ForwardStats(TypedDict):
    bytes: int
    chunks: int
    peak_queued_chunks: int
    max_forward_lag_ms: float
    min_forward_delay_ms: float | None
    eof: bool


class DelayedTCPProxy:
    def __init__(self, target_port: int, delay_ms: int, chunk_bytes: int = 65536) -> None:
        if not 0 <= delay_ms <= 500 or not 1 <= chunk_bytes <= 65536:
            raise ValueError("Delay must be 0..500 ms and chunk size 1..65536 bytes")
        self.target_port = target_port
        self.delay = delay_ms / 1000
        self.chunk_bytes = chunk_bytes
        self.queue_chunks = min(8192, 1048576 // chunk_bytes)
        self.port = 0
        self.connections: list[dict[str, object]] = []
        self.forward_stats: list[ForwardStats] = []
        self.errors: list[str] = []
        self.loop = asyncio.new_event_loop()
        self.thread = threading.Thread(target=self.loop.run_forever, daemon=True)
        self.server: asyncio.Server | None = None
        self.tasks: set[asyncio.Task[None]] = set()
        self.streams: set[asyncio.StreamWriter] = set()

    async def _start(self) -> None:
        self.server = await asyncio.start_server(self._accept, "127.0.0.1", 0, limit=65536)
        self.port = self.server.sockets[0].getsockname()[1]

    def start(self) -> None:
        self.thread.start()
        asyncio.run_coroutine_threadsafe(self._start(), self.loop).result(timeout=5)

    async def _pipe(
        self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter, stats: ForwardStats
    ) -> None:
        queue: asyncio.Queue[tuple[float, bytes | Exception]] = asyncio.Queue(
            maxsize=self.queue_chunks
        )

        async def receive() -> None:
            try:
                while True:
                    data = await reader.read(self.chunk_bytes)
                    await queue.put((time.monotonic() + self.delay, data))
                    stats["peak_queued_chunks"] = max(stats["peak_queued_chunks"], queue.qsize())
                    if not data:
                        break
            except Exception as exc:
                await queue.put((time.monotonic() + self.delay, exc))

        producer = asyncio.create_task(receive())
        try:
            while True:
                due, data = await queue.get()
                await asyncio.sleep(max(0, due - time.monotonic()))
                if isinstance(data, Exception):
                    raise data
                if not data:
                    writer.write_eof()
                    await writer.drain()
                    stats["eof"] = True
                    return
                writer.write(data)
                await writer.drain()
                stats["bytes"] += len(data)
                stats["chunks"] += 1
                elapsed = (time.monotonic() - due + self.delay) * 1000
                previous = stats["min_forward_delay_ms"]
                stats["min_forward_delay_ms"] = (
                    elapsed if previous is None else min(previous, elapsed)
                )
                stats["max_forward_lag_ms"] = max(
                    stats["max_forward_lag_ms"], (time.monotonic() - due) * 1000
                )
        finally:
            producer.cancel()
            await asyncio.gather(producer, return_exceptions=True)

    async def _accept(self, reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
        task = asyncio.current_task()
        assert task is not None  # noqa: S101
        self.tasks.add(task)
        self.streams.add(writer)
        upstream: asyncio.StreamWriter | None = None
        pipes: list[asyncio.Task[None]] = []
        directions: list[ForwardStats] = []
        record: dict[str, object] = {
            "connection": len(self.connections) + 1,
            "accepted_monotonic_ns": time.monotonic_ns(),
        }
        self.connections.append(record)
        try:
            remote, upstream = await asyncio.open_connection("127.0.0.1", self.target_port)
            self.streams.add(upstream)
            for direction, source, destination in (
                ("client_to_server", reader, upstream),
                ("server_to_client", remote, writer),
            ):
                stats: ForwardStats = {
                    "bytes": 0,
                    "chunks": 0,
                    "peak_queued_chunks": 0,
                    "max_forward_lag_ms": 0.0,
                    "min_forward_delay_ms": None,
                    "eof": False,
                }
                record[direction] = stats
                directions.append(stats)
                self.forward_stats.append(stats)
                pipes.append(asyncio.create_task(self._pipe(source, destination, stats)))
            await asyncio.gather(*pipes)
        except (ConnectionError, OSError) as exc:
            record["socket_error"] = f"{type(exc).__name__}: {exc}"
        except asyncio.CancelledError:
            record["cancelled_on_stop"] = True
            raise
        except Exception as exc:
            self.errors.append(f"{type(exc).__name__}: {exc}")
        finally:
            for pipe in pipes:
                pipe.cancel()
            await asyncio.gather(*pipes, return_exceptions=True)
            for stream in (writer, upstream):
                if stream is not None:
                    stream.close()
                    self.streams.discard(stream)
            self.tasks.discard(task)
            record["closed_monotonic_ns"] = time.monotonic_ns()
            record["forwarded_both_directions"] = len(directions) == 2 and all(
                stats["bytes"] > 0 for stats in directions
            )

    async def _stop(self) -> None:
        if self.server is not None:
            self.server.close()
        tasks = list(self.tasks)
        for stream in self.streams:
            stream.close()
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        if self.server is not None:
            await self.server.wait_closed()

    def stop(self) -> dict[str, object]:
        try:
            asyncio.run_coroutine_threadsafe(self._stop(), self.loop).result(timeout=5)
        finally:
            self.loop.call_soon_threadsafe(self.loop.stop)
            self.thread.join(timeout=5)
            if self.thread.is_alive():
                raise RuntimeError("Delay proxy did not stop")
            self.loop.close()
        delays = [
            stats["min_forward_delay_ms"]
            for stats in self.forward_stats
            if stats["min_forward_delay_ms"] is not None
        ]
        return {
            "scope": "local TCP relay only; mesh UDP and HTTP control are unchanged",
            "one_way_delay_ms": self.delay * 1000,
            "read_chunk_bytes": self.chunk_bytes,
            "queue_limit_chunks_per_direction": self.queue_chunks,
            "queue_limit_payload_bytes_per_direction": self.queue_chunks * self.chunk_bytes,
            "connections": self.connections,
            "forwarded_connections": sum(
                bool(record.get("forwarded_both_directions")) for record in self.connections
            ),
            "minimum_forward_delay_ms": min(delays) if delays else None,
            "errors": self.errors,
        }
