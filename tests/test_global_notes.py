import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch

from services.global_notes import GlobalNoteLibrary
from tests import test_project_notes as fixtures

CREATED = fixtures.CREATED


class GlobalNoteTests(unittest.TestCase):
    def setUp(self):
        self.legacy = fixtures.ProjectNoteTests()
        self.legacy.setUp()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.library = GlobalNoteLibrary(self.root, 'global-tests',
                                         lambda: [(str(self.legacy.repo), self.legacy.manager)])

    def tearDown(self):
        self.legacy.tearDown()
        self.temp.cleanup()

    def create_global(self, request='global'):
        return self.library.manager.create(
            request_id=request, created_at=CREATED, capture_started_at=CREATED,
            captured_at=CREATED, recording_state='completed', checkpoint_reason='complete',
            capture_ended_at=CREATED, segments=[],
        )

    def test_global_recording_needs_no_registered_project(self):
        self.library.sources = lambda: []
        saved = self.create_global()
        identity = saved['note']['identity']
        self.assertEqual(identity['project_id'], 'global-notes')
        self.assertEqual(identity['note_id'], 'RR-N1')
        self.assertTrue((self.root / 'notes' / saved['reference']['path']).is_file())
        reopened = GlobalNoteLibrary(self.root, 'new-device', lambda: [])
        self.assertEqual(len(reopened.list()['notes']), 1)
        self.assertEqual(reopened.manager.get(identity['artifact_id'])['note'], saved['note'])

    def test_import_archived_transcript_is_atomic_and_delete_does_not_resurrect(self):
        saved = self.legacy.completed_note()
        original = saved['note']
        identity = original['identity']
        self.legacy.manager.archive(note_id=identity['note_id'], artifact_id=identity['artifact_id'],
                                    request_id='archive', archived_at=CREATED)
        source_head = self.legacy.store._head()
        with ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda _: self.library.list(), range(2)))
        cards = self.library.list()['notes']
        self.assertEqual(len(cards), 1)
        imported = self.library.manager.get(identity['artifact_id'])['note']
        self.assertEqual(imported['segments'], original['segments'])
        self.assertEqual(imported['metadata'], original['metadata'])
        self.assertEqual(imported['identity']['note_id'], identity['note_id'])
        self.assertEqual(self.legacy.store._head(), source_head)
        self.library.manager.delete(note_id=cards[0]['note_id'], artifact_id=cards[0]['artifact_id'], request_id='delete')
        restarted = GlobalNoteLibrary(self.root, 'restart', self.library.sources)
        self.assertEqual(restarted.list()['notes'], [])

    def test_colliding_display_ids_are_reallocated_without_losing_notes(self):
        original = self.legacy.completed_note()['note']
        self.library.manager.import_saved_note(original)
        other = {**original, 'identity': {**original['identity'], 'project_id': 'other-project',
                                         'artifact_id': 'note-other-artifact'}}
        self.library.manager.import_saved_note(other)
        cards = self.library.list()['notes']
        self.assertEqual(len(cards), 2)
        self.assertEqual(len({row['note_id'] for row in cards}), 2)
        self.assertEqual(len({row['artifact_id'] for row in cards}), 2)
        next_note = self.create_global()['note']['identity']['note_id']
        self.assertNotIn(next_note, {row['note_id'] for row in cards})

    def test_global_codes_survive_cross_project_collisions_restart_and_deletion(self):
        original = self.legacy.completed_note()['note']
        other = {**original, 'identity': {**original['identity'], 'note_id': 'OTHER-N1',
                                         'project_id': 'other', 'artifact_id': 'note-other'}}
        self.library.manager.import_saved_note(original)
        self.library.manager.import_saved_note(other)
        cards = self.library.list()['notes']
        codes = {card['artifact_id']: card['global_code'] for card in cards}
        self.assertEqual(set(codes.values()), {'N1', 'N2'})
        reopened = GlobalNoteLibrary(self.root, 'restarted', self.library.sources)
        self.assertEqual({c['artifact_id']: c['global_code'] for c in reopened.list()['notes']}, codes)
        self.assertEqual(reopened.manager.get('N2')['note']['identity']['artifact_id'], 'note-other')
        removed = next(card for card in cards if card['global_code'] == 'N2')
        reopened.manager.delete(note_id=removed['note_id'], artifact_id=removed['artifact_id'], request_id='remove')
        self.create_global('after-delete')
        self.assertEqual({c['global_code'] for c in self.library.list()['notes']}, {'N1', 'N3'})

    def test_existing_catalog_gets_unique_codes_without_changing_note_content(self):
        from services.artifact_store import ArtifactMutation, NoteIndexWrite
        from services.note_contract import decode_note_index, encode_note_index

        original = self.legacy.completed_note()['note']
        self.library.manager.import_saved_note(original)
        other = {**original, 'identity': {**original['identity'], 'note_id': 'OTHER-N1',
                                         'project_id': 'other', 'artifact_id': 'note-other'}}
        self.library.manager.import_saved_note(other)
        store = self.library.manager.store
        snapshot = store.snapshot()
        catalog = decode_note_index(snapshot.files['.orchestrator/note-index.jsonl'], project_id=store.project_id)
        for row in catalog.values():
            del row['global_code']
        store.mutate(ArtifactMutation(
            event_id='pre-codes-fixture', actor_type='system', device_id='test',
            expected_base=snapshot.commit_id,
            operations=(NoteIndexWrite(encode_note_index(catalog, project_id=store.project_id)),),
            summary='Simulate existing global catalog',
        ))
        before = {key: value for key, value in snapshot.files.items() if key.endswith('.md')}
        reopened = GlobalNoteLibrary(self.root, 'upgrade', lambda: [])
        cards = reopened.list()['notes']
        self.assertEqual(len({c['global_code'] for c in cards}), 2)
        self.assertTrue(all(c['global_code'].startswith('N') for c in cards))
        after = reopened.manager.store.snapshot()
        self.assertEqual({key: value for key, value in after.files.items() if key.endswith('.md')}, before)
        head = after.commit_id
        GlobalNoteLibrary(self.root, 'again', lambda: []).list()
        self.assertEqual(store._head(), head)
        self.create_global('after-upgrade')
        self.assertEqual(len({c['global_code'] for c in self.library.list()['notes']}), 3)

    def test_unavailable_source_does_not_block_global_notes_and_recovers(self):
        class Unavailable:
            def list(self, **kwargs):
                raise OSError('offline')
        self.create_global()
        saved = self.legacy.completed_note()
        self.library.sources = lambda: [('offline', Unavailable()), (str(self.legacy.repo), self.legacy.manager)]
        self.assertEqual(len(self.library.list()['notes']), 2)
        self.assertIsNotNone(self.library.manager.get(saved['note']['identity']['artifact_id']))

    def test_unfinished_note_keeps_recovery_route_then_imports_when_saved(self):
        original = self.legacy.create('interrupted')['note']
        card = self.library.list()['notes'][0]
        self.assertEqual(card['repository_path'], str((self.root / 'notes').resolve()))
        self.assertEqual(card['project_id'], 'global-notes')
        self.assertEqual(card['legacy_recovery']['project_id'], original['identity']['project_id'])
        reopened = GlobalNoteLibrary(self.root, 'offline', lambda: [])
        self.assertEqual(len(reopened.list()['notes']), 1)
        self.assertEqual(reopened.manager.get(card['artifact_id'])['note']['segments'], original['segments'])
        update = {**original, 'recording_state': 'completed', 'checkpoint_reason': 'complete', 'capture_ended_at': CREATED}
        self.legacy.manager.update(request_id='finish', update=update)
        self.library._last_import = float('-inf')
        card = self.library.list()['notes'][0]
        self.assertEqual(card['project_id'], 'global-notes')
        self.assertEqual(card['repository_path'], str((self.root / 'notes').resolve()))

    def test_refresh_skips_unchanged_sources_and_restart_skips_completed_imports(self):
        self.legacy.completed_note()
        with patch.object(self.legacy.manager, 'get', wraps=self.legacy.manager.get) as reads:
            self.assertEqual(self.library.list()['total_count'], 1)
            self.assertEqual(reads.call_count, 1)
            self.library._last_import = float('-inf')
            self.assertEqual(self.library.list()['total_count'], 1)
            self.assertEqual(reads.call_count, 1)
            restarted = GlobalNoteLibrary(self.root, 'restart', self.library.sources)
            self.assertEqual(restarted.list()['total_count'], 1)
            self.assertEqual(reads.call_count, 1)

    def test_pagination_is_complete_and_rejects_stale_cursor(self):
        self.library.sources = lambda: []
        for i in range(3):
            self.create_global(str(i))
        first = self.library.list(limit=2)
        second = self.library.list(limit=2, after=first['next_cursor'])
        self.assertEqual(len(first['notes']) + len(second['notes']), 3)
        self.assertFalse(second['has_more'])
        self.create_global('later')
        with self.assertRaises(ValueError):
            self.library.list(limit=2, after=first['next_cursor'])
