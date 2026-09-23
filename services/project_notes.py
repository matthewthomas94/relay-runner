"""Canonical project note allocation, checkpointing, catalog, and history reads."""

from __future__ import annotations

import base64
import hashlib
import json
import re
import uuid
from pathlib import PurePosixPath
from typing import Mapping, Sequence

try:
    from services.artifact_store import (
        ArtifactConcurrentUpdate,
        ArtifactEventCollision,
        ArtifactIdentityError,
        ArtifactMutation,
        ArtifactStore,
        ArtifactValidationError,
        ConfigWrite,
        NoteDelete,
        NoteIndexWrite,
        NoteWrite,
    )
    from services.note_contract import (
        NOTE_INDEX_SCHEMA_VERSION,
        NoteContractError,
        NoteDocument,
        NoteIdentity,
        NoteSegment,
        NoteUpdate,
        metadata_for_update,
        note_source,
        validate_note_metadata,
        decode_note_index,
        encode_note_index,
        parse_note_document,
        render_note_document,
        validate_note_id,
        validate_timestamp,
    )
    from services.toml_compat import tomllib
except ModuleNotFoundError:
    from artifact_store import (  # type: ignore[no-redef]
        ArtifactConcurrentUpdate,
        ArtifactEventCollision,
        ArtifactIdentityError,
        ArtifactMutation,
        ArtifactStore,
        ArtifactValidationError,
        ConfigWrite,
        NoteDelete,
        NoteIndexWrite,
        NoteWrite,
    )
    from note_contract import (  # type: ignore[no-redef]
        NOTE_INDEX_SCHEMA_VERSION,
        NoteContractError,
        NoteDocument,
        NoteIdentity,
        NoteSegment,
        NoteUpdate,
        metadata_for_update,
        note_source,
        validate_note_metadata,
        decode_note_index,
        encode_note_index,
        parse_note_document,
        render_note_document,
        validate_note_id,
        validate_timestamp,
    )
    from toml_compat import tomllib


_REQUEST_ID_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,120}$")
_PREFIX_RE = re.compile(r"^[A-Za-z0-9]+$")
NOTE_CATALOG_DEFAULT_LIMIT = 50
NOTE_CATALOG_MAX_LIMIT = 100


class ProjectNoteManager:
    """Project-scoped note API built only on the canonical artifact ref."""

    def __init__(self, store: ArtifactStore, *, device_id: str) -> None:
        self.store = store
        self.device_id = device_id

    def create(
        self,
        *,
        request_id: str,
        created_at: str,
        capture_started_at: str,
        captured_at: str,
        recording_state: str,
        checkpoint_reason: str,
        segments: object,
        capture_ended_at: str | None = None,
        provider: str | None = None,
    ) -> dict[str, object]:
        event_id = _event_id("create", request_id)
        _validate_provider(provider)
        validate_timestamp(created_at, "note created_at")
        validate_timestamp(capture_started_at, "note capture_started_at")
        raw_segments = _validated_segment_payload(segments)
        request_payload = {
            "created_at": created_at,
            "capture_started_at": capture_started_at,
            "captured_at": captured_at,
            "recording_state": recording_state,
            "checkpoint_reason": checkpoint_reason,
            "segments": raw_segments,
            "capture_ended_at": capture_ended_at,
        }
        request_digest = _digest(request_payload)

        prior = self.store._find_event(event_id)
        if prior is not None:
            self.store.recover()
            return self._prior_create(event_id, prior[0], request_digest)

        with self.store._writer_lock():
            snapshot = self.store.snapshot()
            config = _config(snapshot.files)
            catalog = _catalog(snapshot.files, self.store.project_id)
            existing = next(
                (entry for entry in catalog.values() if entry["creation_event_id"] == event_id),
                None,
            )
            if existing is not None:
                if existing["creation_request_sha256"] != request_digest:
                    raise ArtifactEventCollision(
                        f"note create request {request_id!r} was already used with different content"
                    )
                return self._read_entry(snapshot.commit_id, existing, idempotent=True)

            prefix = str(config.get("prefix") or "").strip()
            if not _PREFIX_RE.fullmatch(prefix):
                raise ArtifactValidationError("artifact config has no valid note prefix")
            number = _next_note_number(config, snapshot.files, catalog)
            note_id = f"{prefix}-N{number}"
            artifact_id = "note-" + hashlib.sha256(
                f"{self.store.project_id}:{event_id}".encode("utf-8")
            ).hexdigest()[:40]
            identity = NoteIdentity(
                note_id=note_id,
                artifact_id=artifact_id,
                project_id=self.store.project_id,
                created_at=created_at,
                capture_started_at=capture_started_at,
            )
            update = _note_update(
                identity,
                captured_at=captured_at,
                recording_state=recording_state,
                checkpoint_reason=checkpoint_reason,
                segments=raw_segments,
                capture_ended_at=capture_ended_at,
            )
            document = NoteDocument(identity=identity, update=update, metadata=metadata_for_update(update))
            path = _note_path(note_id)
            if path in snapshot.files or any(entry["note_id"] == note_id for entry in catalog.values()):
                raise ArtifactConcurrentUpdate(f"note display ID is already issued: {note_id}")
            catalog[artifact_id] = {
                "schema_version": NOTE_INDEX_SCHEMA_VERSION,
                "note_id": note_id,
                "artifact_id": artifact_id,
                "project_id": self.store.project_id,
                "path": path,
                "created_at": created_at,
                "updated_at": captured_at,
                "recording_state": recording_state,
                "segment_count": len(update.segments),
                "materialized": True,
                "creation_event_id": event_id,
                "last_event_id": event_id,
                "creation_request_sha256": request_digest,
                "metadata": document.metadata,
            }
            config_bytes = _set_next_note_id(snapshot.files[".orchestrator/config.toml"], number + 1)
            write = self.store.mutate(ArtifactMutation(
                event_id=event_id,
                actor_type="user",
                device_id=self.device_id,
                expected_base=snapshot.commit_id,
                provider=provider,
                operations=(
                    ConfigWrite(config_bytes),
                    NoteWrite(note_id, artifact_id, self.store.project_id, render_note_document(document)),
                    NoteIndexWrite(encode_note_index(catalog, project_id=self.store.project_id)),
                ),
                summary=f"Create Relay project note {note_id}",
            ))
            return self._response(
                document,
                commit_id=write.commit_id,
                idempotent=write.idempotent,
                materialized=True,
            )

    def update(
        self,
        *,
        request_id: str,
        update: Mapping[str, object],
        provider: str | None = None,
    ) -> dict[str, object]:
        event_id = _event_id("update", request_id)
        _validate_provider(provider)
        desired = _parse_update(update)
        prior = self.store._find_event(event_id)
        if prior is not None:
            self.store.recover()
            document = self._document_at(prior[0], desired.identity.note_id)
            if document.update != desired:
                raise ArtifactEventCollision(
                    f"note update request {request_id!r} was already used with different content"
                )
            return self._response(
                document,
                commit_id=prior[0],
                idempotent=True,
                materialized=self._currently_materialized(desired.identity.artifact_id),
            )

        for attempt in range(4):
            snapshot = self.store.snapshot()
            catalog = _catalog(snapshot.files, self.store.project_id)
            entry = _entry_for_identity(catalog, desired.identity)
            if entry.get("materialized") is not True:
                raise ArtifactValidationError(
                    f"note {desired.identity.note_id} is archived; restore it before updating"
                )
            path = _note_path(desired.identity.note_id)
            content = snapshot.files.get(path)
            if content is None:
                raise ArtifactValidationError(f"materialized note is missing: {desired.identity.note_id}")
            current = _parse_document(content)
            if current.identity != desired.identity:
                raise ArtifactIdentityError("note update cannot change immutable identity or project")
            document = NoteDocument(identity=current.identity, update=desired,
                                    metadata=metadata_for_update(desired, current.metadata))
            updated_entry = dict(entry)
            updated_entry.update({
                "updated_at": desired.captured_at,
                "recording_state": desired.recording_state,
                "segment_count": len(desired.segments),
                "metadata": document.metadata,
                "last_event_id": event_id,
            })
            catalog[desired.identity.artifact_id] = updated_entry
            try:
                write = self.store.mutate(ArtifactMutation(
                    event_id=event_id,
                    actor_type="user",
                    device_id=self.device_id,
                    expected_base=snapshot.commit_id,
                    provider=provider,
                    operations=(
                        NoteWrite(
                            desired.identity.note_id,
                            desired.identity.artifact_id,
                            desired.identity.project_id,
                            render_note_document(document),
                        ),
                        NoteIndexWrite(encode_note_index(catalog, project_id=self.store.project_id)),
                    ),
                    summary=f"Checkpoint Relay project note {desired.identity.note_id}",
                ))
                return self._response(
                    document,
                    commit_id=write.commit_id,
                    idempotent=write.idempotent,
                    materialized=True,
                )
            except ArtifactConcurrentUpdate:
                if attempt == 3:
                    raise
        raise AssertionError("unreachable")

    def publish_metadata(
        self, *, identity: NoteIdentity, source_sha256: str,
        metadata: dict[str, object], expected_metadata: dict[str, object] | None,
    ) -> bool:
        """Compare and publish under the same canonical lock as transcript writes.

        A recorder never sends metadata, so stale recorder snapshots cannot erase
        it. A metadata job never sends segments, so it cannot erase a checkpoint.
        """
        metadata = validate_note_metadata(metadata)
        with self.store._writer_lock():
            snapshot = self.store.snapshot()
            catalog = _catalog(snapshot.files, self.store.project_id)
            entry = catalog.get(identity.artifact_id)
            if not entry or not entry.get("materialized"):
                return False
            content = snapshot.files.get(_note_path(identity.note_id))
            if content is None:
                return False
            current = _parse_document(content)
            if (current.identity != identity or note_source(current.update)[1] != source_sha256
                    or current.metadata != expected_metadata
                    or (current.metadata or {}).get("origin") == "manual"):
                return False
            if metadata.get("source_sha256") != source_sha256:
                raise ArtifactValidationError("metadata digest does not match its source")
            document = NoteDocument(identity, current.update, metadata)
            event_id = _event_id("metadata", uuid.uuid4().hex)
            catalog[identity.artifact_id] = {**entry, "metadata": metadata, "last_event_id": event_id}
            self.store.mutate(ArtifactMutation(
                event_id=event_id, actor_type="system", device_id=self.device_id,
                expected_base=snapshot.commit_id, provider=metadata.get("provider"),
                operations=(
                    NoteWrite(identity.note_id, identity.artifact_id, identity.project_id,
                              render_note_document(document)),
                    NoteIndexWrite(encode_note_index(catalog, project_id=self.store.project_id)),
                ),
                summary=f"Update metadata for Relay project note {identity.note_id}",
            ))
            return True

    def _require_archive_history_safe(
        self,
        head: str,
        files: Mapping[str, bytes],
    ) -> None:
        mode = str(_config(files).get("remote_sync") or "local_only")
        if mode == "local_only":
            return
        try:
            state = json.loads(self.store.project_state.joinpath("sync-state.json").read_text())
        except (OSError, json.JSONDecodeError, AttributeError):
            state = {}
        if not (
            mode == "enabled"
            and state.get("state") == "clean"
            and state.get("local_head") == head
            and state.get("remote_head") == head
        ):
            raise ArtifactValidationError(
                "note archive requires a clean synchronized artifact head so its historical "
                "source commit remains remotely reachable; sync the project and retry"
            )

    def archive(
        self,
        *,
        note_id: str,
        artifact_id: str,
        archived_at: str,
        request_id: str,
        provider: str | None = None,
    ) -> dict[str, object]:
        validate_note_id(note_id)
        validate_timestamp(archived_at, "note archived_at")
        _validate_provider(provider)
        event_id = _event_id("archive", request_id)
        prior = self.store._find_event(event_id)
        if prior is not None:
            self.store.recover()
            entries = self._catalog_at(prior[0])
            entry = entries.get(artifact_id)
            if (
                not entry
                or entry.get("note_id") != note_id
                or entry.get("last_event_id") != event_id
                or entry.get("archived_at") != archived_at
            ):
                raise ArtifactEventCollision(
                    f"note archive request {request_id!r} was already used for another note"
                )
            current = self.store._head()
            if current is None:
                raise ArtifactValidationError("artifact store is not initialized")
            return self._read_entry(current, entry, idempotent=True)

        for attempt in range(4):
            snapshot = self.store.snapshot()
            self._require_archive_history_safe(snapshot.commit_id, snapshot.files)
            catalog = _catalog(snapshot.files, self.store.project_id)
            entry = catalog.get(artifact_id)
            if entry is None or entry.get("note_id") != note_id:
                raise ArtifactIdentityError("note archive identity does not match the catalog")
            if entry.get("materialized") is not True:
                return self._read_entry(snapshot.commit_id, entry, idempotent=True)
            path = _note_path(note_id)
            content = snapshot.files.get(path)
            if content is None:
                raise ArtifactValidationError(f"materialized note is missing: {note_id}")
            document = _parse_document(content)
            if document.identity.artifact_id != artifact_id:
                raise ArtifactIdentityError("note archive artifact_id does not match Markdown")
            tree_entry = self.store._tree_entries(snapshot.commit_id)[path]
            archived = dict(entry)
            archived.update({
                "materialized": False,
                "archived_at": archived_at,
                "source_commit": snapshot.commit_id,
                "source_blob": tree_entry.oid,
                "last_event_id": event_id,
            })
            catalog[artifact_id] = archived
            try:
                write = self.store.mutate(ArtifactMutation(
                    event_id=event_id,
                    actor_type="user",
                    device_id=self.device_id,
                    expected_base=snapshot.commit_id,
                    provider=provider,
                    operations=(
                        NoteIndexWrite(encode_note_index(catalog, project_id=self.store.project_id)),
                        NoteDelete(note_id, artifact_id),
                    ),
                    summary=f"Archive Relay project note {note_id}",
                ))
                return self._response(
                    document,
                    commit_id=write.commit_id,
                    idempotent=write.idempotent,
                    materialized=False,
                )
            except ArtifactConcurrentUpdate:
                if attempt == 3:
                    raise
        raise AssertionError("unreachable")

    def get(self, identity: str) -> dict[str, object]:
        snapshot = self.store.snapshot()
        catalog = _catalog(snapshot.files, self.store.project_id)
        matches = [
            entry for artifact_id, entry in catalog.items()
            if artifact_id == identity or entry.get("note_id") == identity
        ]
        if len(matches) != 1:
            raise ArtifactValidationError(f"no unique project note matches {identity!r}")
        return self._read_entry(snapshot.commit_id, matches[0], idempotent=True)

    def list(
        self,
        *,
        limit: int = NOTE_CATALOG_DEFAULT_LIMIT,
        after: str | None = None,
    ) -> dict[str, object]:
        if (
            not isinstance(limit, int)
            or isinstance(limit, bool)
            or not 1 <= limit <= NOTE_CATALOG_MAX_LIMIT
        ):
            raise ArtifactValidationError(
                f"note catalog limit must be between 1 and {NOTE_CATALOG_MAX_LIMIT}"
            )
        snapshot = self.store.snapshot()
        catalog = _catalog(snapshot.files, self.store.project_id)
        cards = [
            _card(
                entry,
                reference=self._reference(snapshot.commit_id, entry, verify_history=False),
            )
            for entry in catalog.values()
        ]
        cards.sort(key=lambda card: (validate_note_id(str(card["note_id"]))[1], str(card["artifact_id"])))
        start = 0
        if after:
            matches = [index for index, card in enumerate(cards) if card["note_id"] == after]
            if len(matches) != 1:
                raise ArtifactValidationError(f"note catalog cursor does not match this project: {after!r}")
            start = matches[0] + 1
        total_count = len(cards)
        page = cards[start:start + limit]
        has_more = start + len(page) < total_count
        return {
            "notes": page,
            "artifact_commit": snapshot.commit_id,
            "limit": limit,
            "has_more": has_more,
            "next_cursor": page[-1]["note_id"] if has_more and page else None,
            "total_count": total_count,
            "sync": self._sync_state(snapshot.commit_id),
        }

    def _prior_create(
        self,
        event_id: str,
        commit_id: str,
        request_digest: str,
    ) -> dict[str, object]:
        catalog = self._catalog_at(commit_id)
        matches = [entry for entry in catalog.values() if entry["creation_event_id"] == event_id]
        if len(matches) != 1 or matches[0]["creation_request_sha256"] != request_digest:
            raise ArtifactEventCollision("note create event was already committed with different content")
        return self._read_entry(commit_id, matches[0], idempotent=True)

    def _catalog_at(self, commit_id: str) -> dict[str, dict[str, object]]:
        entries = self.store._tree_entries(commit_id)
        index = entries.get(".orchestrator/note-index.jsonl")
        content = self.store._cat_blob(index.oid) if index is not None else b""
        return _decode_catalog(content, self.store.project_id)

    def _document_at(self, commit_id: str, note_id: str) -> NoteDocument:
        entry = self.store._tree_entries(commit_id).get(_note_path(note_id))
        if entry is None:
            raise ArtifactEventCollision("prior note update does not contain the requested note")
        return _parse_document(self.store._cat_blob(entry.oid))

    def _currently_materialized(self, artifact_id: str) -> bool:
        snapshot = self.store.snapshot()
        entry = _catalog(snapshot.files, self.store.project_id).get(artifact_id)
        return bool(entry and entry.get("materialized") is True)

    def _read_entry(
        self,
        head: str,
        entry: Mapping[str, object],
        *,
        idempotent: bool,
    ) -> dict[str, object]:
        note_id = str(entry["note_id"])
        reference = self._reference(head, entry, verify_history=True)
        head = str(reference["catalog_commit"])
        content = self.store._cat_blob(str(reference["revision"]))
        materialized = entry.get("materialized") is True
        document = _parse_document(content)
        if (
            document.identity.note_id != note_id
            or document.identity.artifact_id != entry.get("artifact_id")
            or document.identity.project_id != self.store.project_id
        ):
            raise ArtifactIdentityError("note catalog identity disagrees with verified Markdown")
        return self._response(
            document,
            commit_id=head,
            idempotent=idempotent,
            materialized=materialized,
            reference=reference,
        )

    def _reference(
        self,
        head: str,
        entry: Mapping[str, object],
        *,
        verify_history: bool,
    ) -> dict[str, object]:
        note_id = str(entry["note_id"])
        path = _note_path(note_id)
        if entry.get("materialized") is True:
            tree_entry = self.store._tree_entries(head).get(path)
            if tree_entry is None:
                raise ArtifactValidationError(f"materialized note is missing: {note_id}")
            source_commit = head
            source_blob = tree_entry.oid
            verified = True
        else:
            source_commit = str(entry.get("source_commit") or "")
            source_blob = str(entry.get("source_blob") or "")
            verified = False
            if verify_history:
                ancestor = self.store._git(
                    "merge-base", "--is-ancestor", source_commit, self.store.artifact_ref,
                    allowed_statuses={0, 1, 128},
                )
                if ancestor.returncode != 0:
                    raise ArtifactValidationError("archived note source commit is not reachable")
                historical = self.store._tree_entries(source_commit).get(path)
                if historical is None or historical.oid != source_blob:
                    raise ArtifactValidationError("archived note source reference is invalid")
                verified = True
        return {
            "path": path,
            "artifact_ref": self.store.artifact_ref,
            "commit": source_commit,
            "revision": source_blob,
            "history_reference": f"{source_commit}:{path}",
            "verified": verified,
            "catalog_commit": head,
        }

    def _response(
        self,
        document: NoteDocument,
        *,
        commit_id: str,
        idempotent: bool,
        materialized: bool,
        reference: Mapping[str, object] | None = None,
    ) -> dict[str, object]:
        if reference is None:
            entry = self._catalog_at(commit_id).get(document.identity.artifact_id)
            if entry is None:
                raise ArtifactValidationError(
                    f"note catalog identity is missing: {document.identity.note_id}"
                )
            reference = self._reference(commit_id, entry, verify_history=True)
        markdown = render_note_document(document)
        return {
            "note": document.as_dict(),
            "markdown_base64": base64.b64encode(markdown).decode("ascii"),
            "materialized": materialized,
            "artifact_commit": commit_id,
            "reference": dict(reference),
            "idempotent": idempotent,
            "sync": self._sync_state(commit_id),
        }

    def _sync_state(self, head: str) -> dict[str, object]:
        current_head = self.store._head() or head
        config_entry = self.store._tree_entries(current_head).get(".orchestrator/config.toml")
        if config_entry is None:
            raise ArtifactValidationError("artifact note config is missing")
        config = _config({
            ".orchestrator/config.toml": self.store._cat_blob(config_entry.oid),
        })
        mode = str(config.get("remote_sync") or "local_only")
        if mode == "local_only":
            return {"mode": mode, "state": "local_only", "recovery": None}
        if mode == "paused":
            return {"mode": mode, "state": "pending", "recovery": "Artifact sync is paused."}
        try:
            cached = json.loads(self.store.project_state.joinpath("sync-state.json").read_text())
        except (OSError, json.JSONDecodeError, AttributeError):
            cached = {}
        state = str(cached.get("state") or "")
        if cached.get("local_head") != current_head:
            normalized = "pending"
        elif state == "clean" and cached.get("remote_head") == current_head:
            normalized = "synced"
        elif state == "clean":
            normalized = "pending"
        elif not state:
            normalized = "pending"
        elif state == "conflict":
            normalized = "conflict"
        elif state in {"ahead", "syncing", "retryable_offline", "retryable_auth", "remote_race"}:
            normalized = "pending"
        else:
            normalized = "failure"
        return {
            "mode": mode,
            "state": normalized,
            "recovery": cached.get("recovery"),
        }


def _parse_update(value: Mapping[str, object]) -> NoteUpdate:
    try:
        return NoteUpdate.from_mapping(value)
    except NoteContractError as error:
        raise ArtifactValidationError(str(error)) from error


def _note_update(
    identity: NoteIdentity,
    *,
    captured_at: str,
    recording_state: str,
    checkpoint_reason: str,
    segments: object,
    capture_ended_at: str | None,
) -> NoteUpdate:
    try:
        return NoteUpdate.from_values(
            identity=identity,
            captured_at=captured_at,
            recording_state=recording_state,
            checkpoint_reason=checkpoint_reason,
            raw_segments=segments,
            capture_ended_at=capture_ended_at,
        )
    except NoteContractError as error:
        raise ArtifactValidationError(str(error)) from error


def _validated_segment_payload(value: object) -> list[dict[str, object]]:
    if not isinstance(value, Sequence) or isinstance(value, (str, bytes)):
        raise ArtifactValidationError("note segments must be an array")
    result = []
    try:
        for raw in value:
            if not isinstance(raw, Mapping):
                raise NoteContractError("each note segment must be an object")
            result.append(NoteSegment.from_mapping(raw).as_dict())
    except NoteContractError as error:
        raise ArtifactValidationError(str(error)) from error
    return result


def _parse_document(content: bytes) -> NoteDocument:
    try:
        return parse_note_document(content)
    except NoteContractError as error:
        raise ArtifactValidationError(str(error)) from error


def _config(files: Mapping[str, bytes]) -> Mapping[str, object]:
    try:
        return tomllib.loads(files[".orchestrator/config.toml"].decode("utf-8"))
    except (KeyError, UnicodeDecodeError, tomllib.TOMLDecodeError) as error:
        raise ArtifactValidationError(f"artifact note config is invalid: {error}") from error


def _catalog(files: Mapping[str, bytes], project_id: str) -> dict[str, dict[str, object]]:
    return _decode_catalog(files.get(".orchestrator/note-index.jsonl", b""), project_id)


def _decode_catalog(content: bytes, project_id: str) -> dict[str, dict[str, object]]:
    try:
        return decode_note_index(content, project_id=project_id)
    except NoteContractError as error:
        raise ArtifactValidationError(str(error)) from error


def _next_note_number(
    config: Mapping[str, object],
    files: Mapping[str, bytes],
    catalog: Mapping[str, Mapping[str, object]],
) -> int:
    configured = config.get("next_note_id", 1)
    if not isinstance(configured, int) or isinstance(configured, bool) or configured <= 0:
        raise ArtifactValidationError("artifact config next_note_id must be a positive integer")
    issued = [validate_note_id(str(entry["note_id"]))[1] for entry in catalog.values()]
    for path in files:
        if path.startswith(".orchestrator/notes/") and path.endswith(".md"):
            issued.append(validate_note_id(PurePosixPath(path).stem)[1])
    return max(int(configured), max(issued, default=0) + 1)


def _set_next_note_id(content: bytes, next_note_id: int) -> bytes:
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ArtifactValidationError("artifact config is not UTF-8") from error
    rendered, count = re.subn(
        r"(?m)^next_note_id\s*=\s*[^\n]+$",
        f"next_note_id = {next_note_id}",
        text,
        count=1,
    )
    if count == 0:
        rendered = text.rstrip("\n") + f"\nnext_note_id = {next_note_id}\n"
    return rendered.encode("utf-8")


def _entry_for_identity(
    catalog: Mapping[str, Mapping[str, object]],
    identity: NoteIdentity,
) -> Mapping[str, object]:
    entry = catalog.get(identity.artifact_id)
    if (
        entry is None
        or entry.get("note_id") != identity.note_id
        or entry.get("project_id") != identity.project_id
    ):
        raise ArtifactIdentityError("note identity does not match the project catalog")
    return entry


def _card(
    entry: Mapping[str, object],
    *,
    reference: Mapping[str, object],
) -> dict[str, object]:
    return {
        "note_id": entry["note_id"],
        "artifact_id": entry["artifact_id"],
        "project_id": entry["project_id"],
        "created_at": entry["created_at"],
        "updated_at": entry["updated_at"],
        "recording_state": entry["recording_state"],
        "segment_count": entry["segment_count"],
        "materialized": entry["materialized"],
        "archived_at": entry.get("archived_at"),
        "reference": dict(reference),
        "metadata": entry.get("metadata"),
    }


def _note_path(note_id: str) -> str:
    return f".orchestrator/notes/{note_id}.md"


def _event_id(kind: str, request_id: str) -> str:
    raw = str(request_id or "").strip()
    if not _REQUEST_ID_RE.fullmatch(raw):
        raise ArtifactValidationError("note request_id must be 1 to 120 safe characters")
    return f"note-{kind}:{raw}"


def _digest(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _validate_provider(provider: str | None) -> None:
    if provider not in {None, "codex", "claude"}:
        raise ArtifactValidationError(f"unsupported provider metadata: {provider!r}")


__all__ = ["ProjectNoteManager"]
