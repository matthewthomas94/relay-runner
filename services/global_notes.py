"""Local, project-independent notes with resumable import of legacy catalogs."""
from __future__ import annotations

import base64
import hashlib
import json
import subprocess
import threading
import time
from pathlib import Path

try:
    from services.artifact_store import ArtifactStore, ArtifactMutation, ConfigWrite
    from services.project_notes import ProjectNoteManager
except ModuleNotFoundError:
    from artifact_store import ArtifactStore, ArtifactMutation, ConfigWrite
    from project_notes import ProjectNoteManager


class GlobalNoteLibrary:
    def __init__(self, state_root: Path, device_id: str, sources):
        self.root = Path(state_root)
        self.device_id = device_id
        self.sources = sources
        self._lock = threading.RLock()
        self._manager = None
        self._last_import = float('-inf')
        self._source_heads = {}

    @property
    def manager(self):
        with self._lock:
            if self._manager is None:
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
            cards = [{**card, 'repository_path': str(self.manager.store.repo_path)}
                     for card in self._all_cards(self.manager)]
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
            'sync': {'mode': 'local_only', 'state': 'local_only', 'recovery': None},
        }
