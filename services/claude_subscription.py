"""Relay Runner's subscription-only launch gate for Claude Code.

Relay Runner sends model requests only through the user's own Claude.ai
subscription. Claude Code accepts several credentials and routes, and
`claude auth status` alone does not prove which one a launch will use: it
reports a subscription login even when ANTHROPIC_AUTH_TOKEN or a gateway
ANTHROPIC_BASE_URL would take over, and it cannot say which plan a
long-lived CLAUDE_CODE_OAUTH_TOKEN belongs to. So the decision combines the
effective child environment, Claude settings `env`/`apiKeyHelper`, and the
CLI's own status, and only a positive subscription result is ready.

Messages name variables and settings files, never credential values.
Stdlib only and Python 3.9 compatible: the foreground launcher may run this
before the Relay venv exists.
"""
from __future__ import annotations

from dataclasses import dataclass
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Callable, Iterable, Mapping, Optional, Sequence, Tuple

SUBSCRIPTION_TYPES = frozenset({"pro", "max", "team", "enterprise"})
FIRST_PARTY_BASE_URLS = frozenset({"https://api.anthropic.com", "https://api.anthropic.com/"})
# Variables that move Claude Code off the subscription login: API keys,
# bearer tokens for gateways, cloud-provider routing, and Anthropic (Console)
# profiles or federation, which rank above `/login`.
METERED_ENVIRONMENT = (
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_PROFILE",
    "ANTHROPIC_FEDERATION_RULE_ID",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "AWS_BEARER_TOKEN_BEDROCK",
    "ANTHROPIC_FOUNDRY_API_KEY",
)
STATUS_TIMEOUT = 15
SIGN_IN = "Run `claude auth login` and sign in with your Claude.ai subscription account."
THEN_SIGN_IN = "then run `claude auth login` and sign in with your Claude.ai subscription account."
MANAGED_SETTINGS = Path("/Library/Application Support/ClaudeCode/managed-settings.json")


@dataclass(frozen=True)
class ClaudeSubscriptionReadiness:
    state: str  # "verified", "blocked" or "unverified"
    reason: str
    message: str

    @property
    def ready(self) -> bool:
        return self.state == "verified"


def _verified() -> ClaudeSubscriptionReadiness:
    return ClaudeSubscriptionReadiness("verified", "subscription", "Claude is using your Claude subscription.")


def _blocked(reason: str, detail: str) -> ClaudeSubscriptionReadiness:
    return ClaudeSubscriptionReadiness(
        "blocked", reason, f"Relay Runner only uses your Claude subscription. {detail}")


def _unverified(reason: str, detail: str) -> ClaudeSubscriptionReadiness:
    return ClaudeSubscriptionReadiness(
        "unverified", reason,
        f"Relay Runner couldn't confirm Claude is using your Claude subscription. {detail}")


def _is_set(name: str, value: object) -> bool:
    text = str(value if value is not None else "").strip()
    if not text:
        return False
    if name.startswith("CLAUDE_CODE_USE_"):
        return text.lower() not in {"0", "false", "no", "off"}
    return True


def _metered_names(environment: Mapping[str, object]) -> list[str]:
    names = [name for name in METERED_ENVIRONMENT if _is_set(name, environment.get(name))]
    base_url = str(environment.get("ANTHROPIC_BASE_URL") or "").strip()
    if base_url and base_url not in FIRST_PARTY_BASE_URLS:
        names.append("ANTHROPIC_BASE_URL")
    return names


def evaluate(
    environment: Mapping[str, str],
    settings: Iterable[Tuple[str, Mapping[str, object]]],
    auth_status: Optional[Mapping[str, object]],
    active_profile: Optional[str] = None,
) -> ClaudeSubscriptionReadiness:
    """Decide readiness from the child environment, settings and CLI status.

    `settings` holds (label, parsed document) pairs for every Claude settings
    file that applies to the launch; `auth_status` is `claude auth status
    --json` run with that environment, or None when it could not be read;
    `active_profile` is the auth type of the active Anthropic profile, if any.
    """
    names = _metered_names(environment)
    if names:
        return _blocked("metered_environment", (
            f"{', '.join(names)} would route Claude away from your subscription. "
            "Remove it from your shell profile and the Relay Runner environment, then start again."))
    for label, document in settings:
        if document.get("apiKeyHelper"):
            return _blocked("api_key_helper", (
                f"apiKeyHelper in {label} would supply an API key. Remove it, then start again."))
        if str(document.get("forceLoginMethod") or "").lower() == "console":
            return _blocked("console_login", (
                f"forceLoginMethod in {label} requires Console (API) sign-in. Remove it, then start again."))
        env = document.get("env")
        names = _metered_names(env) if isinstance(env, Mapping) else []
        if names:
            return _blocked("metered_settings", (
                f"{', '.join(names)} in the env of {label} would route Claude away from your "
                "subscription. Remove it, then start again."))
    if active_profile == "oidc_federation":
        return _blocked("federation_profile", (
            "The active Anthropic profile uses workload identity federation, which Claude uses before "
            "your subscription login. Deactivate it, then start again."))
    if auth_status is None:
        return _unverified("status_unavailable", SIGN_IN)
    if not auth_status.get("loggedIn"):
        return _unverified("not_logged_in", SIGN_IN)
    method = str(auth_status.get("authMethod") or "")
    provider = str(auth_status.get("apiProvider") or "")
    if method == "third_party" or provider != "firstParty":
        return _blocked("third_party", (
            "Claude is configured for a cloud provider route. Remove that configuration, " + THEN_SIGN_IN))
    if auth_status.get("apiKeySource") or method in {"api_key", "api_key_helper"}:
        return _blocked("api_key", (
            "Claude would use an API key instead of your subscription login. Remove the key, " + THEN_SIGN_IN))
    subscription = str(auth_status.get("subscriptionType") or "").lower()
    if subscription in SUBSCRIPTION_TYPES and method in {"claude.ai", "oauth_token"}:
        return _verified()
    if method == "oauth_token":
        return _unverified("oauth_token_unverified", (
            "Claude is using a long-lived OAuth token (such as CLAUDE_CODE_OAUTH_TOKEN) and doesn't "
            "report which plan it belongs to. Unset it, " + THEN_SIGN_IN))
    if method == "claude.ai":
        return _blocked("no_subscription", (
            "The signed-in Claude account has no Pro, Max, Team or Enterprise subscription. " + SIGN_IN))
    return _unverified("unknown_route", SIGN_IN)


def settings_documents(
    cwd: str,
    environment: Mapping[str, str],
    *,
    home: Optional[str] = None,
    managed: Path = MANAGED_SETTINGS,
) -> list[Tuple[str, Mapping[str, object]]]:
    """Read every Claude settings file that can change the launch's route."""
    config_dir = environment.get("CLAUDE_CONFIG_DIR") or os.path.join(
        home or environment.get("HOME") or os.path.expanduser("~"), ".claude")
    project = Path(cwd) / ".claude"
    candidates = [
        (str(managed), managed),
        ("user settings", Path(config_dir) / "settings.json"),
        (str(project / "settings.json"), project / "settings.json"),
        (str(project / "settings.local.json"), project / "settings.local.json"),
    ]
    documents = []
    for label, path in candidates:
        try:
            document = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        if isinstance(document, dict):
            documents.append((label, document))
    return documents


def active_profile_type(environment: Mapping[str, str], *, home: Optional[str] = None) -> Optional[str]:
    """Auth type of the active Anthropic profile (`ant profile activate`)."""
    config_dir = Path(environment.get("ANTHROPIC_CONFIG_DIR") or os.path.join(
        home or environment.get("HOME") or os.path.expanduser("~"), ".config", "anthropic"))
    try:
        name = (config_dir / "active_config").read_text(encoding="utf-8").strip() or "default"
    except OSError:
        name = "default"
    try:
        document = json.loads((config_dir / "configs" / f"{name}.json").read_text(encoding="utf-8"))
        return str(document["authentication"]["type"])
    except (OSError, ValueError, KeyError, TypeError):
        return None


def auth_status(
    command: Sequence[str],
    environment: Mapping[str, str],
    cwd: str,
    *,
    run: Callable[..., subprocess.CompletedProcess] = subprocess.run,
) -> Optional[Mapping[str, object]]:
    try:
        result = run(
            [*command, "auth", "status", "--json"],
            cwd=cwd, env=dict(environment), stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=STATUS_TIMEOUT,
        )
        status = json.loads(result.stdout or "")
    except (OSError, subprocess.SubprocessError, ValueError):
        return None
    return status if isinstance(status, dict) else None


def check(
    command: Sequence[str],
    *,
    cwd: str,
    environment: Optional[Mapping[str, str]] = None,
    run: Callable[..., subprocess.CompletedProcess] = subprocess.run,
) -> ClaudeSubscriptionReadiness:
    """Check a Relay-owned Claude launch before it starts."""
    env = dict(os.environ if environment is None else environment)
    return evaluate(env, settings_documents(cwd, env), auth_status(command, env, cwd, run=run),
                    active_profile_type(env))


def main(argv: Optional[Sequence[str]] = None) -> int:
    import argparse
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--binary", default="claude")
    parser.add_argument("--cwd", default=os.getcwd())
    args = parser.parse_args(argv)
    readiness = check([args.binary], cwd=args.cwd)
    if readiness.ready:
        return 0
    print(f"[Relay Runner] {readiness.message}", file=sys.stderr)
    return 78


if __name__ == "__main__":
    sys.exit(main())
