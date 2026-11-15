"""RR-494: the relay-artifacts crate's test driver as a Python object.

``RustArtifacts`` drives the crate through its test driver
(rust/relay-artifacts/examples/artifacts_driver.rs), one JSON line per call:
``call("<module>.<function>", **arguments)`` returns JSON-shaped results and
raises ``Refused`` with the error class and message where the crate refuses.
Bytes travel as hex. The Python implementation it was compared with until
RR-487 is gone; the contract suite uses this module to replay its goldens.

The driver is ``RELAY_ARTIFACTS_DRIVER`` when set, otherwise the debug build
that ``cargo test`` leaves in rust/target/debug/examples. Without either,
the cases that use it skip. It imports nothing from services/.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import threading
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
DEFAULT_DRIVER = REPO / "rust" / "target" / "debug" / "examples" / "artifacts_driver"
GOLDEN_DIR = REPO / "tests" / "contract" / "golden" / "orchestrator"

# The RR-485 golden commits, in commit order. A sequence whose first commit
# has a parent is replayed on a base that holds only its config.
GOLDEN_SEQUENCES = (
    ("board", ("1-bootstrap", "2-claim-next-id", "3-ticket-write", "4-attachment-write",
               "5-ticket-rewrite", "6-ticket-delete")),
    ("artifact-runs", ("1-claim", "2-publish", "3-dependent-publish")),
    ("artifact-runs", ("spike-report",)),
    ("notes", ("1-create", "2-metadata", "3-archive", "4-delete")),
)
_MIME = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
         ".gif": "image/gif", ".webp": "image/webp", ".pdf": "application/pdf"}
_PLACEHOLDER = re.compile(r"<(TIMESTAMP|DEVICE|(SHA256|OID|HEX32):(\d+))>")


class Refused(Exception):
    """The implementation refused the call, as Python would raise ``error``."""

    def __init__(self, error: str, message: str = "", answer: dict | None = None):
        super().__init__(f"{error}: {message}")
        self.error = error
        self.message = message
        # The driver's whole answer, with `recovery`, `report` or `code`.
        self.answer = answer or {}


def driver_command() -> list | None:
    configured = os.environ.get("RELAY_ARTIFACTS_DRIVER", "").strip()
    if configured:
        return shlex.split(configured)
    if os.access(DEFAULT_DRIVER, os.X_OK):
        return [str(DEFAULT_DRIVER)]
    return None


def git_dates(seconds: int = 1_780_000_000) -> dict:
    """Pinned commit dates, so both implementations can produce one commit id."""
    stamp = f"@{seconds} +0000"
    return {"GIT_AUTHOR_DATE": stamp, "GIT_COMMITTER_DATE": stamp}


# -- replaying the golden commits ---------------------------------------------


def concrete(text: str) -> str:
    """A golden text with its documented placeholders replaced by valid
    fixed values, so normalising it again gives back the golden text."""

    def value(match):
        kind, number = match.group(2), match.group(3)
        if match.group(1) == "TIMESTAMP":
            return "2026-08-04T05:00:00Z"
        if match.group(1) == "DEVICE":
            return "daemon-" + hashlib.sha256(b"device").hexdigest()[:24]
        digest = hashlib.sha256(("%s-%s" % (kind, number)).encode()).hexdigest()
        return digest[:{"SHA256": 64, "OID": 40, "HEX32": 32}[kind]]

    return _PLACEHOLDER.sub(value, text)


def _golden_blob(content: bytes) -> bytes:
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError:
        return content
    return content if "\x00" in text else concrete(text).encode("utf-8")


def golden_files(name: str) -> dict:
    """The files of golden commit `name`, placeholders made concrete."""
    tree = GOLDEN_DIR / name / "tree"
    return {
        str(path.relative_to(tree)): _golden_blob(path.read_bytes())
        for path in sorted(tree.rglob("*")) if path.is_file()
    }


def golden_commit(name: str) -> dict:
    """The golden `COMMIT.json`, with its message split into summary and trailers."""
    record = json.loads((GOLDEN_DIR / name / "COMMIT.json").read_text())
    summary, _, rest = concrete(record["message"]).partition("\n\n")
    record["summary"] = summary
    record["trailers"] = dict(line.split(": ", 1) for line in rest.splitlines() if line)
    return record


def _front_matter_value(content: bytes, key: str) -> str:
    for line in content.decode("utf-8").splitlines()[1:]:
        if line.strip() == "---":
            break
        name, _, value = line.partition(":")
        if name.strip() == key:
            return value.strip().strip('"')
    raise ValueError("no %s in front matter" % key)


def tree_operations(before: dict, after: dict, project_id: str) -> list:
    """The typed operations, as driver JSON, that turn tree `before` into `after`."""
    result = []
    deleted_tickets = set()
    removed = sorted(set(before) - set(after))
    for path in removed:
        parts = path.split("/")
        if parts[1] == "notes":
            result.append({"type": "NoteDelete", "note_id": Path(path).stem,
                           "artifact_id": _front_matter_value(before[path], "artifact_id")})
        elif len(parts) == 2:
            deleted_tickets.add(Path(path).stem)
            result.append({"type": "TicketDelete", "ticket_id": Path(path).stem})
    for path in removed:
        parts = path.split("/")
        if parts[1] == "attachments" and parts[2] not in deleted_tickets:
            result.append({"type": "AttachmentDelete", "ticket_id": parts[2], "filename": parts[3]})
    for path in sorted(after):
        content = after[path]
        if before.get(path) == content:
            continue
        parts = path.split("/")[1:]
        if parts == ["config.toml"]:
            result.append({"type": "ConfigWrite", "content": content.hex()})
        elif parts == ["archive-index.jsonl"]:
            result.append({"type": "ArchiveIndexWrite", "content": content.hex()})
        elif parts == ["note-index.jsonl"]:
            result.append({"type": "NoteIndexWrite", "content": content.hex()})
        elif parts[0] == "notes":
            result.append({"type": "NoteWrite", "note_id": Path(path).stem,
                           "artifact_id": _front_matter_value(content, "artifact_id"),
                           "project_id": project_id, "markdown": content.hex()})
        elif parts[0] == "attachments":
            result.append({"type": "AttachmentWrite", "ticket_id": parts[1], "filename": parts[2],
                           "mime_type": _MIME[Path(parts[2]).suffix.lower()],
                           "content": content.hex()})
        elif parts[0] == "program":
            result.append({"type": "ProgramEventWrite", "event_id": Path(path).stem,
                           "content": content.hex()})
        else:
            result.append({"type": "TicketWrite", "ticket_id": Path(path).stem,
                           "artifact_id": _front_matter_value(content, "artifact_id"),
                           "markdown": content.hex()})
    return result


def _bootstrap(call, repo: Path, files: dict, mutation: dict, project_id: str):
    """Publish `files` as the orphan root, then project it as the migration does."""
    for path, content in files.items():
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content)
    mutation = {**mutation, "operations": tree_operations({}, files, project_id)}
    result = call("store.bootstrap_legacy", mutation=mutation)
    shutil.rmtree(repo / ".orchestrator")
    call("store.recover")
    return result


def replay_golden(call, repo: Path, group: str, names, on_commit=None) -> list:
    """Rebuild golden commits `group/names` in `repo` through `call`, an
    implementation's ``call``, on an already opened store. ``on_commit(name,
    result)`` runs after each one; the write results are returned."""
    results = []
    previous = None
    for name in names:
        golden = "%s/%s" % (group, name)
        files = golden_files(golden)
        record = golden_commit(golden)
        trailers = record["trailers"]
        project_id = trailers["Relay-Project-ID"]
        mutation = {
            "event_id": trailers["Relay-Event-ID"],
            "actor_type": trailers["Relay-Actor-Type"],
            "device_id": trailers["Relay-Device-ID"],
            "summary": record["summary"],
        }
        if "Relay-Provider" in trailers:
            mutation["provider"] = trailers["Relay-Provider"]
        if record["parents"] == 0:
            result = _bootstrap(call, repo, files, mutation, project_id)
        else:
            if previous is None:
                previous = {".orchestrator/config.toml": files[".orchestrator/config.toml"]}
                _bootstrap(call, repo, previous, {
                    "event_id": "migration-bootstrap:" + "0" * 32,
                    "actor_type": "migration", "device_id": "migration-cli",
                    "summary": "Bootstrap reviewed legacy Relay artifacts",
                }, project_id)
            mutation["operations"] = tree_operations(previous, files, project_id)
            if not mutation["operations"]:
                raise AssertionError("%s changes nothing to replay" % golden)
            result = call("store.mutate", mutation=mutation)
        results.append(result)
        if on_commit is not None:
            on_commit(name, files, result)
        previous = files
    return results


class RustArtifacts:
    """The relay-artifacts crate, through its JSON-lines test driver."""

    name = "rust"

    def __init__(self, command: list, *, environment: dict | None = None):
        self._process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env={**os.environ, **(environment or {})},
        )
        self._lock = threading.Lock()

    def call(self, op: str, **arguments):
        request = json.dumps({"op": op, **arguments})
        with self._lock:
            self._process.stdin.write(request + "\n")
            self._process.stdin.flush()
            line = self._process.stdout.readline()
        if not line:
            raise RuntimeError(f"artifacts driver exited: {self._process.stderr.read()}")
        answer = json.loads(line)
        if not answer["ok"]:
            raise Refused(answer["error"], answer.get("message", ""), answer)
        return answer["result"]

    def close(self) -> None:
        if self._process.poll() is None:
            self._process.stdin.close()
            try:
                self._process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self._process.kill()
                self._process.wait()
        self._process.stdout.close()
        self._process.stderr.close()
