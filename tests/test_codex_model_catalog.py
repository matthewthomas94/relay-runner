from __future__ import annotations

import json
import unittest

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parent.parent
SERVICES = ROOT / "services"
sys.path.insert(0, str(SERVICES))

from codex_model_catalog import (  # noqa: E402
    CodexModelResolutionError,
    codex_models_from_model_list,
    normalize_codex_family,
    resolve_codex_effort,
    resolve_codex_family,
)


CATALOGUE = {
    "data": [
        {
            "id": "gpt-5.7-sol",
            "model": "gpt-5.7-sol",
            "hidden": False,
            "defaultReasoningEffort": "low",
            "supportedReasoningEfforts": [
                {"reasoningEffort": "low"},
                {"reasoningEffort": "medium"},
                {"reasoningEffort": "high"},
                {"reasoningEffort": "xhigh"},
            ],
        },
        {
            "id": "gpt-6.0-sol",
            "model": "gpt-6.0-sol",
            "hidden": False,
            "defaultReasoningEffort": "medium",
            "supportedReasoningEfforts": [
                {"reasoningEffort": "low"},
                {"reasoningEffort": "medium"},
                {"reasoningEffort": "high"},
                {"reasoningEffort": "xhigh"},
            ],
        },
        {
            "id": "gpt-7.0-sol",
            "model": "gpt-7.0-sol",
            "hidden": False,
            "inputModalities": ["audio"],
            "defaultReasoningEffort": "low",
            "supportedReasoningEfforts": [
                {"reasoningEffort": "low"},
            ],
        },
        {
            "id": "gpt-9.0-luna",
            "model": "gpt-9.0-luna",
            "hidden": True,
            "defaultReasoningEffort": "low",
            "supportedReasoningEfforts": [
                {"reasoningEffort": "low"},
            ],
        },
    ],
}


class CodexModelCatalogTests(unittest.TestCase):
    def test_legacy_values_normalize_to_stable_families(self):
        self.assertEqual(normalize_codex_family("default"), "sol")
        self.assertEqual(normalize_codex_family("gpt-5.6-terra"), "terra")
        self.assertEqual(normalize_codex_family("gpt-5.5"), "sol")
        self.assertEqual(normalize_codex_family("haiku"), "sol")

    def test_resolves_highest_visible_semantic_version(self):
        models = codex_models_from_model_list(CATALOGUE)

        resolved = resolve_codex_family("sol", models)

        self.assertEqual(resolved.launch_model, "gpt-6.0-sol")
        self.assertEqual(resolve_codex_effort("default", resolved), "medium")

    def test_hidden_models_do_not_satisfy_family(self):
        models = codex_models_from_model_list(CATALOGUE)

        with self.assertRaisesRegex(CodexModelResolutionError, "luna"):
            resolve_codex_family("luna", models)

    def test_rejects_unadvertised_effort(self):
        models = codex_models_from_model_list(json.loads(json.dumps(CATALOGUE)))
        resolved = resolve_codex_family("sol", models)

        with self.assertRaisesRegex(CodexModelResolutionError, "ultra"):
            resolve_codex_effort("ultra", resolved)


if __name__ == "__main__":
    unittest.main()
