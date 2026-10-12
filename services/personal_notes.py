"""Global note API over the personal-file cache after verified Git migration.

The document/identity/checkpoint contract is shared with project notes. The small
SQLite catalog stores metadata and idempotency digests; transcript versions live
in the bounded personal-file cache and immutable private GitHub objects.
"""
from __future__ import annotations

import base64
import hashlib
import json
import uuid
from dataclasses import replace
from types import SimpleNamespace

try:
    from services.artifact_store import ArtifactEventCollision, ArtifactIdentityError, ArtifactValidationError
    from services.note_contract import (NoteDocument, NoteIdentity, NoteUpdate, metadata_for_update,
        note_source, parse_note_document, render_note_document, validate_note_metadata, validate_note_id, validate_timestamp)
    from services.project_notes import _card, _event_id, _note_update, _validated_segment_payload, _validate_provider, _digest
except ModuleNotFoundError:
    from artifact_store import ArtifactEventCollision, ArtifactIdentityError, ArtifactValidationError
    from note_contract import (NoteDocument, NoteIdentity, NoteUpdate, metadata_for_update,
        note_source, parse_note_document, render_note_document, validate_note_metadata, validate_note_id, validate_timestamp)
    from project_notes import _card, _event_id, _note_update, _validated_segment_payload, _validate_provider, _digest


class PersonalNoteManager:
    def __init__(self, storage, device_id, *, commit=True):
        self.storage = storage
        self.device_id = device_id
        self.db = storage.db
        self.lock = storage.lock
        self.store = SimpleNamespace(project_id="global-notes", repo_path=storage.files_root, _head=self.head)
        with self.lock:
            self.db.execute("CREATE TABLE IF NOT EXISTS personal_notes(artifact_id TEXT PRIMARY KEY, entry TEXT NOT NULL, deleted INTEGER NOT NULL DEFAULT 0)")
            self.db.execute("CREATE TABLE IF NOT EXISTS personal_note_events(event_id TEXT PRIMARY KEY, digest TEXT NOT NULL, artifact_id TEXT NOT NULL, revision TEXT NOT NULL)")
            if commit:
                self.db.commit()

    def import_remote_entry(self, entry, *, commit=True):
        with self.lock:
            if entry.get('project_id') != 'global-notes' or not isinstance(entry.get('global_code'), str):
                raise ArtifactIdentityError('Remote note catalog has an invalid global identity')
            validate_note_id(entry['note_id'])
            for row in self.db.execute('SELECT entry FROM personal_notes WHERE deleted=0'):
                local = json.loads(row[0])
                if local['artifact_id'] != entry['artifact_id'] and (local['note_id'] == entry['note_id'] or local.get('global_code') == entry['global_code']):
                    raise ArtifactIdentityError('Remote note code collides with another note; both histories are preserved')
            copied = {**entry, 'path': 'notes/' + entry['note_id'] + '.md', 'legacy_recovery': None}
            copied.pop('deleted', None)
            self.db.execute('INSERT OR REPLACE INTO personal_notes VALUES(?,?,?)', (entry['artifact_id'], json.dumps(copied), int(entry.get('deleted', False))))
            if commit:
                self.db.commit()

    def ensure_global_codes(self):
        return None

    def head(self):
        with self.lock:
            return _digest([tuple(row) for row in self.db.execute("SELECT artifact_id,entry,deleted FROM personal_notes ORDER BY artifact_id")])

    def _entry(self, identity, *, include_deleted=False):
        rows = self.db.execute("SELECT entry,deleted FROM personal_notes").fetchall()
        matches = []
        for row in rows:
            entry = json.loads(row[0])
            if identity in (entry["artifact_id"], entry["note_id"], entry.get("global_code")) and (include_deleted or not row[1]):
                matches.append(entry)
        if len(matches) != 1:
            raise ArtifactValidationError("No unique global note matches this identity")
        return matches[0]

    def _document(self, entry, revision=None):
        return parse_note_document(self.storage.read(entry["artifact_id"], revision))

    def _reference(self, entry, revision=None):
        ref = self.storage.reference(entry["artifact_id"], revision)
        local = ref["local_path"]
        path = str(self.storage.root.joinpath(local).relative_to(self.storage.files_root)) if local else entry["path"]
        return {"path": path, "artifact_ref": "personal/files", "commit": ref["remote_commit"] or ref["sha256"],
                "revision": ref["remote_blob"] or ref["sha256"], "history_reference": ref["sha256"],
                "verified": bool(ref["materialized"] or ref["remote_commit"]), "catalog_commit": self.head(),
                "personal_file_id": entry["artifact_id"], "sha256": ref["sha256"]}

    def _response(self, entry, *, revision=None, idempotent=False):
        document = self._document(entry, revision)
        reference = self._reference(entry, revision)
        state = self.storage.status()
        return {"note": document.as_dict(), "markdown_base64": base64.b64encode(render_note_document(document)).decode(),
                "materialized": not bool(entry.get("archived_at")), "artifact_commit": self.head(),
                "reference": reference, "idempotent": idempotent,
                "sync": {"mode": "enabled" if state["connected"] else "local_only", "state": state["state"], "recovery": state["message"]}}

    def _next_number(self):
        return self.storage._get("next_personal_note_id", 1)

    def _save(self, entry, document, event_id, digest):
        existing = self.db.execute("SELECT digest,artifact_id,revision FROM personal_note_events WHERE event_id=?", (event_id,)).fetchone()
        if existing:
            if existing["digest"] != digest or existing["artifact_id"] != entry["artifact_id"]:
                raise ArtifactEventCollision("Note request was already used with different content")
            return self._response(entry, revision=existing["revision"], idempotent=True)
        ref = self.storage.put(entry["artifact_id"], "notes/" + entry["note_id"] + ".md", render_note_document(document),
                               category="notes", metadata={"note_entry": entry}, active=document.update.recording_state != "completed", commit=False)
        self.db.execute("INSERT OR REPLACE INTO personal_notes VALUES(?,?,0)", (entry["artifact_id"], json.dumps(entry)))
        self.db.execute("INSERT INTO personal_note_events VALUES(?,?,?,?)", (event_id, digest, entry["artifact_id"], ref["sha256"]))
        self.db.commit()
        return self._response(entry)

    def import_catalog_entry(self, entry, document):
        """Migration preserves note codes, paths, event keys and immutable identity."""
        with self.lock:
            row = self.db.execute("SELECT entry FROM personal_notes WHERE artifact_id=?", (entry["artifact_id"],)).fetchone()
            if row and json.loads(row[0]) == {**entry, "path": "notes/" + entry["note_id"] + ".md"}:
                return
            copied = {**entry, "path": "notes/" + entry["note_id"] + ".md"}
            self._save(copied, document, "migration:" + entry["artifact_id"] + ":" + _digest(document.as_dict()), _digest(document.as_dict()))
            # Existing create requests still return their original identity after compaction.
            creation = entry.get("creation_event_id")
            if creation and entry.get("creation_request_sha256"):
                ref = self.storage.reference(entry["artifact_id"])
                self.db.execute("INSERT OR IGNORE INTO personal_note_events VALUES(?,?,?,?)",
                                (creation, entry["creation_request_sha256"], entry["artifact_id"], ref["sha256"]))
            self.storage._set("next_personal_note_id", max(self._next_number(), validate_note_id(entry["note_id"])[1] + 1,
                                                          int(entry.get("global_code", "N0")[1:]) + 1))
            self.db.commit()

    def import_git_events(self, manager, current_ids):
        """Preserve retry receipts and deletion/import tombstones before pruning."""
        with self.lock:
            history = manager.store._git('log', '--reverse', '--format=%H%x1f%B%x1e', manager.store.artifact_ref).stdout
            for record in history.split('\x1e'):
                if '\x1f' not in record:
                    continue
                commit, message = record.strip().split('\x1f', 1)
                event = next((line.removeprefix('Relay-Event-ID: ') for line in message.splitlines() if line.startswith('Relay-Event-ID: ')), '')
                if not event.startswith(('note-create:', 'note-update:', 'note-import:', 'note-import-update:')):
                    continue
                catalog = manager._catalog_at(commit)
                entries = [entry for entry in catalog.values() if entry.get('last_event_id') == event or entry.get('creation_event_id') == event]
                for entry in entries:
                    if self.db.execute('SELECT 1 FROM personal_note_events WHERE event_id=?', (event,)).fetchone():
                        continue
                    source = manager._read_entry(commit, entry, idempotent=True)
                    document = parse_note_document(base64.b64decode(source['markdown_base64']))
                    ref = self.storage.put(entry['artifact_id'], 'notes/' + entry['note_id'] + '.md', render_note_document(document),
                                           category='notes', metadata={'note_entry': entry})
                    digest = entry['creation_request_sha256'] if event.startswith(('note-create:', 'note-import:')) else _digest(document.update.as_dict())
                    self.db.execute('INSERT INTO personal_note_events VALUES(?,?,?,?)', (event, digest, entry['artifact_id'], ref['sha256']))
                    self.db.execute('INSERT OR IGNORE INTO personal_notes VALUES(?,?,?)',
                                    (entry['artifact_id'], json.dumps({**entry, 'path': 'notes/' + entry['note_id'] + '.md'}), int(entry['artifact_id'] not in current_ids)))
            self.db.commit()

    def import_saved_note(self, source, *, repository_path=None):
        original = NoteUpdate.from_mapping(source)
        event = "note-import:" + _digest(original.identity.as_dict())
        with self.lock:
            prior = self.db.execute("SELECT artifact_id FROM personal_note_events WHERE event_id=?", (event,)).fetchone()
            if prior:
                deleted = self.db.execute("SELECT deleted FROM personal_notes WHERE artifact_id=?", (original.identity.artifact_id,)).fetchone()
                if not deleted or deleted[0]:
                    return
                existing = self._entry(original.identity.artifact_id)
                if existing["recording_state"] == "completed" or existing["creation_request_sha256"] == _digest(source):
                    return
                number = int(existing["global_code"][1:])
                note_id = existing["note_id"]
                event = "note-import-update:" + _digest(source)
            else:
                number = self._next_number()
                note_id = original.identity.note_id
                if any(json.loads(row[0])["note_id"] == note_id for row in self.db.execute("SELECT entry FROM personal_notes")):
                    note_id = f"RR-N{number}"
            identity = replace(original.identity, project_id="global-notes", note_id=note_id)
            update = replace(original, identity=identity)
            document = NoteDocument(identity, update, source.get("metadata"))
            entry = self._new_entry(identity, update, event, _digest(source), document.metadata, number)
            entry["legacy_recovery"] = {"repository_path": repository_path, "project_id": original.identity.project_id,
                                         "note_id": original.identity.note_id} if repository_path and update.recording_state != "completed" else None
            self.storage._set("next_personal_note_id", max(self._next_number(), number + 1, validate_note_id(note_id)[1] + 1))
            self._save(entry, document, event, _digest(source))

    @staticmethod
    def _new_entry(identity, update, event, digest, metadata, number):
        return {"schema_version": 1, "global_code": f"N{number}", "note_id": identity.note_id,
                "artifact_id": identity.artifact_id, "project_id": identity.project_id,
                "path": "notes/" + identity.note_id + ".md", "created_at": identity.created_at,
                "updated_at": update.captured_at, "recording_state": update.recording_state,
                "segment_count": len(update.segments), "materialized": True,
                "creation_event_id": event, "last_event_id": event, "creation_request_sha256": digest,
                "metadata": metadata, "legacy_recovery": None}

    def create(self, *, request_id, created_at, capture_started_at, captured_at, recording_state,
               checkpoint_reason, segments, capture_ended_at=None, provider=None):
        _validate_provider(provider)
        event = _event_id("create", request_id)
        raw_segments = _validated_segment_payload(segments)
        # Match the legacy request digest so retries spanning migration remain safe.
        payload = {"created_at": created_at, "capture_started_at": capture_started_at, "captured_at": captured_at,
                   "recording_state": recording_state, "checkpoint_reason": checkpoint_reason,
                   "segments": raw_segments, "capture_ended_at": capture_ended_at}
        digest = _digest(payload)
        with self.lock:
            prior = self.db.execute("SELECT * FROM personal_note_events WHERE event_id=?", (event,)).fetchone()
            if prior:
                if prior["digest"] != digest:
                    raise ArtifactEventCollision("Note create request was already used with different content")
                return self._response(self._entry(prior["artifact_id"], include_deleted=True), revision=prior["revision"], idempotent=True)
            number = self._next_number()
            artifact = "note-" + hashlib.sha256(f"global-notes:{event}".encode()).hexdigest()[:40]
            identity = NoteIdentity.from_mapping({"note_id": f"RR-N{number}", "artifact_id": artifact, "project_id": "global-notes",
                                                  "created_at": created_at, "capture_started_at": capture_started_at})
            update = _note_update(identity, captured_at=captured_at, recording_state=recording_state,
                                  checkpoint_reason=checkpoint_reason, segments=raw_segments, capture_ended_at=capture_ended_at)
            document = NoteDocument(identity, update, metadata_for_update(update))
            entry = self._new_entry(identity, update, event, digest, document.metadata, number)
            self.storage._set("next_personal_note_id", number + 1)
            return self._save(entry, document, event, digest)

    def update(self, *, request_id, update, provider=None):
        _validate_provider(provider)
        desired = NoteUpdate.from_mapping(update)
        event = _event_id("update", request_id)
        with self.lock:
            entry = self._entry(desired.identity.artifact_id)
            current = self._document(entry)
            if current.identity != desired.identity:
                raise ArtifactIdentityError("Note update cannot change immutable identity")
            if entry.get("archived_at"):
                raise ArtifactValidationError("Restore the archived note before updating it")
            document = NoteDocument(current.identity, desired, metadata_for_update(desired, current.metadata))
            entry.update(updated_at=desired.captured_at, recording_state=desired.recording_state,
                         segment_count=len(desired.segments), metadata=document.metadata, last_event_id=event)
            return self._save(entry, document, event, _digest(desired.as_dict()))

    def publish_metadata(self, *, identity, source_sha256, metadata, expected_metadata):
        metadata = validate_note_metadata(metadata)
        with self.lock:
            try:
                entry = self._entry(identity.artifact_id)
            except ArtifactValidationError:
                return False
            if entry.get("archived_at"):
                return False
            current = self._document(entry)
            if (current.identity != identity or note_source(current.update)[1] != source_sha256
                    or current.metadata != expected_metadata or (current.metadata or {}).get("origin") == "manual"):
                return False
            if metadata.get("source_sha256") != source_sha256:
                raise ArtifactValidationError("Note metadata does not match the source transcript")
            entry["metadata"] = metadata
            self._save(entry, NoteDocument(identity, current.update, metadata), _event_id("metadata", uuid.uuid4().hex), _digest(metadata))
            return True

    def delete(self, *, note_id, artifact_id, request_id):
        _event_id("delete", request_id)
        with self.lock:
            try:
                entry = self._entry(artifact_id)
            except ArtifactValidationError:
                return {"deleted": True}
            if entry["note_id"] != note_id:
                raise ArtifactIdentityError("Note delete identity does not match the catalog")
            if entry["recording_state"] != "completed":
                raise ArtifactValidationError("Stop and save this note before deleting it")
            self.db.execute("UPDATE personal_notes SET deleted=1 WHERE artifact_id=?", (artifact_id,))
            if self.storage._get("connected"):
                self.storage._set("state", "pending")
            self.db.commit()
            return {"deleted": True}

    def archive(self, *, note_id, artifact_id, archived_at, request_id, provider=None):
        _validate_provider(provider)
        validate_timestamp(archived_at, "archived_at")
        with self.lock:
            entry = self._entry(artifact_id)
            if entry["note_id"] != note_id:
                raise ArtifactIdentityError("Note archive identity does not match the catalog")
            if entry["recording_state"] != "completed":
                raise ArtifactValidationError("Stop and save this note before archiving it")
            document = self._document(entry)
            entry.update(archived_at=archived_at, materialized=False)
            return self._save(entry, document, _event_id("archive", request_id), _digest({"artifact_id": artifact_id, "archived_at": archived_at}))

    def get(self, identity):
        with self.lock:
            return self._response(self._entry(identity), idempotent=True)

    def list(self, *, limit=50, after=None):
        if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
            raise ArtifactValidationError("Note catalog limit must be between 1 and 100")
        with self.lock:
            entries = [json.loads(row[0]) for row in self.db.execute("SELECT entry FROM personal_notes WHERE deleted=0")]
            entries.sort(key=lambda entry: (validate_note_id(entry["note_id"])[1], entry["artifact_id"]))
            start = 0
            if after:
                matches = [i for i, entry in enumerate(entries) if entry["note_id"] == after]
                if len(matches) != 1:
                    raise ArtifactValidationError("Unknown note catalog cursor")
                start = matches[0] + 1
            page = entries[start:start + limit]
            cards = []
            for entry in page:
                ref = self.storage.reference(entry["artifact_id"])
                card = _card(entry, reference=self._reference(entry))
                card["materialized"] = ref["materialized"] and not bool(entry.get("archived_at"))
                cards.append(card)
            more = start + len(page) < len(entries)
            state = self.storage.status()
            return {"notes": cards, "artifact_commit": self.head(), "limit": limit, "has_more": more,
                    "next_cursor": page[-1]["note_id"] if more and page else None, "total_count": len(entries),
                    "sync": {"mode": "enabled" if state["connected"] else "local_only", "state": state["state"], "recovery": state["message"]}}
