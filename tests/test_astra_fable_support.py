"""Model-only regressions: no provider processes or live voice transports."""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "services"))

import command_actions
import orchestrator
from codex_model_catalog import (
    CODEX_WORKER_TIER_FAMILIES, CodexModelResolutionError,
    codex_models_from_model_list, normalize_codex_family,
    resolve_codex_effort, resolve_codex_family,
)
from config import load_config
from messenger import (
    MessengerConfig, ClaudeMessengerBackend, CodexMessengerBackend,
    resolve_messenger_catalog_selection,
)

ASTRA = {
    "id": "gpt-6-astra", "hidden": False, "inputModalities": ["text", "image"],
    "defaultReasoningEffort": "medium",
    "supportedReasoningEfforts": ["low", "medium", "high", "xhigh", "max", "ultra"],
}


class AstraFableSupportTests(unittest.TestCase):
    def test_astra_resolves_exact_family_and_advertised_efforts(self):
        for selection in ("astra", "gpt-6-astra"):
            self.assertEqual(normalize_codex_family(selection), "astra")
            models = codex_models_from_model_list([ASTRA, {**ASTRA, "id": "gpt-7-astra", "hidden": True}])
            resolved = resolve_codex_family(selection, models)
            self.assertEqual(resolved.launch_model, "gpt-6-astra")
            self.assertEqual(resolve_codex_effort("default", resolved), "medium")
            self.assertEqual(resolve_codex_effort("ultra", resolved), "ultra")
            with self.assertRaises(CodexModelResolutionError):
                resolve_codex_effort("none", resolved)

    def test_missing_hidden_or_nontext_astra_never_falls_back_to_sol(self):
        sol = {**ASTRA, "id": "gpt-6-sol"}
        for entries in ([sol], [sol, {**ASTRA, "hidden": True}],
                        [sol, {**ASTRA, "inputModalities": ["audio"]}]):
            with self.assertRaisesRegex(CodexModelResolutionError, "astra"):
                resolve_codex_family("gpt-6-astra", codex_models_from_model_list(entries))
        self.assertEqual(CODEX_WORKER_TIER_FAMILIES, {"fast": "luna", "balanced": "terra", "strong": "sol"})

    def test_config_and_messenger_preserve_new_selections(self):
        for provider, model, effort in (("codex", "astra", "ultra"), ("claude", "claude-fable-5-1", "max")):
            with self.subTest(provider=provider), tempfile.TemporaryDirectory() as tmp:
                path = Path(tmp) / "config.toml"
                path.write_text(f'[general]\nprovider="{provider}"\nmodel="{model}"\n'
                                f'orchestrator_effort="{effort}"\nmessenger_model="{model}"\n'
                                f'messenger_effort="{effort}"\n')
                config = load_config(str(path))
                self.assertEqual(config["general"]["model"], model)
                self.assertEqual(config["general"]["orchestrator_effort"], effort)
                messenger = MessengerConfig.from_app_config(config, cwd=tmp)
                self.assertEqual((messenger.model, messenger.effort), (model, effort))
                self.assertEqual(command_actions._normalized_general_model(model, provider), model)
                self.assertIn(effort, command_actions._valid_general_efforts(provider, model))
                if provider == "codex":
                    with patch.dict(os.environ, {"RELAY_CODEX_MODEL_LIST_JSON": json.dumps([ASTRA])}):
                        messenger = resolve_messenger_catalog_selection(messenger)
                    self.assertEqual(CodexMessengerBackend(messenger).thread_start_params()["model"], "gpt-6-astra")
                else:
                    command = ClaudeMessengerBackend(messenger).spawn_command()
                    self.assertEqual(command[command.index("--model") + 1], model)
                    self.assertEqual(command[command.index("--effort") + 1], effort)
                    self.assertNotIn("ultra", command_actions._valid_general_efforts(provider, model))

    def test_concrete_astra_config_preserves_explicit_messenger_effort(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.toml"
            path.write_text('[general]\nprovider="codex"\nmodel="gpt-6-astra"\n'
                            'messenger_model="gpt-6-astra"\nmessenger_effort="ultra"\n')
            config = load_config(str(path))
            self.assertEqual(config["general"]["model"], "astra")
            self.assertEqual(config["general"]["messenger_model"], "astra")
            self.assertEqual(config["general"]["messenger_effort"], "ultra")

    def test_worker_selection_and_commands_preserve_models(self):
        for provider, model, effort in (("codex", "astra", "high"), ("codex", "astra", "max"),
                                        ("codex", "astra", "ultra"), ("claude", "claude-fable-5-1", "max")):
            with self.subTest(provider=provider):
                ticket = {"_raw_fields": {
                    "worker_model": f"{provider}:{model}", "worker_effort": effort,
                    "worker_sizing_rationale": "Model compatibility test.",
                    "worker_provider_notes": "Claude max is provider-specific; Codex uses advertised efforts.",
                }}
                sizing = orchestrator.resolve_worker_sizing(ticket, provider)
                self.assertEqual(sizing["model_alias"], model)
                with patch.dict(os.environ, {"RELAY_CODEX_MODEL_LIST_JSON": json.dumps([ASTRA])}):
                    command = orchestrator._agent_command(agent_kind=provider, agent_bin=provider, run=sizing)
                self.assertEqual(command[command.index("--model") + 1], "gpt-6-astra" if provider == "codex" else model)
                inherited = orchestrator.resolve_worker_sizing({}, provider, general={
                    "subagent_sizing_policy": "user_default", "model": model, "orchestrator_effort": effort,
                })
                self.assertEqual((inherited["model_alias"], inherited["worker_effort"]), (model, effort))
                with self.assertRaisesRegex(ValueError, "scoped"):
                    orchestrator.resolve_worker_sizing(ticket, "claude" if provider == "codex" else "codex")

    def test_worker_extended_efforts_remain_catalog_validated(self):
        for effort in ("max", "ultra"):
            with self.assertRaises(ValueError):
                orchestrator._validate_worker_effort(effort, worker_model="strong", agent_kind="codex", provider_notes="none")
            run = {"model_alias": "astra", "worker_effort": effort}
            limited = {**ASTRA, "supportedReasoningEfforts": ["low", "medium", "high"]}
            with patch.dict(os.environ, {"RELAY_CODEX_MODEL_LIST_JSON": json.dumps([limited])}):
                with self.assertRaisesRegex(RuntimeError, "does not advertise"):
                    orchestrator._agent_command(agent_kind="codex", agent_bin="codex", run=run)


if __name__ == "__main__":
    unittest.main()
