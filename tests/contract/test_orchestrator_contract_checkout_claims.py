"""Checkout claims (RR-527): the real `relay-rs hook` on PreToolUse against a live daemon.

A session runs while `<runtime>/relay-sessions/<key>/` holds a `session_agent`
file, as the app writes it. Each case starts the sessions it needs and stops
them afterwards, which releases their claims before the next case.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import time
import unittest

from orchestrator_contract_support import RUST_BIN_DIR, DaemonCase, require_built

HOOK = [str(RUST_BIN_DIR / "relay-rs"), "hook"]

LISTED_GIT = [
    "checkout main", "switch -c feature", "commit -m wip", "merge feature", "rebase main",
    "reset --hard HEAD", "stash", "cherry-pick abc123", "revert abc123", "pull --rebase",
    "push origin main", "tag v1.2.3",
]


class CheckoutClaimCase(DaemonCase):
    @classmethod
    def prepare(cls):
        require_built(HOOK)
        cls.repo = cls.box.make_repo("claimed-checkout")
        cls.box.register(cls.repo)
        cls.general = cls.box.state_root / "general-tasks"
        cls.general.mkdir(parents=True, exist_ok=True)
        # general-tasks is a registered project too, and still never claimable.
        cls.box.register(cls.general)
        cls.worker = cls.box.data_root / "workspaces" / "claimed-checkout-1-ct-1"
        cls.worker.mkdir(parents=True, exist_ok=True)

    def start(self, key: str, agent: str) -> str:
        spool = self.box.runtime / "relay-sessions" / key
        spool.mkdir(parents=True)
        (spool / "session_agent").write_text(agent + "\n")
        self.addCleanup(self.stop, key)
        return key

    def stop(self, key: str) -> None:
        shutil.rmtree(self.box.runtime / "relay-sessions" / key, ignore_errors=True)
        self.box.get("/v1/checkout-claims")

    def hook(self, key: str, tool: str, tool_input: dict, *, cwd=None, port_file=None,
             provider: str = "claude") -> subprocess.CompletedProcess:
        payload = {
            "hook_event_name": "PreToolUse", "session_id": "00000000-0000-4000-8000-000000000001",
            "cwd": str(cwd or self.repo), "tool_name": tool, "tool_input": tool_input,
            "tool_use_id": "call-1", "permission_mode": "bypassPermissions",
        }
        if provider == "codex":
            payload.update({"turn_id": "turn-1", "model": "gpt", "transcript_path": None})
        env = {
            "PATH": "/usr/bin:/bin", "HOME": str(self.box.home),
            "RELAY_RUNNER_PROVIDER": provider, "RELAY_SESSION_KEY": key,
            "RELAY_APP_SESSION_ID": "app-session", "RELAY_RECOVERY_GENERATION": "generation-1",
            "RELAY_ACTOR_ROLE": "foreground_pm", "RELAY_FOREGROUND_GATE_HANDLE": "gate-1",
            "ORCHESTRATOR_PORT_FILE": str(port_file or self.box.port_file),
            "ORCHESTRATOR_DEFAULT_PORT": "1",
        }
        result = subprocess.run(HOOK, input=json.dumps(payload), capture_output=True, text=True,
                                env=env, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result

    def assertAllowed(self, result):
        self.assertEqual(result.stdout.strip(), "", result.stdout)

    def assertRefused(self, result, holder: str = "Puck") -> str:
        output = json.loads(result.stdout)
        specific = output["hookSpecificOutput"]
        self.assertEqual(set(output), {"hookSpecificOutput"})
        self.assertEqual(specific["hookEventName"], "PreToolUse")
        self.assertEqual(specific["permissionDecision"], "deny")
        reason = specific["permissionDecisionReason"]
        self.assertIn("%s holds the claim on the claimed-checkout checkout" % holder, reason)
        self.assertIn("ask how to proceed", reason)
        return reason

    def edit(self, path) -> dict:
        return {"file_path": str(path), "old_string": "a", "new_string": "b"}

    def claims(self) -> list:
        return self.assertStatus(self.box.get("/v1/checkout-claims"), 200).json["checkout_claims"]

    def notices(self, key: str) -> list:
        response = self.assertStatus(
            self.box.post("/v1/agent-notices/claim", {"relay_session_key": key}), 200,
        )
        return [notice["text"] for notice in response.json["notices"]]


class FileWriteTests(CheckoutClaimCase):
    def test_a_write_by_a_non_holder_is_refused_and_the_rest_are_allowed(self):
        puck = self.start("puck-files", "puck")
        george = self.start("george-files", "george")
        readme = self.repo / "README.md"

        self.assertAllowed(self.hook(puck, "Edit", self.edit(readme)))
        [claim] = self.claims()
        self.assertEqual((claim["agent"], claim["purpose"]), ("puck", "Edit README.md"))
        before = readme.read_text()
        reason = self.assertRefused(self.hook(george, "Write", {"file_path": str(readme), "content": "x"}))
        self.assertIn('for "Edit README.md"', reason)
        self.assertIn("last write just now", reason)
        self.assertEqual(readme.read_text(), before, "a hook decision never writes")
        self.assertRefused(self.hook(george, "apply_patch", {
            "command": "*** Begin Patch\n*** Update File: README.md\n@@\n-a\n+b\n*** End Patch\n",
        }, provider="codex"))

        # The holder, worktrees, general-tasks and reads are never refused.
        self.assertAllowed(self.hook(puck, "MultiEdit", self.edit(readme)))
        self.assertAllowed(self.hook(george, "Edit", self.edit(
            self.repo / ".claude" / "worktrees" / "george" / "README.md")))
        self.assertAllowed(self.hook(george, "Write", {"file_path": str(self.worker / "README.md")}))
        self.assertAllowed(self.hook(george, "Write", {"file_path": str(self.general / "notes.md")}))
        self.assertAllowed(self.hook(george, "Read", {"file_path": str(readme)}))
        self.assertEqual([claim["agent"] for claim in self.claims()], ["puck"])

    def test_the_claim_moves_on_after_release_or_stop(self):
        puck = self.start("puck-release", "puck")
        george = self.start("george-release", "george")
        readme = self.repo / "README.md"
        response = self.assertStatus(self.box.post("/v1/checkout-claims/claim", {
            "relay_session_key": puck, "repo_path": str(self.repo), "purpose": "cutting release v1.2.3",
        }), 200)
        self.assertEqual(response.json["claimed"], "taken")
        refused = self.assertError(self.box.post("/v1/checkout-claims/claim", {
            "relay_session_key": george, "repo_path": str(self.repo), "purpose": "mine",
        }), 409)
        self.assertIn("Puck holds the claim", refused["error"])
        self.assertIn("cutting release v1.2.3", self.assertRefused(self.hook(george, "Bash", {"command": "git push"})))
        self.assertEqual(self.notices(george), [
            "Agent notice: Puck took the checkout claim on claimed-checkout (cutting release v1.2.3); "
            "other agents' edits, branch switches and releases there are refused until it is released.",
        ])

        self.assertError(self.box.post("/v1/checkout-claims/release", {
            "relay_session_key": george, "repo_path": str(self.repo)}), 409)
        released = self.assertStatus(self.box.post("/v1/checkout-claims/release", {
            "relay_session_key": puck}), 200).json["released"]
        self.assertEqual([claim["repository"] for claim in released], ["claimed-checkout"])
        self.assertEqual(self.notices(george), [
            "Agent notice: Puck released the checkout claim on claimed-checkout (released).",
        ])
        self.assertAllowed(self.hook(george, "Edit", self.edit(readme)))
        self.assertRefused(self.hook(puck, "Edit", self.edit(readme)), holder="George")

        # The presence read shows the claim; George stopping releases it.
        presence = self.assertStatus(self.box.post("/v1/agent-presence", {"relay_session_key": puck}), 200)
        self.assertEqual([claim["agent"] for claim in presence.json["checkout_claims"]], ["george"])
        self.stop(george)
        self.assertEqual(self.claims(), [])
        self.assertIn("Agent notice: George released the checkout claim on claimed-checkout (George stopped).",
                      self.notices(puck))
        self.assertAllowed(self.hook(puck, "Edit", self.edit(readme)))

    def test_no_daemon_or_no_agent_session_allows_the_call(self):
        puck = self.start("puck-down", "puck")
        self.start("george-down", "george")
        self.assertAllowed(self.hook(puck, "Edit", self.edit(self.repo / "README.md")))
        down = self.box.root / "closed.port"
        down.write_text("1\n")
        self.assertAllowed(self.hook("george-down", "Bash", {"command": "git push"}, port_file=down))
        self.assertAllowed(self.hook("nobody-running", "Bash", {"command": "git push"}))


class GitCommandTests(CheckoutClaimCase):
    def test_each_listed_git_command_is_refused_here_and_with_dash_c(self):
        puck = self.start("puck-git", "puck")
        george = self.start("george-git", "george")
        self.assertAllowed(self.hook(puck, "Bash", {"command": "git commit -m first"}))
        elsewhere = self.box.root
        for provider in ("claude", "codex"):
            for command in LISTED_GIT:
                with self.subTest(provider=provider, command=command):
                    self.assertRefused(self.hook(george, "Bash", {"command": "git " + command},
                                                 provider=provider))
                    self.assertRefused(self.hook(
                        george, "Bash", {"command": "git -C %s %s" % (self.repo, command)},
                        cwd=elsewhere, provider=provider))
            for command in ("git status", "git log --oneline", "git diff HEAD", "git stash list",
                            "git tag -l", "git -C %s status" % self.repo, "cargo test --locked"):
                with self.subTest(provider=provider, command=command):
                    self.assertAllowed(self.hook(george, "Bash", {"command": command},
                                                 provider=provider))
        self.assertRefused(self.hook(george, "Bash", {"command": "./scripts/build-dmg.sh"}))
        self.assertRefused(self.hook(george, "Bash", {"command": "gh release create v1.2.3"}))

    def test_an_ordinary_tool_call_stays_fast(self):
        puck = self.start("puck-fast", "puck")
        for label, tool, tool_input in (
            ("read-only shell", "Bash", {"command": "git status && cargo test"}),
            ("file write", "Edit", self.edit(self.repo / "README.md")),
        ):
            started = time.perf_counter()
            for _ in range(20):
                self.assertAllowed(self.hook(puck, tool, tool_input))
            per_call = (time.perf_counter() - started) / 20
            print("checkout-claim hook, %s: %.1f ms per call" % (label, per_call * 1000))
            self.assertLess(per_call, 0.5, label)


if __name__ == "__main__":
    unittest.main()
