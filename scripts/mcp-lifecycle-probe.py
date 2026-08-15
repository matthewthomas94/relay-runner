#!/usr/bin/env python3
"""Probe the legacy Relay MCP adapters against the 2026-07-28 lifecycle."""

import argparse
import json
import select
import shutil
import subprocess
import sys
from pathlib import Path


ADAPTERS = (
    "relay-actions-mcp",
    "relay-vision-mcp",
    "relay-orchestrator-mcp",
)
META = {
    "io.modelcontextprotocol/protocolVersion": "2026-07-28",
    "io.modelcontextprotocol/clientInfo": {"name": "rr-326-probe", "version": "1"},
    "io.modelcontextprotocol/clientCapabilities": {},
}


def request(process, payload):
    process.stdin.write(json.dumps(payload) + "\n")
    process.stdin.flush()
    ready, _, _ = select.select([process.stdout], [], [], 5)
    if not ready:
        raise AssertionError(f"timed out waiting for {payload['method']}")
    return json.loads(process.stdout.readline())


def expect_no_response(process, payload):
    process.stdin.write(json.dumps(payload) + "\n")
    process.stdin.flush()
    ready, _, _ = select.select([process.stdout], [], [], 0.2)
    if ready:
        raise AssertionError(f"notification {payload['method']} unexpectedly responded")


def probe_adapter(binary):
    process = subprocess.Popen(
        [str(binary)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )
    try:
        initialized = request(process, {
            "jsonrpc": "2.0", "id": "legacy-initialize", "method": "initialize",
            "params": {"protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "rr-326-probe", "version": "1"}},
        })
        assert initialized["result"]["protocolVersion"] == "2024-11-05"
        expect_no_response(process, {"jsonrpc": "2.0", "method": "notifications/initialized"})

        legacy_list = request(process, {"jsonrpc": "2.0", "id": "legacy-list", "method": "tools/list"})
        assert legacy_list["id"] == "legacy-list"
        assert legacy_list["result"]["tools"]

        discover = request(process, {
            "jsonrpc": "2.0", "id": "stateless-discover", "method": "server/discover", "params": {"_meta": META},
        })
        assert discover["error"]["code"] == -32601

        direct_list = request(process, {
            "jsonrpc": "2.0", "id": "stateless-list", "method": "tools/list", "params": {"_meta": META},
        })
        assert direct_list["id"] == "stateless-list"
        assert direct_list["result"]["tools"]
        assert "_meta" not in direct_list["result"]

        handle_list = request(process, {
            "jsonrpc": "2.0", "id": "request-handle", "method": "tools/list",
            "params": {"_meta": {**META, "com.relay-runner/request-handle": "rr-326-probe"}},
        })
        assert handle_list["result"]["tools"]
        assert "_meta" not in handle_list["result"]

        expect_no_response(process, {
            "jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": {"requestId": "stateless-list", "reason": "rr-326 probe", "_meta": META},
        })
        post_cancel_list = request(process, {"jsonrpc": "2.0", "id": "post-cancel-list", "method": "tools/list"})
        assert post_cancel_list["result"]["tools"]

        missing_tool = request(process, {"jsonrpc": "2.0", "id": "missing-tool", "method": "tools/call", "params": {}})
        assert missing_tool["error"]["code"] == -32602
        return {
            "legacy_initialize": "2024-11-05 accepted",
            "stateless_discover": "-32601 method not found",
            "stateless_direct_request": "accepted without 2026-07-28 validation",
            "request_handle": "ignored; no explicit application-handle surface",
            "cancellation": "notification accepted; no in-flight cancellation evidence",
            "error": "missing tool name returns -32602",
        }
    finally:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def probe_client(command, health_status=None):
    executable = shutil.which(command[0])
    if not executable:
        return {"available": False, "result": "CLI not installed"}
    completed = subprocess.run(command, text=True, capture_output=True, timeout=20)
    output = completed.stdout + completed.stderr
    return {
        "available": True,
        "exit_code": completed.returncode,
        "all_relay_servers_listed": all(adapter in output for adapter in ADAPTERS),
        "health_status": health_status in output if health_status else "not exposed by this CLI command",
        "negotiated_capabilities": "not exposed by this CLI command",
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin-dir", type=Path, required=True)
    parser.add_argument("--skip-client-probes", action="store_true")
    args = parser.parse_args()

    report = {"adapters": {}}
    for adapter in ADAPTERS:
        binary = args.bin_dir / adapter
        if not binary.is_file():
            raise SystemExit(f"missing adapter binary: {binary}")
        report["adapters"][adapter] = probe_adapter(binary)
    if not args.skip_client_probes:
        report["installed_clients"] = {
            "codex": probe_client(["codex", "mcp", "list"]),
            "claude": probe_client(["claude", "mcp", "list"], "Connected"),
        }
    print(json.dumps(report, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
