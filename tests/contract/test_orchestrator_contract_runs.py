"""Run lifecycle on a legacy board: dispatch, review, merge, retry, cancel.

A legacy board keeps its tickets as tracked files. The worker commits the
ticket update on its `relay/<id>` branch, a review worker accepts or retries,
and the daemon merges into the checked-out branch.
"""

from __future__ import annotations

import unittest

from orchestrator_contract_support import DaemonCase, git, ticket_markdown

TERMINAL = ("Merged", "Failed", "Canceled", "AwaitingReview", "VerificationBlocked",
            "IntegrationBlocked")


class RunCase(DaemonCase):
    @classmethod
    def prepare(cls):
        cls.repo = cls.box.make_repo("runs", next_id=40)
        for number in range(1, 16):
            cls.box.write_ticket(cls.repo, "CT-%d" % number)
        cls.box.write_ticket(cls.repo, "CT-20", sizing=False)
        # A finished ticket whose run row was lost.
        preserved = ticket_markdown("CT-21", status="done").replace("run_id: null", "run_id: 77")
        preserved += "\n## Run log\n\n- **Run 77** (attempt 1) - branch `relay/ct-21`\n- Done earlier.\n"
        (cls.repo / ".orchestrator" / "CT-21.md").write_text(preserved)
        git(cls.repo, "add", ".orchestrator/CT-21.md")
        git(cls.repo, "commit", "--quiet", "-m", "docs(CT-21): run 77 log")
        cls.box.plan("implementation", "CT-2", exit_code=3)
        cls.box.plan("implementation", "CT-3", outcome="no_commit")
        cls.box.plan("implementation", "CT-4", outcome="partial")
        cls.box.plan("review", "CT-5", decision="none")
        cls.box.plan("review", "CT-6", decision="retry", redispatch=False, reason="Needs another pass.")
        cls.box.plan("implementation", "CT-7", outcome="verification_blocked")
        cls.box.plan("implementation", "CT-8", hold=str(cls.box.hold("ct8")))
        cls.box.plan("implementation", "CT-9", hold=str(cls.box.hold("ct9")))

    def dispatch(self, ticket_id: str, **extra):
        return self.box.post("/v1/runs", {"ticket_id": ticket_id, "repo_path": str(self.repo), **extra})

    def finish(self, ticket_id: str, *states: str) -> dict:
        response = self.assertStatus(self.dispatch(ticket_id), 202)
        return self.box.wait_for_run(response.json["run"]["id"], *(states or TERMINAL))


class DispatchTests(RunCase):
    def test_implementation_run_is_reviewed_and_merged(self):
        response = self.assertStatus(self.dispatch("CT-1", context="Prefer the simple fix."), 202)
        self.assertIs(response.json["already_active"], False)
        claimed = response.json["run"]
        self.assertEqual(claimed["state"], "Claimed")
        self.box.assert_golden_json("runs/dispatch.response", response.json)

        merged = self.box.wait_for_run(claimed["id"], "Merged")
        self.assertEqual(merged["exit_code"], 0)
        self.assertIsNone(merged["last_error"])
        self.box.assert_golden_json("runs/merged.run", merged)

        # The worker's three commits and the daemon's merge commit, in order.
        subjects = git(self.repo, "log", "--format=%s", "-4").splitlines()
        self.assertEqual(subjects, [
            "merge CT-1 worker run %d" % claimed["id"],
            "docs(CT-1): run %d log" % claimed["id"],
            "feat: implement the scripted change (CT-1)",
            "chore(CT-1): claim run %d" % claimed["id"],
        ])
        self.assertEqual(git(self.repo, "rev-list", "--parents", "-1", "HEAD").count(" "), 2)
        self.assertEqual(
            (self.repo / "work" / "CT-1.txt").read_text(), "implemented by run %d\n" % claimed["id"],
        )
        ticket = (self.repo / ".orchestrator" / "CT-1.md").read_text()
        self.assertIn("status: done", ticket)
        self.assertIn("run_id: %d" % claimed["id"], ticket)
        # The worktree and its throwaway branch are gone after the merge.
        self.assertFalse((self.box.workspaces / claimed["workspace_path"].split("/")[-1]).exists())
        self.assertEqual(git(self.repo, "branch", "--list", "relay/ct-1"), "")
        self.assertEqual(git(self.repo, "status", "--porcelain"), "")

        worker = self.box.invocations(role="implementation", id="CT-1")[0]
        review = self.box.invocations(role="review", id="CT-1")[0]
        self.assertEqual(worker["cwd"], claimed["workspace_path"])
        self.assertEqual(review["cwd"], str(self.repo))
        self.box.assert_golden_json("runs/provider-argv.%s" % self.agent, {
            "implementation": worker["argv"], "review": review["argv"],
        })
        log = self.box.wait_for(
            lambda: self.box.rows("runs.db", "SELECT * FROM runs WHERE id = ?", claimed["id"]),
        )[0]
        self.assertEqual(log["state"], "Merged")

    def test_dispatch_context_reaches_the_worker_prompt(self):
        # The fake records only launch metadata; the log names the prompt digest.
        run = self.finish("CT-10", "Merged")
        inspection = self.assertStatus(self.box.get("/v1/runs/%d/review" % run["id"]), 200).json
        self.assertIs(inspection["review_needed"], False)
        self.assertEqual(inspection["ticket_status"], "done")
        self.assertIn("Run %d" % run["id"], inspection["ticket_run_log"])

    def test_dispatch_requires_ticket_id_and_repo_path(self):
        self.assertError(self.box.post("/v1/runs", {}), 400, "ticket_id is required")
        self.assertError(self.box.post("/v1/runs", {"ticket_id": "CT-1"}), 400, "repo_path is required")

    def test_dispatch_rejects_a_path_that_is_not_a_repository(self):
        self.assertError(
            self.box.post("/v1/runs", {"ticket_id": "CT-1", "repo_path": str(self.box.root / "nowhere")}),
            400, "is not a git repository",
        )

    def test_dispatch_rejects_an_unknown_ticket(self):
        self.assertError(self.dispatch("CT-404"), 400, "ticket CT-404 not found")

    def test_dispatch_without_worker_sizing_is_refused_and_recorded(self):
        self.assertError(
            self.dispatch("CT-20"), 400,
            "missing worker sizing metadata: worker_model, worker_effort, "
            "worker_sizing_rationale, worker_provider_notes",
        )
        refused = [
            run for run in self.box.get("/v1/runs").json["runs"] if run["ticket_id"] == "CT-20"
        ]
        self.assertEqual(len(refused), 1)
        self.assertEqual(refused[0]["state"], "Failed")
        self.assertEqual(refused[0]["exit_code"], -1)
        self.assertEqual(self.box.invocations(id="CT-20"), [])

    def test_malformed_json_body_is_a_400(self):
        response = self.box.request("POST", "/v1/runs", raw=b"{not json")
        self.assertError(response, 400)


class RunFailureTests(RunCase):
    def test_nonzero_worker_exit_fails_the_run(self):
        run = self.finish("CT-2", "Failed")
        self.assertEqual(run["exit_code"], 3)
        self.assertTrue(run["last_error"].startswith("exit=3; tail="), run["last_error"])
        self.assertEqual(self.box.invocations(role="review", id="CT-2"), [])

    def test_clean_exit_without_a_commit_fails_the_run(self):
        run = self.finish("CT-3", "Failed")
        self.assertEqual(run["exit_code"], 0)
        self.assertEqual(
            run["last_error"],
            "exit=0 but ticket incomplete: worker made no new commit; ticket status is 'backlog', "
            "expected 'done' or 'verification_blocked'; ticket run_id is None, expected %d; "
            "ticket run log does not mention run %d" % (run["id"], run["id"]),
        )

    def test_clean_exit_with_an_unfinished_ticket_fails_the_run(self):
        run = self.finish("CT-4", "Failed")
        self.assertEqual(
            run["last_error"],
            "exit=0 but ticket incomplete: ticket status is 'in_progress', expected 'done' or "
            "'verification_blocked'; ticket run log does not mention run %d" % run["id"],
        )


class ReviewTests(RunCase):
    def test_undecided_review_leaves_the_run_awaiting_review(self):
        run = self.finish("CT-5", "AwaitingReview")
        self.box.wait_for(
            lambda: self.box.run(run["id"])["last_error"], message="review worker exit recorded",
        )
        run = self.box.run(run["id"])
        self.assertEqual(run["last_error"], "review worker exited 0 without accepting or retrying run")

        inspection = self.assertStatus(self.box.get("/v1/runs/%d/review" % run["id"]), 200).json
        self.assertIs(inspection["review_needed"], True)
        self.assertEqual(inspection["ticket_status"], "done")
        self.assertEqual(
            inspection["branch_diff_name_status"], "M\t.orchestrator/CT-5.md\nA\twork/CT-5.txt",
        )
        self.assertEqual(
            [line.split(" ", 1)[1] for line in inspection["branch_commits"].splitlines()],
            ["docs(CT-5): run %d log" % run["id"], "feat: implement the scripted change (CT-5)",
             "chore(CT-5): claim run %d" % run["id"]],
        )
        self.assertEqual(sorted(inspection), [
            "branch_commits", "branch_diff_name_status", "branch_diff_stat", "log_tail",
            "review_needed", "run", "ticket_run_log", "ticket_status", "verification_evidence",
        ])

        # A second review worker can be requested explicitly.
        again = self.assertStatus(
            self.box.post("/v1/runs/%d/review" % run["id"], {"context": "Look again."}), 202,
        ).json
        self.assertIs(again["review_dispatched"], True)
        self.box.wait_for(
            lambda: len(self.box.invocations(role="review", id="CT-5")) >= 2,
            message="second review worker",
        )

        self.assertError(
            self.box.post("/v1/runs/%d/review/decision" % run["id"], {"decision": "maybe"}),
            400, "decision must be 'accept' or 'retry'",
        )
        accepted = self.assertStatus(
            self.box.post("/v1/runs/%d/review/decision" % run["id"], {"decision": "accept"}), 200,
        ).json
        self.assertIs(accepted["accepted"], True)
        self.assertEqual(accepted["run"]["state"], "Merged")
        self.assertIs(accepted["worktree_removed"], True)
        self.assertEqual(accepted["promoted"], [])
        self.box.assert_golden_json("runs/review-accept.response", accepted)
        self.assertError(
            self.box.post("/v1/runs/%d/review/decision" % run["id"], {"decision": "accept"}),
            400, "is not awaiting review",
        )
        self.assertError(
            self.box.post("/v1/runs/%d/review" % run["id"], {}), 400, "is not awaiting review",
        )

    def test_retry_decision_fails_the_run_with_the_reviewer_reason(self):
        run = self.finish("CT-6", "Failed")
        self.assertEqual(run["last_error"], "Review requested retry: Needs another pass.")
        posted = self.box.invocations(event="decision-posted", ticket_id="CT-6")[0]
        self.assertEqual(posted["status"], 202)
        self.assertEqual(git(self.repo, "branch", "--list", "relay/ct-6"), "")
        ticket = (self.repo / ".orchestrator" / "CT-6.md").read_text()
        self.assertIn("status: backlog", ticket)

    def test_review_routes_reject_an_unknown_run(self):
        self.assertError(self.box.get("/v1/runs/9999/review"), 400, "unknown run_id 9999")
        self.assertError(self.box.post("/v1/runs/9999/review", {}), 400, "unknown run_id 9999")
        self.assertError(
            self.box.post("/v1/runs/9999/review/decision", {"decision": "accept"}), 400,
            "unknown run_id 9999",
        )


class VerificationBlockedTests(RunCase):
    def test_blocked_run_is_merged_but_held_until_resumed(self):
        run = self.finish("CT-7", "VerificationBlocked")
        self.assertEqual(
            run["last_error"],
            "verification blocked: The staging device is unavailable.; "
            "resume: Retry once the staging device is online.",
        )
        ticket = (self.repo / ".orchestrator" / "CT-7.md").read_text()
        self.assertIn("status: verification_blocked", ticket)
        self.assertTrue((self.repo / "work" / "CT-7.txt").exists())

        self.assertError(self.dispatch("CT-7"), 400, "is verification blocked")
        self.assertError(
            self.box.post("/v1/runs/%d/resume-verification" % run["id"], {}), 400, "reason is required",
        )
        resumed = self.assertStatus(self.box.post(
            "/v1/runs/%d/resume-verification" % run["id"],
            {"reason": "The device is back online.", "redispatch": False},
        ), 200).json
        self.assertIs(resumed["resumed"], True)
        self.assertIsNone(resumed["redispatched"])
        self.assertEqual(resumed["reason"], "The device is back online.")
        self.assertEqual(resumed["resume_commit"], git(self.repo, "rev-parse", "HEAD"))
        self.assertEqual(resumed["previous_run"]["id"], run["id"])
        self.box.assert_golden_json("runs/resume-verification.response", resumed)
        ticket = (self.repo / ".orchestrator" / "CT-7.md").read_text()
        self.assertIn("status: ready", ticket)
        # A legacy board records the resume in the run log and clears the run;
        # `verification_resumed_run_id` is an artifact-board field.
        self.assertIn("run_id: null", ticket)
        self.assertIn(
            "- **Verification resumed after run %d** \u2014 The device is back online.\n" % run["id"],
            ticket,
        )
        self.assertNotIn("verification_resumed_run_id", ticket)

    def test_resume_rejects_a_run_that_is_not_blocked(self):
        run = self.finish("CT-11", "Merged")
        self.assertError(
            self.box.post("/v1/runs/%d/resume-verification" % run["id"], {"reason": "x"}), 400,
            "is not verification blocked",
        )


class CancelTests(RunCase):
    def test_cancel_stops_the_worker_and_removes_the_worktree(self):
        response = self.assertStatus(self.dispatch("CT-8"), 202)
        run_id = response.json["run"]["id"]
        self.box.wait_for(lambda: self.box.invocations(role="implementation", id="CT-8"))
        running = self.box.wait_for_run(run_id, "Running")

        again = self.assertStatus(self.dispatch("CT-8"), 200).json
        self.assertIs(again["already_active"], True)
        self.assertEqual(again["run"]["id"], run_id)

        canceled = self.assertStatus(self.box.post("/v1/runs/%d/cancel" % run_id, {}), 200).json
        self.assertIs(canceled["canceled"], True)
        self.assertIs(canceled["worktree_removed"], True)
        self.assertEqual(canceled["run"]["state"], "Canceled")
        self.assertEqual(canceled["run"]["exit_code"], -15)
        self.box.assert_golden_json("runs/cancel.response", canceled)
        self.assertFalse((self.box.workspaces / running["workspace_path"].split("/")[-1]).exists())

        repeat = self.assertStatus(self.box.post("/v1/runs/%d/cancel" % run_id, {}), 200).json
        self.assertIs(repeat["canceled"], False)
        self.assertEqual(repeat["reason"], "run is in terminal state Canceled")

    def test_cancel_can_keep_the_worktree(self):
        response = self.assertStatus(self.dispatch("CT-9"), 202)
        run_id = response.json["run"]["id"]
        running = self.box.wait_for_run(run_id, "Running")
        canceled = self.assertStatus(
            self.box.post("/v1/runs/%d/cancel" % run_id, {"prune_worktree": False}), 200,
        ).json
        self.assertIs(canceled["canceled"], True)
        # Without pruning the response carries no worktree result at all.
        self.assertNotIn("worktree_removed", canceled)
        self.assertTrue((self.box.workspaces / running["workspace_path"].split("/")[-1]).is_dir())

    def test_cancel_rejects_an_unknown_run(self):
        self.assertError(self.box.post("/v1/runs/9999/cancel", {}), 400, "unknown run_id 9999")


class RunQueryTests(RunCase):
    def test_unknown_run_is_a_404_with_a_null_run(self):
        response = self.assertStatus(self.box.get("/v1/runs/9999"), 404)
        self.assertEqual(response.json, {"run": None})

    def test_run_id_that_is_not_a_number_is_a_400(self):
        self.assertError(self.box.get("/v1/runs/abc"), 400, "invalid literal for int()")
        self.assertError(self.box.get("/v1/runs", limit="many"), 400, "invalid literal for int()")

    def test_list_filters_by_state_and_limit(self):
        first = self.finish("CT-12", "Merged")
        second = self.finish("CT-13", "Merged")
        merged = self.assertStatus(self.box.get("/v1/runs", state="Merged"), 200).json["runs"]
        self.assertTrue(all(run["state"] == "Merged" for run in merged))
        # Newest first.
        ids = [run["id"] for run in merged]
        self.assertEqual(ids, sorted(ids, reverse=True))
        self.assertLess(ids.index(second["id"]), ids.index(first["id"]))
        limited = self.assertStatus(self.box.get("/v1/runs", limit=1), 200).json["runs"]
        self.assertEqual(len(limited), 1)

    def test_outcome_routes_reject_a_legacy_run(self):
        run = self.finish("CT-14", "Merged")
        self.assertError(
            self.box.get("/v1/runs/%d/outcome" % run["id"]), 400, "uses the legacy ticket lifecycle",
        )
        self.assertError(
            self.box.post("/v1/runs/%d/outcome" % run["id"], {"status": "completed"}), 400,
            "is not accepting a worker outcome",
        )


class PreservedRunTests(RunCase):
    def test_reconcile_restores_the_run_row_from_the_committed_ticket(self):
        self.assertEqual(self.box.get("/v1/runs/77").status, 404)
        body = {"repo_path": str(self.repo), "ticket_id": "CT-21"}
        restored = self.assertStatus(self.box.post("/v1/runs/reconcile-preserved", body), 200).json
        self.assertIs(restored["reconciled"], True)
        self.assertEqual(restored["source"], "canonical-ticket")
        self.assertEqual(restored["run"]["id"], 77)
        self.assertEqual(restored["run"]["state"], "Merged")
        self.assertEqual(restored["run"]["branch"], "preserved/ct-21")
        self.box.assert_golden_json("runs/reconcile-preserved.response", restored)

        again = self.assertStatus(self.box.post("/v1/runs/reconcile-preserved", body), 200).json
        self.assertIs(again["reconciled"], False)
        self.assertEqual(again["source"], "existing-ledger")
        self.assertEqual(again["run"], restored["run"])

        self.assertError(
            self.box.post("/v1/runs/recover-preserved-collision", body), 400,
            "run 77 does not represent a different-ticket collision",
        )

    def test_reconcile_rejects_a_ticket_that_is_not_finished(self):
        self.assertError(
            self.box.post("/v1/runs/reconcile-preserved",
                          {"repo_path": str(self.repo), "ticket_id": "CT-15"}),
            400, "only committed done or verification_blocked tickets can restore preserved runs",
        )

    def test_preserved_routes_require_a_ticket_and_repository(self):
        for route in ("/v1/runs/reconcile-preserved", "/v1/runs/recover-preserved-collision"):
            self.assertError(self.box.post(route, {}), 400, "is required")


class CodexDispatchTests(DaemonCase):
    """The same lifecycle with Codex as the worker provider."""

    agent = "codex"

    @classmethod
    def prepare(cls):
        cls.repo = cls.box.make_repo("codex", next_id=5)
        cls.box.write_ticket(cls.repo, "CT-1")

    def test_codex_run_is_reviewed_and_merged(self):
        response = self.assertStatus(
            self.box.post("/v1/runs", {"ticket_id": "CT-1", "repo_path": str(self.repo)}), 202,
        )
        claimed = response.json["run"]
        self.assertEqual(claimed["provider_key"], "codex")
        merged = self.box.wait_for_run(claimed["id"], "Merged")
        self.assertEqual(merged["exit_code"], 0)
        worker = self.box.invocations(role="implementation", id="CT-1")[0]
        review = self.box.invocations(role="review", id="CT-1")[0]
        self.assertEqual(worker["provider"], "codex")
        self.box.assert_golden_json("runs/provider-argv.codex", {
            "implementation": worker["argv"], "review": review["argv"],
        })


if __name__ == "__main__":
    unittest.main()
