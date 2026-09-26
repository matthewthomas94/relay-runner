#!/usr/bin/env python3
"""Separate, read-only qualification session. Never launches tools or providers."""

import argparse
import json
import os
from pathlib import Path
import sys
import uuid

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "services"))
from command_actions import format_command_for_agent, resolve_command_action
from laya_qualification import attach_hint, qualify_for_bridge


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--socket", required=True)
    parser.add_argument("--provider", choices=("codex", "claude"), default="codex")
    parser.add_argument("--text", help="One utterance; omit for an interactive read-only session")
    parser.add_argument("--context", help="JSON file with ordered user/assistant role/content messages")
    args = parser.parse_args()
    os.environ.update(RELAY_LAYA_TEST_MODE="1", RELAY_LAYA_SOCKET=args.socket)
    context = json.loads(Path(args.context).read_text()) if args.context else []
    seq = 0
    while True:
        if args.text is not None:
            text = args.text
        else:
            try:
                text = input("Qualification preview (Ctrl-D to exit)> ")
            except EOFError:
                break
        seq += 1
        command = {"relay_command_id": "preview-" + uuid.uuid4().hex, "relay_command_seq": seq, "provider": args.provider}
        action = resolve_command_action(text, repo_path=ROOT, relay_command=command)
        hint = qualify_for_bridge(text, command, context)
        item = {"metadata": {**command, "action": action.kind}, "prompt": format_command_for_agent(action)}
        attach_hint([item], hint)
        print(json.dumps({"read_only_preview": True, "source_text": text, **item}, indent=2, ensure_ascii=False))
        if args.text is not None:
            break


if __name__ == "__main__":
    main()
