"""Update the selected coding harness before Relay launches a new session."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile


CODEX_INSTALLER = "https://chatgpt.com/codex/install.sh"


class HarnessUpdateError(RuntimeError):
    pass


def run(arguments, *, environment=None, timeout=180):
    """Bound downloads and kill the whole updater tree on timeout."""
    process = subprocess.Popen(
        [str(value) for value in arguments],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        env=environment,
        start_new_session=True,
    )
    try:
        output, _ = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.communicate()
        raise HarnessUpdateError("The harness update timed out. Check your connection and start the session again.")
    if process.returncode:
        # Installer output can contain shell configuration or credentials.
        raise HarnessUpdateError(
            f"The harness updater exited with status {process.returncode}. "
            "Check your connection and installation permissions, then start the session again."
        )
    return output.decode("utf-8", errors="replace").strip()


def version(binary):
    output = run([binary, "--version"], timeout=15)
    match = re.search(r"\b(\d+)\.(\d+)\.(\d+)([^\s]*)", output)
    if not match:
        raise HarnessUpdateError("The updated harness did not report a valid version.")
    # A stable build sorts after a prerelease of the same version.
    return tuple(int(value) for value in match.group(1, 2, 3)) + (not bool(match.group(4)),)


def package_manager(binary, provider):
    resolved = str(Path(binary).resolve())
    for directory, kind in (("Caskroom", "--cask"), ("Cellar", "--formula")):
        marker = f"/{directory}/"
        if marker in resolved:
            prefix, package_path = resolved.split(marker, 1)
            package = package_path.split("/", 1)[0]
            allowed = {"codex"} if provider == "codex" else {"claude-code", "claude-code@latest"}
            if package in allowed:
                return "brew", Path(prefix) / "bin/brew", kind, package
    package = "@openai/codex" if provider == "codex" else "@anthropic-ai/claude-code"
    marker = f"/lib/node_modules/{package}/"
    if marker in resolved:
        prefix = resolved.split(marker, 1)[0]
        npm = Path(prefix) / "bin/npm"
        if not npm.is_file():
            npm = shutil.which("npm")
        if npm:
            return "npm", npm, prefix, package
    return None


def update_harness(provider, command, *, root=None):
    root = root or Path.home() / "Library/Application Support/relay-runner/harnesses"
    root.mkdir(parents=True, exist_ok=True)
    with (root / f"{provider}.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise HarnessUpdateError("A harness update is already running. Wait for it to finish, then start the session again.")
        binary = shutil.which(command)
        manager = package_manager(binary, provider) if binary else None
        if manager:
            kind, executable, option, package = manager
            environment = dict(os.environ, NONINTERACTIVE="1", HOMEBREW_NO_INSTALL_CLEANUP="1")
            if kind == "brew":
                run([executable, "update"], environment=environment)
                run([executable, "upgrade", option, package], environment=environment)
                binary = str(Path(executable).parent / provider)
            else:
                environment["PATH"] = f"{option}/bin:{os.environ.get('PATH', '')}"
                run([executable, "install", "--global", "--prefix", option, f"{package}@latest"], environment=environment)
        elif provider == "claude":
            if not binary:
                raise HarnessUpdateError("Claude Code is not installed. Run setup before starting a session.")
            if os.environ.get("DISABLE_UPDATES") == "1":
                raise HarnessUpdateError("Claude Code updates are disabled by DISABLE_UPDATES. Enable updates before starting a session.")
            run([binary, "update"])
        else:
            bundled = binary and ".app/Contents/" in binary
            standalone = binary and "/packages/standalone/" in str(Path(binary).resolve())
            managed_bin = root / "codex/bin"
            if binary and not bundled and not standalone and Path(binary).parent != managed_bin:
                raise HarnessUpdateError(
                    "This custom Codex executable has no supported automatic updater. "
                    "Choose the default Codex command in Settings to use automatic updates."
                )
            previous_version = version(binary) if bundled else None
            managed_bin.mkdir(parents=True, exist_ok=True)
            # Keep the official installer from discovering another package
            # manager on PATH and rewriting the user's shell profile.
            if bundled and not os.path.lexists(managed_bin / "codex"):
                (managed_bin / "codex").symlink_to(binary)
            environment = dict(
                os.environ,
                CODEX_INSTALL_DIR=str(managed_bin),
                CODEX_NON_INTERACTIVE="true",
                CODEX_RELEASE="latest",
                CODEX_INSTALL_DAEMON_ONLY="0",
                CODEX_INSTALL_DEFER_SELECTION="0",
                PATH=f"{managed_bin}:{os.environ.get('PATH', '')}",
            )
            with tempfile.TemporaryDirectory(prefix="relay-codex-update-") as temporary:
                installer = Path(temporary) / "install.sh"
                run(["/usr/bin/curl", "--fail", "--silent", "--show-error", "--location",
                     "--connect-timeout", "10", "--max-time", "30", CODEX_INSTALLER, "--output", installer])
                run(["/bin/sh", installer], environment=environment)
            updated_binary = str(managed_bin / "codex")
            updated_version = version(updated_binary)
            # Desktop builds can lead the public standalone release. Never
            # replace a newer bundled harness with an older stable CLI.
            if previous_version is None or updated_version >= previous_version:
                binary = updated_binary
        version(binary)
        return binary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--provider", choices=("codex", "claude"), required=True)
    parser.add_argument("--command", required=True)
    args = parser.parse_args()
    try:
        binary = update_harness(args.provider, args.command)
    except (HarnessUpdateError, OSError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    print(json.dumps({"binary": binary}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
