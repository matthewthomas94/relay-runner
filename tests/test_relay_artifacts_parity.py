"""RR-494: the relay-artifacts crate against the Python artifact store,
tickets, follow-up proposals, config and archive catalog.

``StoreParityTest`` runs the RR-485 golden commit sequences and an adversarial
store scenario through both implementations with pinned Git dates and
requires the same answers call by call and the same commit ids, so the two
write byte-identical commits; then it runs them with the implementations
taking turns on one data root, as a daemon swap would. ``TicketParityTest``
requires the same parse and write results over every ticket file to hand and
that the crate's ticket document gives back each file unchanged. The
remaining cases compare the other ported modules over corpora.

Rust cases skip when the crate's test driver is not built (``cargo test`` in
rust/ builds it); see tests/relay_artifacts_support.py.
"""

from __future__ import annotations

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from relay_artifacts_support import (
    GOLDEN_DIR,
    GOLDEN_SEQUENCES,
    REPO,
    Refused,
    concrete,
    driver_command,
    git_dates,
    golden_commit,
    golden_files,
    implementation,
    replay_golden,
)

DEVICE = "daemon-0123456789abcdef01234567"
PNG = b"\x89PNG\r\n\x1a\n" + b"p" * 24
JPEG = b"\xff\xd8\xff\xe0" + b"j" * 24
CONFIG = (
    'schema_version = 2\nproject_id = "parity"\nprefix = "PAR"\n'
    'artifact_ref = "refs/heads/relay/artifacts"\nremote_sync = "local_only"\n'
    'artifact_lifecycle = "legacy"\nnext_id = 1\nnext_note_id = 1\n'
)
# Where the crate and Python word a refusal differently on purpose: JSON
# decode details (`Expecting value: line 1 column 1 (char 0)`). The class
# still has to match.
LOOSE = "loose"


def isolation() -> dict:
    return {"GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", **git_dates()}


def git(repo: Path, *arguments: str) -> str:
    done = subprocess.run(
        ["git", "-C", str(repo), *arguments], capture_output=True, check=True,
        env={**os.environ, **isolation()},
    )
    return done.stdout.decode("utf-8", "replace").strip()


def make_repo(root: Path, name: str = "parity") -> Path:
    repo = root / name
    repo.mkdir(parents=True)
    git(repo, "init", "--initial-branch=main", "--quiet")
    (repo / "README.md").write_text("# Parity\n")
    git(repo, "add", "README.md")
    git(repo, "-c", "user.name=Parity", "-c", "user.email=parity@example.invalid",
        "commit", "--quiet", "-m", "initial")
    return repo


def outcome(target, op: str, **arguments):
    try:
        return ["ok", target.call(op, **arguments)]
    except Refused as refused:
        return ["refused", refused.error, refused.message]


def scrub(value, root: Path):
    """`value` with the sandbox root replaced, so two sandboxes compare equal."""
    if isinstance(value, dict):
        return {scrub(key, root): scrub(item, root) for key, item in value.items()}
    if isinstance(value, list):
        return [scrub(item, root) for item in value]
    if isinstance(value, str):
        return value.replace(str(root), "<ROOT>")
    return value


def hexed(content) -> str:
    return (content if isinstance(content, bytes) else content.encode("utf-8")).hex()


def ticket_write(ticket_id: str, markdown, artifact_id: str = None) -> dict:
    return {"type": "TicketWrite", "ticket_id": ticket_id,
            "artifact_id": artifact_id or "ticket-%s" % ticket_id.lower(),
            "markdown": hexed(markdown)}


def ticket_text(ticket_id: str, body: str = "Body\n", extra: str = "") -> str:
    return "---\nid: %s\ntitle: \"Ticket %s\"\nstatus: backlog\n%s---\n\n%s" % (
        ticket_id, ticket_id, extra, body)


def mutation(event_id: str, *operations, **options) -> dict:
    value = {"event_id": event_id, "actor_type": "user", "device_id": DEVICE,
             "operations": list(operations)}
    value.update(options)
    return value


def write(path: str, content) -> tuple:
    return ("fs.write", path, content)


def store_scenario() -> list:
    """Every store entry point, its refusals, and recovery after a failure."""
    golden_note = golden_files("notes/1-create")
    note = golden_note[".orchestrator/notes/RR-N1.md"]
    steps = [
        ("store.open", {"enabled": False}),
        ("store.initialize", {"device_id": DEVICE}),
        ("store.snapshot", {}),
        ("store.open", {"project_warning_bytes": 40}),
        ("store.mutate", {"mutation": mutation("e-0", ticket_write("RR-1", ticket_text("RR-1")))}),
        ("store.recover", {}),
        ("store.initialize", {"device_id": "bad id"}),
        ("store.initialize", {"device_id": DEVICE, "actor_type": "robot"}),
        ("store.initialize", {"device_id": DEVICE}),
        ("store.initialize", {"device_id": DEVICE}),
        ("store.mutate", {"mutation": mutation(
            "e-1", ticket_write("RR-1", "---\r\nid: RR-1\r\ntitle: \"First\"\r\n---\r\n\r\nBody\r\n\n\n"),
            summary="Save Relay ticket RR-1")}),
        ("store.mutate", {"mutation": mutation(
            "e-1", ticket_write("RR-1", "---\r\nid: RR-1\r\ntitle: \"First\"\r\n---\r\n\r\nBody\r\n\n\n"),
            summary="Save Relay ticket RR-1")}),
        ("store.mutate", {"mutation": mutation("e-1", ticket_write("RR-1", ticket_text("RR-1")))}),
        ("store.mutate", {"mutation": mutation("e-2", ticket_write("RR-2", ticket_text("RR-2")),
                                               expected_base="0" * 40)}),
        ("store.mutate", {"mutation": mutation("e-3", ticket_write("RR-2", ticket_text("RR-2")),
                                               expected_base="xyz")}),
        ("store.mutate", {"mutation": mutation("e-4", ticket_write("RR-2", ticket_text("RR-2")),
                                               provider="gemini")}),
        ("store.mutate", {"mutation": mutation("e-5", ticket_write("RR-2", ticket_text("RR-2")),
                                               summary="two\nlines")}),
        ("store.mutate", {"mutation": mutation("e-6")}),
        ("store.mutate", {"mutation": mutation("e 7", ticket_write("RR-2", ticket_text("RR-2")))}),
        ("store.mutate", {"mutation": mutation("e-7", ticket_write("config", ticket_text("config")))}),
        ("store.mutate", {"mutation": mutation("e-8", ticket_write("RR-2", ticket_text("RR-2")),
                                               ticket_write("RR-2", ticket_text("RR-2")))}),
        ("store.mutate", {"mutation": mutation("e-9", ticket_write("RR-2", ticket_text("RR-3")))}),
        ("store.mutate", {"mutation": mutation("e-10", ticket_write(
            "RR-2", ticket_text("RR-2", extra="artifact_id: ticket-other\n")))}),
        ("store.mutate", {"mutation": mutation("e-11", ticket_write("RR-2", "no front matter\n"))}),
        ("store.mutate", {"mutation": mutation("e-12", ticket_write("RR-2", "---\nid: RR-2\n"))}),
        ("store.mutate", {"mutation": mutation("e-13", ticket_write(
            "RR-2", ticket_text("RR-2", "token ghp_" + "a" * 36 + "\n")))}),
        ("store.mutate", {"mutation": mutation("e-14", ticket_write(
            "RR-2", ticket_text("RR-2", "<Hidden_Reasoning >\n")))}),
        ("store.mutate", {"mutation": mutation("e-15", ticket_write(
            "RR-2", ticket_text("RR-2", "nul \x00\n")))}),
        ("store.mutate", {"mutation": mutation("e-16", ticket_write(
            "RR-2", ticket_text("RR-2").encode() + b"\xff\n"))}),
        ("store.mutate", {"mutation": mutation(
            "e-17",
            ticket_write("RR-2", ticket_text("RR-2", "Unicode é ✓ body next\n",
                                             extra="artifact_id: ticket-rr-2\n")),
            {"type": "AttachmentWrite", "ticket_id": "RR-2", "filename": "shot.png",
             "mime_type": "image/png", "content": hexed(PNG)},
            {"type": "AttachmentWrite", "ticket_id": "RR-2", "filename": "photo.JPG",
             "mime_type": "IMAGE/JPEG", "content": hexed(JPEG)},
            summary="  Save RR-2 with attachments  ")}),
    ]
    for index, (filename, mime, content) in enumerate((
        ("voice.mp3", "audio/mpeg", b"ID3"),
        ("shot.jpg", "image/png", PNG),
        ("shot.png", "image/png", b"not a png"),
        ("../x.png", "image/png", PNG),
        ("archive.tar.gz", "application/gzip", b"\x1f\x8b"),
    )):
        steps.append(("store.mutate", {"mutation": mutation(
            "attach-%d" % index,
            {"type": "AttachmentWrite", "ticket_id": "RR-2", "filename": filename,
             "mime_type": mime, "content": hexed(content)})}))
    for index, config in enumerate((
        "not = [valid",
        CONFIG.replace("schema_version = 2", "schema_version = 3"),
        CONFIG.replace("schema_version = 2", "schema_version = 2.0"),
        CONFIG.replace('"parity"', '"other"'),
        CONFIG.replace('project_id = "parity"\n', ""),
        CONFIG.replace('"refs/heads/relay/artifacts"', '"refs/heads/main"'),
        CONFIG.replace('"local_only"', '"sometimes"'),
        CONFIG.replace('"local_only"', '["local_only"]'),
        CONFIG.replace('"legacy"', '"unknown"'),
        CONFIG.replace("next_note_id = 1", "next_note_id = 0"),
        CONFIG.replace("next_note_id = 1", "next_note_id = 99999999999999999999999"),
        CONFIG + 'token = "sk-' + "a" * 24 + '"\n',
        CONFIG.replace("next_id = 1", "next_id = 7"),
    )):
        steps.append(("store.mutate", {"mutation": mutation(
            "config-%d" % index, {"type": "ConfigWrite", "content": hexed(config)},
            provider="codex", summary="Write config %d" % index)}))
    for index, (content, loose) in enumerate((
        ('{"ticket_id":"RR-9","state":"archived"}\n\n{"ticket_id":"RR-8"}\n', False),
        ('{"ticket_id":"RR-9"}\nnot json\n', True),
        ('[1, 2]\n', False),
        ('{"nested":{"Raw_Transcript ":"x"}}\n', False),
    )):
        step = ("store.mutate", {"mutation": mutation(
            "archive-%d" % index, {"type": "ArchiveIndexWrite", "content": hexed(content)})})
        steps.append(step + ((LOOSE,) if loose else ()))
    event = {"project_id": "parity", "event_id": "program-1", "kind": "decision",
             "text": "Ship it ✓", "count": 2}
    for index, (event_id, content, loose) in enumerate((
        ("program-1", json.dumps(event, indent=2, ensure_ascii=False), False),
        ("program-1", json.dumps(event, sort_keys=True, separators=(",", ":")), False),
        ("program-1", json.dumps({**event, "count": 3}), False),
        ("program-2", json.dumps(event), False),
        ("program-3", json.dumps({**event, "event_id": "program-3", "project_id": "x"}), False),
        ("program-4", json.dumps({**event, "event_id": "program-4", "tool_output": 1}), False),
        ("program-5", "{not json", True),
        ("program-6", "[]", False),
        ("program-7", json.dumps({**event, "event_id": "program-7"}).encode("utf-16"), False),
    )):
        step = ("store.mutate", {"mutation": mutation(
            "program-write-%d" % index,
            {"type": "ProgramEventWrite", "event_id": event_id, "content": hexed(content)})})
        steps.append(step + ((LOOSE,) if loose else ()))
    steps += [
        ("store.mutate", {"mutation": mutation("note-0", {
            "type": "NoteWrite", "note_id": "RR-N1", "artifact_id": "note-" + "a" * 40,
            "project_id": "other", "markdown": hexed(note)})}),
        ("store.mutate", {"mutation": mutation("note-1", {
            "type": "NoteWrite", "note_id": "RR-N1", "artifact_id": "note-" + "a" * 40,
            "project_id": "parity", "markdown": hexed(note)})}),
        ("store.mutate", {"mutation": mutation("note-2", {
            "type": "NoteWrite", "note_id": "RR-N1", "artifact_id": "note-" + "a" * 40,
            "project_id": "parity", "markdown": hexed("---\nid: RR-N1\n---\n")})}),
        ("store.mutate", {"mutation": mutation("note-3", {
            "type": "NoteDelete", "note_id": "RR-N1", "artifact_id": "note-" + "a" * 40})}),
        ("store.mutate", {"mutation": mutation("note-4", {
            "type": "NoteIndexWrite", "content": hexed('{"schema_version": 9}\n')})}),
        ("store.prepare_mutation", {"mutation": mutation(
            "prepared-1", ticket_write("RR-3", ticket_text("RR-3")))}),
        ("store.prepare_mutation", {"mutation": mutation(
            "prepared-2", ticket_write("RR-3", ticket_text("RR-3")), expected_base="$HEAD")}),
        ("store.snapshot", {}),
        write(".orchestrator/RR-1.md", "edited by hand\n"),
        ("store.mutate", {"mutation": mutation("conflict-1", ticket_write("RR-3", ticket_text("RR-3")))}),
        write(".orchestrator/zz-extra.md", "extra\n"),
        ("store.mutate", {"mutation": mutation("conflict-2", ticket_write("RR-3", ticket_text("RR-3")))}),
        ("store.recover", {}),
        write(".orchestrator/.DS_Store", b"\x00\x00\x00\x01Bud1"),
        write(".orchestrator/attachments/._shot.png", b"\x00\x05\x16\x07"),
        ("store.mutate", {"mutation": mutation("finder-1", ticket_write("RR-3", ticket_text("RR-3")))}),
        ("store.open", {"fail_stage": "before_commit"}),
        ("store.mutate", {"mutation": mutation("fail-1", ticket_write("RR-4", ticket_text("RR-4")))}),
        ("store.open", {"fail_stage": "after_ref_update"}),
        ("store.mutate", {"mutation": mutation("fail-2", ticket_write("RR-4", ticket_text("RR-4")))}),
        ("store.open", {"fail_stage": "during_materialization"}),
        ("store.mutate", {"mutation": mutation("fail-3", ticket_write("RR-5", ticket_text("RR-5")))}),
        ("store.open", {}),
        ("store.snapshot", {}),
        ("store.mutate", {"mutation": mutation("fail-3", ticket_write("RR-5", ticket_text("RR-5")))}),
        ("store.mutate", {"mutation": mutation(
            "delete-1", {"type": "TicketDelete", "ticket_id": "RR-2"},
            {"type": "AttachmentDelete", "ticket_id": "RR-9", "filename": "gone.png"})}),
        ("fs.rmtree", ".orchestrator"),
        ("store.mutate", {"mutation": mutation("after-rmtree", ticket_write("RR-6", ticket_text("RR-6")))}),
        ("store.recover", {}),
        ("store.snapshot", {}),
        ("store.digest", {"mutation": mutation("digest", ticket_write("RR-7", "x"), provider="claude")}),
    ]
    return steps


def bootstrap_scenario() -> list:
    legacy = [
        write(".orchestrator/config.toml", CONFIG),
        write(".orchestrator/RR-1.md", ticket_text("RR-1")),
    ]
    bootstrap = mutation("migration-bootstrap:1", {"type": "ConfigWrite", "content": hexed(CONFIG)},
                         ticket_write("RR-1", ticket_text("RR-1")), actor_type="migration",
                         device_id="migration-cli", summary="Bootstrap reviewed legacy Relay artifacts")
    return [
        ("store.open", {}),
        ("store.bootstrap_legacy", {"mutation": bootstrap}),
        *legacy,
        ("store.initialize", {"device_id": DEVICE}),
        ("store.bootstrap_legacy", {"mutation": {**bootstrap, "actor_type": "user"}}),
        ("store.bootstrap_legacy", {"mutation": {**bootstrap, "expected_base": "1" * 40}}),
        ("store.bootstrap_legacy", {"mutation": bootstrap}),
        ("store.bootstrap_legacy", {"mutation": bootstrap}),
        ("store.bootstrap_legacy", {"mutation": {**bootstrap, "summary": "Different"}}),
        ("store.bootstrap_legacy", {"mutation": {**bootstrap, "event_id": "migration-bootstrap:2"}}),
        ("store.mutate", {"mutation": mutation("after-bootstrap", ticket_write("RR-2", ticket_text("RR-2")))}),
        ("fs.rmtree", ".orchestrator"),
        ("store.recover", {}),
        ("store.mutate", {"mutation": mutation("after-bootstrap", ticket_write("RR-2", ticket_text("RR-2")))}),
        ("store.snapshot", {}),
    ]


class Sandbox:
    """One repository and data root that implementations take turns on."""

    def __init__(self, test: unittest.TestCase, name: str = "parity"):
        self.root = Path(os.path.realpath(tempfile.mkdtemp(prefix="relay-artifacts-parity-")))
        test.addCleanup(shutil.rmtree, str(self.root), True)
        self.repo = make_repo(self.root, name)
        self.state_root = self.root / "state"

    def play(self, implementations, steps, project_id: str = "parity") -> list:
        """Run `steps`, implementation `i % len` taking step `i`; every
        implementation sees each `store.open`."""
        results = []
        for index, step in enumerate(steps):
            if step[0] == "fs.write":
                target = self.repo / step[1]
                target.parent.mkdir(parents=True, exist_ok=True)
                content = step[2]
                target.write_bytes(content if isinstance(content, bytes) else content.encode())
                continue
            if step[0] == "fs.rmtree":
                shutil.rmtree(self.repo / step[1])
                continue
            op, arguments = step[0], dict(step[1])
            if op == "store.open":
                arguments.update(repo=str(self.repo), project_id=project_id,
                                 state_root=str(self.state_root))
                for target in implementations:
                    target.call(op, **arguments)
                continue
            if arguments.get("mutation", {}).get("expected_base") == "$HEAD":
                arguments["mutation"] = {**arguments["mutation"],
                                         "expected_base": git(self.repo, "rev-parse", "relay/artifacts")}
            answer = scrub(outcome(implementations[index % len(implementations)], op, **arguments),
                           self.root)
            if LOOSE in step[2:] and answer[0] == "refused":
                answer = answer[:2]
            results.append([op, answer])
        return results

    def state(self) -> dict:
        """Everything a daemon would read back: the ref's history, the
        projection and the store's own files."""
        log = git(self.repo, "log", "--format=%H %T %P%n%B", "relay/artifacts") \
            if git(self.repo, "branch", "--list", "relay/artifacts") else ""
        projection = {}
        board = self.repo / ".orchestrator"
        for path in sorted(board.rglob("*")) if board.exists() else ():
            if path.is_file():
                projection[str(path.relative_to(board))] = [
                    oct(path.stat().st_mode & 0o777), path.read_bytes().hex()]
        files = {}
        for path in sorted(self.state_root.rglob("*")) if self.state_root.exists() else ():
            if path.is_file():
                relative = str(path.relative_to(self.state_root))
                if path.suffix == ".json":
                    value = json.loads(path.read_text())
                    value.pop("materialized_at", None)
                    for key in ("temp", "backup", "target"):
                        if key in value:
                            value[key] = Path(value[key]).name.rsplit("-", 1)[0]
                    files[relative] = scrub(value, self.root)
                else:
                    files[relative] = path.read_bytes().hex()
        exclude = Path(git(self.repo, "rev-parse", "--git-path", "info/exclude"))
        exclude = exclude if exclude.is_absolute() else self.repo / exclude
        leftovers = sorted(path.name for path in self.repo.iterdir()
                           if path.name.startswith(".relay-materialization-"))
        return {"log": log, "projection": projection, "files": files,
                "exclude": exclude.read_text() if exclude.exists() else None,
                "leftovers": [name.rsplit("-", 1)[0] for name in leftovers],
                "source_status": git(self.repo, "status", "--porcelain")}


class ParityCase(unittest.TestCase):
    def setUp(self):
        if not driver_command():
            self.skipTest("relay-artifacts driver is not built; run cargo test in rust/")

    def implementations(self, *names, environment=None):
        environment = {**isolation(), **(environment or {})}
        result = []
        for name in names:
            target = implementation(name, environment=environment)
            self.addCleanup(target.close)
            result.append(target)
        return result


class StoreParityTest(ParityCase):
    def golden_run(self, names) -> tuple:
        box = Sandbox(self)
        targets = self.implementations(*names)
        results = []
        for group, sequence in GOLDEN_SEQUENCES:
            repo = make_repo(box.root, "%s-%s" % (group, sequence[0]))
            project = golden_commit("%s/%s" % (group, sequence[0]))["trailers"]["Relay-Project-ID"]
            for target in targets:
                target.call("store.open", repo=str(repo), project_id=project,
                            state_root=str(box.state_root))
            turn = iter(range(10 ** 6))

            def call(op, **arguments):
                return targets[next(turn) % len(targets)].call(op, **arguments)

            results.append(replay_golden(call, repo, group, sequence))
            results.append(git(repo, "log", "--format=%H %T %P%n%B", "relay/artifacts"))
        return scrub(results, box.root)

    def test_golden_sequences_make_the_same_commits(self):
        python = self.golden_run(["python"])
        self.assertEqual(python, self.golden_run(["rust"]))
        self.assertEqual(python, self.golden_run(["python", "rust"]))
        self.assertEqual(python, self.golden_run(["rust", "python"]))

    def scenario(self, steps, names) -> tuple:
        box = Sandbox(self)
        results = box.play(self.implementations(*names), steps)
        return results, box.state()

    def assertSameRun(self, steps):
        python, python_state = self.scenario(steps, ["python"])
        rust, rust_state = self.scenario(steps, ["rust"])
        for index, (expected, actual) in enumerate(zip(python, rust)):
            self.assertEqual(expected, actual, "step %d differs" % index)
        self.assertEqual(len(python), len(rust))
        self.assertEqual(python_state, rust_state)
        for names in (["python", "rust"], ["rust", "python"]):
            mixed, mixed_state = self.scenario(steps, names)
            self.assertEqual(python, mixed, names)
            self.assertEqual(python_state, mixed_state, names)
        return python

    def test_store_scenario(self):
        results = self.assertSameRun(store_scenario())
        # The scenario reaches what it means to: commits, idempotent
        # replays, warnings and each refusal class.
        answers = [answer for _op, answer in results]
        errors = {answer[1] for answer in answers if answer[0] == "refused"}
        self.assertTrue({
            "ArtifactStoreDisabled", "ArtifactValidationError", "ArtifactIdentityError",
            "ArtifactConcurrentUpdate", "ArtifactEventCollision",
            "ArtifactMaterializationConflict", "ArtifactInjectedFailure", "TypeError",
        } <= errors, errors)
        writes = [answer[1] for answer in answers if answer[0] == "ok" and isinstance(answer[1], dict)]
        self.assertTrue(any(write.get("idempotent") for write in writes))
        self.assertTrue(any(write.get("warnings") for write in writes))

    def test_bootstrap_scenario(self):
        self.assertSameRun(bootstrap_scenario())

    def test_ticket_corpus_prepares_the_same_commits(self):
        """Each ticket file to hand, as a ticket write on one base: the same
        canonical bytes, refusals and commit ids."""
        answers = []
        for name in ("python", "rust"):
            box = Sandbox(self)
            target, = self.implementations(name)
            target.call("store.open", repo=str(box.repo), project_id="parity",
                        state_root=str(box.state_root))
            head = target.call("store.initialize", device_id=DEVICE)["commit_id"]
            run = []
            for index, (key, text) in enumerate(sorted(ticket_corpus().items())):
                ticket_id = next((line.partition(":")[2].strip().strip("\"'")
                                  for line in text.splitlines()[1:12] if line.startswith("id:")), "RR-1")
                run.append(outcome(target, "store.prepare_mutation", mutation=mutation(
                    "corpus-%d" % index, ticket_write(ticket_id, text, "ticket-%d" % index),
                    expected_base=head)))
            answers.append(scrub(run, box.root))
        self.assertEqual(answers[0], answers[1])
        self.assertGreater(sum(answer[0] == "ok" for answer in answers[0]), 20)

    def test_writer_lock_is_shared_across_implementations(self):
        """A Rust writer waits for the flock a Python writer holds."""
        box = Sandbox(self)
        rust, = self.implementations("rust")
        rust.call("store.open", repo=str(box.repo), project_id="parity",
                  state_root=str(box.state_root))
        rust.call("store.initialize", device_id=DEVICE)
        lock_path = box.state_root / "locks" / "parity.lock"
        holder = subprocess.Popen(
            [sys.executable, "-c",
             "import fcntl,sys,time\n"
             "f=open(sys.argv[1],'a+');fcntl.flock(f,fcntl.LOCK_EX);print('held',flush=True)\n"
             "time.sleep(float(sys.argv[2]))", str(lock_path), "1.5"],
            stdout=subprocess.PIPE, text=True,
        )
        self.addCleanup(holder.wait)
        self.assertEqual(holder.stdout.readline().strip(), "held")
        started = time.monotonic()
        rust.call("store.mutate", mutation=mutation("locked", ticket_write("RR-1", ticket_text("RR-1"))))
        self.assertGreater(time.monotonic() - started, 1.0)


def ticket_corpus() -> dict:
    """Ticket files to hand: this checkout's board, the golden trees, an
    optional extra directory and edge cases."""
    corpus = {}
    directories = [REPO / ".orchestrator"]
    extra = os.environ.get("RELAY_ARTIFACTS_TICKET_CORPUS", "").strip()
    if extra:
        directories.append(Path(extra))
    for directory in directories:
        for path in sorted(directory.glob("*.md")) if directory.is_dir() else ():
            corpus[str(path)] = path.read_bytes().decode("utf-8", "replace")
    for path in sorted(GOLDEN_DIR.rglob("*.md")):
        if "/notes/" not in str(path):
            text = path.read_text()
            corpus["golden:" + str(path.relative_to(GOLDEN_DIR))] = text
            corpus["concrete:" + str(path.relative_to(GOLDEN_DIR))] = concrete(text)
    base = ticket_text("RR-1", "## Description\n\nBody.\n", extra=(
        "priority: high\nexecution_mode: implementation\ndepends_on: [RR-2, RR-3]\n"
        "run_id: null\ncanceled: false\n"))
    edge = {
        "minimal": "---\nid: RR-1\ntitle: T\nstatus: ready\ndepends_on: []\n---\n",
        "no-final-newline": base.rstrip("\n"),
        "crlf": base.replace("\n", "\r\n"),
        "closing-at-eof": "---\nid: RR-1\ntitle: T\nstatus: done\ndepends_on: []\n---",
        "blank-separator": base.replace("---\n\n", "---\n\n\n"),
        "quotes": "---\nid: 'RR-1'\ntitle: \"Quoted: yes\"\nstatus: \"backlog\"\ndepends_on: ['RR-2', \"RR-3\"]\n---\nb\n",
        "duplicate-keys": "---\nid: RR-1\ntitle: A\ntitle: B\nstatus: backlog\ndepends_on: []\n---\n",
        "extras": "---\nid: RR-1\ntitle: T\nstatus: backlog\ndepends_on: []\nzeta: 1\nalpha: two words\nnot a field\n---\n",
        "spaces": "  ---  \nid :  RR-1  \ntitle:T\nstatus:  Backlog \ndepends_on:[ RR-2 ,, RR-3 ]\n  ---\nbody\n",
        "order": "---\nid: RR-1\ntitle: T\nstatus: backlog\ndepends_on: []\norder: 7\n---\n",
        "order-blank": "---\nid: RR-1\ntitle: T\nstatus: backlog\ndepends_on: []\norder:\n---\n",
        "order-unicode": "---\nid: RR-1\ntitle: T\nstatus: backlog\ndepends_on: []\norder: ٣_0\n---\n",
        "order-bad": "---\nid: RR-1\ntitle: T\nstatus: backlog\ndepends_on: []\norder: 1.5\n---\n",
        "run-id": "---\nid: RR-1\ntitle: T\nstatus: in_progress\ndepends_on: []\nrun_id: 42\n---\n",
        "run-id-bad": "---\nid: RR-1\ntitle: T\nstatus: in_progress\ndepends_on: []\nrun_id: abc\n---\n",
        "canceled": "---\nid: RR-1\ntitle: T\nstatus: done\ndepends_on: []\ncanceled: TRUE\ndraft: yes\n---\n",
        "bad-status": "---\nid: RR-1\ntitle: T\nstatus: waiting\ndepends_on: []\n---\n",
        "bad-priority": "---\nid: RR-1\ntitle: T\nstatus: ready\npriority: none\ndepends_on: []\n---\n",
        "bad-mode": "---\nid: RR-1\ntitle: T\nstatus: ready\nexecution_mode: Research\ndepends_on: []\n---\n",
        "missing-title": "---\nid: RR-1\nstatus: ready\ndepends_on: []\n---\n",
        "missing-deps": "---\nid: RR-1\ntitle: T\nstatus: ready\n---\n",
        "no-open": "id: RR-1\n---\n",
        "no-close": "---\nid: RR-1\ntitle: T\n",
        "bom": "﻿---\nid: RR-1\ntitle: T\nstatus: ready\ndepends_on: []\n---\n",
        "blocked": "---\nid: RR-1\ntitle: T\nstatus: verification_blocked\ndepends_on: []\nrun_id: 3\n"
                   "verification_blocker: needs a device\nverification_resume: plug it in\n---\n",
        "blocked-inline": "---\nid: RR-1\ntitle: T\nstatus: verification_blocked\ndepends_on: []\n"
                          "verification_blocker: b\nverification_resume: r\nverification_origin: INLINE\n---\n",
        "blocked-no-run": "---\nid: RR-1\ntitle: T\nstatus: verification_blocked\ndepends_on: []\n"
                          "verification_blocker: b\nverification_resume: r\n---\n",
        "blocked-no-resume": "---\nid: RR-1\ntitle: T\nstatus: verification_blocked\ndepends_on: []\n"
                             "run_id: 3\nverification_blocker: b\n---\n",
        "bad-origin": "---\nid: RR-1\ntitle: T\nstatus: ready\ndepends_on: []\nverification_origin: worker\n---\n",
        "unicode-separators": "---\nid: RR-1\x1c\ntitle: T x\nstatus: ready\ndepends_on: []\n---\nb\u0085c\n",
        "empty": "",
    }
    corpus.update({"edge:" + name: text for name, text in edge.items()})
    return corpus


class TicketParityTest(ParityCase):
    def test_parse_and_write_match(self):
        python, rust = self.implementations("python", "rust")
        root = Path(tempfile.mkdtemp(prefix="relay-artifacts-tickets-"))
        self.addCleanup(shutil.rmtree, str(root), True)
        parsed = 0
        for name, text in ticket_corpus().items():
            with self.subTest(ticket=name):
                expected = outcome(python, "tickets.parse", text=text)
                self.assertEqual(expected, outcome(rust, "tickets.parse", text=text))
                if expected[0] != "ok":
                    continue
                parsed += 1
                for edit in ({}, {"status": "done", "run_id": 9, "order": 3,
                                  "depends_on": ["RR-9"], "verification_blocker": "x"}):
                    ticket = {**expected[1], **edit}
                    written = []
                    for target in (python, rust):
                        path = root / ("%s.md" % target.name)
                        self.assertEqual(outcome(target, "tickets.write", path=str(path), ticket=ticket),
                                         ["ok", None])
                        written.append(path.read_bytes())
                    self.assertEqual(written[0], written[1])
                path = root / "read.md"
                path.write_bytes(text.encode("utf-8"))
                self.assertEqual(outcome(python, "tickets.read", path=str(path)),
                                 outcome(rust, "tickets.read", path=str(path)))
        self.assertGreater(parsed, 30)

    def test_ticket_files_round_trip_unchanged(self):
        rust, = self.implementations("rust")
        python, = self.implementations("python")
        for name, text in ticket_corpus().items():
            with self.subTest(ticket=name):
                answer = outcome(rust, "tickets.roundtrip", text=text)
                if answer[0] == "ok":
                    self.assertEqual(answer[1], text)
                else:
                    # Only a file without front matter has no document.
                    self.assertEqual(answer[1], "TicketParseError")
                    self.assertEqual(outcome(python, "tickets.parse", text=text)[1], "TicketParseError")

    def test_scan_repo_and_dependencies(self):
        python, rust = self.implementations("python", "rust")
        root = Path(tempfile.mkdtemp(prefix="relay-artifacts-scan-"))
        self.addCleanup(shutil.rmtree, str(root), True)
        board = root / ".orchestrator"
        board.mkdir()
        corpus = ticket_corpus()
        for index, name in enumerate(sorted(name for name in corpus if name.startswith("edge:"))):
            if name in {"edge:order-bad", "edge:order-unicode"}:
                continue
            (board / ("T%02d.md" % index)).write_text(corpus[name])
        (board / ".hidden.md").write_text(corpus["edge:minimal"])
        (board / "binary.MD").write_bytes(b"\xff")
        (board / "dir.md").mkdir()
        expected = outcome(python, "tickets.scan_repo", repo=str(root))
        self.assertEqual(expected, outcome(rust, "tickets.scan_repo", repo=str(root)))
        (board / "bad.md").write_bytes(b"---\nid: RR-1\ntitle: T\nstatus: ready\ndepends_on: []\n---\n\xff")
        self.assertEqual(outcome(python, "tickets.scan_repo", repo=str(root)),
                         outcome(rust, "tickets.scan_repo", repo=str(root)))
        (board / "bad.md").write_text(corpus["edge:order-bad"])
        self.assertEqual(outcome(python, "tickets.scan_repo", repo=str(root)),
                         outcome(rust, "tickets.scan_repo", repo=str(root)))
        tickets = expected[1]
        for ticket in tickets:
            self.assertEqual(outcome(python, "tickets.all_deps_done", ticket=ticket, all=tickets),
                             outcome(rust, "tickets.all_deps_done", ticket=ticket, all=tickets))


class ModuleParityTest(ParityCase):
    def assertSame(self, python, rust, op, loose=False, **arguments):
        expected = outcome(python, op, **arguments)
        actual = outcome(rust, op, **arguments)
        if loose and expected[0] == "refused":
            expected, actual = expected[:2], actual[:2]
        self.assertEqual(expected, actual, "%s %r" % (op, arguments))
        return expected

    def test_board_config(self):
        python, rust = self.implementations("python", "rust")
        texts = [
            'prefix = "CT"\nnext_id = 1\n', "prefix='rr'\nnext_id=42", "  prefix = ab9 \n  next_id =  7  \n",
            'prefix = "CT"\n', "next_id = 3\n", 'prefix = "9X"\nnext_id = 1\n',
            'prefix = "CT"\nnext_id = ٣\n', 'prefix = "CT"\nnext_id = 1\nnext_id = 2\n',
            'prefix = "CT"\r\nnext_id = 4\r\n', 'prefix = "CT"\nnext_id = 5\x1c\n',
        ]
        for text in texts:
            self.assertSame(python, rust, "board.ticket_config", text=text)
            self.assertSame(python, rust, "board.with_next_id", text=text, next_id=12)
        contents = [
            CONFIG, CONFIG.replace('"PAR"', '"  ab ✓"'), CONFIG.replace('"PAR"', '"Ab9"'),
            CONFIG.replace('"PAR"', "7"), CONFIG.replace('"PAR"', '""'),
            CONFIG.replace("next_id = 1", "next_id = 0"), CONFIG.replace("next_id = 1", "next_id = true"),
            CONFIG.replace("next_id = 1", "next_id = 1 # comment"), CONFIG.replace("next_id = 1", "next_id=  41"),
            CONFIG + "[x]\nnext_id = 3\n", "prefix = \"A\"\n[t]\nnext_id = 1\n", "invalid = = 1",
        ]
        for content in contents:
            self.assertSame(python, rust, "board.claim_next_id", content=hexed(content))
        self.assertSame(python, rust, "board.claim_next_id", content="ff")

    def test_toml_and_isotime(self):
        python, rust = self.implementations("python", "rust")
        documents = [
            "a = 1\nb = 'x'\nc = \"\\u00e9\\t\"\nd = [1, 2.5, true]\n[t]\ne = {f = 1}\n[[arr]]\ng = 1\n[[arr]]\n",
            "n = 123456789012345678901234567890\nm = -0x7f\no = 0o17\nb = 0b101\nf = 6.02e23\ni = inf\nz = -0.0\n",
            "d = 1979-05-27T07:32:00Z\nl = 1979-05-27T07:32:00.999999\nt = 07:32:00\nday = 1979-05-27\n"
            "o = 1979-05-27 07:32:00-07:30\n",
            '"quoted key".\'literal\' = 1\nbare-key_1 = """\nmulti\\\n   line"""\nlit = \'\'\'raw\\n\'\'\'\n',
            "a = 1\na = 2\n", "a = {b = 1,}", "[a]\n[a]\n", "a = 1 b", 'a = "x', "a = 2026-02-30",
            'a = "\\e"', "﻿a = 1", "a = 01", "a = 1\n# \x00\n", "a = {\n}", "a.b = 1\n[a.b]\n",
            "[a.b]\nc=1\n[a]\nb=2\n", "a = {b=1}\na.c = 2\n", "[[a]]\n[a]\n", "x = 1_000\ny = 1__0\n",
            "x = 99999999999999999999.5\n", "t = 24:00:00\n", "s = \"\\U0010FFFF\\uD800\"\n",
        ]
        for document in documents:
            self.assertSame(python, rust, "toml.loads", text=document)
        self.assertSame(python, rust, "toml.loads_bytes", content=hexed("a = 1\r\nb = 2\r\n"))
        self.assertSame(python, rust, "toml.loads_bytes", content="61203d20ff")
        times = [
            "2026-08-04T05:00:00Z", "2026-08-04T05:00:00+00:00", "2026-08-04", "2026-W32-2",
            "2026-216", "20260804T050000.123456-0130", "2026-08-04 05:00", "2026-08-04T05",
            "2026-08-04T24:00:00", "2026-08-04T05:00:00.1234567", "0001-01-01T00:00:00+01:00",
            "9999-12-31T23:59:59-01:00", "2026-02-30", "2026-08-04T05:00:00+24:00", "", "x",
            "2026-08-04é05:00", "2026-08-04T05:00:00,5Z", "2026-08-04T05:00:00 +0100",
            "2026-W53-1", "2026-W54-1", "2026-W01-8", "2026-W00-1", "0000-01-01", "2026-13-01",
            "2026-08-04T23:60", "2026-08-04T24:00:01", "2026-08-04T05:00:00+23:59:59.999999",
            "2026-08-04T05:00:00-24:00", "2026-08-04T05:00:00+25:30:15.5",
        ]
        for text in times:
            self.assertSame(python, rust, "isotime.fromisoformat", text=text)

    def test_config(self):
        python, rust = self.implementations("python", "rust")
        root = Path(tempfile.mkdtemp(prefix="relay-artifacts-config-"))
        self.addCleanup(shutil.rmtree, str(root), True)
        path = root / "config.toml"
        documents = [None, "", "[tts]\nrate = 1.1\nengine = 'piper'\nvoice = 'en_US-amy'\ncustom_voice_id = 'x'\n",
                     "[stt]\nmodel = 'whisper-large-v3'\n[orchestrator]\nworker_timeout_seconds = 5\n",
                     "[general]\ncommand = '/opt/bin/claude'\nmodel = 'Sonnet'\n",
                     "[general]\nprovider = 'claude'\ncommand = 'codex'\nmodel = 'gpt-9'\n",
                     "[general]\nprovider = 'other'\nmodel = 'gpt-6.1-codex-terra'\norchestrator_effort = 'ultra'\n"
                     "messenger_model = 'opus'\nmessenger_effort = 'max'\n",
                     "[general]\nprovider = 'claude'\nmodel = 'haiku'\norchestrator_effort = 'high'\n"
                     "codex_reasoning_effort = 'xhigh'\nsubagent_sizing_policy = 'always'\n",
                     "[extra]\nkept = [1, {a = 2}]\n", "invalid = [", "general = 'flat'\n"]
        documents += ["[tts]\nrate = %d\n" % rate for rate in range(8, 401)]
        for document in documents:
            if document is None:
                path.unlink(missing_ok=True)
            else:
                path.write_text(document)
            for major in (14, 15, 26):
                for phonon in (True, False):
                    loose = document == "general = 'flat'\n"
                    self.assertSame(python, rust, "config.load", loose=loose, path=str(path),
                                    macos_major=major, phonon_default_active=phonon)
        environment = {"VOICE_TERMINAL_TTS_AUTO_PLAY": "Yes", "VOICE_TERMINAL_ORCHESTRATOR_PORT": "8000",
                       "VOICE_TERMINAL_TTS_RATE": "1.7", "VOICE_TERMINAL_GENERAL_MODEL": "astra"}
        path.write_text("[tts]\nvoice = 'bf_isabella'\n")
        for overrides in (environment, {"VOICE_TERMINAL_ORCHESTRATOR_PORT": "eighty"}):
            python, rust = self.implementations("python", "rust", environment=overrides)
            self.assertSame(python, rust, "config.load", path=str(path), macos_major=26)

    def test_catalog(self):
        python, rust = self.implementations("python", "rust")
        content = golden_files("board/5-ticket-rewrite")[".orchestrator/CT-2.md"]
        entry = json.loads(golden_files("board/6-ticket-delete")[".orchestrator/archive-index.jsonl"])
        variants = [
            {}, {"ticket_path": ".orchestrator/CT-3.md"}, {"ticket_id": "CT-3"}, {"artifact_id": "x"},
            {"title": "Other"}, {"title": None}, {"status": "Backlog "}, {"status": "done"},
            {"dependencies": ["CT-1"]}, {"dependencies": "CT-1"}, {"dependencies": [" "]},
            {"activity_at": "2026-08-04T06:00:00+01:00"}, {"activity_at": "2026-08-04T05:00:01Z"},
            {"activity_at": "2026-08-04T05:00:00"}, {"activity_at": "soon"},
        ]
        for variant in variants:
            self.assertSame(python, rust, "catalog.validate", entry={**entry, **variant},
                            content=hexed(content))
        replaced = content.replace(b"status: backlog", b"status: cancelled\ncanceled: yes")
        for fields in (None, ["claimed_at"], []):
            arguments = {} if fields is None else {"activity_fields": fields}
            self.assertSame(python, rust, "catalog.validate", entry=entry, content=hexed(replaced),
                            **arguments)
        for broken in (b"no front matter", b"---\nid: CT-2\n", b"\xff"):
            self.assertSame(python, rust, "catalog.validate", entry=entry, content=hexed(broken))

    def test_notes(self):
        python, rust = self.implementations("python", "rust")
        documents = []
        for name in ("notes/1-create", "notes/2-metadata"):
            files = golden_files(name)
            documents.append(files[".orchestrator/notes/RR-N1.md"])
            index = files[".orchestrator/note-index.jsonl"]
            self.assertSame(python, rust, "notes.decode_index", content=hexed(index),
                            project_id="global-notes")
            self.assertSame(python, rust, "notes.decode_index", content=hexed(index), project_id="other")
            self.assertSame(python, rust, "notes.decode_index",
                            content=hexed(index.replace(b'"recording_state":"', b'"recording_state":["')
                                          .replace(b'","schema_version"', b'"],"schema_version"', 1)),
                            project_id="global-notes")
        note = documents[1]
        documents += [
            note.replace(b"segment_count: 2", b"segment_count: 3"),
            note.replace(b"note_schema_version: 1", b"note_schema_version: 2"),
            note.replace(b"recording_state: completed", b"recording_state: paused"),
            note.replace(b'"origin": "generated"', b'"origin": ["generated"]'),
            note.replace(b'"provider": "claude"', b'"provider": "gemini"'),
            note.replace(b'"generated_at": "2026-08-04T05:00:00Z"', b'"generated_at": 5'),
            note.replace(b'"title": "Scripted note title"', b'"title": "\\ud800"'),
            note.replace(b"note_metadata: {", b"note_metadata: {,"),
            note.replace(b"\nWe decided", b"\nstray text\n<!-- relay-note-segment {} -->\nWe decided"),
            note.replace(b"id: RR-N1", b"id: RR-X1"), note + b"\x00", b"\xff",
        ]
        for document in documents:
            self.assertSame(python, rust, "notes.parse", content=hexed(document))
            self.assertSame(python, rust, "notes.normalize", content=hexed(document))
        for value in (None, [], {"origin": "manual", "state": "empty"},
                      {"origin": "generated", "state": "ready", "title": "t"},
                      {"origin": "generated", "state": {"x": 1}}, {"origin": "manual", "state": "failed",
                                                                   "error_code": "x" * 81},
                      {"origin": "manual", "state": "failed", "source_sha256": "A" * 64},
                      {"origin": "manual", "state": "failed", "generated_at": "2026-08-04T05:00:00"},
                      {"origin": "manual", "state": "failed", "generated_at": [1]}):
            self.assertSame(python, rust, "notes.validate_metadata", value=value)
        for value in ("RR-N1", "RR-N0", "N1", "ABC-N12", "rr-n1", "RR-N01", "RR-N1x", ""):
            self.assertSame(python, rust, "notes.validate_note_id", value=value)


class FollowupParityTest(ParityCase):
    def test_drafts_and_identifiers(self):
        python, rust = self.implementations("python", "rust")
        same = ModuleParityTest.assertSame.__get__(self)
        draft = {
            "title": "  Port the store  ", "description": "Line one\r\n\r\n\r\nLine two\t",
            "acceptance_criteria": ["  first ", "second"], "priority": "HIGH", "depends_on": ["RR-1"],
            "worker_model": "balanced", "worker_effort": "medium",
            "worker_sizing_rationale": "Bounded.", "worker_provider_notes": "none",
        }
        variants = [
            {}, {"title": ""}, {"title": "x" * 500}, {"title": 5}, {"priority": "whenever"},
            {"acceptance_criteria": []}, {"acceptance_criteria": "one"}, {"depends_on": [1]},
            {"worker_effort": "ultra"}, {"worker_model": ""}, {"target_repo_path": "/tmp/other"},
            {"target_repo_path": 5}, {"description": "see /Users/someone/private and token sk-" + "a" * 30},
            {"hidden_reasoning": "x"},
        ]
        for variant in variants:
            same(python, rust, "followup.sanitize", draft={**draft, **variant}, origin_repo_path="/repo")
        same(python, rust, "followup.sanitize", draft="not a dict", origin_repo_path="/repo")
        bodies = [
            "## Spike report\n\n**Recommended next steps**\n- Port tickets\n* Port the store  \n  - nested\n\n"
            "**Uncertainties**\n- none\n",
            "**Recommended next steps**  \n\n- only one\n## Next section\n- not a step\n",
            "no steps here", "**recommended NEXT steps**\n-   spaced   out  \n",
        ]
        for body in bodies:
            same(python, rust, "followup.recommended_next_steps", body=body)
            same(python, rust, "followup.automatic_drafts", body=body, origin_repo_path="/repo")
        batch = same(python, rust, "followup.batch_id", origin_repo_path="/repo", origin_ticket_id="RR-1",
                     origin_run_id=7)[1]
        proposal = same(python, rust, "followup.proposal_id", batch=batch, position=2)[1]
        same(python, rust, "followup.acceptance_key", batch=batch, proposal=proposal)

    def test_proposal_store(self):
        root = Path(tempfile.mkdtemp(prefix="relay-artifacts-followup-"))
        self.addCleanup(shutil.rmtree, str(root), True)
        results, dumps = [], []
        for name in ("python", "rust"):
            target, = self.implementations(name)
            path = root / ("%s.sqlite3" % name)
            target.call("followup.open", path=str(path))
            drafts = [{"title": "One", "description": "d", "acceptance_criteria": ["a"]},
                      {"title": "Two", "description": "e", "acceptance_criteria": ["b"], "priority": "low"}]
            calls = [
                ("followup.create_or_get", {"origin_repo_path": "/repo", "origin_ticket_id": "RR-1",
                                            "origin_run_id": 7, "provider_key": "claude", "drafts": drafts}),
                ("followup.create_or_get", {"origin_repo_path": "/repo", "origin_ticket_id": "RR-1",
                                            "origin_run_id": 7, "provider_key": "codex", "drafts": []}),
                ("followup.get", {"batch": "missing"}),
            ]
            answers = [outcome(target, op, **arguments) for op, arguments in calls]
            batch = answers[0][1][0]["id"]
            proposal = answers[0][1][0]["proposals"][0]["id"]
            for op, arguments in (
                ("followup.update_draft", {"batch": batch, "proposal": proposal,
                                           "draft": {"title": "Edited", "description": "x",
                                                     "acceptance_criteria": ["y"]}}),
                ("followup.update_draft", {"batch": batch, "proposal": "missing", "draft": {"title": "x"}}),
                ("followup.set_result", {"batch": batch, "proposal": proposal, "state": "accepted",
                                         "ticket_id": "RR-9"}),
                ("followup.set_result", {"batch": batch, "proposal": proposal, "state": "maybe"}),
                ("followup.set_result", {"batch": batch, "proposal": "missing", "state": "rejected"}),
                ("followup.set_error", {"batch": batch, "proposal": proposal, "error": "failed once"}),
                ("followup.get", {"batch": batch}),
            ):
                answers.append(outcome(target, op, **arguments))
            results.append(normalized_times(answers))
            connection = sqlite3.connect(str(path))
            dumps.append(normalized_times([
                connection.execute("SELECT type, name, sql FROM sqlite_master ORDER BY name").fetchall(),
                [[table, connection.execute("SELECT * FROM %s ORDER BY rowid" % table).fetchall()]
                 for table in ("batches", "proposals")],
            ]))
            connection.close()
        self.assertEqual(results[0], results[1])
        self.assertEqual(json.loads(json.dumps(dumps[0])), json.loads(json.dumps(dumps[1])))


def normalized_times(value):
    """Wall-clock seconds replaced, so two runs compare equal."""
    if isinstance(value, dict):
        return {key: "<time>" if key.endswith("_at") and isinstance(item, float) else normalized_times(item)
                for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [normalized_times(item) for item in value]
    if isinstance(value, float) and value > 1e9:
        return "<time>"
    return value


if __name__ == "__main__":
    unittest.main()
