from __future__ import annotations

import os
import queue
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(__file__))
SERVICES = os.path.join(ROOT, "services")
sys.path.insert(0, SERVICES)

from tts_filter import TTSFilter  # noqa: E402


class TTSFilterTests(unittest.TestCase):
    def collect(self, *lines: str) -> list[str]:
        output_queue: queue.Queue = queue.Queue()
        filter_ = TTSFilter(chunk_timeout=999, output_queue=output_queue)
        try:
            for line in lines:
                filter_.feed((line + "\n").encode())
            filter_.shutdown()
        finally:
            filter_._shutdown = True

        chunks: list[str] = []
        while not output_queue.empty():
            chunks.append(output_queue.get_nowait())
        return chunks

    def test_strips_codex_terminal_chrome(self):
        chunks = self.collect(
            "OpenAI Codex v0.52.0",
            "Model: gpt-5-codex",
            "Approval: never",
            "Sandbox: danger-full-access",
            "Workdir: /tmp/project",
            "› fix the failing test",
            "Thinking...",
            "Done. The focused tests pass now.",
        )

        self.assertEqual(chunks, ["Done. The focused tests pass now."])

    def test_keeps_natural_codex_sentence(self):
        chunks = self.collect("Codex can handle that as a normal response.")

        self.assertEqual(chunks, ["Codex can handle that as a normal response."])


if __name__ == "__main__":
    unittest.main()
