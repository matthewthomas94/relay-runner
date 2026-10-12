"""Local, project-independent notes with resumable import of legacy catalogs."""
from __future__ import annotations

import base64
import hashlib
import json
import re
import subprocess
import shutil
import threading
import time
import uuid
from pathlib import Path

try:
    from services.artifact_store import ArtifactStore, ArtifactMutation, ConfigWrite
    from services.project_notes import ProjectNoteManager
    from services.personal_notes import PersonalNoteManager
    from services.note_contract import decode_note_index, parse_note_document
except ModuleNotFoundError:
    from artifact_store import ArtifactStore, ArtifactMutation, ConfigWrite
    from project_notes import ProjectNoteManager
    from personal_notes import PersonalNoteManager
    from note_contract import decode_note_index, parse_note_document


class GlobalNoteLibrary:
    def __init__(self, state_root: Path, device_id: str, sources):
        self.root = Path(state_root)
        self.device_id = device_id
        self.sources = sources
        self._lock = threading.RLock()
        self._manager = None
        self._last_import = float('-inf')
        self._source_heads = {}
        self.personal_storage = None

    @property
    def manager(self):
        with self._lock:
            if self._manager is None:
                if self.personal_storage is not None and self.personal_storage._get('notes_migrated', False):
                    self._manager = PersonalNoteManager(self.personal_storage, self.device_id)
                    return self._manager
                repo = self.root / 'notes'
                repo.mkdir(parents=True, exist_ok=True)
                if not (repo / '.git').exists():
                    subprocess.run(['git', 'init', '--quiet', str(repo)], check=True,
                                   capture_output=True, timeout=10)
                store = ArtifactStore(repo, 'global-notes', self.root, enabled=True)
                store.initialize(device_id=self.device_id)
                snapshot = store.snapshot()
                config = snapshot.files['.orchestrator/config.toml']
                if b'prefix = "NOT"' in config:
                    store.mutate(ArtifactMutation(
                        event_id='global-notes-config', actor_type='system', device_id=self.device_id,
                        expected_base=snapshot.commit_id,
                        operations=(ConfigWrite(config.replace(b'prefix = "NOT"', b'prefix = "RR"')),),
                        summary='Configure global notes',
                    ))
                manager = ProjectNoteManager(store, device_id=self.device_id)
                manager.ensure_global_codes()
                self._manager = manager
            return self._manager

    def prepare_personal_storage(self, storage):
        """Stage notes and their old Git history only for an explicit sync flow.

        This does not upload or remove anything. Recording/paused notes postpone
        migration so the recorder never changes writers mid-capture.
        """
        with self._lock:
            if storage._get('notes_migrated', False):
                return
            manager = self.manager
            with manager.store._writer_lock():
                snapshot = manager.store.snapshot()
                catalog = decode_note_index(snapshot.files.get('.orchestrator/note-index.jsonl', b''), project_id='global-notes')
                if any(row['recording_state'] != 'completed' for row in catalog.values()):
                    return
                candidate = PersonalNoteManager(storage, self.device_id)
                candidate.import_git_events(manager, set(catalog))
                for entry in catalog.values():
                    source = manager.get(entry['artifact_id'])
                    candidate.import_catalog_entry(entry, parse_note_document(base64.b64decode(source['markdown_base64'])))
                # The exact old graph is archived before reclaiming any .git data.
                # A bundle contains only objects/refs, never Git credentials/config.
                bundle = storage.support_root / ('notes-history-' + uuid.uuid4().hex + '.bundle')
                try:
                    subprocess.run(['git', '-C', str(manager.store.repo_path), 'bundle', 'create', str(bundle), '--all'],
                                   check=True, capture_output=True, timeout=120)
                    subprocess.run(['git', '-C', str(manager.store.repo_path), 'bundle', 'verify', str(bundle)],
                                   check=True, capture_output=True, timeout=120)
                    storage.put('legacy-global-notes-history', 'history/global-notes.bundle', bundle.read_bytes(),
                                category='history', metadata={'legacy_note_head': snapshot.commit_id})
                finally:
                    bundle.unlink(missing_ok=True)
                storage._set('notes_migration_head', snapshot.commit_id)
                storage._set('next_personal_note_id', max(candidate._next_number(),
                    int(re.search(r'next_note_id\s*=\s*(\d+)', snapshot.files['.orchestrator/config.toml'].decode())[1])
                    if b'next_note_id' in snapshot.files['.orchestrator/config.toml'] else 1))
                storage.db.commit()

    def finalize_personal_storage(self, storage):
        """Switch only after every migrated version and the bundle have proof."""
        with self._lock:
            if storage._get('notes_migrated', False):
                pending = storage._get('notes_migration_cleanup')
                if pending:
                    repo = Path(pending)
                    if repo.exists():
                        if repo.resolve() != (self.root / 'notes').resolve() or repo.is_symlink():
                            raise ValueError('Unexpected legacy notes cleanup location; content preserved')
                        with storage.lock:
                            reference = storage.reference('legacy-global-notes-history')
                            storage._verify_remote(reference, storage._validate_destination())
                            head = subprocess.run(['git', '-C', str(repo), 'rev-parse', 'refs/heads/relay/artifacts'],
                                                  check=True, capture_output=True, text=True, timeout=10).stdout.strip()
                            if head != storage._get('notes_migration_head'):
                                raise ValueError('Legacy notes changed since archival; content preserved')
                            if any(path.name not in ('.git', '.orchestrator') for path in repo.iterdir()):
                                raise ValueError('Legacy notes folder contains other files; content preserved')
                            shutil.rmtree(repo)
                    storage._set('notes_migration_cleanup', None)
                    storage.db.commit()
                return
            expected = storage._get('notes_migration_head')
            if not expected or not storage._get('connected'):
                return
            manager = self.manager
            with manager.store._writer_lock():
                if manager.store._head() != expected:
                    return
                rows = storage.db.execute("SELECT artifact_id,sha256 FROM versions v JOIN files f USING(artifact_id) WHERE f.category IN ('notes','history')").fetchall()
                destination = storage._validate_destination()
                for row in rows:
                    reference = storage.reference(row['artifact_id'], row['sha256'])
                    if not reference['remote_commit']:
                        return
                    storage._verify_remote(reference, destination)
                repo = manager.store.repo_path
                if repo != (self.root / 'notes').resolve() or repo.is_symlink():
                    raise ValueError('Unexpected legacy notes repository location; history preserved')
                if any(path.name not in ('.git', '.orchestrator') for path in repo.iterdir()):
                    raise ValueError('Legacy notes folder contains other files; history preserved')
                # Set the writer transition durably first. A crash now leaves a
                # harmless protected old folder, never an empty notes library.
                storage._set('notes_migrated', True)
                storage._set('notes_migration_cleanup', str(repo))
                storage.db.commit()
                self._manager = PersonalNoteManager(storage, self.device_id)
                shutil.rmtree(repo)
                storage._set('notes_migration_cleanup', None)
                storage.db.commit()

    def import_legacy(self):
        with self._lock:
            if time.monotonic() - self._last_import < 30:
                return
            manager = self.manager
            completed = {card['artifact_id'] for card in self._all_cards(manager)
                         if card['recording_state'] == 'completed'}
            for repo_path, source in self.sources():
                try:
                    store = getattr(source, 'store', None)
                    head = store._head() if store is not None else None
                    if head is not None and self._source_heads.get(repo_path) == head:
                        continue
                    cards = self._all_cards(source)
                    imported_all = True
                    for card in cards:
                        if card['artifact_id'] in completed:
                            continue
                        try:
                            manager.import_saved_note(source.get(card['artifact_id'])['note'], repository_path=repo_path)
                        except Exception:
                            # One unreadable note cannot hide the other notes.
                            imported_all = False
                    if imported_all and head is not None:
                        self._source_heads[repo_path] = head
                except Exception:
                    # Global copies remain readable while a source is offline.
                    continue
            self._last_import = time.monotonic()

    @staticmethod
    def _all_cards(manager):
        cards, after = [], None
        while True:
            page = manager.list(limit=100, after=after)
            cards.extend(page['notes'])
            if not page['has_more']:
                return cards
            after = page['next_cursor']

    def list(self, *, limit=50, after=None):
        limit = max(1, min(int(limit), 100))
        self.import_legacy()
        with self._lock:
            # This is the global API route sentinel, independent of cache/writer location.
            cards = [{**card, 'repository_path': str((self.root / 'notes').resolve())}
                     for card in self._all_cards(self.manager)]
            sync = {'mode': 'local_only', 'state': 'local_only', 'recovery': None}
            if self.personal_storage is not None and self.personal_storage._get('notes_migrated', False):
                state = self.personal_storage.status()
                sync = {'mode': 'enabled' if state['connected'] else 'local_only',
                        'state': state['state'], 'recovery': state['message']}
        cards.sort(key=lambda row: (row['created_at'], row['artifact_id']), reverse=True)
        digest = hashlib.sha256(json.dumps(cards, sort_keys=True).encode()).hexdigest()
        offset = 0
        if after:
            try:
                cursor = json.loads(base64.urlsafe_b64decode(after))
                if cursor['digest'] != digest:
                    raise ValueError('Notes changed while paging; retry the catalog')
                offset = int(cursor['offset'])
                if offset < 0 or offset > len(cards):
                    raise ValueError('Invalid note cursor')
            except (KeyError, TypeError, json.JSONDecodeError) as error:
                raise ValueError('Invalid note cursor') from error
        end = offset + limit
        return {
            'notes': cards[offset:end], 'artifact_commit': digest, 'limit': limit,
            'has_more': end < len(cards), 'total_count': len(cards),
            'next_cursor': base64.urlsafe_b64encode(json.dumps({'digest': digest, 'offset': end}).encode()).decode() if end < len(cards) else None,
            'sync': sync,
        }
