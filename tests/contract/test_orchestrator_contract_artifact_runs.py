"""Runs on an artifact board, spikes, the ready sweep, queue drains and runs.json.

An artifact-board worker commits source only and posts one outcome; the
daemon records the claim and the reviewed outcome as commits on
refs/heads/relay/artifacts, merges the source, and dispatches dependents.
Each golden-bearing case owns its daemon so run ids are fixed.
"""

from __future__ import annotations

import unittest

from orchestrator_contract_support import ARTIFACT_REF, DaemonCase, git

RUNS_JSON_KEYS = sorted([
    "activity", "activity_at", "attempt", "branch", "ended_at", "execution_mode",
    "last_error", "model_alias", "provider_key", "repo_path", "run_id", "started_at", "state",
    "ticket_id", "workspace_path", "worker_effort", "worker_model", "worker_provider_notes",
    "worker_sizing_rationale",
])


def artifact_commit(repo, subject: str) -> str:
    """The artifact-ref commit with exactly this subject."""
    lines = git(repo, "log", "--format=%H %s", ARTIFACT_REF).splitlines()
    matches = [line.split(" ", 1)[0] for line in lines if line.split(" ", 1)[1] == subject]
    if len(matches) != 1:
        raise AssertionError("expected one artifact commit %r, found %d" % (subject, len(matches)))
    return matches[0]


class ArtifactCase(DaemonCase):
    def dispatch(self, ticket_id: str, repo=None, **extra):
        repo = repo or self.repo
        body = {"ticket_id": ticket_id, "repo_path": str(repo),
                "project_scope_token": self.box.scope_token(repo)}
        body.update(extra)
        return self.box.post("/v1/runs", body)

    def runs_for(self, ticket_id: str) -> list:
        return [run for run in self.box.get("/v1/runs").json["runs"] if run["ticket_id"] == ticket_id]


class ArtifactImplementationTests(ArtifactCase):
    @classmethod
    def prepare(cls):
        cls.repo = cls.box.artifact_project("flow", tickets=[
            ("CT-1", {}),
            ("CT-2", {"depends_on": ["CT-1"]}),
        ], next_id=3)

    def test_outcome_review_merge_and_dependency_progression(self):
        response = self.assertStatus(self.dispatch("CT-1"), 202)
        claimed = response.json["run"]
        self.box.assert_golden_json("artifact-runs/dispatch.response", response.json)
        merged = self.box.wait_for_run(claimed["id"], "Merged")
        self.assertIsNone(merged["last_error"])

        # The finished predecessor moves its dependent to ready and dispatches it.
        dependent = self.box.wait_for(lambda: self.runs_for("CT-2"), message="CT-2 dispatched")[0]
        self.box.wait_for_run(dependent["id"], "Merged")
        self.assertIn(
            "dispatch claimed CT-2 from dependency-progression: run %d" % dependent["id"],
            self.box.stderr(),
        )

        subjects = git(self.repo, "log", "--format=%s", ARTIFACT_REF).splitlines()
        self.assertEqual(subjects[:4], [
            "Publish reviewed outcome for CT-2 run %d" % dependent["id"],
            "Claim CT-2 for run %d" % dependent["id"],
            "Publish reviewed outcome for CT-1 run %d" % claimed["id"],
            "Claim CT-1 for run %d" % claimed["id"],
        ])
        for name, subject in (
            ("1-claim", "Claim CT-1 for run %d" % claimed["id"]),
            ("2-publish", "Publish reviewed outcome for CT-1 run %d" % claimed["id"]),
            ("3-dependent-publish", "Publish reviewed outcome for CT-2 run %d" % dependent["id"]),
        ):
            self.box.assert_golden_commit(
                "artifact-runs/%s" % name, self.repo, artifact_commit(self.repo, subject),
            )

        # Source history: the worker commit and the daemon merge, never a ticket file.
        self.assertEqual(git(self.repo, "log", "--format=%s", "-4", "main").splitlines(), [
            "merge CT-2 worker run %d" % dependent["id"],
            "feat: implement the scripted change (CT-2)",
            "merge CT-1 worker run %d" % claimed["id"],
            "feat: implement the scripted change (CT-1)",
        ])
        base = git(self.repo, "log", "--format=%H", "-1", "--grep",
                   "^Stop tracking Relay artifact materialization$", "main")
        touched = git(self.repo, "log", "--no-merges", "--format=", "--name-only", base + "..HEAD")
        self.assertEqual(sorted(touched.split()), ["work/CT-1.txt", "work/CT-2.txt"])
        for ticket_id in ("CT-1", "CT-2"):
            projected = (self.repo / ".orchestrator" / ("%s.md" % ticket_id)).read_text()
            self.assertIn("\nstatus: done\n", projected)
        self.assertEqual(git(self.repo, "status", "--porcelain", "--untracked-files=all"), "")

        recorded = self.assertStatus(self.box.get("/v1/runs/%d/outcome" % claimed["id"]), 200).json
        self.box.assert_golden_json("artifact-runs/outcome.response", recorded)
        posted = self.box.invocations(event="outcome-posted", run_id=claimed["id"])[0]
        self.assertEqual(posted["status"], 202)

        # The worker prompt names the sandbox port file, not /tmp.
        worker = self.box.invocations(role="artifact-implementation", id="CT-1")[0]
        self.assertEqual(worker["cwd"], claimed["workspace_path"])


class ArtifactDispatchErrorTests(ArtifactCase):
    @classmethod
    def prepare(cls):
        cls.repo = cls.box.artifact_project("errors", tickets=[("CT-1", {}), ("CT-2", {})], next_id=3)
        cls.box.plan("artifact-implementation", "CT-2", payload={"source_commit": "0" * 40})

    def test_dispatch_without_a_scope_token_is_refused(self):
        response = self.box.post("/v1/runs", {"ticket_id": "CT-1", "repo_path": str(self.repo)})
        self.assertError(
            response, 422, "artifact lifecycle dispatch requires a confirmed project scope token",
        )

    def test_an_outcome_naming_another_commit_fails_the_run_at_exit(self):
        run = self.assertStatus(self.dispatch("CT-2"), 202).json["run"]
        # The outcome is recorded as posted; the check against the worker's
        # HEAD happens when the worker exits.
        posted = self.box.wait_for(
            lambda: self.box.invocations(event="outcome-posted", run_id=run["id"]),
            message="outcome posted",
        )[0]
        self.assertEqual(posted["status"], 202, posted)
        failed = self.box.wait_for_run(run["id"], "Failed")
        self.assertEqual(
            failed["last_error"],
            "exit=0 but ticket incomplete: structured outcome source_commit does not match worker HEAD",
        )
        self.assertEqual(self.box.invocations(role="review", id="CT-2"), [])
        self.box.wait_for(
            lambda: "Record failed for CT-2 run %d" % run["id"]
            in git(self.repo, "log", "--format=%s", ARTIFACT_REF),
            message="failure published",
        )
        # The failure returns the ticket to backlog with a run-log entry.
        canonical = git(self.repo, "show", "%s:.orchestrator/CT-2.md" % ARTIFACT_REF)
        for line in ("status: backlog", "run_id: null", "run_state: failed"):
            self.assertIn("\n%s\n" % line, canonical)
        self.assertIn(
            "- **Run %d** \u2014 failed: exit=0 but ticket incomplete: structured outcome "
            "source_commit does not match worker HEAD" % run["id"], canonical,
        )
        # The working-tree projection catches up with the ref.
        self.box.wait_for(
            lambda: (self.repo / ".orchestrator" / "CT-2.md").read_text() == canonical + "\n"
            or (self.repo / ".orchestrator" / "CT-2.md").read_text() == canonical,
            message="projection refreshed",
        )


class SpikeTests(ArtifactCase):
    @classmethod
    def prepare(cls):
        cls.repo = cls.box.artifact_project("spike", tickets=[
            ("CT-1", {"execution_mode": "spike"}),
            ("CT-2", {"depends_on": ["CT-1"]}),
        ], next_id=3)

    def test_spike_result_is_recorded_without_review_or_progression(self):
        run = self.assertStatus(self.dispatch("CT-1"), 202).json["run"]
        self.assertEqual(run["execution_mode"], "spike")
        finished = self.box.wait_for_run(run["id"], "SpikeCompleted")
        self.assertFalse(finished["last_error"])
        self.box.assert_golden_commit(
            "artifact-runs/spike-report", self.repo,
            artifact_commit(self.repo, "Record spike findings for CT-1 run %d" % run["id"]),
        )
        ticket = (self.repo / ".orchestrator" / "CT-1.md").read_text()
        self.assertIn("\nstatus: done\n", ticket)
        self.assertIn("\n## Spike report\n", ticket)
        # Read-only: no review worker, no source commit, no promoted dependent.
        self.assertEqual(self.box.invocations(role="review"), [])
        self.assertEqual(git(self.repo, "log", "--format=%s", "-1", "main"),
                         "Stop tracking Relay artifact materialization")
        self.assertIn("\nstatus: backlog\n", (self.repo / ".orchestrator" / "CT-2.md").read_text())
        self.assertEqual(self.runs_for("CT-2"), [])


class ReadySweepTests(DaemonCase):
    """A legacy board, so the sweep needs no scope token."""

    @classmethod
    def prepare(cls):
        cls.repo = cls.box.make_repo("sweep")
        cls.box.write_ticket(cls.repo, "CT-1", status="ready")
        cls.box.write_ticket(cls.repo, "CT-2", status="ready", depends_on=["CT-1"])
        cls.box.write_ticket(cls.repo, "CT-3", status="backlog")
        cls.box.plan("implementation", "CT-1", hold=str(cls.box.hold("ct1")))
        cls.other = cls.box.make_repo("drain")
        cls.box.write_ticket(cls.other, "CT-9", status="ready")
        cls.box.plan("implementation", "CT-9", hold=str(cls.box.hold("never")))

    def test_queued_dispatch_then_sweep_then_drain_completion(self):
        queued = self.assertStatus(
            self.box.post("/v1/runs", {"ticket_id": "CT-2", "repo_path": str(self.repo)}), 202,
        ).json
        self.assertEqual(queued, {
            "queued": True, "already_active": False, "run": None, "waiting_on": ["CT-1"],
        })

        sweep = self.assertStatus(
            self.box.post("/v1/ready-sweep", {"repo_path": str(self.repo), "trigger": "contract"}), 200,
        ).json
        self.assertEqual(sweep["trigger"], "contract")
        self.assertEqual(sweep["promoted"], [])
        self.assertEqual([item["ticket_id"] for item in sweep["dispatched"]], ["CT-1"])
        self.assertEqual(sweep["skipped"], [
            {"ticket_id": "CT-2", "reason": "dependencies_not_done"},
            {"ticket_id": "CT-3", "reason": "status:backlog"},
        ])
        drain = sweep["drain"]
        self.assertEqual(drain["state"], "active")
        self.assertEqual(
            {item["ticket_id"]: item["state"] for item in drain["items"]},
            {"CT-1": "active", "CT-2": "dependency_waiting"},
        )
        self.box.assert_golden_json("artifact-runs/ready-sweep.response", sweep)

        listed = self.box.get("/v1/queue-drains", repo_path=str(self.repo)).json["queue_drains"]
        self.assertEqual([item["id"] for item in listed], [drain["id"]])

        self.box.release(self.box.hold("ct1"))
        first = sweep["dispatched"][0]["run_id"]
        self.box.wait_for_run(first, "Merged")
        second = self.box.wait_for(
            lambda: [run for run in self.box.get("/v1/runs").json["runs"] if run["ticket_id"] == "CT-2"],
            message="CT-2 dispatched",
        )[0]
        self.box.wait_for_run(second["id"], "Merged")

        def completed():
            drains = self.box.get(
                "/v1/queue-drains", repo_path=str(self.repo), include_terminal=True,
            ).json["queue_drains"]
            return drains if drains and drains[0]["state"] == "completed" else None
        self.box.wait_for(completed, message="drain completed")
        # Backlog tickets are never swept.
        self.assertEqual(
            [run for run in self.box.get("/v1/runs").json["runs"] if run["ticket_id"] == "CT-3"], [],
        )

    def test_a_drain_can_be_canceled(self):
        sweep = self.assertStatus(
            self.box.post("/v1/ready-sweep", {"repo_path": str(self.other)}), 200,
        ).json
        drain_id = sweep["drain"]["id"]
        canceled = self.assertStatus(
            self.box.post("/v1/queue-drains/%s/cancel" % drain_id, {"reason": "contract"}), 200,
        ).json
        self.box.assert_golden_json("artifact-runs/drain-cancel.response", canceled)
        active = self.box.get("/v1/queue-drains", repo_path=str(self.other)).json["queue_drains"]
        self.assertEqual(active, [])
        for run in sweep["dispatched"]:
            self.box.post("/v1/runs/%d/cancel" % run["run_id"], {})

    def test_sweep_requires_a_repository(self):
        self.assertError(self.box.post("/v1/ready-sweep", {}), 400, "repo_path is required")

    def test_program_sweep_covers_only_registered_projects(self):
        result = self.assertStatus(self.box.post("/v1/program/ready-sweep", {"trigger": "t"}), 200).json
        self.assertEqual(result, {"trigger": "t", "projects": [], "dispatched": [], "skipped": []})


class RunsIndexTests(ArtifactCase):
    @classmethod
    def prepare(cls):
        cls.repo = cls.box.make_repo("index")
        cls.box.write_ticket(cls.repo, "CT-1")
        cls.box.write_ticket(cls.repo, "CT-2")
        cls.box.plan("implementation", "CT-2", hold=str(cls.box.hold("ct2")))

    def test_runs_json_mirrors_the_ledger_for_the_board(self):
        first = self.assertStatus(
            self.box.post("/v1/runs", {"ticket_id": "CT-1", "repo_path": str(self.repo)}), 202,
        ).json["run"]
        self.box.wait_for_run(first["id"], "Merged")
        second = self.assertStatus(
            self.box.post("/v1/runs", {"ticket_id": "CT-2", "repo_path": str(self.repo)}), 202,
        ).json["run"]
        self.box.wait_for_run(second["id"], "Running")

        def indexed():
            index = self.box.runs_index()
            states = {entry["run_id"]: entry["state"] for entry in index["runs"]}
            return index if states.get(second["id"]) == "Running" else None
        index = self.box.wait_for(indexed, message="runs.json shows the running run")
        self.assertEqual(sorted(index), ["runs"])
        self.assertEqual([entry["run_id"] for entry in index["runs"]], [second["id"], first["id"]])
        for entry in index["runs"]:
            self.assertEqual(sorted(entry), RUNS_JSON_KEYS)
            run = self.box.run(entry["run_id"])
            for key in RUNS_JSON_KEYS:
                if key not in {"run_id", "activity", "activity_at", "state"}:
                    self.assertEqual(entry[key], run[key], key)
        self.assertEqual(index["runs"][1]["state"], "Merged")
        self.assertIsNone(index["runs"][0]["ended_at"])
        # Written by rename: no temporary file is left behind.
        self.assertFalse((self.box.data_root / "runs.json.tmp").exists())
        self.box.release(self.box.hold("ct2"))
        self.box.wait_for_run(second["id"], "Merged")
        self.box.wait_for(
            lambda: [e for e in self.box.runs_index()["runs"]
                     if e["run_id"] == second["id"] and e["state"] == "Merged"],
            message="runs.json shows the merge",
        )


if __name__ == "__main__":
    unittest.main()
