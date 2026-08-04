import hashlib
import json
import tempfile
import unittest
from datetime import UTC, datetime
from pathlib import Path

from services.artifact_rollout import (
    LEGACY_MIGRATION_OFFER,
    LEGACY_REQUIRED_EVIDENCE,
    NEW_PROJECT_DEFAULT,
    NEW_PROJECT_REQUIRED_EVIDENCE,
    ArtifactRolloutBlocked,
    ArtifactRolloutError,
    ArtifactRolloutStore,
    RolloutEvidence,
    privacy_safe_report_digest,
)


class ArtifactRolloutTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="relay-rollout-tests-")
        self.root = Path(self.temporary.name)
        self.store = ArtifactRolloutStore(
            self.root,
            now=lambda: datetime(2026, 8, 5, 0, 0, tzinfo=UTC),
        )

    def tearDown(self):
        self.temporary.cleanup()

    def test_every_project_defaults_off_and_explicit_opt_in_is_reversible_only_after_drain(self):
        existing = self.store.decision("project-a", project_kind="existing")
        new = self.store.decision("project-b", project_kind="new")
        legacy = self.store.decision("project-c", project_kind="legacy")
        self.assertFalse(existing.artifact_writes_enabled)
        self.assertFalse(new.artifact_writes_enabled)
        self.assertFalse(legacy.offer_legacy_migration)

        with self.assertRaisesRegex(ArtifactRolloutBlocked, "explicit confirmation"):
            self.store.set_project_opt_in("project-a", enabled=True, confirmed=False)
        enabled = self.store.set_project_opt_in("project-a", enabled=True, confirmed=True)
        self.assertTrue(enabled.artifact_writes_enabled)
        self.assertTrue(enabled.artifact_sync_enabled)
        self.assertFalse(self.store.decision("project-other", project_kind="existing").artifact_writes_enabled)

        with self.assertRaisesRegex(ArtifactRolloutBlocked, "drained writers"):
            self.store.set_project_opt_in("project-a", enabled=False, confirmed=True)
        disabled = self.store.set_project_opt_in(
            "project-a",
            enabled=False,
            confirmed=True,
            writers_drained=True,
            sync_frozen=True,
        )
        self.assertFalse(disabled.artifact_writes_enabled)
        self.assertEqual(self.store.diagnostics()["project_opt_in_count"], 0)

    def test_later_cohorts_never_auto_promote_and_require_accepted_external_evidence(self):
        self.store.set_project_opt_in("pilot", enabled=True, confirmed=True)
        for kind in sorted(NEW_PROJECT_REQUIRED_EVIDENCE):
            self.store.record_evidence(self.evidence(kind, outcome="accepted"))
        self.assertFalse(
            self.store.decision("new-one", project_kind="new").artifact_writes_enabled
        )
        self.assertFalse(
            self.store.decision("legacy-one", project_kind="legacy").offer_legacy_migration
        )

        promoted = self.store.promote_cohort(NEW_PROJECT_DEFAULT, confirmed=True)
        self.assertTrue(promoted["cohorts"][NEW_PROJECT_DEFAULT]["enabled"])
        self.assertTrue(
            self.store.decision("new-one", project_kind="new").artifact_writes_enabled
        )
        self.assertFalse(
            self.store.decision("existing-one", project_kind="existing").artifact_writes_enabled
        )
        with self.assertRaisesRegex(ArtifactRolloutBlocked, "missing accepted evidence"):
            self.store.promote_cohort(LEGACY_MIGRATION_OFFER, confirmed=True)

        for kind in sorted(LEGACY_REQUIRED_EVIDENCE - NEW_PROJECT_REQUIRED_EVIDENCE):
            self.store.record_evidence(self.evidence(kind, outcome="accepted"))
        self.assertFalse(
            self.store.decision("legacy-one", project_kind="legacy").offer_legacy_migration
        )
        self.store.promote_cohort(LEGACY_MIGRATION_OFFER, confirmed=True)
        legacy = self.store.decision("legacy-one", project_kind="legacy")
        self.assertTrue(legacy.offer_legacy_migration)
        self.assertFalse(legacy.artifact_writes_enabled)

    def test_rejected_latest_evidence_blocks_promotion_until_new_immutable_acceptance(self):
        for kind in sorted(NEW_PROJECT_REQUIRED_EVIDENCE):
            self.store.record_evidence(self.evidence(kind, outcome="accepted", suffix="first"))
        self.store.record_evidence(
            self.evidence("signed_installed_workspace", outcome="rejected", suffix="rejected")
        )
        with self.assertRaisesRegex(ArtifactRolloutBlocked, "signed_installed_workspace"):
            self.store.promote_cohort(NEW_PROJECT_DEFAULT, confirmed=True)
        self.store.record_evidence(
            self.evidence("signed_installed_workspace", outcome="accepted", suffix="reviewed")
        )
        self.store.promote_cohort(NEW_PROJECT_DEFAULT, confirmed=True)
        self.assertTrue(self.store.diagnostics()["cohorts"][NEW_PROJECT_DEFAULT]["enabled"])

    def test_independent_kill_switch_requires_drain_and_preserves_evidence_and_opt_ins(self):
        self.store.set_project_opt_in("pilot", enabled=True, confirmed=True)
        evidence = self.evidence("source_matrix", outcome="accepted")
        self.store.record_evidence(evidence)
        with self.assertRaisesRegex(ArtifactRolloutBlocked, "drained writers"):
            self.store.pause_cohort(
                "project_opt_in",
                writers_drained=False,
                sync_frozen=True,
                reason_code="cas_failure",
            )
        paused = self.store.pause_cohort(
            "project_opt_in",
            writers_drained=True,
            sync_frozen=True,
            reason_code="cas_failure",
        )
        self.assertTrue(paused["cohorts"]["project_opt_in"]["paused"])
        self.assertFalse(
            self.store.decision("pilot", project_kind="existing").artifact_writes_enabled
        )
        self.assertEqual(paused["project_opt_in_count"], 1)
        self.assertIn("source_matrix", paused["evidence"])
        self.store.resume_cohort("project_opt_in", confirmed=True)
        self.assertTrue(
            self.store.decision("pilot", project_kind="existing").artifact_writes_enabled
        )

    def test_corrupt_primary_uses_valid_backup_and_repair_does_not_overwrite_backup_with_corruption(self):
        self.store.set_project_opt_in("first", enabled=True, confirmed=True)
        self.store.set_project_opt_in("second", enabled=True, confirmed=True)
        self.assertTrue(self.store.backup_path.is_file())
        backup_before = self.store.backup_path.read_bytes()
        self.store.path.write_text("{not-json", encoding="utf-8")

        recovered = self.store.load()
        self.assertEqual(recovered["recovery_state"], "primary_corrupt_using_backup")
        self.store.set_project_opt_in("repair", enabled=True, confirmed=True)

        self.assertEqual(self.store.backup_path.read_bytes(), backup_before)
        self.assertEqual(self.store.load().get("recovery_state"), None)
        self.assertTrue(
            self.store.decision("repair", project_kind="existing").artifact_writes_enabled
        )

    def test_diagnostics_are_bounded_and_reject_raw_or_unknown_evidence_fields(self):
        self.store.set_project_opt_in("private-project-name", enabled=True, confirmed=True)
        diagnostics = self.store.diagnostics()
        serialized = json.dumps(diagnostics, sort_keys=True)
        self.assertNotIn("private-project-name", serialized)
        self.assertNotIn(str(self.root), serialized)
        self.assertNotIn("raw", serialized.lower())

        with self.assertRaisesRegex(ArtifactRolloutError, "prohibited diagnostic field"):
            privacy_safe_report_digest({"raw_log": "private output"})
        with self.assertRaisesRegex(ArtifactRolloutError, "unbounded string"):
            privacy_safe_report_digest({"summary": "x" * 5000})

        self.store.record_evidence(self.evidence("source_matrix", outcome="accepted"))
        document = json.loads(self.store.path.read_text(encoding="utf-8"))
        document["evidence"][0]["raw_transcript"] = "must never persist"
        self.store.path.write_text(json.dumps(document), encoding="utf-8")
        self.assertEqual(
            self.store.load()["recovery_state"],
            "primary_corrupt_using_backup",
        )
        self.store.backup_path.write_text(json.dumps(document), encoding="utf-8")
        with self.assertRaises(ArtifactRolloutBlocked):
            self.store.load()

    def test_installed_provider_evidence_requires_signed_identity_and_both_providers(self):
        invalid = self.evidence("installed_provider_parity", outcome="accepted")
        invalid = RolloutEvidence(**{**invalid.as_dict(), "providers": ("codex",)})
        with self.assertRaisesRegex(ArtifactRolloutError, "Codex and Claude"):
            self.store.record_evidence(invalid)
        valid = RolloutEvidence(**{**invalid.as_dict(), "providers": ("codex", "claude")})
        self.store.record_evidence(valid)
        self.assertEqual(
            self.store.diagnostics()["evidence"]["installed_provider_parity"]["providers"],
            ["claude", "codex"],
        )

    def evidence(self, kind: str, *, outcome: str, suffix: str = "one") -> RolloutEvidence:
        installed = kind in {"signed_installed_workspace", "installed_provider_parity"}
        return RolloutEvidence(
            evidence_id=f"{kind}:{suffix}",
            kind=kind,
            outcome=outcome,
            recorded_at="2026-08-05T00:00:00Z",
            report_sha256=hashlib.sha256(f"{kind}:{suffix}:{outcome}".encode()).hexdigest(),
            build_version="0.4.99" if installed else None,
            build_number="99" if installed else None,
            bundle_sha256=hashlib.sha256(b"bundle").hexdigest() if installed else None,
            signer_team_id="TEAM123" if installed else None,
            providers=("codex", "claude") if kind == "installed_provider_parity" else (),
            scenario_ids=("mounted_workspace",) if installed else (),
            rejection_code="installed_gate_failed" if outcome == "rejected" else None,
        )


if __name__ == "__main__":
    unittest.main()
