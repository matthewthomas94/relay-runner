from __future__ import annotations

import http.client
import os
import socket
import sys
import threading
import time
import unittest


ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from orchestrator import (  # noqa: E402
    BoundedThreadingHTTPServer,
    Handler,
    ProgramRefreshUnavailable,
    _SingleFlight,
)


class SingleFlightTests(unittest.TestCase):
    def test_concurrent_refreshes_share_one_operation(self):
        flight = _SingleFlight(wait_seconds=2)
        started = threading.Event()
        release = threading.Event()
        calls = 0
        calls_lock = threading.Lock()
        results: list[dict[str, int]] = []
        failures: list[BaseException] = []

        def operation() -> dict[str, int]:
            nonlocal calls
            with calls_lock:
                calls += 1
            started.set()
            self.assertTrue(release.wait(timeout=2))
            return {"tickets": 200}

        def invoke() -> None:
            try:
                results.append(flight.run(operation))
            except BaseException as error:  # pragma: no cover - assertion reports details
                failures.append(error)

        threads = [threading.Thread(target=invoke) for _ in range(24)]
        for thread in threads:
            thread.start()
        self.assertTrue(started.wait(timeout=1))
        time.sleep(0.05)
        release.set()
        for thread in threads:
            thread.join(timeout=2)

        self.assertEqual(failures, [])
        self.assertEqual(calls, 1)
        self.assertEqual(results, [{"tickets": 200}] * 24)

    def test_waiter_times_out_without_canceling_leading_refresh(self):
        flight = _SingleFlight(wait_seconds=0.05)
        started = threading.Event()
        release = threading.Event()

        def operation() -> dict[str, int]:
            started.set()
            release.wait(timeout=1)
            return {"tickets": 1}

        leader = threading.Thread(target=lambda: flight.run(operation))
        leader.start()
        self.assertTrue(started.wait(timeout=1))
        with self.assertRaisesRegex(ProgramRefreshUnavailable, "still in progress"):
            flight.run(operation)
        release.set()
        leader.join(timeout=1)
        self.assertFalse(leader.is_alive())


class HTTPResourceLifecycleTests(unittest.TestCase):
    def test_request_threads_and_descriptors_return_to_bounded_baseline(self):
        class BlockingDaemon:
            def __init__(self):
                self.started = threading.Event()
                self.release = threading.Event()
                self.calls = 0
                self.lock = threading.Lock()
                self.fail = False

            def program_dashboard(self, **_: object) -> dict[str, object]:
                if self.fail:
                    raise OSError(24, "fixture resource failure")
                with self.lock:
                    self.calls += 1
                self.started.set()
                self.release.wait(timeout=3)
                return {"summary": {"items": []}}

        class TestHandler(Handler):
            daemon = BlockingDaemon()

            def log_message(self, _format: str, *_args: object) -> None:
                pass

        descriptor_path = "/dev/fd"
        descriptor_baseline = (
            len(os.listdir(descriptor_path)) if os.path.isdir(descriptor_path) else None
        )
        server = BoundedThreadingHTTPServer(
            ("127.0.0.1", 0),
            TestHandler,
            max_request_threads=4,
            max_program_request_threads=1,
        )
        port = int(server.server_address[1])
        serving = threading.Thread(target=server.serve_forever, daemon=True)
        serving.start()

        def request(index: int) -> None:
            connection: socket.socket | None = None
            try:
                connection = socket.create_connection(("127.0.0.1", port), timeout=2)
                connection.sendall(
                    b"GET /v1/program/dashboard HTTP/1.1\r\n"
                    b"Host: 127.0.0.1\r\nConnection: close\r\n\r\n"
                )
                if index % 2 == 0:
                    return
                connection.settimeout(2)
                while connection.recv(4096):
                    pass
            except OSError:
                pass
            finally:
                if connection is not None:
                    connection.close()

        clients = [threading.Thread(target=request, args=(index,)) for index in range(100)]
        try:
            for client in clients:
                client.start()
            self.assertTrue(TestHandler.daemon.started.wait(timeout=2))
            deadline = time.monotonic() + 2
            while server.peak_request_count < 4 and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(server.peak_request_count, 4)
            self.assertLessEqual(server.active_request_count, 4)
            self.assertEqual(server.peak_program_request_count, 1)

            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            connection.request("GET", "/v1/health")
            response = connection.getresponse()
            response.read()
            self.assertEqual(response.status, 200)
            connection.close()

            TestHandler.daemon.release.set()
            for client in clients:
                client.join(timeout=3)
            deadline = time.monotonic() + 2
            while server.active_request_count and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertEqual(server.active_request_count, 0)
            self.assertEqual(server.active_program_request_count, 0)

            TestHandler.daemon.fail = True
            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            connection.request("GET", "/v1/program/dashboard")
            response = connection.getresponse()
            response.read()
            self.assertEqual(response.status, 503)
            connection.close()

            connection = http.client.HTTPConnection("127.0.0.1", port, timeout=2)
            connection.request("GET", "/v1/health")
            response = connection.getresponse()
            response.read()
            self.assertEqual(response.status, 200)
            connection.close()
        finally:
            TestHandler.daemon.release.set()
            server.shutdown()
            server.server_close()
            serving.join(timeout=2)
            for client in clients:
                client.join(timeout=1)

        if descriptor_baseline is not None:
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                if len(os.listdir(descriptor_path)) <= descriptor_baseline + 2:
                    break
                time.sleep(0.01)
            self.assertLessEqual(
                len(os.listdir(descriptor_path)),
                descriptor_baseline + 2,
            )


if __name__ == "__main__":
    unittest.main()
