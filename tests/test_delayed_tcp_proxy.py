"""Check exact stream forwarding, half-close delivery and bounded proxy cleanup."""

import asyncio
import importlib.util
import socket
import struct
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/delayed_tcp_proxy.py"
SPEC = importlib.util.spec_from_file_location("delayed_tcp_proxy", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"Could not load {SCRIPT}")
proxy_module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(proxy_module)


class DelayedProxyTests(unittest.IsolatedAsyncioTestCase):
    async def test_delayed_binary_stream_and_reply_after_client_half_close(self) -> None:
        body = bytes(range(256)) * 8192
        received = []

        async def reply(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            received.append(await reader.read())
            writer.write(body[::-1])
            await writer.drain()
            writer.close()
            await asyncio.wait_for(writer.wait_closed(), timeout=1)

        server = await asyncio.start_server(reply, "127.0.0.1", 0)
        proxy = proxy_module.DelayedTCPProxy(server.sockets[0].getsockname()[1], 25, 127)
        proxy.start()
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", proxy.port)
            writer.write(body)
            await writer.drain()
            writer.write_eof()
            result = await asyncio.wait_for(reader.read(), timeout=10)
            self.assertEqual(received, [body])
            self.assertEqual(result, body[::-1])
            writer.close()
            await asyncio.wait_for(writer.wait_closed(), timeout=1)
        finally:
            report = proxy.stop()
            server.close()
            await server.wait_closed()
        self.assertEqual(report["errors"], [])
        self.assertEqual(len(report["connections"]), 1)
        for direction in ("client_to_server", "server_to_client"):
            stats = report["connections"][0][direction]
            self.assertEqual(stats["bytes"], len(body))
            self.assertTrue(stats["eof"])
            self.assertGreater(stats["chunks"], 16)
            self.assertLessEqual(
                stats["peak_queued_chunks"], report["queue_limit_chunks_per_direction"]
            )
            self.assertGreaterEqual(stats["min_forward_delay_ms"], 24)

    async def test_reset_does_not_leave_forwarder_waiting_for_a_queue_item(self) -> None:
        finished = asyncio.Event()

        async def reset(_reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            transport_socket = writer.get_extra_info("socket")
            transport_socket.setsockopt(
                socket.SOL_SOCKET,
                socket.SO_LINGER,
                struct.pack("ii", 1, 0),
            )
            writer.transport.abort()
            finished.set()

        server = await asyncio.start_server(reset, "127.0.0.1", 0)
        proxy = proxy_module.DelayedTCPProxy(server.sockets[0].getsockname()[1], 10)
        proxy.start()
        try:
            reader, writer = await asyncio.open_connection("127.0.0.1", proxy.port)
            await asyncio.wait_for(finished.wait(), timeout=5)
            self.assertEqual(await asyncio.wait_for(reader.read(), timeout=5), b"")
            writer.close()
            await asyncio.wait_for(writer.wait_closed(), timeout=1)
        finally:
            report = proxy.stop()
            server.close()
            await server.wait_closed()
        self.assertEqual(report["errors"], [])
        self.assertIn("socket_error", report["connections"][0])
        self.assertNotIn("cancelled_on_stop", report["connections"][0])

    async def test_stop_retires_live_idle_connections(self) -> None:
        accepted = asyncio.Event()
        ended = asyncio.Event()

        async def idle(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
            accepted.set()
            await reader.read()
            writer.close()
            await asyncio.wait_for(writer.wait_closed(), timeout=1)
            ended.set()

        server = await asyncio.start_server(idle, "127.0.0.1", 0)
        proxy = proxy_module.DelayedTCPProxy(server.sockets[0].getsockname()[1], 25)
        proxy.start()
        reader, writer = await asyncio.open_connection("127.0.0.1", proxy.port)
        try:
            await asyncio.wait_for(accepted.wait(), timeout=5)
            report = proxy.stop()
            self.assertFalse(proxy.thread.is_alive())
            self.assertEqual(report["errors"], [])
            self.assertTrue(report["connections"][0]["cancelled_on_stop"])
            self.assertEqual(await asyncio.wait_for(reader.read(), timeout=5), b"")
            await asyncio.wait_for(ended.wait(), timeout=5)
        finally:
            writer.close()
            await asyncio.wait_for(writer.wait_closed(), timeout=1)
            server.close()
            await server.wait_closed()


if __name__ == "__main__":
    unittest.main()
