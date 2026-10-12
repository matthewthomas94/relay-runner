from __future__ import annotations

import hashlib
import io
import json
import os
from pathlib import Path
import shlex
import sqlite3
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'services'))
sys.modules.setdefault('numpy', types.SimpleNamespace(asarray=lambda samples: samples, int16=object()))
from intent_inbox import IntentInbox
from provider_turn_broker import ProviderTurnBroker
import relay_completion_hook as hook
import relay_authorization as auth
import voice_bridge


class ContextContinuationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.database = str(self.root / 'inbox.sqlite3')
        self.projection = str(self.root / 'turns-v2.json')
        self.turns = str(self.root / 'turns.json')
        self.ledger = str(self.root / 'authorizations.json')
        self.inbox = IntentInbox(self.database, provider_turn_projection_path=self.projection)
        self.broker = ProviderTurnBroker(self.database, projection_path=self.projection)
        self.addCleanup(self.inbox.close)
        self.addCleanup(self.broker.close)
        self.real_authority = hook.context_continuation_authority
        self.controls = []

    def authority(self, operation, source, **kwargs):
        return self.real_authority({'operation': operation, 'source': source, **kwargs}, database_path=self.database, authorization_path=self.ledger)

    def source(self, provider='codex', *, voice=False):
        self.record = dict(provider=provider, provider_session_id='source-transport', session_id='source-native',
            app_session_id='source-app', recovery_generation='source-generation', actor_role='foreground_pm',
            foreground_gate_handle='source-gate', turn_id='source-turn', origin='relay' if voice else 'manual', state='active', created_at=100.0)
        if voice:
            self.record.update(intent_id='original-intent', relay_command_seq=42, relay_command_id='original-voice')
            self.inbox.enqueue('public request in repo X', self.record, 'continue_current')
            with sqlite3.connect(self.database) as db:
                db.execute("UPDATE intents SET state='acked' WHERE intent_id='original-intent'")
            auth.record_command_authorization(self.ledger, {**self.record, 'action': 'create_ticket'}, relationship='replacement', now=100.0)
        else:
            self.record['manual_submission_id'] = 'typed-source'
        self.broker.activate(self.record, now=100.0)
        hook._activate_turn_record(self.turns, self.record, now=100.0)
        owner = {k: self.record[k] for k in ('provider', 'provider_session_id', 'app_session_id', 'recovery_generation', 'foreground_gate_handle')}
        owner['native_session_id'] = self.record['session_id']
        result = self.authority('capture', owner)
        self.assertEqual(result['status'], 'active')
        return result['source']

    def finish(self):
        state = 'completed_manual' if self.record['origin'] == 'manual' else 'completed_final'
        self.broker.transition(self.record, to_state=state, event_type='provider_completed', release_reason='provider_stop', now=101.0)
        hook._upsert_turn_record(self.turns, {**self.record, 'state': state}, now=101.0)

    def destination(self, provider):
        return dict(provider=provider, provider_session_id='destination-transport', native_session_id='destination-native',
            app_session_id='destination-app', recovery_generation='destination-generation', foreground_gate_handle='destination-gate')

    def submit(self, source, *, text='Implement Y in confirmed repo X.', actual_text=None, observed_at=102.0):
        owner = self.destination(source['provider'])
        evidence = {**owner, 'actor_role': 'foreground_pm', 'state': 'pending', 'submission_id': 'continuation-fixed-source-destination',
            'evidence_source': 'relay_terminal_manual_submit', 'observed_at': observed_at, 'continuation_source': source,
            'prompt_sha256': hashlib.sha256(text.encode()).hexdigest()}
        manual = self.root / 'manual.json'
        manual.write_text(json.dumps(evidence))
        payload = {'hook_event_name': 'UserPromptSubmit', 'provider': owner['provider'], 'provider_session_id': owner['provider_session_id'],
            'session_id': owner['native_session_id'], 'turn_id': 'destination-turn', 'prompt': actual_text or text}
        env = {'RELAY_RUNNER_PROVIDER': owner['provider'], 'RELAY_PROVIDER_SESSION_ID': owner['provider_session_id'],
            'RELAY_APP_SESSION_ID': owner['app_session_id'], 'RELAY_RECOVERY_GENERATION': owner['recovery_generation'],
            'RELAY_FOREGROUND_GATE_HANDLE': owner['foreground_gate_handle'], 'RELAY_ACTOR_ROLE': 'foreground_pm'}
        with mock.patch.dict(os.environ, env), mock.patch.object(hook, '_open_turn_broker', side_effect=lambda _: ProviderTurnBroker(self.database, projection_path=self.projection)), \
                mock.patch.object(hook, 'context_continuation_authority', side_effect=lambda r: self.real_authority(r, database_path=self.database, authorization_path=self.ledger)):
            handled = hook.handle_hook_payload(payload, claim_path=str(self.root/'claim.json'), state_path=str(self.root/'state.json'), turns_path=self.turns,
                manual_submissions_path=str(manual), write_control=lambda p: self.controls.append(p) or True, write_provider_event=lambda _: True,
                now=102.1, stderr=io.StringIO())
        return handled, owner, payload, env

    def test_typed_and_voice_sources_are_immutable_and_require_exact_current_identity(self):
        for voice in (False, True):
            with self.subTest(voice=voice):
                source = self.source(voice=voice)
                with sqlite3.connect(self.database) as db:
                    db.execute('UPDATE provider_turns SET updated_at=100.5')
                owner = {k: source[k] for k in ('provider', 'provider_session_id', 'native_session_id', 'app_session_id', 'recovery_generation', 'foreground_gate_handle')}
                self.assertEqual(self.authority('capture', owner)['source'], source)
                for field in owner:
                    self.assertEqual(self.authority('capture', {**owner, field: 'foreign'})['status'], 'blocked')
                self.finish()
                self.assertEqual(self.authority('check', source)['status'], 'ready')
                # Separate native identity for the next fixture in this same DB.
                with sqlite3.connect(self.database) as db:
                    db.execute('DELETE FROM provider_turns')
                    db.execute('DELETE FROM provider_turn_transitions')

    def test_ordered_both_provider_voice_handoff_ack_and_manual_final_do_not_replay_voice_final(self):
        for provider in ('codex', 'claude'):
            with self.subTest(provider=provider):
                source = self.source(provider, voice=True)
                self.assertEqual(self.authority('check', source)['status'], 'active')
                self.finish()
                handled, owner, payload, env = self.submit(source)
                self.assertTrue(handled)
                self.assertEqual(self.authority('ack', source, destination=owner, submission_id='wrong')['status'], 'waiting')
                for field in owner:
                    self.assertEqual(self.authority('ack', source, destination={**owner, field: 'foreign'}, submission_id='continuation-fixed-source-destination')['status'], 'waiting')
                self.assertEqual(self.authority('ack', source, destination=owner, submission_id='continuation-fixed-source-destination')['status'], 'consumed')
                dest = next(r for r in self.broker.table_records('provider_turns') if r['native_session_id'] == owner['native_session_id'])
                self.assertEqual((dest['origin'], dest['intent_id'], dest['command_seq'], dest['command_id']), ('manual', 'original-intent', 42, 'original-voice'))
                with mock.patch.dict(os.environ, env), mock.patch.object(hook, '_open_turn_broker', side_effect=lambda _: ProviderTurnBroker(self.database, projection_path=self.projection)):
                    self.assertFalse(hook.handle_hook_payload({**payload, 'hook_event_name': 'Stop', 'last_assistant_message': 'Y finished'},
                        claim_path=str(self.root/'claim.json'), state_path=str(self.root/'state.json'), turns_path=self.turns,
                        write_control=lambda p: self.controls.append(p) or True, now=103.0, stderr=io.StringIO()))
                self.assertEqual(self.controls, [], 'A distinct manual final must never publish/reset the original voice final')
                states = {r['native_session_id']: r['state'] for r in self.broker.table_records('provider_turns')}
                self.assertEqual(states['source-native'], 'completed_final')
                self.assertEqual(states['destination-native'], 'completed_manual')
                self.assertEqual(self.inbox.records()[0]['state'], 'acked')
                self.assertFalse((self.root/'claim.json').exists())
                with sqlite3.connect(self.database) as db:
                    db.execute('DELETE FROM provider_turns')
                    db.execute('DELETE FROM provider_turn_transitions')
                Path(self.turns).unlink()

    def test_hook_rejects_changed_prompt_expired_boundary_and_cancelled_parent_without_ack(self):
        source = self.source(voice=True)
        self.finish()
        self.assertFalse(self.submit(source, actual_text='Unrelated work')[0])
        self.assertFalse(self.submit(source, observed_at=80)[0])
        self.inbox.cancel_scoped({'intent_id': 'cancel', 'cancellation_scope': 'item', 'target_intent_ids': ['original-intent']})
        self.assertEqual(self.authority('check', source)['status'], 'blocked')
        self.assertFalse(self.submit(source)[0])
        self.assertEqual(len(self.broker.table_records('provider_turns')), 1)

    def test_parent_cancellation_after_destination_submit_blocks_authority_and_mutation(self):
        source = self.source(voice=True); self.finish()
        handled, owner, _, _ = self.submit(source)
        self.assertTrue(handled)
        self.inbox.cancel_scoped({'intent_id': 'cancel', 'cancellation_scope': 'item', 'target_intent_ids': ['original-intent']})
        auth.record_command_authorization(self.ledger, {'relay_command_seq': 43, 'relay_command_id': 'cancel', 'intent_id': 'cancel',
            'cancellation_scope': 'item', 'target_intent_ids': ['original-intent']}, relationship='cancel', now=103.0)
        self.assertEqual(self.authority('ack', source, destination=owner, submission_id='continuation-fixed-source-destination')['status'], 'blocked')
        with self.assertRaisesRegex(ValueError, 'revoked'):
            auth.validate_and_mark_mutation(self.ledger, 42, 'original-voice', {'kind':'orchestrator_action','action_kind':'create_ticket','ticket_id':'RR-9'}, relay_intent_id='original-intent')

    def test_new_typed_request_supersedes_but_voice_continue_preserves_original_parent(self):
        source = self.source(voice=True); self.finish()
        next_record = {**self.record, 'turn_id':'next-native', 'intent_id':'continue-intent', 'relay_command_seq':43, 'relay_command_id':'continue', 'created_at':102.0}
        self.broker.activate(next_record, now=102.0)
        self.assertEqual(self.authority('check', source)['status'], 'ready')
        self.broker.activate({**next_record, 'turn_id':'new-manual', 'origin':'manual', 'created_at':103.0}, now=103.0)
        self.assertEqual(self.authority('check', source)['status'], 'blocked')

    def test_clean_launchd_and_fallback_forward_general_scope_for_both_providers(self):
        source = (Path(__file__).resolve().parents[1] / 'scripts/relay-bridge').read_text()
        functions = []
        for name in ('voice_bridge_log_path', 'start_voice_bridge_daemon'):
            start = source.index(f'{name}() {{')
            functions.append(source[start:source.index('\n}\n', start) + 3])
        for provider in ('codex', 'claude'):
            for fallback in (False, True):
                with self.subTest(provider=provider, fallback=fallback), tempfile.TemporaryDirectory() as temp:
                    root = Path(temp)
                    files = root / 'General files'
                    files.mkdir()
                    bridge = root / 'relay-bridge'
                    bridge_source = root / 'relay_bridge_fixture.py'
                    bridge_source.write_text("""
import json, os, socket, sys
if '--rotate-log' in sys.argv: raise SystemExit(0)
from command_actions import resolve_command_action
out = {key: os.environ.get(key) for key in ('RELAY_SESSION_SCOPE', 'RELAY_GENERAL_FILES_ROOT', 'RELAY_PRESERVE_CONTEXT_AUTHORIZATION', 'RELAY_RUNNER_PROVIDER')}
request = resolve_command_action('Create a ticket to prepare a detailed report about renewable energy.', repo_path=os.getcwd())
project = resolve_command_action('Create a ticket to fix the bug in app.swift.', repo_path=os.getcwd())
out['general'] = [request.kind, request.scope, request.repo_path]
out['project'] = [project.kind, project.repo_path]
with open(os.environ['HANDOFF_FILE'], 'w') as handle: json.dump(out, handle)
sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
sock.bind(os.environ['BRIDGE_TEST_SOCK'])
sock.close()
""")
                    bridge.write_text('#!/bin/bash\nexec ' + shlex.quote(sys.executable) + ' ' + shlex.quote(str(bridge_source)) + ' "$@"\n')
                    bridge.chmod(0o700)
                    harness = '\n'.join(functions) + """
record_embedded_session_event() { :; }
sleep() { /bin/sleep 0.01; }
launchctl() {
    case "$1" in
        remove) return 0 ;;
        print) return 1 ;;
        submit)
            [ "$FALLBACK" = 1 ] && return 23
            while [ "$1" != -- ]; do shift; done
            shift
            /usr/bin/env -u RELAY_SESSION_SCOPE -u RELAY_GENERAL_FILES_ROOT -u RELAY_PRESERVE_CONTEXT_AUTHORIZATION "$@"
            ;;
    esac
}
nohup() { /usr/bin/env -u RELAY_SESSION_SCOPE -u RELAY_GENERAL_FILES_ROOT -u RELAY_PRESERVE_CONTEXT_AUTHORIZATION "$@"; }
SUPPRESS_STARTUP_GREETING=false
start_voice_bridge_daemon
status=$?
wait
exit "$status"
"""
                    result = subprocess.run(['/bin/bash', '-c', harness], cwd=files, timeout=10, capture_output=True, text=True,
                        env={**os.environ, 'PYTHONPATH':str(Path(__file__).resolve().parents[1] / 'services'),
                            'SCRIPT_DIR':str(root), 'BRIDGE_SOCK':str(root/'voice.sock'), 'BRIDGE_TEST_SOCK':str(root/'voice.sock'),
                            'VOICE_BRIDGE_LOG_PATH':str(root/'voice.log'), 'HANDOFF_FILE':str(root/'handoff.json'),
                            'RELAY_SESSION_SCOPE':'general', 'RELAY_GENERAL_FILES_ROOT':str(files),
                            'RELAY_PRESERVE_CONTEXT_AUTHORIZATION':'1', 'RELAY_RUNNER_PROVIDER':provider, 'FALLBACK':str(int(fallback))})
                    self.assertEqual(result.returncode, 0, result.stderr + (root/'voice.log').read_text())
                    out = json.loads((root/'handoff.json').read_text())
                    self.assertEqual(out, {'RELAY_SESSION_SCOPE':'general', 'RELAY_GENERAL_FILES_ROOT':str(files),
                        'RELAY_PRESERVE_CONTEXT_AUTHORIZATION':'1', 'RELAY_RUNNER_PROVIDER':provider,
                        'general':['create_ticket', 'general', None], 'project':['needs_project', None]})

    def test_controlled_bridge_replacement_preserves_existing_grant_revocations_and_fingerprints(self):
        source = self.source(voice=True); self.finish()
        mutation = {'kind':'orchestrator_action','action_kind':'create_ticket','ticket_id':'RR-9'}
        auth.validate_and_mark_mutation(self.ledger,42,'original-voice',mutation,relay_intent_id='original-intent',now=101.0)
        before = Path(self.ledger).read_bytes()
        constants = ('TTS_IN_FIFO','VOICE_CMD_FILE','VOICE_CMD_META_FILE','VOICE_COMMAND_CLAIM_FILE','VOICE_MANUAL_CLAIM_ACK_FILE','VOICE_PROVIDER_TURNS_FILE','VOICE_COMMAND_STATE_FILE')
        with mock.patch.multiple(voice_bridge, **{k:str(self.root/k) for k in constants}, VOICE_COMMAND_AUTHORIZATION_FILE=self.ledger), \
                mock.patch.object(voice_bridge,'ensure_fifo',return_value=False), mock.patch.dict(os.environ, {'RELAY_PRESERVE_CONTEXT_AUTHORIZATION':'1'}):
            self.assertFalse(voice_bridge._run_relay(None,threading.Event()))
        self.assertEqual(Path(self.ledger).read_bytes(),before)
        self.assertEqual(self.authority('check',source)['status'],'ready')
        with self.assertRaisesRegex(ValueError,'replayed'):
            auth.validate_and_mark_mutation(self.ledger,42,'original-voice',mutation,relay_intent_id='original-intent')
        auth.validate_and_mark_mutation(self.ledger,42,'original-voice',{**mutation,'ticket_id':'RR-10'},relay_intent_id='original-intent')
        auth.record_command_authorization(self.ledger, {'relay_command_seq':43,'relay_command_id':'cancel','intent_id':'cancel'},relationship='cancel',now=104)
        revoked = Path(self.ledger).read_bytes()
        with mock.patch.multiple(voice_bridge, **{k:str(self.root/k) for k in constants}, VOICE_COMMAND_AUTHORIZATION_FILE=self.ledger), \
                mock.patch.object(voice_bridge,'ensure_fifo',return_value=False), mock.patch.dict(os.environ, {'RELAY_PRESERVE_CONTEXT_AUTHORIZATION':'1'}):
            voice_bridge._run_relay(None,threading.Event())
        self.assertEqual(Path(self.ledger).read_bytes(),revoked)
        self.assertEqual(self.authority('check',source)['status'],'blocked')
        with mock.patch.multiple(voice_bridge, **{k:str(self.root/k) for k in constants}, VOICE_COMMAND_AUTHORIZATION_FILE=self.ledger), \
                mock.patch.object(voice_bridge,'ensure_fifo',return_value=False), mock.patch.dict(os.environ, {'RELAY_PRESERVE_CONTEXT_AUTHORIZATION':'0'}):
            voice_bridge._run_relay(None,threading.Event())
        self.assertFalse(Path(self.ledger).exists(),'Unrelated fresh starts retain the existing clean-start behavior')


if __name__ == '__main__':
    unittest.main()
