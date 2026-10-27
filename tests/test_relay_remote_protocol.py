import json
import unittest
from pathlib import Path

from services import relay_remote_protocol as proto

VECTORS = Path(__file__).parent / "RelayRemoteProtocolTests" / "Vectors"


def load(name):
    return json.loads((VECTORS / f"{name}.json").read_text(encoding="utf-8"))


class RelayRemoteProtocolTests(unittest.TestCase):
    def test_frame_vectors_round_trip_byte_for_byte(self):
        types = set()
        for entry in load("frames"):
            line = entry["line"].encode("utf-8")
            frame = proto.decode(line)
            types.add(frame.TYPE)
            self.assertEqual(frame.PHONE_TO_MAC, entry["direction"] == "phone_to_mac", entry["name"])
            self.assertEqual(proto.encode(frame), line + b"\n", entry["name"])
            self.assertEqual(proto.decode(line + b"\n"), frame, entry["name"])
        self.assertEqual(types, set(proto.FRAME_TYPES))

    def test_invalid_vectors_report_shared_error_codes(self):
        for entry in load("invalid"):
            with self.assertRaises(proto.FrameError, msg=entry["name"]) as ctx:
                proto.decode(entry["line"].encode("utf-8"))
            self.assertEqual(ctx.exception.code, entry["error"], entry["name"])

    def test_line_limit_on_encode_and_decode(self):
        limits = load("limits")
        limit = limits["max_line_bytes"]
        self.assertEqual(limit, proto.MAX_LINE_BYTES)

        def utterance(n):
            return proto.Utterance(limits["pad_client_id"], "a" * n, limits["captured_at"])

        overhead = len(proto.encode(utterance(0))) - 1
        exact = proto.encode(utterance(limit - overhead))
        self.assertEqual(len(exact) - 1, limit)
        proto.decode(exact)
        with self.assertRaises(proto.FrameError) as ctx:
            proto.encode(utterance(limit - overhead + 1))
        self.assertEqual(ctx.exception.code, "line_too_long")
        with self.assertRaises(proto.FrameError) as ctx:
            proto.decode(exact[:-1] + b"a\n")
        self.assertEqual(ctx.exception.code, "line_too_long")

    def test_seq_counter_is_monotonic(self):
        counter = proto.SeqCounter()
        self.assertEqual([counter.next(), counter.next(), counter.next()], [1, 2, 3])

    def test_client_id_deduplication_vectors(self):
        vectors = load("dedup")
        dedup = proto.ClientIDDeduplicator(vectors["window"])
        self.assertEqual([dedup.is_duplicate(i) for i in vectors["ids"]], vectors["expected_duplicates"])

    def test_replay_vectors(self):
        for scenario in load("replay"):
            name = scenario["name"]
            counter = proto.SeqCounter()
            buffer = proto.ReplayBuffer()
            for step in scenario["steps"]:
                if step["op"] == "send":
                    for _ in range(step["count"]):
                        seq = counter.next()
                        buffer.record(proto.Status(seq, f"frame {seq}"), step["at"])
                elif step["op"] == "ack":
                    buffer.ack(step["seq"])
                else:
                    result = buffer.resume(step["after"], step["at"])
                    expect = step["expect"]
                    seqs = [f.seq for f in result.frames]
                    if seqs:
                        self.assertEqual(seqs, list(range(seqs[0], seqs[-1] + 1)), name)
                    self.assertEqual([seqs[0], seqs[-1]] if seqs else None, expect["replayed_range"], name)
                    self.assertEqual(result.dropped, expect["dropped"], name)
                    self.assertEqual(result.server_seq, expect["server_seq"], name)


if __name__ == "__main__":
    unittest.main()
