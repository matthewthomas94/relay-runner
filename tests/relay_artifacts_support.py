"""RR-494: one interface to the Python and Rust artifact store, ticket,
follow-up, config and catalog code, so the same scenarios run against both.

``PythonArtifacts`` calls services/artifact_store.py, tickets.py,
followup_tickets.py, config.py, artifact_catalog.py and note_contract.py
in-process. ``RustArtifacts`` drives the relay-artifacts crate through its
test driver (rust/relay-artifacts/examples/artifacts_driver.rs), one JSON
line per call. Both take ``call("<module>.<function>", **arguments)``, return
JSON-shaped results and raise ``Refused`` with the Python exception class and
message where the implementation refuses. Bytes travel as hex.

The driver is ``RELAY_ARTIFACTS_DRIVER`` when set, otherwise the debug build
that ``cargo test`` leaves in rust/target/debug/examples. Without either,
Rust cases skip. ``RustArtifacts`` alone imports nothing from services/, so
the contract suite can use it too.
"""

from __future__ import annotations

import datetime as _datetime
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import threading
import types
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


def _services():
    services = str(REPO / "services")
    if services not in sys.path:
        sys.path.insert(0, services)
    import artifact_catalog
    import artifact_store
    import config
    import followup_tickets
    import note_contract
    import tickets

    return types.SimpleNamespace(
        artifact_catalog=artifact_catalog,
        artifact_store=artifact_store,
        config=config,
        followup_tickets=followup_tickets,
        note_contract=note_contract,
        tickets=tickets,
    )


# The classes the crate reports; a Python subclass outside them reports its
# nearest listed ancestor (UnicodeDecodeError and JSONDecodeError are
# ValueError, FileNotFoundError is OSError).
_REPORTED_ERRORS = frozenset({
    "TicketParseError", "TOMLDecodeError", "NoteContractError", "CatalogSemanticError",
    "ArtifactStoreError", "ArtifactStoreDisabled", "ArtifactValidationError",
    "ArtifactIdentityError", "ArtifactConcurrentUpdate", "ArtifactEventCollision",
    "ArtifactMaterializationConflict", "ArtifactInjectedFailure",
    "ValueError", "TypeError", "AttributeError", "RuntimeError", "OverflowError", "OSError",
})


def _error_name(exc: BaseException) -> str:
    import sqlite3

    if isinstance(exc, sqlite3.Error):
        return "sqlite3.Error"
    for kind in type(exc).__mro__:
        if kind.__name__ in _REPORTED_ERRORS:
            return kind.__name__
    return type(exc).__name__


def _toml_jsonable(value):
    """A tomllib value as the driver writes it."""
    if isinstance(value, dict):
        return {key: _toml_jsonable(item) for key, item in value.items()}
    if isinstance(value, list):
        return [_toml_jsonable(item) for item in value]
    if isinstance(value, bool) or isinstance(value, (str, float)):
        return value
    if isinstance(value, int):
        if -(2**63) <= value < 2**63:
            return value
        return {"$bigint": str(value)}
    if isinstance(value, (_datetime.date, _datetime.time)):
        return {"$datetime": str(value)}
    raise TypeError(type(value).__name__)


def _ticket_jsonable(ticket: dict) -> dict:
    value = {key: item for key, item in ticket.items() if key != "_path"}
    if "_path" in ticket:
        value["_path"] = str(ticket["_path"])
    return value


class PythonArtifacts:
    """The Python modules, called in-process."""

    name = "python"

    def __init__(self, *, environment: dict | None = None):
        self.modules = _services()
        self.environment = dict(environment or {})
        self.store = None
        self.followups = None

    def call(self, op: str, **arguments):
        saved = {key: os.environ.get(key) for key in self.environment}
        os.environ.update(self.environment)
        try:
            return json.loads(json.dumps(self._call(op, arguments)))
        except Refused:
            raise
        except Exception as exc:  # noqa: BLE001 - every refusal is compared by class
            raise Refused(_error_name(exc), str(exc)) from exc
        finally:
            for key, value in saved.items():
                if value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = value

    def close(self) -> None:
        self.store = self.followups = None

    def _call(self, op: str, a: dict):
        module, _, function = op.partition(".")
        handler = getattr(self, "_" + module)
        return handler(function, a)

    # -- the artifact store ---------------------------------------------------

    def _operation(self, value: dict):
        store = self.modules.artifact_store
        kind = getattr(store, value["type"])
        fields = {}
        for field in kind.__dataclass_fields__:
            item = value[field]
            if field in {"markdown", "content"}:
                item = bytes.fromhex(item)
            fields[field] = item
        return kind(**fields)

    def _mutation(self, value: dict):
        store = self.modules.artifact_store
        options = {key: value[key] for key in ("expected_base", "provider", "summary") if key in value}
        return store.ArtifactMutation(
            event_id=value["event_id"],
            actor_type=value["actor_type"],
            device_id=value["device_id"],
            operations=tuple(self._operation(item) for item in value["operations"]),
            **options,
        )

    @staticmethod
    def _write(result) -> dict:
        return {
            "event_id": result.event_id,
            "commit_id": result.commit_id,
            "tree_id": result.tree_id,
            "base_commit": result.base_commit,
            "idempotent": result.idempotent,
            "warnings": list(result.warnings),
        }

    def _store(self, function: str, a: dict):
        module = self.modules.artifact_store
        if function == "open":
            fail_stage = a.get("fail_stage")

            def injector(stage: str) -> None:
                if stage == fail_stage:
                    raise module.ArtifactInjectedFailure(f"injected failure at {stage}")

            self.store = module.ArtifactStore(
                a["repo"], a["project_id"], a["state_root"],
                enabled=a.get("enabled", True),
                project_warning_bytes=a.get(
                    "project_warning_bytes", module.DEFAULT_PROJECT_WARNING_BYTES
                ),
                failure_injector=injector if fail_stage else None,
            )
            return None
        store = self.store
        if function == "initialize":
            return self._write(store.initialize(
                device_id=a["device_id"], actor_type=a.get("actor_type", "system")
            ))
        if function in {"mutate", "prepare_mutation", "bootstrap_legacy"}:
            return self._write(getattr(store, function)(self._mutation(a["mutation"])))
        if function == "recover":
            return store.recover()
        if function == "snapshot":
            snapshot = store.snapshot()
            return {
                "project_id": snapshot.project_id,
                "commit_id": snapshot.commit_id,
                "tree_id": snapshot.tree_id,
                "files": {path: content.hex() for path, content in snapshot.files.items()},
            }
        if function == "digest":
            return store._mutation_digest(self._mutation(a["mutation"]))
        raise KeyError(function)

    # -- tickets ----------------------------------------------------------------

    def _tickets(self, function: str, a: dict):
        tickets = self.modules.tickets
        if function == "parse":
            return _ticket_jsonable(tickets.parse(a["text"]))
        if function == "read":
            return _ticket_jsonable(tickets.read(Path(a["path"])))
        if function == "write":
            return tickets.write(Path(a["path"]), a["ticket"])
        if function == "scan_repo":
            return [_ticket_jsonable(ticket) for ticket in tickets.scan_repo(Path(a["repo"]))]
        if function == "all_deps_done":
            return tickets.all_deps_done(a["ticket"], a["all"])
        raise KeyError(function)

    # -- board config -------------------------------------------------------

    def _board(self, function: str, a: dict):
        import tempfile

        import orchestrator

        if function == "ticket_config":
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "config.toml"
                path.write_text(a["text"])
                prefix, next_id, _text = orchestrator._ticket_config(path)
            return [prefix, next_id]
        if function == "with_next_id":
            with tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "config.toml"
                orchestrator._write_ticket_config_next_id(path, a["text"], a["next_id"])
                return path.read_bytes().decode("utf-8")
        if function == "claim_next_id":
            # The daemon's own claim, against a store that returns the config
            # and records the mutation instead of committing it.
            content = bytes.fromhex(a["content"])
            recorded = []

            def mutate(mutation):
                recorded.append(mutation)
                return types.SimpleNamespace(commit_id="0" * 40, idempotent=False)

            store = types.SimpleNamespace(
                snapshot=lambda: types.SimpleNamespace(
                    commit_id="0" * 40, files={".orchestrator/config.toml": content}
                ),
                mutate=mutate,
            )
            daemon = types.SimpleNamespace(
                ARTIFACT_BOARD_WRITE_ATTEMPTS=1, _artifact_device_id="daemon-test"
            )
            claim = orchestrator.Daemon._claim_artifact_board_id(
                daemon, types.SimpleNamespace(store=store), "board-claim:test"
            )
            return {
                "prefix": claim["prefix"],
                "next_id": claim["id"],
                "config": recorded[0].operations[0].content.decode("utf-8"),
            }
        raise KeyError(function)

    # -- follow-up proposals ------------------------------------------------

    def _followup(self, function: str, a: dict):
        followup = self.modules.followup_tickets
        origin = a.get("origin_repo_path", "")
        if function == "sanitize":
            return followup.sanitize_followup_draft(a.get("draft"), origin_repo_path=origin)
        if function == "recommended_next_steps":
            return followup.recommended_next_steps(a["body"])
        if function == "automatic_drafts":
            return followup.automatic_followup_drafts(a["body"], origin_repo_path=origin)
        if function == "batch_id":
            return followup.batch_id(origin, a["origin_ticket_id"], a["origin_run_id"])
        if function == "proposal_id":
            return followup.proposal_id(a["batch"], a["position"])
        if function == "acceptance_key":
            return followup.acceptance_key(a["batch"], a["proposal"])
        if function == "open":
            self.followups = followup.FollowupProposalStore(Path(a["path"]))
            return None
        store = self.followups
        if function == "create_or_get":
            batch, created = store.create_or_get(
                origin_repo_path=origin,
                origin_ticket_id=a["origin_ticket_id"],
                origin_run_id=a["origin_run_id"],
                provider_key=a.get("provider_key"),
                drafts=a["drafts"],
            )
            return [batch, created]
        if function == "get":
            return store.get(a["batch"])
        if function == "update_draft":
            return store.update_draft(a["batch"], a["proposal"], a["draft"])
        if function == "set_result":
            return store.set_result(
                a["batch"], a["proposal"], state=a["state"],
                ticket_id=a.get("ticket_id"), error=a.get("error"),
            )
        if function == "set_error":
            return store.set_error(a["batch"], a["proposal"], a["error"])
        raise KeyError(function)

    # -- the rest -----------------------------------------------------------

    def _catalog(self, function: str, a: dict):
        catalog = self.modules.artifact_catalog
        if function == "validate":
            from artifact_retention import ACTIVITY_FIELDS

            return catalog.validate_catalog_ticket_metadata(
                a["entry"], bytes.fromhex(a["content"]),
                activity_fields=a.get("activity_fields", ACTIVITY_FIELDS),
            )
        raise KeyError(function)

    def _config(self, function: str, a: dict):
        if function == "load":
            return _toml_jsonable(self.modules.config.load_config(
                a["path"],
                macos_major=a.get("macos_major"),
                phonon_default_active=a.get("phonon_default_active", True),
            ))
        raise KeyError(function)

    def _toml(self, function: str, a: dict):
        import tomllib

        if function == "loads":
            return _toml_jsonable(tomllib.loads(a["text"]))
        if function == "loads_bytes":
            return _toml_jsonable(tomllib.loads(bytes.fromhex(a["content"]).decode("utf-8")))
        raise KeyError(function)

    def _isotime(self, function: str, a: dict):
        if function == "fromisoformat":
            parsed = _datetime.datetime.fromisoformat(a["text"])
            offset = parsed.utcoffset()
            utc_micros = None
            if offset is not None:
                instant = parsed.astimezone(_datetime.timezone.utc).replace(tzinfo=None)
                delta = instant - _datetime.datetime(1, 1, 1)
                utc_micros = (delta.days * 86_400 + delta.seconds) * 1_000_000 + delta.microseconds
            return {
                "year": parsed.year, "month": parsed.month, "day": parsed.day,
                "hour": parsed.hour, "minute": parsed.minute, "second": parsed.second,
                "microsecond": parsed.microsecond,
                "offset_us": None if offset is None else (
                    (offset.days * 86_400 + offset.seconds) * 1_000_000 + offset.microseconds
                ),
                "utc_micros": utc_micros,
            }
        raise KeyError(function)

    def _notes(self, function: str, a: dict):
        notes = self.modules.note_contract
        if function == "parse":
            return notes.parse_note_document(bytes.fromhex(a["content"])).as_dict()
        if function == "normalize":
            document = notes.parse_note_document(bytes.fromhex(a["content"]))
            return notes.render_note_document(document).hex()
        if function == "validate_metadata":
            return notes.validate_note_metadata(a.get("value"))
        if function == "decode_index":
            return notes.decode_note_index(bytes.fromhex(a["content"]), project_id=a["project_id"])
        if function == "validate_note_id":
            return list(notes.validate_note_id(a["value"]))
        raise KeyError(function)


def implementation(name: str, **options):
    """A fresh implementation by name; ``None`` for Rust without a driver."""
    if name == "python":
        return PythonArtifacts(**options)
    command = driver_command()
    return RustArtifacts(command, **options) if command else None
