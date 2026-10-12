"""Optional, account-bound personal files with a verified, bounded local cache.

GitHub is accessed through gh's credential store. No Git checkout or access token
is kept here. Each uploaded version has an immutable commit, Git blob and SHA-256
proof; publication never force-updates a ref. Operational app files are outside
the explicit user-file allowlist.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import time
import uuid
from pathlib import Path, PurePosixPath
from urllib.parse import quote

DEFAULT_BUDGET_BYTES = 256 * 1024 * 1024
DEFAULT_RETENTION_DAYS = 30
MARKER_PATH = ".relay-runner-storage.json"
CATALOG_PATH = "relay-catalog.json"
REPO_DESCRIPTION = "Private personal notes and task files for Relay Runner"
_ID = re.compile(r"^[A-Za-z0-9_.:-]{1,160}$")
_REPO = re.compile(r"^[A-Za-z0-9_.-]{1,100}$")


class StorageError(ValueError):
    def __init__(self, state, message):
        super().__init__(message)
        self.state = state


def git_blob_id(content):
    return hashlib.sha1(f"blob {len(content)}\0".encode() + content).hexdigest()


class GitHubFiles:
    """Small injectable GitHub transport; credentials stay with gh/Keychain."""
    def __init__(self, executable=None):
        self.executable = executable or shutil.which("gh")

    def api(self, method, endpoint, body=None):
        if not self.executable:
            raise StorageError("auth_failure", "Install GitHub CLI and sign in to connect private storage.")
        command = [self.executable, "api", "--hostname", "github.com", "--method", method,
                   "-H", "Accept: application/vnd.github+json", endpoint]
        if body is not None:
            command += ["--input", "-"]
        try:
            result = subprocess.run(command, input=json.dumps(body).encode() if body is not None else None,
                                    capture_output=True, timeout=60)
        except (OSError, subprocess.TimeoutExpired) as error:
            raise StorageError("pending", "GitHub is unavailable. Local files are preserved; retry when online.") from error
        if result.returncode:
            # Never surface gh diagnostics: they can contain private paths or login material.
            diagnostic = result.stderr.decode(errors="replace")
            match = re.search(r"HTTP (\d{3})", diagnostic)
            status = int(match[1]) if match else None
            if status == 404:
                raise StorageError("missing", "The GitHub object is missing or inaccessible.")
            if status in (401, 403) or "auth login" in diagnostic:
                raise StorageError("auth_failure", "Sign in to GitHub with access to the private storage repository.")
            if status in (409, 422):
                raise StorageError("conflict", "GitHub changed during publication; both versions are preserved.")
            raise StorageError("pending", "GitHub is unavailable. Local files are preserved; retry when online.")
        try:
            return json.loads(result.stdout)
        except (ValueError, UnicodeDecodeError) as error:
            raise StorageError("pending", "GitHub returned an unreadable response; local files are preserved.") from error

    def account(self):
        user = self.api("GET", "user")
        if not user.get("id") or not re.fullmatch(r"[A-Za-z0-9-]+", user.get("login", "")):
            raise StorageError("auth_failure", "GitHub did not return an authenticated user identity.")
        return {"id": user["id"], "login": user["login"], "suggested_repository": user["login"] + "-rr-files"}

    def repo(self, full_name):
        return self.api("GET", "repos/" + full_name)

    def tree(self, full_name, commit):
        tree_sha = self.api("GET", f"repos/{full_name}/git/commits/{commit}")["tree"]["sha"]
        data = self.api("GET", f"repos/{full_name}/git/trees/{tree_sha}?recursive=1")
        if data.get("truncated"):
            raise StorageError("conflict", "The storage repository tree is too large to validate completely.")
        return {row["path"]: row["sha"] for row in data["tree"] if row["type"] == "blob"}

    def read_blob(self, full_name, blob, expected_size=None):
        data = self.api("GET", f"repos/{full_name}/git/blobs/{blob}")
        if data.get("sha") != blob or data.get("encoding") != "base64":
            raise StorageError("conflict", "Remote file identity or encoding is invalid.")
        if expected_size is not None and data.get("size") != expected_size:
            raise StorageError("conflict", "Remote file size does not match its verified catalog.")
        try:
            content = base64.b64decode(data["content"].replace("\n", ""), validate=True)
        except (ValueError, KeyError) as error:
            raise StorageError("conflict", "Remote file content is invalid.") from error
        if git_blob_id(content) != blob or (expected_size is not None and len(content) != expected_size):
            raise StorageError("conflict", "Remote file checksum failed. The local copy is preserved.")
        return content

    def head(self, full_name, branch):
        return self.api("GET", f"repos/{full_name}/git/ref/heads/{quote(branch, safe='')}")["object"]["sha"]

    def publish(self, full_name, branch, changes, expected=None):
        """Append one commit. expected path blobs detect edits by other devices."""
        head = self.head(full_name, branch)
        existing = self.tree(full_name, head)
        for path, blob in (expected or {}).items():
            if existing.get(path) != blob and existing.get(path) != git_blob_id(changes[path]):
                raise StorageError("conflict", "A remote file changed. Resolve the conflict before uploading.")
        tree = []
        for path, content in changes.items():
            blob = self.api("POST", f"repos/{full_name}/git/blobs", {
                "content": base64.b64encode(content).decode(), "encoding": "base64"})["sha"]
            if blob != git_blob_id(content):
                raise StorageError("conflict", "GitHub acknowledged an unexpected file revision.")
            tree.append({"path": path, "mode": "100644", "type": "blob", "sha": blob})
        base_tree = self.api("GET", f"repos/{full_name}/git/commits/{head}")["tree"]["sha"]
        new_tree = self.api("POST", f"repos/{full_name}/git/trees", {"base_tree": base_tree, "tree": tree})["sha"]
        commit = self.api("POST", f"repos/{full_name}/git/commits", {
            "message": "Save Relay personal files", "tree": new_tree, "parents": [head]})["sha"]
        self.api("PATCH", f"repos/{full_name}/git/refs/heads/{quote(branch, safe='')}",
                 {"sha": commit, "force": False})
        proof = self.tree(full_name, commit)
        for path, content in changes.items():
            blob = git_blob_id(content)
            if proof.get(path) != blob or self.read_blob(full_name, blob, len(content)) != content:
                raise StorageError("conflict", "Remote publication could not be verified. Local files are preserved.")
        return commit


class PersonalFileStorage:
    def __init__(self, state_root, *, github=None, clock=time.time):
        self.root = Path(state_root).resolve()
        self.files_root = self.root / "files"
        self.general_tasks_root = self.root / "general-tasks"
        self.support_root = self.root / "personal-storage"
        if any(path.is_symlink() for path in (self.files_root, self.support_root, self.files_root / "documents")):
            raise StorageError("conflict", "Personal storage folders must not be symbolic links.")
        self.files_root.mkdir(parents=True, exist_ok=True)
        (self.files_root / "documents").mkdir(exist_ok=True)
        self.support_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.github = github or GitHubFiles()
        self.clock = clock
        self.lock = threading.RLock()
        self.db = sqlite3.connect(self.support_root / "catalog.sqlite3", check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript("""
            CREATE TABLE IF NOT EXISTS settings(key TEXT PRIMARY KEY, value TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS files(
              artifact_id TEXT PRIMARY KEY, logical_path TEXT NOT NULL UNIQUE, category TEXT NOT NULL,
              current_sha TEXT NOT NULL, metadata TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0,
              active INTEGER NOT NULL DEFAULT 0, approved INTEGER NOT NULL DEFAULT 0, updated REAL NOT NULL);
            CREATE TABLE IF NOT EXISTS versions(
              artifact_id TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL, local_path TEXT,
              remote_repo TEXT, remote_commit TEXT, remote_blob TEXT, accessed REAL NOT NULL,
              PRIMARY KEY(artifact_id,sha256));
        """)
        self.db.commit()
        os.chmod(self.support_root / "catalog.sqlite3", 0o600)
        self._login = None
        self.note_library = None

    def attach_notes(self, library):
        self.note_library = library
        library.personal_storage = self
        if self._get("notes_migrated", False):
            library._manager = None

    def _get(self, key, default=None):
        row = self.db.execute("SELECT value FROM settings WHERE key=?", (key,)).fetchone()
        return json.loads(row[0]) if row else default

    def _set(self, key, value):
        self.db.execute("INSERT OR REPLACE INTO settings VALUES(?,?)", (key, json.dumps(value)))

    def _state(self, state, message=None):
        self._set("state", state)
        self._set("message", message)
        self.db.commit()

    def account(self):
        with self.lock:
            return self.github.account()

    def sign_in(self):
        """User-invoked browser device login; no auth text enters the file allowlist."""
        with self.lock:
            if not self.github.executable:
                raise StorageError("auth_failure", "Install GitHub CLI to connect private storage.")
            if self._login is None or self._login[0].poll() is not None:
                log = self.support_root / "github-login.txt"
                handle = log.open("wb")
                os.chmod(log, 0o600)
                process = subprocess.Popen([self.github.executable, "auth", "login", "--hostname", "github.com",
                                            "--git-protocol", "https", "--web"], stdin=subprocess.DEVNULL,
                                           stdout=handle, stderr=handle, env={**os.environ, "GH_BROWSER": "/usr/bin/open"})
                handle.close()
                self._login = (process, log)
            time.sleep(0.15)
            output = self._login[1].read_text(errors="replace")
            code = re.search(r"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b", output)
            return {"state": "pending", "device_code": code[0] if code else None,
                    "url": "https://github.com/login/device"}

    @staticmethod
    def _identity(repo, account):
        if repo.get("private") is not True or repo.get("visibility", "private") != "private":
            raise StorageError("conflict", "Personal storage must be private. This repository was not adopted.")
        if repo.get("owner", {}).get("id") != account["id"]:
            raise StorageError("conflict", "The storage repository must belong to the authenticated GitHub user.")
        if not repo.get("permissions", {}).get("push", False):
            raise StorageError("auth_failure", "The authenticated account cannot write this repository.")
        return {"repository_id": repo["id"], "node_id": repo["node_id"], "owner_id": account["id"],
                "login": account["login"], "full_name": repo["full_name"], "html_url": repo["html_url"],
                "clone_url": repo["clone_url"], "branch": repo["default_branch"]}

    def configure(self, *, confirm=False, repository_name=None, create=True):
        if confirm is not True:
            raise StorageError("local_only", "Enable private GitHub storage explicitly before creating a repository.")
        with self.lock:
            account = self.github.account()
            name = repository_name or account["suggested_repository"]
            if not _REPO.fullmatch(name):
                raise ValueError("Invalid storage repository name")
            full_name = account["login"] + "/" + name
            prior = self._get("destination")
            pending = self._get("provisioning")
            try:
                repo = self.github.repo(full_name)
            except StorageError as error:
                if error.state != "missing" or not create:
                    raise
                pending = {"full_name": full_name, "owner_id": account["id"], "request_id": uuid.uuid4().hex}
                pending["description"] = REPO_DESCRIPTION + " (" + pending["request_id"] + ")"
                self._set("provisioning", pending)
                self.db.commit()
                repo = self.github.api("POST", "user/repos", {
                    "name": name, "private": True, "auto_init": True, "description": pending["description"]})
            identity = self._identity(repo, account)
            head = self.github.head(full_name, identity["branch"])
            tree = self.github.tree(full_name, head)
            if MARKER_PATH in tree:
                marker = json.loads(self.github.read_blob(full_name, tree[MARKER_PATH]))
                if marker != {"schema_version": 1, "purpose": "relay-runner-personal-files", "owner_id": account["id"]}:
                    raise StorageError("conflict", "This repository has an unrelated storage identity marker.")
            else:
                # Retry an interrupted create only for our own empty, private, identified repository.
                pending = self._get("provisioning") or pending
                if (not pending or pending.get("full_name") != full_name or pending.get("owner_id") != account["id"]
                        or repo.get("description") != pending.get("description") or set(tree) - {"README.md"}):
                    raise StorageError("conflict", "This existing repository is unrelated. Select a Relay storage repo or a new name.")
                marker = json.dumps({"schema_version": 1, "purpose": "relay-runner-personal-files", "owner_id": account["id"]}).encode()
                self.github.publish(full_name, identity["branch"], {MARKER_PATH: marker}, {MARKER_PATH: None})
            if prior and prior != identity:
                # Explicit setup can revalidate a rename of the same identity, but never adopts old proofs for a new repo.
                if prior["repository_id"] != identity["repository_id"]:
                    for revision in self.db.execute("SELECT local_path FROM versions WHERE remote_repo IS NOT NULL AND remote_repo!=?",
                                                    (str(identity["repository_id"]),)):
                        if not revision["local_path"] or not self._cache_path(revision["local_path"]).is_file():
                            raise StorageError("conflict", "Retrieve archived files from the existing storage repository before changing destinations. The existing destination is preserved.")
                self.db.execute("UPDATE versions SET remote_repo=NULL,remote_commit=NULL,remote_blob=NULL WHERE remote_repo!=?",
                                (str(identity["repository_id"]),))
            self._set("destination", identity)
            self._set("connected", True)
            self._set("provisioning", None)
            self._import_catalog(identity)
            self._state("pending", "Select and approve the personal files to synchronize.")
            return self.status()

    def _remote_catalog(self, destination):
        head = self.github.head(destination["full_name"], destination["branch"])
        tree = self.github.tree(destination["full_name"], head)
        blob = tree.get(CATALOG_PATH)
        if not blob:
            return None, None
        catalog = json.loads(self.github.read_blob(destination["full_name"], blob))
        if (not isinstance(catalog, dict) or catalog.get("schema_version") != 1 or catalog.get("repository_id") != destination["repository_id"]
                or catalog.get("owner_id") != destination["owner_id"]):
            raise StorageError("conflict", "The portable file catalog belongs to another repository or account.")
        return catalog, blob

    def _import_catalog(self, destination):
        # A rejected remote catalog must not replace any current pointers, notes or receipts.
        self.db.execute("SAVEPOINT personal_catalog_import")
        try:
            self._apply_catalog(destination)
        except BaseException as error:
            self.db.execute("ROLLBACK TO personal_catalog_import")
            self.db.execute("RELEASE personal_catalog_import")
            if isinstance(error, StorageError):
                raise
            if isinstance(error, (ValueError, KeyError, TypeError, sqlite3.IntegrityError)):
                raise StorageError("conflict", "The remote file catalog is invalid. The previous local catalog and content are preserved.") from error
            raise
        self.db.execute("RELEASE personal_catalog_import")
        self.db.commit()

    def _apply_catalog(self, destination):
        catalog, blob = self._remote_catalog(destination)
        if catalog is None:
            self._set("remote_catalog_blob", None)
            return
        if any(not isinstance(catalog.get(key, []), list) for key in ("files", "notes", "note_events")):
            raise StorageError("conflict", "The remote file catalog has an invalid collection; local content is preserved.")
        for file in catalog.get("files", []):
            if not isinstance(file, dict) or not isinstance(file.get("versions"), list):
                raise StorageError("conflict", "The remote file catalog has an invalid file or version list; local content is preserved.")
            identity, current = file["artifact_id"], file["current_sha"]
            if not _ID.fullmatch(identity) or not re.fullmatch(r"[0-9a-f]{64}", current):
                raise StorageError("conflict", "Remote file catalog contains an invalid identity.")
            logical = self._logical_path(file["logical_path"], file["category"])
            existing = self.db.execute("SELECT * FROM files WHERE artifact_id=?", (identity,)).fetchone()
            if existing and (existing["logical_path"] != logical or existing["category"] != file["category"]):
                raise StorageError("conflict", "A remote file identity collides with local content.")
            baseline = self._get("remote_current:" + identity)
            if existing and existing["current_sha"] != current and current != baseline and existing["current_sha"] != baseline:
                raise StorageError("conflict", "The remote and local current revisions differ. Both copies are preserved for resolution.")
            if not existing:
                self.db.execute("INSERT INTO files VALUES(?,?,?,?,?,0,0,1,?)", (identity, logical, file["category"], current,
                                json.dumps(file.get("metadata", {})), file.get("updated", self.clock())))
            elif existing["current_sha"] == baseline and current != baseline:
                self.db.execute("UPDATE files SET current_sha=?,metadata=?,updated=? WHERE artifact_id=?",
                                (current, json.dumps(file.get("metadata", {})), file.get("updated", self.clock()), identity))
            for revision in file["versions"]:
                if (not re.fullmatch(r"[0-9a-f]{64}", revision["sha256"])
                        or not re.fullmatch(r"[0-9a-f]{40}", revision["remote_blob"])
                        or not re.fullmatch(r"[0-9a-f]{40}", revision["remote_commit"])
                        or not isinstance(revision["size"], int) or revision["size"] < 0):
                    raise StorageError("conflict", "Remote file catalog contains an invalid revision proof.")
                self.db.execute("""INSERT INTO versions VALUES(?,?,?,NULL,?,?,?,?) ON CONFLICT(artifact_id,sha256)
                    DO UPDATE SET remote_repo=excluded.remote_repo,remote_commit=excluded.remote_commit,remote_blob=excluded.remote_blob""",
                    (identity, revision["sha256"], revision["size"], str(destination["repository_id"]),
                     revision["remote_commit"], revision["remote_blob"], self.clock()))
            self.reference(identity, current)
            if file["category"] == "documents":
                self._set("source_path:" + identity, "files/" + logical)
            self._set("remote_current:" + identity, current)
        if catalog.get("notes"):
            try:
                from services.personal_notes import PersonalNoteManager
                from services.artifact_store import ArtifactStoreError
            except ModuleNotFoundError:
                from personal_notes import PersonalNoteManager
                from artifact_store import ArtifactStoreError
            manager = PersonalNoteManager(self, "remote-catalog", commit=False)
            for entry in catalog["notes"]:
                self.reference(entry["artifact_id"])
                local = self.db.execute("SELECT entry,deleted FROM personal_notes WHERE artifact_id=?", (entry["artifact_id"],)).fetchone()
                local_entry = {**json.loads(local["entry"]), "legacy_recovery": None, "deleted": bool(local["deleted"])} if local else None
                baseline = self._get("remote_note:" + entry["artifact_id"])
                if local_entry is not None and local_entry != entry and local_entry != baseline and entry != baseline:
                    raise StorageError("conflict", "Another device changed this note's metadata or deletion state. Both histories are preserved.")
                if local is None or local_entry == baseline:
                    try:
                        manager.import_remote_entry(entry, commit=False)
                    except (ValueError, ArtifactStoreError) as error:
                        raise StorageError("conflict", "Remote note identities collide with local notes; both histories are preserved.") from error
                self._set("remote_note:" + entry["artifact_id"], entry)
            for receipt in catalog.get("note_events", []):
                if (not re.fullmatch(r"[A-Za-z0-9_.:-]{1,512}", receipt.get("event_id", ""))
                        or not re.fullmatch(r"[0-9a-f]{64}", receipt.get("digest", ""))):
                    raise StorageError("conflict", "The remote note request receipt is invalid.")
                revision = self.reference(receipt["artifact_id"], receipt["revision"])
                if revision["category"] != "notes" or not revision["remote_commit"]:
                    raise StorageError("conflict", "The remote note request receipt has no immutable note version.")
                prior = self.db.execute("SELECT * FROM personal_note_events WHERE event_id=?", (receipt["event_id"],)).fetchone()
                if prior and dict(prior) != receipt:
                    raise StorageError("conflict", "A remote note request receipt collides with a local request; both histories are preserved.")
                self.db.execute("INSERT OR IGNORE INTO personal_note_events VALUES(?,?,?,?)",
                                (receipt["event_id"], receipt["digest"], receipt["artifact_id"], receipt["revision"]))
            self._set("next_personal_note_id", max(manager._next_number(), catalog.get("next_note_id", 1)))
            # An existing legacy library is migrated by the verified bundle flow.
            if not (self.root / "notes" / ".git").exists():
                self._set("notes_migrated", True)
                if self.note_library is not None:
                    self.note_library._manager = None
        self._set("remote_catalog_blob", blob)

    def _publish_catalog(self, destination):
        # Import newly published identities and unchanged-local remote updates before merging.
        self._import_catalog(destination)
        remote, expected_blob = self._remote_catalog(destination)
        by_id = {file["artifact_id"]: file for file in (remote or {}).get("files", [])}
        for row in self.db.execute("SELECT * FROM files WHERE approved=1 AND active=0"):
            versions = [dict(version) for version in self.db.execute("""SELECT sha256,size,remote_commit,remote_blob FROM versions
                WHERE artifact_id=? AND remote_repo=? AND remote_commit IS NOT NULL""", (row["artifact_id"], str(destination["repository_id"])))]
            if not versions or row["current_sha"] not in {version["sha256"] for version in versions}:
                continue
            prior = by_id.get(row["artifact_id"])
            if prior and prior["current_sha"] not in (row["current_sha"], self._get("remote_current:" + row["artifact_id"])):
                raise StorageError("conflict", "Another device changed the current file revision. Both histories are preserved.")
            if prior:
                versions = list({version["sha256"]: version for version in [*prior["versions"], *versions]}.values())
            metadata = json.loads(row["metadata"])
            if "note_entry" in metadata:
                metadata = {"note_entry": {**metadata["note_entry"], "legacy_recovery": None}}
            by_id[row["artifact_id"]] = {"artifact_id": row["artifact_id"], "logical_path": row["logical_path"],
                "category": row["category"], "current_sha": row["current_sha"], "metadata": metadata,
                "updated": row["updated"], "versions": versions}
        notes_by_id = {entry["artifact_id"]: entry for entry in (remote or {}).get("notes", [])}
        if self.db.execute("SELECT 1 FROM sqlite_master WHERE name='personal_notes'").fetchone():
            for row in self.db.execute("SELECT n.entry,n.deleted FROM personal_notes n JOIN files f USING(artifact_id) WHERE f.active=0"):
                entry = json.loads(row["entry"])
                if entry["artifact_id"] in by_id:
                    notes_by_id[entry["artifact_id"]] = {**entry, "legacy_recovery": None, "deleted": bool(row["deleted"])}
        receipts = {row["event_id"]: row for row in (remote or {}).get("note_events", [])}
        if self.db.execute("SELECT 1 FROM sqlite_master WHERE name='personal_note_events'").fetchone():
            for row in self.db.execute("SELECT * FROM personal_note_events"):
                file = by_id.get(row["artifact_id"])
                if file and row["revision"] in {version["sha256"] for version in file["versions"]}:
                    if row["event_id"] in receipts and receipts[row["event_id"]] != dict(row):
                        raise StorageError("conflict", "A remote note request receipt conflicts with a local request.")
                    receipts[row["event_id"]] = dict(row)
        catalog = {"schema_version": 1, "repository_id": destination["repository_id"], "owner_id": destination["owner_id"],
                   "files": list(by_id.values()), "notes": list(notes_by_id.values()), "note_events": list(receipts.values()),
                   "next_note_id": self._get("next_personal_note_id", 1)}
        self.github.publish(destination["full_name"], destination["branch"], {CATALOG_PATH: json.dumps(catalog, sort_keys=True).encode()}, {CATALOG_PATH: expected_blob})
        self._set("remote_catalog_blob", git_blob_id(json.dumps(catalog, sort_keys=True).encode()))
        for identity, file in by_id.items():
            self._set("remote_current:" + identity, file["current_sha"])
        for identity, entry in notes_by_id.items():
            self._set("remote_note:" + identity, entry)
        self.db.commit()

    def disconnect(self):
        with self.lock:
            self._set("connected", False)
            self._state("disconnected", "Uploads are stopped. Local and remote files are preserved.")
            return self.status()

    def _validate_destination(self):
        destination = self._get("destination")
        if not self._get("connected") or not destination:
            raise StorageError("disconnected", "Connect private GitHub storage to publish or retrieve files.")
        account = self.github.account()
        repo = self.github.repo(destination["full_name"])
        if self._identity(repo, account) != destination:
            raise StorageError("conflict", "GitHub account, repository identity, privacy or destination changed. Reconnect to revalidate.")
        head = self.github.head(destination["full_name"], destination["branch"])
        tree = self.github.tree(destination["full_name"], head)
        marker = tree.get(MARKER_PATH)
        if not marker or json.loads(self.github.read_blob(destination["full_name"], marker)) != {
                "schema_version": 1, "purpose": "relay-runner-personal-files", "owner_id": destination["owner_id"]}:
            raise StorageError("conflict", "The repository storage marker changed. Reconnect to revalidate.")
        return destination

    @staticmethod
    def _logical_path(path, category):
        parsed = PurePosixPath(path)
        if category not in ("notes", "tasks", "documents", "history") or parsed.is_absolute() or ".." in parsed.parts:
            raise ValueError("Only explicitly selected personal notes, task files and documents can be stored")
        if not parsed.parts or parsed.parts[0] != category or any(part.startswith(".") for part in parsed.parts):
            raise ValueError("Private runtime files and hidden paths cannot be synchronized")
        if parsed.suffix.lower() in (".sqlite", ".sqlite3", ".db", ".log", ".pem", ".key"):
            raise ValueError("Operational databases, logs and credential files cannot be synchronized")
        return str(parsed)

    def _cache_path(self, relative):
        path = self.root / relative
        if not path.resolve().is_relative_to(self.files_root) or any(parent.is_symlink() for parent in [path, *path.parents] if parent != self.root):
            raise StorageError("conflict", "The local cache path is not a managed personal file. Content is preserved.")
        return path

    def _durable_directory(self, directory):
        # Adoption may remove a source only after the cache name and parents are durable.
        while directory.is_relative_to(self.files_root):
            descriptor = os.open(directory, os.O_RDONLY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)
            directory = directory.parent

    def put(self, artifact_id, logical_path, content, *, category="documents", metadata=None, active=False, approved=None, commit=True):
        if not _ID.fullmatch(artifact_id):
            raise ValueError("Invalid personal file identity")
        logical_path = self._logical_path(logical_path, category)
        if not isinstance(content, bytes):
            raise ValueError("Personal file content must be bytes")
        digest = hashlib.sha256(content).hexdigest()
        with self.lock:
            prior = self.db.execute("SELECT * FROM files WHERE artifact_id=?", (artifact_id,)).fetchone()
            if prior and (prior["logical_path"] != logical_path or prior["category"] != category):
                raise ValueError("Personal file identity cannot change its path or category")
            path = self.files_root / category / artifact_id / (digest + PurePosixPath(logical_path).suffix)
            self._cache_path(str(path.relative_to(self.root)))
            path.parent.mkdir(parents=True, exist_ok=True)
            temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
            try:
                with temporary.open("xb") as output:
                    os.chmod(temporary, 0o600)
                    output.write(content)
                    output.flush()
                    os.fsync(output.fileno())
                os.replace(temporary, path)
                self._durable_directory(path.parent)
            finally:
                temporary.unlink(missing_ok=True)
            self.db.execute("""INSERT INTO files VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(artifact_id) DO UPDATE SET
                current_sha=excluded.current_sha,metadata=excluded.metadata,active=excluded.active,
                approved=excluded.approved,updated=excluded.updated""",
                (artifact_id, logical_path, category, digest, json.dumps(metadata or {}), prior["pinned"] if prior else 0,
                 int(active), int(approved if approved is not None else bool(prior and prior["approved"])), self.clock()))
            self.db.execute("""INSERT INTO versions VALUES(?,?,?,?,NULL,NULL,NULL,?) ON CONFLICT(artifact_id,sha256)
                DO UPDATE SET local_path=excluded.local_path,accessed=excluded.accessed""",
                (artifact_id, digest, len(content), str(path.relative_to(self.root)), self.clock()))
            if self._get("connected"):
                self._set("state", "pending")
            if commit:
                self.db.commit()
            return self.reference(artifact_id)

    def register_file(self, path, *, artifact_id=None, active=False, approved=False, adopt=False):
        source = Path(path)
        if not source.exists() and artifact_id:
            return self.reference(artifact_id)
        if source.is_symlink():
            raise ValueError("Symbolic links cannot be selected for private storage")
        source = source.resolve()
        relative = source.relative_to(self.files_root)
        category = relative.parts[0]
        content = source.read_bytes()
        reference = self.put(artifact_id or "file-" + hashlib.sha256(str(relative).encode()).hexdigest()[:40],
                             str(relative), content, category=category, active=active, approved=approved)
        if adopt and source != self.root / reference["local_path"]:
            if self.read(reference["artifact_id"]) != content or source.read_bytes() != content:
                raise StorageError("conflict", "The task file changed while being adopted; both copies are preserved.")
            source.unlink()
        return reference

    def discover_documents(self):
        """Catalog foreground user documents; runtime and immutable cache paths are excluded."""
        with self.lock:
            managed = {row[0] for row in self.db.execute("SELECT artifact_id FROM files WHERE category='documents'")}
            for root, category in ((self.files_root / "documents", "documents"), (self.general_tasks_root, "tasks")):
                if root.is_symlink() or not root.is_dir():
                    continue
                for directory, dirs, names in os.walk(root, followlinks=False):
                    folder = Path(directory)
                    dirs[:] = [name for name in dirs if not name.startswith(".")
                               and not (folder / name).is_symlink()
                               and not (root != self.general_tasks_root and folder == root and name in managed)]
                    for name in names:
                        source = folder / name
                        if (name.startswith(".") or source.is_symlink() or not source.is_file()
                                or re.fullmatch(r"[0-9a-f]{64}(?:\.[^/]+)?", name)):
                            continue
                        logical = ("tasks/general-tasks/" + source.relative_to(root).as_posix()
                                   if root == self.general_tasks_root else str(source.relative_to(self.files_root)))
                        try:
                            self._logical_path(logical, category)
                        except ValueError:
                            continue
                        prior = self.db.execute("SELECT artifact_id,current_sha FROM files WHERE logical_path=?", (logical,)).fetchone()
                        identity = prior["artifact_id"] if prior else "document-" + hashlib.sha256(logical.encode()).hexdigest()[:40]
                        try:
                            content = source.read_bytes()
                        except OSError:
                            continue  # A foreground writer may be replacing or removing this document.
                        if prior is None or prior["current_sha"] != hashlib.sha256(content).hexdigest():
                            self.put(identity, logical, content, category=category, approved=False)
                        self._set("source_path:" + identity, str(source.relative_to(self.root)))
            self.db.commit()

    def _source_path(self, artifact_id):
        relative = self._get("source_path:" + artifact_id)
        if relative and PurePosixPath(relative).parts[0] == "general-tasks":
            self._logical_path("tasks/" + relative, "tasks")
            path = self.root / relative
            if (not path.resolve().is_relative_to(self.general_tasks_root)
                    or any(parent.is_symlink() for parent in [path, *path.parents] if parent != self.root)):
                raise StorageError("conflict", "The general-tasks source path changed. Content is preserved.")
            return path
        return self._cache_path(relative) if relative else None

    def _restore_source(self, artifact_id, digest, content):
        current = self.db.execute("SELECT current_sha FROM files WHERE artifact_id=?", (artifact_id,)).fetchone()
        source = self._source_path(artifact_id)
        if source is None or current[0] != digest or source.exists():
            return
        source.parent.mkdir(parents=True, exist_ok=True)
        temporary = source.with_name(source.name + ".tmp-" + uuid.uuid4().hex)
        try:
            with temporary.open("xb") as output:
                os.chmod(temporary, 0o600)
                output.write(content)
                output.flush()
                os.fsync(output.fileno())
            # link is exclusive: a document created while downloading is never replaced.
            try:
                os.link(temporary, source)
                self._durable_directory(source.parent)
            except FileExistsError:
                pass
        finally:
            temporary.unlink(missing_ok=True)

    def reference(self, artifact_id, sha256=None):
        with self.lock:
            row = self.db.execute("""SELECT v.*,f.logical_path,f.category,f.metadata,f.pinned,f.active,f.approved
                FROM versions v JOIN files f USING(artifact_id)
                WHERE v.artifact_id=? AND v.sha256=COALESCE(?,f.current_sha)""", (artifact_id, sha256)).fetchone()
            if row is None:
                raise ValueError("Unknown personal file identity or revision")
            result = dict(row)
            result["metadata"] = json.loads(result["metadata"])
            result["materialized"] = bool(result["local_path"] and self._cache_path(result["local_path"]).is_file())
            source = self._source_path(artifact_id)
            result["source_path"] = str(source.relative_to(self.root)) if source and source.is_file() else None
            return result

    def list_files(self, query=""):
        self.discover_documents()
        with self.lock:
            rows = self.db.execute("SELECT artifact_id FROM files WHERE artifact_id LIKE ? OR logical_path LIKE ? OR metadata LIKE ? ORDER BY updated DESC",
                                   ("%" + query + "%", "%" + query + "%", "%" + query + "%")).fetchall()
            return {"files": [self.reference(row[0]) for row in rows]}

    def pin(self, artifact_id, pinned):
        with self.lock:
            self.reference(artifact_id)
            self.db.execute("UPDATE files SET pinned=? WHERE artifact_id=?", (int(bool(pinned)), artifact_id))
            self.db.commit()
            return self.reference(artifact_id)

    def approve(self, artifact_ids):
        with self.lock:
            for identity in artifact_ids:
                self.reference(identity)
                self.db.execute("UPDATE files SET approved=1 WHERE artifact_id=? AND active=0", (identity,))
            self.db.commit()

    def sync(self, *, approve=False, artifact_ids=None):
        self.discover_documents()
        if self.note_library is not None and self._get("connected") and approve is True:
            try:
                self.note_library.prepare_personal_storage(self)
            except (OSError, subprocess.SubprocessError):
                with self.lock:
                    self._state("pending", "Notes history could not be prepared. Local notes and history are preserved; retry synchronization.")
                return self.status()
        with self.lock:
            if approve is True:
                self.approve(artifact_ids if artifact_ids is not None else [row[0] for row in self.db.execute("SELECT artifact_id FROM files")])
            try:
                destination = self._validate_destination()
                rows = self.db.execute("""SELECT v.*,f.logical_path FROM versions v JOIN files f USING(artifact_id)
                    WHERE f.approved=1 AND f.active=0 AND (v.remote_repo IS NULL OR v.remote_repo!=?) ORDER BY v.accessed""",
                    (str(destination["repository_id"]),)).fetchall()
                for row in rows:
                    path = self._cache_path(row["local_path"]) if row["local_path"] else None
                    if not path or not path.is_file():
                        raise StorageError("conflict", "An unsynchronized local revision is missing. Restore it before cleanup.")
                    content = path.read_bytes()
                    if hashlib.sha256(content).hexdigest() != row["sha256"]:
                        raise StorageError("conflict", "A local file changed outside Relay. Import the edited file before synchronization.")
                    remote_path = "files/" + row["artifact_id"] + "/" + row["sha256"] + PurePosixPath(row["logical_path"]).suffix
                    # Each revision owns a unique immutable path. A conflicting byte sequence cannot overwrite it.
                    commit = self.github.publish(destination["full_name"], destination["branch"], {remote_path: content}, {remote_path: None})
                    self.db.execute("UPDATE versions SET remote_repo=?,remote_commit=?,remote_blob=? WHERE artifact_id=? AND sha256=?",
                                    (str(destination["repository_id"]), commit, git_blob_id(content), row["artifact_id"], row["sha256"]))
                    self.db.commit()
                self._publish_catalog(destination)
                self._state("synced", None)
            except StorageError as error:
                self._state(error.state if error.state != "missing" else "auth_failure", str(error))
        if self.note_library is not None and self._get("state") == "synced":
            try:
                self.note_library.finalize_personal_storage(self)
            except (OSError, StorageError, ValueError, subprocess.SubprocessError) as error:
                with self.lock:
                    self._state(error.state if isinstance(error, StorageError) else "pending",
                                "Local notes cleanup is pending. Notes and their verified history are preserved; retry synchronization.")
        if self._get("state") == "synced":
            self.enforce_retention()
            with self.lock:
                if self.db.execute("SELECT 1 FROM files WHERE approved=0 OR active=1 LIMIT 1").fetchone():
                    self._state("pending", "Some personal files are waiting for approval or remain active and local until completed.")
        return self.status()

    def _verify_remote(self, reference, destination):
        if reference["remote_repo"] != str(destination["repository_id"]):
            raise StorageError("conflict", "This revision belongs to another storage destination.")
        path = "files/" + reference["artifact_id"] + "/" + reference["sha256"] + PurePosixPath(reference["logical_path"]).suffix
        tree = self.github.tree(destination["full_name"], reference["remote_commit"])
        if tree.get(path) != reference["remote_blob"]:
            raise StorageError("conflict", "The immutable remote revision no longer matches the catalog.")
        content = self.github.read_blob(destination["full_name"], reference["remote_blob"], reference["size"])
        if hashlib.sha256(content).hexdigest() != reference["sha256"]:
            raise StorageError("conflict", "The remote checksum failed; local content is preserved.")
        return content

    def read(self, artifact_id, sha256=None):
        with self.lock:
            reference = self.reference(artifact_id, sha256)
            path = self._cache_path(reference["local_path"]) if reference["local_path"] else None
            if path and path.is_file():
                content = path.read_bytes()
                if hashlib.sha256(content).hexdigest() != reference["sha256"]:
                    raise StorageError("conflict", "The local checksum failed. No content was overwritten.")
            else:
                try:
                    destination = self._validate_destination()
                    content = self._verify_remote(reference, destination)
                except StorageError as error:
                    self._state(error.state, str(error))
                    raise
                # A single verified result is streamed from memory into an atomic file.
                # No clone, unpacked history, or persistent download directory is created.
                path = self.files_root / reference["category"] / artifact_id / (reference["sha256"] + PurePosixPath(reference["logical_path"]).suffix)
                self._cache_path(str(path.relative_to(self.root)))
                path.parent.mkdir(parents=True, exist_ok=True)
                temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
                try:
                    with temporary.open("xb") as output:
                        os.chmod(temporary, 0o600)
                        output.write(content)
                        output.flush()
                        os.fsync(output.fileno())
                    os.replace(temporary, path)
                    self._durable_directory(path.parent)
                    self.db.execute("UPDATE versions SET local_path=? WHERE artifact_id=? AND sha256=?",
                                    (str(path.relative_to(self.root)), artifact_id, reference["sha256"]))
                finally:
                    temporary.unlink(missing_ok=True)
            self.db.execute("UPDATE versions SET accessed=? WHERE artifact_id=? AND sha256=?", (self.clock(), artifact_id, reference["sha256"]))
            self._restore_source(artifact_id, reference["sha256"], content)
            self.db.commit()
            return content

    def policy(self, *, budget_bytes=DEFAULT_BUDGET_BYTES, retention_days=DEFAULT_RETENTION_DAYS):
        if isinstance(budget_bytes, bool) or not isinstance(budget_bytes, int) or budget_bytes <= 0:
            raise ValueError("Storage budget must be a positive byte count")
        if isinstance(retention_days, bool) or not isinstance(retention_days, int) or retention_days < 0:
            raise ValueError("Retention days must be a nonnegative integer")
        with self.lock:
            self._set("budget_bytes", budget_bytes)
            self._set("retention_days", retention_days)
            self.db.commit()
            return self.enforce_retention()

    def usage(self):
        roots = [self.files_root, self.support_root, self.root / "notes", self.general_tasks_root]
        total = git_bytes = user_file_bytes = 0
        for root in roots:
            if root.is_symlink() or not root.exists():
                continue
            for directory, dirs, files in os.walk(root, followlinks=False):
                dirs[:] = [name for name in dirs if not (Path(directory) / name).is_symlink()]
                for filename in files:
                    path = Path(directory) / filename
                    if path.is_symlink():
                        continue
                    size = path.stat().st_size
                    total += size
                    if root == self.files_root or (root == self.general_tasks_root and
                            not any(part.startswith(".") for part in path.relative_to(root).parts)):
                        user_file_bytes += size
                    if ".git" in path.relative_to(root).parts:
                        git_bytes += size
        return {"total_bytes": total, "git_object_bytes": git_bytes, "user_file_bytes": user_file_bytes}

    def enforce_retention(self):
        self.discover_documents()
        with self.lock:
            budget = self._get("budget_bytes", DEFAULT_BUDGET_BYTES)
            cutoff = self.clock() - self._get("retention_days", DEFAULT_RETENTION_DAYS) * 86400
            reclaimed = 0
            candidates = self.db.execute("""SELECT v.*,f.logical_path,f.current_sha FROM versions v JOIN files f USING(artifact_id)
                WHERE v.local_path IS NOT NULL AND f.pinned=0 AND f.active=0 AND v.remote_commit IS NOT NULL
                ORDER BY v.accessed""").fetchall()
            destination = None
            for row in candidates:
                if row["accessed"] >= cutoff and self.usage()["total_bytes"] <= budget:
                    continue
                try:
                    destination = destination or self._validate_destination()
                    self._verify_remote(dict(row), destination)
                except StorageError as error:
                    self._state(error.state, str(error))
                    break
                path = self._cache_path(row["local_path"])
                # Verify again immediately before unlink; an external edit is unique local work.
                if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == row["sha256"]:
                    source = self._source_path(row["artifact_id"])
                    if (source and not source.is_relative_to(self.general_tasks_root)
                            and row["sha256"] == row["current_sha"] and source.is_file()
                            and hashlib.sha256(source.read_bytes()).hexdigest() == row["sha256"]):
                        reclaimed += source.stat().st_size
                        source.unlink()
                    reclaimed += path.stat().st_size
                    path.unlink()
                    self.db.execute("UPDATE versions SET local_path=NULL WHERE artifact_id=? AND sha256=?", (row["artifact_id"], row["sha256"]))
                    self.db.commit()
            self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            result = self.status()
            result["reclaimed_bytes"] = reclaimed
            return result

    def status(self):
        with self.lock:
            destination = self._get("destination")
            usage = self.usage()
            budget = self._get("budget_bytes", DEFAULT_BUDGET_BYTES)
            sizes = {"evictable_bytes": 0, "protected_bytes": 0, "unsynced_bytes": 0}
            for row in self.db.execute("SELECT v.*,f.pinned,f.active,f.current_sha FROM versions v JOIN files f USING(artifact_id) WHERE v.local_path IS NOT NULL OR v.sha256=f.current_sha"):
                bucket = "protected_bytes" if row["pinned"] or row["active"] else "unsynced_bytes" if not row["remote_commit"] else "evictable_bytes"
                try:
                    path = self._cache_path(row["local_path"]) if row["local_path"] else None
                    sizes[bucket] += path.stat().st_size if path and path.is_file() else 0
                    source = self._source_path(row["artifact_id"]) if row["sha256"] == row["current_sha"] else None
                    if source and source != path and source.is_file():
                        source_bucket = "protected_bytes" if source.is_relative_to(self.general_tasks_root) else bucket
                        sizes[source_bucket] += source.stat().st_size
                except (StorageError, OSError):
                    continue
            unmanaged_bytes = max(0, usage["user_file_bytes"] - sum(sizes.values()))
            sizes["unsynced_bytes"] += unmanaged_bytes
            reasons = []
            if usage["total_bytes"] > budget:
                if sizes["unsynced_bytes"]:
                    reasons.append("Unsynchronized files are preserved. Connect or retry GitHub, or explicitly export/delete files.")
                if unmanaged_bytes:
                    reasons.append("Unregistered task files and operational traces remain local. Export or delete them explicitly; traces are never uploaded.")
                if sizes["protected_bytes"]:
                    reasons.append("Pinned files and active tasks or recordings are protected.")
                if usage["git_object_bytes"]:
                    reasons.append("Local Git history is protected; verified legacy notes archives can be migrated separately.")
                reasons.append("The durable catalog and other required local metadata count toward storage usage.")
            return {"state": self._get("state", "local_only"), "message": self._get("message"),
                    "connected": bool(self._get("connected", False)), "destination": destination,
                    "files_root": str(self.files_root), "budget_bytes": budget,
                    "retention_days": self._get("retention_days", DEFAULT_RETENTION_DAYS),
                    "usage": {**usage, **sizes, "unmanaged_bytes": unmanaged_bytes,
                              "metadata_bytes": max(0, usage["total_bytes"] - sum(sizes.values()) - usage["git_object_bytes"])},
                    "over_budget": usage["total_bytes"] > budget, "overage_reasons": reasons,
                    "disclosure": "Only approved personal notes, task artifacts and documents are uploaded. The private repository is accessible to your GitHub account and anyone you grant access. Provider credentials, terminal logs, operational databases and project boards are excluded."}


def handle_personal_storage_request(storage, method, path, payload=None):
    """Daemon route adapter. Returns None for an unrelated route."""
    if not path.startswith("/v1/personal-storage/"):
        return None
    payload = payload or {}
    route = path.split("?", 1)[0].removeprefix("/v1/personal-storage/")
    if method == "GET" and route == "status":
        return storage.status()
    if method == "GET" and route == "account":
        return storage.account()
    if method == "GET" and route == "files":
        return storage.list_files(str(payload.get("query", "")))
    if method == "POST":
        if route == "sign-in":
            return storage.sign_in()
        if route == "configure":
            return storage.configure(confirm=payload.get("confirm"), repository_name=payload.get("repository_name"), create=payload.get("create", True))
        if route == "disconnect":
            return storage.disconnect()
        if route == "sync":
            return storage.sync(approve=payload.get("approve", False), artifact_ids=payload.get("artifact_ids"))
        if route == "policy":
            return storage.policy(budget_bytes=payload.get("budget_bytes", DEFAULT_BUDGET_BYTES), retention_days=payload.get("retention_days", DEFAULT_RETENTION_DAYS))
        if route == "pin":
            return storage.pin(payload["artifact_id"], payload.get("pinned", True))
        if route == "retrieve":
            content = storage.read(payload["artifact_id"], payload.get("sha256"))
            return {"reference": storage.reference(payload["artifact_id"], payload.get("sha256")),
                    "content_base64": base64.b64encode(content).decode()}
    raise ValueError("Unsupported personal storage route")
