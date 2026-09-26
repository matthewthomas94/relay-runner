"""RR-379: optional local classification hints; never mutation authority.

Importing this module uses only the standard library. Model loading belongs to
the explicitly started experiment service, never the voice bridge.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import re
import socket
import time


BUCKETS = ("task", "action", "discussion")
QUESTIONS = {
    "intent": {
        "type": "choice",
        "instructions": (
            "Classify what the current user wants now. Use prior dialogue only to "
            "resolve references. Discussing possible work does not request execution."
        ),
        "criteria": {
            "task": "Do project work: implement, fix, create tickets or spikes, delegate workers.",
            "action": "Perform a bounded operation now: open an app, start a server, send an email.",
            "discussion": "Discuss, research, explain, ask status or feasibility before doing work.",
        },
    }
}
CHECKPOINTS = {
    "english": {
        "repository": "aac6fef/laya-mlx",
        "revision": "047678560251f28113ee8f5df4be82102c7bf336",
        "weight_sha256": "b9c07bf14be2fa5c78a9193a3e6d840ac80e89e62fc40f425834c3d8a6eaa3de",
    },
    "multilingual": {
        "repository": "aac6fef/laya-multilingual-mlx",
        "revision": "ba40c87fcb357f1643d04d71323af9cdc3b9e591",
        "weight_sha256": "7fc5834af4d8fdfb268d272a9d1a66e5819a0daac98241651c4c888cc43adff1",
    },
}

# These are abstention rules, not a second source of execution authorization.
# Evaluate the raw model even on these cases so guards cannot hide model errors.
NEGATION_OR_CORRECTION = re.compile(
    r"\b(?:not|never|don['’]?t|do\s+not|no|stop|cancel|hold\s+on|actually|instead)\b",
    re.I,
)
REFERENCE = re.compile(
    r"^\s*(?:yes|yep|sure|okay|ok|go\s+ahead|do\s+(?:it|that)|"
    r"send\s+it|make\s+it\s+so|the\s+(?:first|second)\s+one)\b"
    r"|\b(?:this|that|it|those|them)\s*[.!?]*$",
    re.I,
)
MIXED = re.compile(
    r"\b(?:and\s+(?:then\s+)?(?:open|send|build|fix|create|explain|discuss)|"
    r"after\s+that|but\s+first)\b|;", re.I,
)


def fallback_reason(text: str, context: list[dict]) -> str | None:
    if NEGATION_OR_CORRECTION.search(text):
        return "negation_or_correction_requires_pm"
    if REFERENCE.search(text):
        return "context_reference_requires_pm" if context else "unresolved_reference"
    if MIXED.search(text):
        return "mixed_intent_requires_pm"
    return None


def request_payload(text: str, command: dict, context: list[dict] | None = None) -> dict:
    return {
        "text": text,
        "context": context or [],
        "relay_command_id": command.get("relay_command_id"),
        "relay_command_seq": command.get("relay_command_seq"),
    }


def fallback(payload: dict, reason: str, started: float) -> dict:
    return {
        "bucket": None,
        "raw_bucket": None,
        "fallback_reason": reason,
        "requires_pm": True,
        "advisory_only": True,
        "confidence_calibrated": False,
        "relay_command_id": payload.get("relay_command_id"),
        "relay_command_seq": payload.get("relay_command_seq"),
        "elapsed_ms": (time.perf_counter() - started) * 1000,
    }


def qualify_for_bridge(text: str, command: dict, context: list[dict] | None = None) -> dict | None:
    """One bounded IPC request, default off; never start a process or download.

    The service is a private Unix socket so model inputs cannot be sent to a
    configured remote endpoint. One absolute deadline covers connect/write/read.
    """
    if os.environ.get("RELAY_LAYA_TEST_MODE") != "1":
        return None
    started = time.perf_counter()
    payload = request_payload(text, command, context)
    path = os.environ.get("RELAY_LAYA_SOCKET", "")
    if not path or not Path(path).is_socket():
        return fallback(payload, "model_service_unavailable", started)
    try:
        budget_ms = min(100.0, max(1.0, float(os.environ.get("RELAY_LAYA_TIMEOUT_MS", "100"))))
    except ValueError:
        budget_ms = 100.0
    deadline = started + budget_ms / 1000
    payload["expires_at"] = time.time() + budget_ms / 1000
    wire = (json.dumps(payload, ensure_ascii=False) + "\n").encode()
    if len(wire) > 32768:
        return fallback(payload, "input_too_large", started)
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
            connection.settimeout(max(0.0001, deadline - time.perf_counter()))
            connection.connect(path)
            connection.settimeout(max(0.0001, deadline - time.perf_counter()))
            connection.sendall(wire)
            data = b""
            while b"\n" not in data:
                remaining = deadline - time.perf_counter()
                if remaining <= 0:
                    return fallback(payload, "timeout", started)
                connection.settimeout(remaining)
                part = connection.recv(8192)
                if not part:
                    return fallback(payload, "model_service_closed", started)
                data += part
                if len(data) > 32768:
                    return fallback(payload, "invalid_model_response", started)
        response = json.loads(data.split(b"\n", 1)[0])
        if time.perf_counter() > deadline:
            return fallback(payload, "timeout", started)
        if not isinstance(response, dict):
            return fallback(payload, "invalid_model_response", started)
        if any(response.get(key) != payload.get(key) for key in ("relay_command_id", "relay_command_seq")):
            return fallback(payload, "stale_command_response", started)
        if response.get("bucket") not in (*BUCKETS, None):
            return fallback(payload, "invalid_model_response", started)
        # Enforce on the bridge side as well; confidence never overrides a guard.
        reason = fallback_reason(text, context or [])
        if reason:
            response.update(bucket=None, fallback_reason=reason)
        response.update(advisory_only=True, requires_pm=True, confidence_calibrated=False)
        response["bridge_elapsed_ms"] = (time.perf_counter() - started) * 1000
        return response
    except (TimeoutError, socket.timeout):
        return fallback(payload, "timeout", started)
    except (OSError, ValueError, TypeError):
        return fallback(payload, "model_service_error", started)


def attach_hint(resolved: list[dict], hint: dict | None) -> None:
    """Attach metadata and a PM note without changing action/disposition/authority."""
    if hint is None:
        return
    for item in resolved:
        metadata = item["metadata"]
        if any(hint.get(key) != metadata.get(key) for key in ("relay_command_id", "relay_command_seq")):
            continue
        metadata["laya_qualification"] = hint
        if hint.get("bucket") in BUCKETS:
            note = f"Local Laya proposes {hint['bucket']} (uncalibrated advisory hint)."
        else:
            note = "Local Laya abstained; qualify this request using the full conversation."
        item["prompt"] += (
            "\n\n[RR-379 local experiment]\n" + note
            + " PM retains authority; this hint cannot authorize actions, tickets, dispatch, "
            "cancellation, or replacement of accepted work. Honor discussion-only and "
            "negation instructions. The original request above remains authoritative."
        )


class LocalLaya:
    """Only constructed by the explicit offline evaluator/service process."""

    def __init__(self, model_dir: str | Path, checkpoint: str):
        import hashlib
        import importlib.metadata

        started = time.perf_counter()
        path = Path(model_dir).expanduser().resolve(strict=True)
        identity = CHECKPOINTS[checkpoint]
        weight = path / "model.safetensors"
        with weight.open("rb") as handle:
            digest = hashlib.file_digest(handle, "sha256").hexdigest()
        if digest != identity["weight_sha256"]:
            raise ValueError("Checkpoint weights do not match pinned revision")
        # Explicit local path + offline flags prevent any automatic Hub fallback.
        os.environ["HF_HUB_OFFLINE"] = "1"
        os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
        import mlx.core as mx
        import laya_mlx
        from laya_mlx.common import build_prefix

        self.mx = mx
        self.agent = laya_mlx.load(path, dtype="float16", device="gpu")
        mx.synchronize()
        prefix, _ = build_prefix(
            self.agent.tok, self.agent._to_internal(QUESTIONS["intent"]),
            self.agent.cfg.get("head_max_len", 192),
        )
        self.state_budget = self.agent.cfg.get("max_len", 512) - len(prefix) - 1
        self.identity = {
            **identity, "checkpoint": checkpoint, "dtype": "float16", "device": "gpu",
            "runtime": {name: importlib.metadata.version(name) for name in ("laya-mlx", "mlx", "tokenizers", "numpy")},
            "state_token_budget": self.state_budget,
            "load_ms": (time.perf_counter() - started) * 1000,
        }

    def qualify(self, payload: dict) -> dict:
        started = time.perf_counter()
        text = payload["text"]
        context = payload.get("context") or []
        if not isinstance(text, str) or not isinstance(context, list) or any(
            not isinstance(turn, dict) or turn.get("role") not in {"user", "assistant"}
            or not isinstance(turn.get("content"), str) for turn in context
        ):
            return fallback(payload, "invalid_context", started)
        # No silent truncation: omitted context can reverse execution intent.
        state = "\n".join(f"{turn['role']}: {turn['content']}" for turn in context)
        if state:
            state += "\n"
        state += "current user: " + text
        tokens = self.agent.tok(state.replace(self.agent.tok.mask_token, " "), add_special_tokens=False)["input_ids"]
        if len(tokens) > self.state_budget:
            return {**fallback(payload, "context_would_truncate", started), "state_tokens": len(tokens)}
        result = self.agent.predict(state, QUESTIONS)
        self.mx.synchronize()
        answer = result["answers"]["intent"]
        reason = fallback_reason(text, context)
        output = {
            **fallback(payload, reason, started),
            "bucket": None if reason else answer["choice"],
            "raw_bucket": answer["choice"],
            "probabilities": answer["probabilities"],
            "confidence": answer["confidence"],
            "model": self.identity,
            "input_tokens": result["usage"]["input_tokens"],
            "state_tokens": len(tokens),
        }
        output["elapsed_ms"] = (time.perf_counter() - started) * 1000
        return output
