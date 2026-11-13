//! Unit tests for `SpeechCoordinator`: one test per coordinator rule of
//! docs/specs/speech-service-protocol.md (RR-481). Each doc comment quotes the
//! rule it checks.
//!
//! `FakeWorker` stands in for `TtsWorker`. It records what the coordinator
//! asks of it and reports lifecycle states through the coordinator's hooks at
//! the moments worker.rs does: `cancelled` for the playing attempt on
//! `stop_playback`, for the playing attempt and then the waiting intent on
//! `skip`, and for an intent that is no longer eligible when it is received,
//! played or about to play another sentence. Nothing runs on another thread:
//! a test receives, starts and ends each attempt itself.

use std::collections::VecDeque;
use std::sync::atomic::{AtomicI64, AtomicUsize};

use super::*;

type Shared<T> = Arc<Mutex<T>>;
type PreservedCall = (CommandKey, Json);

// -- The fake worker ------------------------------------------------------------

#[derive(Default)]
struct WorkerState {
    hooks: Option<Arc<dyn SpeechHooks>>,
    /// Enqueued, not yet received by the collect loop.
    inbox: VecDeque<Arc<SpeechIntent>>,
    /// Everything ever enqueued, in order.
    enqueued: Vec<Arc<SpeechIntent>>,
    /// Received and waiting for play.
    pending: Option<Arc<SpeechIntent>>,
    /// The attempt under way, from `preparing` on.
    current: Option<Arc<SpeechIntent>>,
    plays: usize,
    skips: usize,
    stops: Vec<String>,
    jobs: Vec<RemoteJob>,
}

#[derive(Default)]
struct FakeWorker {
    st: Mutex<WorkerState>,
    /// `[tts]` `auto_play`: a received intent plays at once.
    auto_play: AtomicBool,
    /// What `remote_audio_available` answers.
    remote_audio: AtomicBool,
    /// `reload_config` changed the voice, which stops the playing attempt.
    voice_changed: AtomicBool,
}

impl FakeWorker {
    fn lock(&self) -> MutexGuard<'_, WorkerState> {
        self.st.lock().unwrap()
    }

    fn hooks(&self) -> Arc<dyn SpeechHooks> {
        self.lock()
            .hooks
            .clone()
            .expect("the coordinator set its hooks")
    }

    fn report(&self, state: &str, intent: &SpeechIntent) {
        self.hooks().observe(state, intent, None);
    }

    fn eligible(&self, intent: &SpeechIntent) -> bool {
        self.hooks().eligible(intent)
    }

    /// `handle_chunk_locked`: a received intent becomes the waiting one.
    fn take(&self, intent: Arc<SpeechIntent>) {
        if !self.eligible(&intent) {
            self.report("cancelled", &intent);
            return;
        }
        let replaced = self.lock().pending.replace(intent.clone());
        if let Some(replaced) = replaced
            && replaced.utterance_id != intent.utterance_id
        {
            self.report("cancelled", &replaced);
        }
        self.report("queued", &intent);
    }

    /// The collect loop: receive everything enqueued so far.
    fn deliver(&self) {
        loop {
            let Some(intent) = self.lock().inbox.pop_front() else {
                break;
            };
            self.take(intent);
            if self.auto_play.load(Ordering::SeqCst) && self.lock().current.is_none() {
                self.play_now();
            }
        }
    }

    /// `play_now`: the waiting intent starts preparing while it is eligible.
    fn play_now(&self) {
        if self.lock().current.is_some() {
            return;
        }
        while self.lock().pending.is_none() {
            let Some(intent) = self.lock().inbox.pop_front() else {
                break;
            };
            self.take(intent);
        }
        let Some(intent) = self.lock().pending.take() else {
            return;
        };
        if !self.eligible(&intent) {
            self.report("cancelled", &intent);
            return;
        }
        self.lock().current = Some(intent.clone());
        self.report("preparing", &intent);
    }

    fn current(&self) -> Arc<SpeechIntent> {
        self.lock()
            .current
            .clone()
            .expect("an attempt is under way")
    }

    /// The first sentence is ready; it starts only while the intent is eligible.
    fn start(&self) -> bool {
        let intent = self.current();
        self.report("wav_ready", &intent);
        if !self.eligible(&intent) {
            self.end("cancelled");
            return false;
        }
        self.report("started", &intent);
        self.report("afplay_started", &intent);
        true
    }

    /// Eligibility is checked again before each further sentence.
    fn next_sentence(&self) -> bool {
        let intent = self.current();
        if !self.eligible(&intent) {
            self.end("cancelled");
            return false;
        }
        self.report("afplay_started", &intent);
        true
    }

    /// The attempt ends on its own; returns its utterance id.
    fn end(&self, state: &str) -> String {
        let intent = self.lock().current.take().expect("an attempt is under way");
        self.report(state, &intent);
        intent.utterance_id.clone()
    }

    fn enqueued(&self) -> Vec<String> {
        self.lock()
            .enqueued
            .iter()
            .map(|intent| intent.utterance_id.clone())
            .collect()
    }

    fn last_enqueued(&self) -> Arc<SpeechIntent> {
        self.lock()
            .enqueued
            .last()
            .cloned()
            .expect("something was enqueued")
    }

    fn plays(&self) -> usize {
        self.lock().plays
    }

    fn skips(&self) -> usize {
        self.lock().skips
    }

    fn stops(&self) -> Vec<String> {
        self.lock().stops.clone()
    }
}

impl Worker for FakeWorker {
    fn set_hooks(&self, hooks: Arc<dyn SpeechHooks>) {
        self.lock().hooks = Some(hooks);
    }

    fn enqueue(&self, item: WorkItem) {
        let intent = item.intent.expect("the coordinator enqueues intents");
        let mut st = self.lock();
        st.enqueued.push(intent.clone());
        st.inbox.push_back(intent);
    }

    fn play(&self) {
        self.lock().plays += 1;
        self.play_now();
    }

    /// `skip_with`: the playing attempt, then the waiting intent, end `cancelled`.
    fn skip(&self) {
        let (current, pending) = {
            let mut st = self.lock();
            st.skips += 1;
            (st.current.take(), st.pending.take())
        };
        for intent in current.iter().chain(&pending) {
            self.report("cancelled", intent);
        }
    }

    /// `stop_playback_locked`: only the playing attempt ends `cancelled`.
    fn stop_playback(&self, reason: &str) {
        let current = {
            let mut st = self.lock();
            st.stops.push(reason.to_string());
            st.current.take()
        };
        if let Some(current) = current {
            self.report("cancelled", &current);
        }
    }

    fn reload_config(&self) {
        if self.voice_changed.load(Ordering::SeqCst) {
            let current = self.lock().current.take();
            if let Some(current) = current {
                self.report("cancelled", &current);
            }
        }
    }

    fn shutdown(&self) {
        self.skip();
    }

    fn remote_audio_available(&self) -> bool {
        self.remote_audio.load(Ordering::SeqCst)
    }

    fn synthesize_remote(&self, job: RemoteJob) {
        self.lock().jobs.push(job);
    }
}

// -- The fake Relay Remote device ---------------------------------------------

/// A device session; its frames and controls share one seq numbering.
struct FakeDevice {
    id: String,
    routable: AtomicBool,
    refuse_speech: AtomicBool,
    seq: AtomicI64,
    routable_calls: AtomicUsize,
    frames: Mutex<Vec<(i64, Json)>>,
    controls: Mutex<Vec<(String, String)>>,
    audio: Mutex<Vec<(i64, AudioPart)>>,
}

impl FakeDevice {
    fn new(id: &str) -> Arc<Self> {
        Arc::new(Self {
            id: id.into(),
            routable: AtomicBool::new(true),
            refuse_speech: AtomicBool::new(false),
            seq: AtomicI64::new(0),
            routable_calls: AtomicUsize::new(0),
            frames: Mutex::default(),
            controls: Mutex::default(),
            audio: Mutex::default(),
        })
    }

    fn frames(&self) -> Vec<Value> {
        self.frames
            .lock()
            .unwrap()
            .iter()
            .map(|(_, frame)| Value::Object(frame.clone()))
            .collect()
    }

    fn texts(&self) -> Vec<String> {
        self.frames()
            .iter()
            .map(|frame| frame["text"].as_str().unwrap().to_string())
            .collect()
    }

    fn last_seq(&self) -> i64 {
        self.frames
            .lock()
            .unwrap()
            .last()
            .expect("a frame was sent")
            .0
    }

    fn controls(&self) -> Vec<(String, String)> {
        self.controls.lock().unwrap().clone()
    }

    fn audio(&self) -> Vec<(i64, AudioPart)> {
        self.audio.lock().unwrap().clone()
    }
}

impl RemoteDevice for FakeDevice {
    fn device_id(&self) -> &str {
        &self.id
    }

    fn routable(&self) -> bool {
        self.routable_calls.fetch_add(1, Ordering::SeqCst);
        self.routable.load(Ordering::SeqCst)
    }

    fn speech(&self, frame: Json) -> Result<i64, CallFailed> {
        if self.refuse_speech.load(Ordering::SeqCst) {
            return Err(CallFailed);
        }
        let seq = self.seq.fetch_add(1, Ordering::SeqCst) + 1;
        self.frames.lock().unwrap().push((seq, frame));
        Ok(seq)
    }

    fn speech_control(&self, action: &str, reason: &str) -> Result<i64, CallFailed> {
        let seq = self.seq.fetch_add(1, Ordering::SeqCst) + 1;
        self.controls
            .lock()
            .unwrap()
            .push((action.into(), reason.into()));
        Ok(seq)
    }

    fn speech_audio(&self, seq: i64, part: &AudioPart) -> Result<(), CallFailed> {
        self.audio.lock().unwrap().push((seq, part.clone()));
        Ok(())
    }
}

// -- The harness ----------------------------------------------------------------

/// One `on_playback` callback: what the service turns into a `playback` event.
#[derive(Clone, Debug)]
struct Playback {
    state: String,
    utterance_id: String,
    stop_reason: Option<String>,
    requeued_as: Option<String>,
}

struct Harness {
    coordinator: Arc<SpeechCoordinator>,
    worker: Arc<FakeWorker>,
    current: Shared<Option<CommandKey>>,
    preserve: Arc<AtomicBool>,
    preserved_calls: Shared<Vec<PreservedCall>>,
    playback: Shared<Vec<Playback>>,
    finished: Shared<Vec<String>>,
    commands: AtomicI64,
}

impl Harness {
    fn new() -> Self {
        Self::with(FakeWorker::default())
    }

    fn with(worker: FakeWorker) -> Self {
        let worker = Arc::new(worker);
        let current: Shared<Option<CommandKey>> = Arc::default();
        let preserve = Arc::new(AtomicBool::new(false));
        let preserved_calls: Shared<Vec<PreservedCall>> = Arc::default();
        let playback: Shared<Vec<Playback>> = Arc::default();
        let finished: Shared<Vec<String>> = Arc::default();
        let options = Options {
            is_current: Some(Box::new({
                let current = current.clone();
                move |seq: i64, id: &str| {
                    current
                        .lock()
                        .unwrap()
                        .as_ref()
                        .is_some_and(|key| key.0 == seq && key.1 == id)
                }
            })),
            is_preserved: Some(Box::new({
                let (preserve, calls) = (preserve.clone(), preserved_calls.clone());
                move |seq: i64, id: &str, disposition: &Json| {
                    calls
                        .lock()
                        .unwrap()
                        .push(((seq, id.to_string()), disposition.clone()));
                    preserve.load(Ordering::SeqCst)
                }
            })),
            event_log: None,
            control_socket: None,
            on_reply_finished: Some(Box::new({
                let finished = finished.clone();
                move |reason: &str| finished.lock().unwrap().push(reason.to_string())
            })),
            on_playback: Some(Box::new({
                let playback = playback.clone();
                move |state: &str,
                      intent: &SpeechIntent,
                      stop_reason: Option<&str>,
                      requeued_as: Option<&str>| {
                    playback.lock().unwrap().push(Playback {
                        state: state.to_string(),
                        utterance_id: intent.utterance_id.clone(),
                        stop_reason: stop_reason.map(str::to_string),
                        requeued_as: requeued_as.map(str::to_string),
                    });
                }
            })),
        };
        let coordinator = SpeechCoordinator::new(worker.clone(), options);
        Self {
            coordinator,
            worker,
            current,
            preserve,
            preserved_calls,
            playback,
            finished,
            commands: AtomicI64::new(0),
        }
    }

    fn auto_play() -> Self {
        Self::with(FakeWorker {
            auto_play: AtomicBool::new(true),
            ..Default::default()
        })
    }

    /// A newer command becomes the current one, as a new user turn does.
    fn command(&self) -> CommandKey {
        let seq = self.commands.fetch_add(1, Ordering::SeqCst) + 1;
        let key = (seq, format!("command-{seq}"));
        self.set_current(Some(key.clone()));
        key
    }

    fn set_current(&self, key: Option<CommandKey>) {
        *self.current.lock().unwrap() = key;
    }

    fn propose(&self, spec: IntentSpec) -> bool {
        self.propose_armed(spec, None).0
    }

    fn propose_armed(
        &self,
        spec: IntentSpec,
        waiting_playback_kind: Option<&str>,
    ) -> (bool, String) {
        let intent = Arc::new(intent::build(spec));
        let accepted = self
            .coordinator
            .submit(intent.clone(), waiting_playback_kind);
        (accepted, intent.utterance_id.clone())
    }

    fn accept(&self, spec: IntentSpec) -> String {
        let text = spec.spoken_text.clone();
        let (accepted, utterance_id) = self.propose_armed(spec, None);
        assert!(accepted, "{text:?} was refused");
        utterance_id
    }

    /// The provider's final reply to a new current command.
    fn speak(&self, text: &str) -> String {
        let command = self.command();
        self.accept(reply(text, &command))
    }

    fn speak_in(&self, text: &str, session_key: &str) -> String {
        let command = self.command();
        self.accept(IntentSpec {
            session_key: Some(session_key.into()),
            ..reply(text, &command)
        })
    }

    fn snapshot(&self) -> Json {
        self.coordinator.queue_snapshot()
    }

    fn flag(&self, name: &str) -> bool {
        self.snapshot()[name].as_bool().unwrap()
    }

    fn depth(&self) -> u64 {
        self.snapshot()["queue_depth"].as_u64().unwrap()
    }

    /// `(utterance_id, original_utterance_id)` per queued item, head first.
    fn entries(&self) -> Vec<(String, String)> {
        let snapshot = self.snapshot();
        snapshot["queue"]
            .as_array()
            .unwrap()
            .iter()
            .map(|item| {
                (
                    item["utterance_id"].as_str().unwrap().to_string(),
                    item["original_utterance_id"].as_str().unwrap().to_string(),
                )
            })
            .collect()
    }

    /// Original utterance ids, head first.
    fn queue(&self) -> Vec<String> {
        self.entries()
            .into_iter()
            .map(|(_, original)| original)
            .collect()
    }

    fn events(&self, utterance_id: &str) -> Vec<Playback> {
        let playback = self.playback.lock().unwrap();
        playback
            .iter()
            .filter(|event| event.utterance_id == utterance_id)
            .cloned()
            .collect()
    }

    /// The protocol's playback phases, without the per-sentence stages.
    fn phases(&self, utterance_id: &str) -> Vec<String> {
        self.events(utterance_id)
            .into_iter()
            .map(|event| event.state)
            .filter(|state| !matches!(state.as_str(), "wav_ready" | "afplay_started"))
            .collect()
    }

    fn was_cancelled(&self, utterance_id: &str) -> bool {
        self.phases(utterance_id)
            .iter()
            .any(|phase| phase == "cancelled")
    }

    /// The event that ended the utterance's last attempt.
    fn ended(&self, utterance_id: &str) -> Playback {
        self.events(utterance_id)
            .into_iter()
            .rev()
            .find(|event| matches!(event.state.as_str(), "completed" | "cancelled" | "failed"))
            .unwrap_or_else(|| panic!("{utterance_id} has not ended"))
    }

    fn finished(&self) -> Vec<String> {
        self.finished.lock().unwrap().clone()
    }

    fn states(&self, waiting_session_key: &str) -> Value {
        Value::Object(
            self.coordinator
                .session_playback_states(waiting_session_key),
        )
    }

    fn control(&self, session_key: &str, action: &str) -> bool {
        self.coordinator.control_session(session_key, action, "")
    }

    fn play(&self) {
        self.coordinator.play(None, "");
    }

    /// Receive and play the head until its first sentence is at the output.
    fn start_head(&self) -> String {
        self.worker.deliver();
        self.play();
        assert!(self.worker.start(), "the head did not start");
        self.worker.current().utterance_id.clone()
    }

    /// Play the head to its end; returns the utterance id that played.
    fn play_through(&self) -> String {
        self.start_head();
        self.worker.end("completed")
    }

    /// Play a newly started attempt (a replay, `read_out`) to its end.
    fn finish_started(&self) -> Arc<SpeechIntent> {
        let current = self.worker.current();
        assert!(self.worker.start(), "the attempt did not start");
        self.worker.end("completed");
        current
    }
}

fn spec(
    text: &str,
    command: &CommandKey,
    kind: &str,
    source: &str,
    authoritative: bool,
) -> IntentSpec {
    IntentSpec {
        spoken_text: text.into(),
        command_seq: Some(command.0),
        command_id: Some(command.1.clone()),
        kind: Some(kind.into()),
        source: Some(source.into()),
        authoritative,
        ..Default::default()
    }
}

/// The provider's own final, as the contract suite's `speak` sends it.
fn reply(text: &str, command: &CommandKey) -> IntentSpec {
    spec(text, command, "final", "orchestrator", true)
}

fn handoff(text: &str, command: &CommandKey) -> IntentSpec {
    spec(text, command, "handoff", "messenger", false)
}

fn progress(text: &str, command: &CommandKey) -> IntentSpec {
    spec(text, command, "progress", "lifecycle", false)
}

fn fallback(text: &str, command: &CommandKey) -> IntentSpec {
    spec(text, command, "fallback", "fallback", false)
}

fn uncommanded(text: &str, kind: &str, dedup_key: &str) -> IntentSpec {
    IntentSpec {
        spoken_text: text.into(),
        kind: Some(kind.into()),
        source: Some("lifecycle".into()),
        dedup_key: Some(dedup_key.into()),
        ..Default::default()
    }
}

// -- Queue rules: order and refusals ------------------------------------------

/// "An accepted intent goes to the back of the queue."
#[test]
fn queue_accepted_intents_play_in_the_order_they_were_accepted() {
    let h = Harness::new();
    let ids: Vec<String> = ["First reply.", "Second reply.", "Third reply."]
        .iter()
        .map(|text| h.speak(text))
        .collect();
    assert_eq!(h.queue(), ids);
    // Only the head is handed to the worker.
    assert_eq!(h.worker.enqueued(), ids[..1]);

    let played: Vec<String> = ids.iter().map(|_| h.play_through()).collect();

    assert_eq!(played, ids);
    assert_eq!(h.worker.enqueued(), ids);
    assert!(h.queue().is_empty());
}

/// "`speak` answers `accepted: false`, and the intent is never spoken, when:
/// `text` is empty"
#[test]
fn refuses_empty_text() {
    let h = Harness::new();
    let command = h.command();
    assert!(!h.propose(reply("   ", &command)));
    assert!(h.queue().is_empty());
    assert!(h.worker.enqueued().is_empty());
}

/// "`speak` answers `accepted: false` ... when: ... `expires_at` has passed"
#[test]
fn refuses_an_intent_whose_expires_at_has_passed() {
    let h = Harness::new();
    let command = h.command();
    let expiring = |at: f64| IntentSpec {
        expires_at: Some(at),
        ..reply("Too late.", &command)
    };
    assert!(!h.propose(expiring(support::now() - 1.0)));
    assert!(h.queue().is_empty());
    assert!(h.propose(expiring(support::now() + 60.0)));
}

/// "`expires_at` | Unix time after which the intent is no longer spoken."
#[test]
fn drops_an_intent_that_expired_while_it_was_queued() {
    let h = Harness::new();
    let command = h.command();
    let head = h.accept(reply("The answer.", &command));
    let note = h.accept(IntentSpec {
        expires_at: Some(support::now() + 0.1),
        ..progress("Soon stale.", &command)
    });
    assert_eq!(h.queue(), [head.clone(), note.clone()]);
    std::thread::sleep(Duration::from_millis(150));

    assert_eq!(h.play_through(), head);

    assert!(h.queue().is_empty());
    assert!(h.events(&note).is_empty());
}

/// "`speak` answers `accepted: false` ... when: ... the intent is stale"
#[test]
fn refuses_a_stale_intent() {
    let h = Harness::new();
    let older = h.command();
    h.command();
    for spec in [
        handoff("Looking into it.", &older),
        progress("Still working.", &older),
        reply("The answer.", &older),
        fallback("I could not confirm it.", &older),
    ] {
        let kind = spec.kind.clone();
        assert!(
            !h.propose(spec),
            "{kind:?} of an older command was accepted"
        );
    }
    assert!(h.queue().is_empty());
}

/// "`speak` answers `accepted: false` ... when: ... its `dedup_key` was
/// accepted before"; "A `final` or `fallback` of a command defaults to one key
/// per command, so a command has one real final and one fallback."
#[test]
fn refuses_a_dedup_key_accepted_before() {
    let h = Harness::new();
    let command = h.command();
    let keyed = |text: &str| IntentSpec {
        dedup_key: Some("note-1".into()),
        ..progress(text, &command)
    };
    assert!(h.propose(keyed("Still working.")));
    assert!(!h.propose(keyed("Still working on it.")));

    assert!(h.propose(fallback("I could not confirm it.", &command)));
    assert!(!h.propose(fallback("Another stand-in.", &command)));
    assert!(h.propose(reply("The build passed.", &command)));
    assert!(!h.propose(reply("The build passed again.", &command)));
    // Every real final of the command shares that key.
    assert!(!h.propose(spec(
        "Probably done.",
        &command,
        "final",
        "messenger",
        false
    )));
}

/// "`speak` answers `accepted: false` ... when: ... it is a fallback for a
/// command whose real final was accepted"
#[test]
fn refuses_a_fallback_after_the_real_final() {
    let h = Harness::new();
    let command = h.command();
    assert!(h.propose(reply("The build passed.", &command)));
    assert!(!h.propose(fallback("I could not confirm the result.", &command)));
    // A final from the fallback source is a fallback outcome too.
    assert!(!h.propose(spec("A stand-in.", &command, "final", "fallback", false)));
    assert_eq!(h.queue().len(), 1);
}

/// "`speak` answers `accepted: false` ... when: ... the queue already holds 50 items."
#[test]
fn refuses_the_fifty_first_item() {
    let h = Harness::new();
    let ids: Vec<String> = (0..SPEECH_QUEUE_LIMIT)
        .map(|number| h.speak(&format!("Reply {number}.")))
        .collect();
    assert_eq!(h.depth(), 50);

    let command = h.command();
    let refused = reply("One too many.", &command);
    assert!(!h.propose(refused.clone()));
    assert_eq!(h.queue(), ids);

    // It was never accepted, so it may be proposed again once there is room.
    h.play_through();
    let again = h.accept(refused);
    let mut expected = ids[1..].to_vec();
    expected.push(again);
    assert_eq!(h.queue(), expected);
}

// -- Queue rules: Supersede -------------------------------------------------------

/// "Supersede. A `clarification`, `final` or `fallback` replaces the same
/// command's `handoff` or `progress` speech that has not started"
#[test]
fn supersede_a_reply_replaces_its_commands_waiting_handoff() {
    let h = Harness::new();
    let command = h.command();
    let ack = h.accept(handoff("Looking into it.", &command));
    h.worker.deliver();

    let answer = h.accept(reply("Here is the answer.", &command));

    assert_eq!(h.queue(), [answer.as_str()]);
    let ended = h.ended(&ack);
    assert_eq!(
        (ended.state.as_str(), ended.requeued_as),
        ("cancelled", None)
    );
    assert_eq!(h.play_through(), answer);
}

/// "Supersede. ... wherever it is queued."
#[test]
fn supersede_reaches_the_commands_status_speech_wherever_it_is_queued() {
    let h = Harness::new();
    let earlier = h.speak("Earlier reply.");
    let command = h.command();
    let ack = h.accept(handoff("Looking into it.", &command));
    let note = h.accept(progress("Still working.", &command));
    assert_eq!(h.queue(), [earlier.clone(), ack.clone(), note.clone()]);

    let question = h.accept(spec(
        "Which file?",
        &command,
        "clarification",
        "orchestrator",
        true,
    ));

    assert_eq!(h.queue(), [earlier.clone(), question]);
    // They never reached the head, so they have no playback events.
    assert!(h.events(&ack).is_empty() && h.events(&note).is_empty());
    assert_eq!(h.worker.enqueued(), [earlier]);
}

/// Supersede applies only to speech "that has not started".
#[test]
fn supersede_spares_status_speech_that_started() {
    let h = Harness::new();
    let command = h.command();
    let ack = h.accept(handoff("Looking into it.", &command));
    h.start_head();

    let answer = h.accept(reply("Here is the answer.", &command));

    assert_eq!(h.queue(), [ack.clone(), answer]);
    assert!(h.flag("playing"));
    assert_eq!(h.worker.skips(), 0);
    assert!(!h.was_cancelled(&ack));
}

/// "Speech with a higher `priority` likewise replaces the same command's
/// `progress` or `control` speech waiting at the head."
#[test]
fn supersede_on_priority_replaces_waiting_progress_or_control() {
    let h = Harness::new();
    let command = h.command();
    let note = h.accept(progress("Still working.", &command));
    h.worker.deliver();
    // A handoff outranks progress by default: 20 against 10.
    let ack = h.accept(handoff("Looking into it.", &command));
    assert_eq!(h.queue(), [ack.as_str()]);
    assert_eq!(h.ended(&note).state, "cancelled");
    h.worker.deliver();
    // A waiting handoff is never replaced on priority.
    let urgent = h.accept(IntentSpec {
        priority: Some(90),
        ..progress("An urgent note.", &command)
    });
    assert_eq!(h.queue(), [ack.clone(), urgent]);
    assert_eq!(h.phases(&ack), ["queued"]);

    let h = Harness::new();
    let command = h.command();
    let control = h.accept(spec("Stopping.", &command, "control", "lifecycle", false));
    h.worker.deliver();
    // Equal priority replaces nothing; a higher one replaces the control.
    let same = h.accept(IntentSpec {
        priority: Some(100),
        ..progress("Same rank.", &command)
    });
    let higher = h.accept(IntentSpec {
        priority: Some(101),
        ..progress("Higher rank.", &command)
    });
    assert_eq!(h.queue(), [higher.clone(), same.clone()]);
    assert_eq!(h.ended(&control).state, "cancelled");
    // "`priority` ... Only compared between speech of the same command."
    let other = h.accept(IntentSpec {
        priority: Some(999),
        ..uncommanded("No command.", "progress", "note-1")
    });
    assert_eq!(h.queue(), [higher, same, other]);
}

/// Supersede is for "the same command's" speech; another command's reply keeps its place.
#[test]
fn supersede_never_touches_another_commands_reply() {
    let h = Harness::new();
    let earlier = h.speak("Earlier reply.");
    h.worker.deliver();
    let later = h.speak("Later reply.");
    assert_eq!(h.queue(), [earlier.clone(), later]);
    assert_eq!(h.phases(&earlier), ["queued"]);
    assert_eq!(h.worker.skips(), 0);
}

// -- Queue rules: Replace ---------------------------------------------------------

/// "Replace. An authoritative `final` from `completion` or `orchestrator`
/// replaces the same command's fallback outcome"
#[test]
fn replace_real_final_replaces_the_waiting_fallback() {
    let h = Harness::new();
    let command = h.command();
    let stand_in = h.accept(fallback("I could not confirm the result.", &command));
    h.worker.deliver();

    let answer = h.accept(spec(
        "The build passed.",
        &command,
        "final",
        "completion",
        true,
    ));

    assert_eq!(h.queue(), [answer.as_str()]);
    let ended = h.ended(&stand_in);
    assert_eq!(
        (ended.state.as_str(), ended.requeued_as),
        ("cancelled", None)
    );
    assert_eq!(h.play_through(), answer);
}

/// "Replace. ... even while that fallback is playing."
#[test]
fn replace_real_final_replaces_the_fallback_while_it_plays() {
    let h = Harness::new();
    let command = h.command();
    let stand_in = h.accept(fallback("I could not confirm the result.", &command));
    h.start_head();

    let answer = h.accept(reply("The build passed.", &command));

    let ended = h.ended(&stand_in);
    assert_eq!(
        (ended.state.as_str(), ended.requeued_as),
        ("cancelled", None)
    );
    assert_eq!(h.queue(), [answer.as_str()]);
    assert!(!h.flag("playing"));
    assert_eq!(h.worker.enqueued(), [stand_in, answer.clone()]);
    assert_eq!(h.play_through(), answer);
}

/// Replace reaches the command's fallback anywhere in the queue.
#[test]
fn replace_reaches_a_fallback_queued_behind_another_reply() {
    let h = Harness::new();
    let earlier = h.speak("Earlier reply.");
    let command = h.command();
    h.accept(fallback("I could not confirm the result.", &command));
    let answer = h.accept(reply("The build passed.", &command));
    assert_eq!(h.queue(), [earlier, answer]);
}

/// Replace needs "An authoritative `final` from `completion` or `orchestrator`".
#[test]
fn replace_needs_an_authoritative_final_from_completion_or_orchestrator() {
    for (source, authoritative) in [
        ("messenger", true),
        ("orchestrator", false),
        ("lifecycle", true),
    ] {
        let h = Harness::new();
        let command = h.command();
        let stand_in = h.accept(fallback("I could not confirm the result.", &command));
        let guess = h.accept(spec(
            "Probably done.",
            &command,
            "final",
            source,
            authoritative,
        ));
        assert_eq!(
            h.queue(),
            [stand_in, guess],
            "{source} authoritative={authoritative}"
        );
    }
}

// -- Queue rules: Newer command ---------------------------------------------------

/// "Newer command. Speech of a newer command stops the older command's status
/// speech at the head."
#[test]
fn newer_command_stops_the_older_status_speech_at_the_head() {
    // Waiting at the head.
    let h = Harness::new();
    let older = h.command();
    let waiting = h.accept(handoff("Looking into it.", &older));
    h.worker.deliver();
    let command = h.command();
    let newer = h.accept(handoff("Looking into the next thing.", &command));
    let ended = h.ended(&waiting);
    assert_eq!(
        (ended.state.as_str(), ended.requeued_as),
        ("cancelled", None)
    );
    assert_eq!(h.queue(), [newer.as_str()]);
    h.worker.deliver();
    assert_eq!(h.phases(&newer), ["queued"]);

    // Playing at the head.
    let h = Harness::new();
    let older = h.command();
    let playing = h.accept(progress("Still working.", &older));
    h.start_head();
    let command = h.command();
    let answer = h.accept(reply("The answer.", &command));
    let ended = h.ended(&playing);
    assert_eq!(
        (ended.state.as_str(), ended.requeued_as),
        ("cancelled", None)
    );
    assert_eq!(h.queue(), [answer.as_str()]);
    assert_eq!(h.worker.enqueued(), [playing, answer]);
}

/// "Newer command. ... A reply is never removed by a newer command."
#[test]
fn newer_command_never_removes_a_reply() {
    let h = Harness::new();
    let waiting = h.speak("Earlier reply.");
    h.worker.deliver();
    let command = h.command();
    let newer = h.accept(handoff("Looking into the next thing.", &command));
    assert_eq!(h.queue(), [waiting.clone(), newer]);
    assert_eq!(h.phases(&waiting), ["queued"]);

    let h = Harness::new();
    let playing = h.speak("Earlier reply.");
    h.start_head();
    let newer = h.speak("Later reply.");
    assert_eq!(h.queue(), [playing, newer]);
    assert!(h.flag("playing"));
    assert_eq!(h.worker.skips(), 0);
    assert!(h.worker.stops().is_empty());
}

// -- Queue rules: the head --------------------------------------------------------

/// "The head of the queue is published as waiting and plays on `play`"
#[test]
fn head_waits_and_plays_on_play() {
    let h = Harness::new();
    let utterance_id = h.speak("The answer.");
    assert_eq!(h.worker.enqueued(), [utterance_id.as_str()]);
    h.worker.deliver();
    assert_eq!(h.phases(&utterance_id), ["queued"]);
    assert_eq!(h.worker.plays(), 0);

    h.play();

    assert_eq!(h.worker.plays(), 1);
    assert!(h.worker.start());
    assert!(h.flag("playing"));
    h.worker.end("completed");
    assert_eq!(
        h.phases(&utterance_id),
        ["queued", "preparing", "started", "completed"]
    );
    let ended = h.ended(&utterance_id);
    assert_eq!((ended.stop_reason, ended.requeued_as), (None, None));
}

/// `play`: "Does nothing while audio is playing or when the queue is empty."
#[test]
fn play_does_nothing_while_audio_is_playing_or_the_queue_is_empty() {
    let h = Harness::new();
    h.play();
    assert_eq!(h.worker.plays(), 0);

    let first = h.speak("First reply.");
    let second = h.speak("Second reply.");
    h.start_head();
    h.play();
    assert_eq!(h.worker.plays(), 1);
    assert_eq!(h.worker.enqueued(), [first.as_str()]);
    assert!(h.events(&second).is_empty());
    assert!(!h.was_cancelled(&first));
}

/// "with `auto_play` it plays at once. When it ends, the next item becomes the head."
#[test]
fn auto_play_plays_each_head_as_it_arrives() {
    let h = Harness::auto_play();
    let ids: Vec<String> = ["First reply.", "Second reply.", "Third reply."]
        .iter()
        .map(|text| h.speak(text))
        .collect();
    let mut played = Vec::new();
    for _ in &ids {
        h.worker.deliver();
        played.push(h.finish_started().utterance_id.clone());
    }
    assert_eq!(played, ids);
    // The coordinator never had to ask: the worker played each head itself.
    assert_eq!(h.worker.plays(), 0);
}

// -- Queue rules: how a reply leaves the queue -----------------------------------

/// `state`: `speaking`, `playing`, `held`, `queue_depth` and `queue` as a reply waits, plays and ends.
#[test]
fn state_follows_the_reply() {
    let h = Harness::new();
    let utterance_id = h.speak("The answer.");
    assert_eq!(
        Value::Object(h.snapshot()),
        json!({"speaking": true, "playing": false, "held": false, "queue_depth": 1,
               "queue": [{"utterance_id": utterance_id, "original_utterance_id": utterance_id}]})
    );
    h.start_head();
    assert_eq!(
        (h.flag("speaking"), h.flag("playing"), h.depth()),
        (true, true, 1)
    );

    h.coordinator.skip("user_stop");

    assert_eq!(
        Value::Object(h.snapshot()),
        json!({"speaking": false, "playing": false, "held": false, "queue_depth": 0, "queue": []})
    );
}

/// "a reply that was only stopped returns to the head"; "A reply that returned
/// to the queue has a new `utterance_id` and keeps its `original_utterance_id`."
/// `stop_playback`: "With any other reason the reply returns to the head of the
/// queue and the queue is held."
#[test]
fn stop_playback_returns_the_reply_to_the_head_with_a_new_utterance_id() {
    let h = Harness::new();
    let first = h.speak("First reply.");
    let second = h.speak("Second reply.");
    h.start_head();

    h.coordinator.stop_playback("interrupt", None);

    assert_eq!(h.worker.stops(), ["interrupt"]);
    let ended = h.ended(&first);
    assert_eq!(
        (ended.state.as_str(), ended.stop_reason.as_deref()),
        ("cancelled", Some("interrupt"))
    );
    let requeued = ended.requeued_as.expect("the reply returned to the queue");
    assert_ne!(requeued, first);
    assert_eq!(
        h.entries(),
        [(requeued.clone(), first.clone()), (second.clone(), second)]
    );
    assert!(h.flag("held") && !h.flag("playing"));
    assert_eq!(h.depth(), 2);
    // Held: nothing comes forward.
    assert_eq!(h.worker.enqueued(), [first.as_str()]);

    // The next play starts the reply again.
    h.play();
    assert_eq!(h.worker.last_enqueued().utterance_id, requeued);
    assert!(h.worker.start());
    assert_eq!(h.worker.current().original_utterance_id, first);
    assert!(!h.flag("held"));
}

/// `stop_playback`: "With `recording_barge_in` the reply counts as heard: it
/// leaves the queue, stays replayable, and nothing else comes forward until
/// `new_turn` or `play`."
#[test]
fn stop_playback_recording_barge_in_counts_the_reply_as_heard() {
    let h = Harness::new();
    let first = h.speak("First reply.");
    let second = h.speak("Second reply.");
    h.start_head();

    h.coordinator.stop_playback("recording_barge_in", None);

    let ended = h.ended(&first);
    assert_eq!(ended.stop_reason.as_deref(), Some("recording_barge_in"));
    assert_eq!(ended.requeued_as, None);
    assert_eq!(h.queue(), [second.as_str()]);
    assert!(!h.flag("playing") && !h.flag("held"));
    assert_eq!(h.worker.enqueued(), [first.as_str()]);

    let command = h.command();
    h.coordinator.new_turn(command.0, &command.1);
    assert_eq!(h.worker.enqueued(), [first.clone(), second]);

    // It stays replayable.
    assert!(h.coordinator.replay(None));
    let (replay, original) = h.entries()[1].clone();
    assert_ne!(replay, first);
    assert_eq!(original, first);

    // `play` brings the next reply forward too.
    let h = Harness::new();
    h.speak("First reply.");
    let second = h.speak("Second reply.");
    h.start_head();
    h.coordinator.stop_playback("recording_barge_in", None);
    h.play();
    assert_eq!(h.worker.current().utterance_id, second);
}

/// `stop_playback`: "With nothing playing it acts as `pause`."
#[test]
fn stop_playback_with_nothing_playing_acts_as_pause() {
    let h = Harness::new();
    let utterance_id = h.speak("The answer.");
    h.worker.deliver();

    h.coordinator.stop_playback("", None);

    assert!(h.flag("held"));
    assert_eq!(h.queue(), [utterance_id.as_str()]);
    assert_eq!(h.phases(&utterance_id), ["queued"]);
}

/// `pause`: "stops the audio and **holds** the queue. The reply that was
/// playing returns to the head of the queue and plays from its start on the
/// next `play`."
#[test]
fn pause_holds_the_queue_until_play() {
    let h = Harness::new();
    let first = h.speak("First reply.");
    let second = h.speak("Second reply.");
    h.start_head();

    h.coordinator.stop();

    let ended = h.ended(&first);
    assert_eq!(ended.stop_reason.as_deref(), Some("speech_only_barge_in"));
    let requeued = ended.requeued_as.expect("the reply returned to the queue");
    assert!(h.flag("held"));
    // Nothing comes forward while held, not even new speech.
    let third = h.speak("Third reply.");
    assert_eq!(h.queue(), [first.clone(), second, third]);
    assert_eq!(h.worker.enqueued(), [first]);

    h.play();

    assert!(h.worker.start());
    assert_eq!(h.worker.current().utterance_id, requeued);
    assert!(!h.flag("held"));
}

/// `pause` before the head started holds the queue; nothing is dropped.
#[test]
fn pause_before_play_keeps_the_reply_waiting() {
    let h = Harness::new();
    let utterance_id = h.speak("The answer.");
    h.worker.deliver();
    h.coordinator.stop();
    assert!(h.flag("held"));
    let later = h.speak("Later reply.");
    assert_eq!(h.queue(), [utterance_id.clone(), later]);

    assert_eq!(h.play_through(), utterance_id);
    assert!(!h.flag("held"));
}

/// `new_turn`: "releases a held queue"; "`held` | A stop is holding the queue
/// until `play` or `new_turn`."
#[test]
fn new_turn_releases_a_held_queue() {
    let h = Harness::new();
    let utterance_id = h.speak("The answer.");
    h.start_head();
    h.coordinator.stop();
    let requeued = h
        .ended(&utterance_id)
        .requeued_as
        .expect("the reply returned to the queue");
    assert!(h.flag("held"));

    let command = h.command();
    h.coordinator.new_turn(command.0, &command.1);

    assert!(!h.flag("held"));
    // The reply waits at the head again, for the next play.
    h.worker.deliver();
    assert_eq!(h.phases(&requeued), ["queued"]);
    assert_eq!(h.queue(), [utterance_id]);
    assert_eq!(h.worker.plays(), 1);
}

// -- Playback control: skip -------------------------------------------------------

/// `skip`: "Removes the reply that is playing ... The next queued reply comes forward"
#[test]
fn skip_removes_the_playing_reply_and_brings_the_next_forward() {
    let h = Harness::new();
    let first = h.speak("First reply.");
    let second = h.speak("Second reply.");
    h.start_head();

    h.coordinator.skip("user_stop");

    let ended = h.ended(&first);
    assert_eq!(
        (ended.stop_reason.as_deref(), ended.requeued_as),
        (Some("user_stop"), None)
    );
    assert_eq!(h.queue(), [second.as_str()]);
    assert!(!h.flag("held"));
    assert_eq!(h.worker.enqueued(), [first, second]);
    assert!(h.finished().is_empty());
}

/// `skip`: "Removes the reply that is playing, or else the one waiting at the head"
#[test]
fn skip_removes_the_waiting_reply() {
    let h = Harness::new();
    let first = h.speak("First reply.");
    let second = h.speak("Second reply.");
    h.worker.deliver();

    h.coordinator.skip("user_stop");

    assert_eq!(h.worker.skips(), 1);
    let ended = h.ended(&first);
    // Nothing was playing, so no stop reason is reported.
    assert_eq!(
        (ended.state.as_str(), ended.stop_reason, ended.requeued_as),
        ("cancelled", None, None)
    );
    assert_eq!(h.queue(), [second.as_str()]);
    h.worker.deliver();
    assert_eq!(h.phases(&second), ["queued"]);
}

/// `skip`: "... it stays replayable."
#[test]
fn skip_keeps_the_removed_reply_replayable() {
    for playing in [true, false] {
        let h = Harness::new();
        let utterance_id = h.speak("The answer.");
        h.worker.deliver();
        if playing {
            h.start_head();
        }
        h.coordinator.skip("user_stop");
        assert!(h.queue().is_empty());

        assert!(h.coordinator.replay(None), "playing={playing}");
        let replay = h.worker.current();
        assert_eq!(
            replay.replay_of.as_deref(),
            Some(utterance_id.as_str()),
            "playing={playing}"
        );
    }
}

/// `skip`: "The next queued reply comes forward, except with `focus_switch`,
/// `wheel_stop` or `recording_barge_in`, which bring nothing forward."
#[test]
fn skip_with_a_non_advancing_reason_brings_nothing_forward() {
    for reason in ["focus_switch", "wheel_stop", "recording_barge_in"] {
        let h = Harness::new();
        let first = h.speak("First reply.");
        let second = h.speak("Second reply.");
        h.start_head();

        h.coordinator.skip(reason);

        let ended = h.ended(&first);
        assert_eq!(
            (ended.stop_reason.as_deref(), ended.requeued_as),
            (Some(reason), None)
        );
        assert_eq!(h.queue(), [second.as_str()], "{reason}");
        assert_eq!(h.worker.enqueued(), [first.as_str()], "{reason}");
        assert!(!h.flag("held"), "{reason}");
        // The reply left behind plays on the next play.
        h.play();
        assert_eq!(h.worker.current().utterance_id, second, "{reason}");
    }

    // A waiting head is removed the same way.
    let h = Harness::new();
    let first = h.speak("First reply.");
    let second = h.speak("Second reply.");
    h.worker.deliver();
    h.coordinator.skip("focus_switch");
    assert_eq!(h.ended(&first).state, "cancelled");
    assert_eq!(h.queue(), [second]);
    assert_eq!(h.worker.enqueued(), [first]);
}

/// `skip` with nothing playing or waiting changes nothing.
#[test]
fn skip_with_nothing_queued_does_nothing() {
    let h = Harness::new();
    h.coordinator.skip("user_stop");
    assert_eq!(
        Value::Object(h.snapshot()),
        json!({"speaking": false, "playing": false, "held": false, "queue_depth": 0, "queue": []})
    );
    assert!(h.playback.lock().unwrap().is_empty());
}

// -- Playback control: new_turn ---------------------------------------------------

/// `new_turn`: "stops a playing reply of an older command (it returns to the head of the queue)"
#[test]
fn new_turn_stops_a_playing_older_reply_which_returns_to_the_head() {
    let h = Harness::new();
    let first = h.speak("First reply.");
    let second = h.speak("Second reply.");
    h.start_head();

    let command = h.command();
    h.coordinator.new_turn(command.0, &command.1);

    assert_eq!(h.worker.stops(), ["newer_command"]);
    let ended = h.ended(&first);
    assert_eq!(ended.stop_reason.as_deref(), Some("newer_command"));
    let requeued = ended.requeued_as.expect("the reply returned to the queue");
    assert_eq!(
        h.entries(),
        [(requeued.clone(), first), (second.clone(), second)]
    );
    assert!(!h.flag("held") && !h.flag("playing"));

    h.play();
    assert_eq!(h.worker.current().utterance_id, requeued);
}

/// `new_turn` stops a playing reply "of an older command" only.
#[test]
fn new_turn_leaves_a_reply_of_the_same_command_playing() {
    let h = Harness::new();
    let command = h.command();
    h.accept(reply("The answer.", &command));
    h.start_head();
    h.coordinator.new_turn(command.0, &command.1);
    assert!(h.flag("playing"));
    assert!(h.worker.stops().is_empty());
}

/// `new_turn`: "drops queued status speech of older commands. Queued replies stay."
#[test]
fn new_turn_drops_queued_status_speech_of_older_commands() {
    let h = Harness::new();
    let older = h.command();
    let answer = h.accept(reply("The answer.", &older));
    let note = h.accept(progress("One more note.", &older));
    h.worker.deliver();
    assert_eq!(h.queue(), [answer.clone(), note]);

    let command = h.command();
    h.coordinator.new_turn(command.0, &command.1);

    assert_eq!(h.queue(), [answer.as_str()]);
    assert_eq!(h.phases(&answer), ["queued"]);
    assert_eq!(h.worker.skips(), 0);
}

/// `new_turn` drops status speech of an older command waiting at the head
/// too; a reply queued behind it comes forward.
#[test]
fn new_turn_drops_older_status_speech_waiting_at_the_head() {
    let h = Harness::new();
    let older = h.command();
    let ack = h.accept(handoff("Looking into it.", &older));
    let stored = h.accept(uncommanded("A stored reply.", "final", "stored-1"));
    h.worker.deliver();
    assert_eq!(h.queue(), [ack.clone(), stored.clone()]);

    let command = h.command();
    h.coordinator.new_turn(command.0, &command.1);

    let ended = h.ended(&ack);
    assert_eq!(
        (ended.state.as_str(), ended.requeued_as),
        ("cancelled", None)
    );
    assert_eq!(h.queue(), [stored.as_str()]);
    assert_eq!(h.worker.last_enqueued().utterance_id, stored);
}

// -- Playback control: replay, play_or_replay, read_out -------------------------

/// `replay`: "`false` when there is none."
#[test]
fn replay_without_history_is_refused() {
    let h = Harness::new();
    assert!(!h.coordinator.replay(None));
    assert!(h.worker.enqueued().is_empty());
}

/// `replay`: "Speaks the newest replayable reply again as a new utterance whose
/// `replay_of` names the original. ... with nothing at the head the replay
/// plays at once"
#[test]
fn replay_speaks_the_newest_reply_again_as_a_new_utterance() {
    let h = Harness::new();
    h.speak("First reply.");
    h.play_through();
    let newest = h.speak("Second reply.");
    h.play_through();

    assert!(h.coordinator.replay(None));

    // It plays at once, without another play.
    assert_eq!(h.worker.plays(), 3);
    let replay = h.finish_started();
    assert_ne!(replay.utterance_id, newest);
    assert_eq!(replay.original_utterance_id, newest);
    assert_eq!(replay.replay_of.as_deref(), Some(newest.as_str()));
    assert_eq!(replay.spoken_text, "Second reply.");

    // A replay of a replay still names the original reply.
    assert!(h.coordinator.replay(None));
    let again = h.finish_started();
    assert_ne!(again.utterance_id, replay.utterance_id);
    assert_eq!(again.replay_of.as_deref(), Some(newest.as_str()));
}

/// `replay` "also acts as `play`: ... with a reply waiting at the head, that
/// reply plays and the replay is next, ahead of everything else queued."
#[test]
fn replay_plays_the_waiting_head_and_goes_next() {
    let h = Harness::new();
    let heard = h.speak("Heard reply.");
    h.play_through();
    let waiting = h.speak("Waiting reply.");
    let behind = h.speak("Reply behind it.");
    h.worker.deliver();

    assert!(h.coordinator.replay(None));

    assert_eq!(h.worker.current().utterance_id, waiting);
    assert_eq!(h.queue(), [waiting, heard.clone(), behind.clone()]);
    h.finish_started();
    assert_eq!(
        h.worker.last_enqueued().replay_of.as_deref(),
        Some(heard.as_str())
    );
    assert_eq!(h.queue(), [heard, behind]);
}

/// `play_or_replay`: "`play` when a reply is waiting or queued, otherwise `replay`."
#[test]
fn play_or_replay_plays_what_is_waiting_otherwise_replays() {
    let h = Harness::new();
    assert!(!h.coordinator.play_or_replay());
    h.speak("Heard reply.");
    h.play_through();
    let waiting = h.speak("Waiting reply.");

    assert!(h.coordinator.play_or_replay());
    let played = h.finish_started();
    assert_eq!(
        (played.utterance_id.as_str(), played.replay_of.as_deref()),
        (waiting.as_str(), None)
    );

    assert!(h.coordinator.play_or_replay());
    assert_eq!(
        h.finish_started().replay_of.as_deref(),
        Some(waiting.as_str())
    );
}

/// "`replayable` | `kind == "final"` | Whether `replay` may repeat it."
#[test]
fn replay_repeats_only_replayable_speech() {
    let h = Harness::new();
    let answer = h.speak("The answer.");
    h.play_through();
    let command = h.command();
    h.accept(spec(
        "Which file do you mean?",
        &command,
        "clarification",
        "orchestrator",
        true,
    ));
    h.play_through();
    let command = h.command();
    h.accept(IntentSpec {
        replayable: Some(false),
        ..reply("Not for repeating.", &command)
    });
    h.play_through();

    assert!(h.coordinator.replay(None));
    assert_eq!(
        h.finish_started().replay_of.as_deref(),
        Some(answer.as_str())
    );

    // Any kind may be made replayable.
    let command = h.command();
    let question = h.accept(IntentSpec {
        replayable: Some(true),
        ..spec(
            "Which branch?",
            &command,
            "clarification",
            "orchestrator",
            true,
        )
    });
    h.play_through();
    assert!(h.coordinator.replay(None));
    assert_eq!(
        h.finish_started().replay_of.as_deref(),
        Some(question.as_str())
    );
}

/// `read_out`: "Speaks explicit text now, such as a stored reply: queues it as
/// a replayable reply and plays it. Empty text is refused."
#[test]
fn read_out_speaks_the_text_at_once() {
    let h = Harness::new();
    assert!(!h.coordinator.read_out("  ", ""));

    assert!(h.coordinator.read_out("A stored reply.", ""));
    let first = h.finish_started();
    assert_eq!(first.spoken_text, "A stored reply.");
    assert!(first.replayable);
    // It is never deduplicated against an earlier one.
    assert!(h.coordinator.read_out("A stored reply.", ""));
    let second = h.finish_started();
    assert_ne!(second.utterance_id, first.utterance_id);
    assert!(h.coordinator.replay(None));
    assert_eq!(
        h.finish_started().replay_of.as_deref(),
        Some(second.utterance_id.as_str())
    );

    // With a session key it plays through that session's control.
    assert!(h.coordinator.read_out("For session a.", "session-a"));
    assert_eq!(h.finish_started().session_key, "session-a");
}

/// "The newest 32 replayable replies that played, were skipped or were stopped
/// form the replay history."
#[test]
fn replay_history_keeps_the_newest_thirty_two() {
    let h = Harness::new();
    for number in 0..=REPLAY_HISTORY_LIMIT {
        h.speak_in(&format!("Reply {number}."), &format!("session-{number}"));
        h.play_through();
    }

    let expected: Json = (1..=REPLAY_HISTORY_LIMIT)
        .map(|number| (format!("session-{number}"), json!("replay")))
        .collect();
    assert_eq!(h.states(""), Value::Object(expected));
    assert!(!h.coordinator.replay(Some("session-0")));
    assert!(h.coordinator.replay(Some("session-1")));
}

// -- Speaking: arm_waiting_playback ---------------------------------------------

/// `arm_waiting_playback`: "Binds the next play gesture to the speech of this command."
#[test]
fn arm_waiting_playback_keeps_the_next_play_for_the_commands_speech() {
    let h = Harness::new();
    let command = h.command();
    h.coordinator
        .arm_waiting_playback(command.0, &command.1, "final");
    h.play();
    assert_eq!(h.worker.plays(), 0);

    let answer = h.accept(reply("The answer.", &command));

    // The reply plays as it arrives; no second play is needed.
    assert_eq!(h.worker.plays(), 1);
    assert_eq!(h.finish_started().utterance_id, answer);
}

/// The armed play is for the named command's speech only.
#[test]
fn armed_play_is_not_taken_by_other_status_speech() {
    let h = Harness::new();
    let ack = h.accept(uncommanded("Looking into it.", "handoff", "handoff-1"));
    h.worker.deliver();
    let command = h.command();
    h.coordinator
        .arm_waiting_playback(command.0, &command.1, "final");

    h.play();

    assert_eq!(h.worker.plays(), 0);
    assert_eq!(h.phases(&ack), ["queued"]);
}

/// "`speak` with `waiting_playback_kind` does the same atomically."
#[test]
fn waiting_playback_kind_arms_with_the_speak() {
    let h = Harness::new();
    let command = h.command();
    assert!(
        h.propose_armed(reply("The answer.", &command), Some("final"))
            .0
    );
    assert_eq!(h.states("session-a"), json!({"session-a": "play"}));

    let h = Harness::new();
    let command = h.command();
    assert!(h.propose(reply("The answer.", &command)));
    assert_eq!(h.states("session-a"), json!({}));
}

// -- Sessions -----------------------------------------------------------------------

/// `session_playback_states`: "`states`: session key to `play`, `stop` or
/// `replay`" — "What each session's control would do now."
#[test]
fn session_playback_states_follow_each_sessions_reply() {
    let h = Harness::new();
    assert_eq!(h.states(""), json!({}));
    let first = h.speak_in("First reply.", "session-a");
    h.speak_in("Second reply.", "session-b");
    h.speak("No session.");
    assert_eq!(
        h.states(""),
        json!({"session-a": "play", "session-b": "play"})
    );

    assert_eq!(h.start_head(), first);
    assert_eq!(
        h.states(""),
        json!({"session-a": "stop", "session-b": "play"})
    );

    h.coordinator.skip("user_stop");
    assert_eq!(
        h.states(""),
        json!({"session-a": "replay", "session-b": "play"})
    );
}

/// `waiting_session_key`: "While that play is armed, the session reports `play`"
#[test]
fn waiting_session_key_reports_play_only_while_a_play_is_armed() {
    let h = Harness::new();
    assert_eq!(h.states("session-a"), json!({}));
    let command = h.command();
    h.coordinator
        .arm_waiting_playback(command.0, &command.1, "final");
    assert_eq!(h.states("session-a"), json!({"session-a": "play"}));
    assert_eq!(h.states(""), json!({}));
}

/// `waiting_session_key`: "a `control_session` `play` for it is kept for the reply."
#[test]
fn control_session_play_for_the_waiting_session_is_kept_for_its_reply() {
    let h = Harness::new();
    let command = h.command();
    h.coordinator
        .arm_waiting_playback(command.0, &command.1, "final");
    assert!(
        !h.coordinator
            .control_session("session-b", "play", "session-a")
    );
    assert!(
        h.coordinator
            .control_session("session-a", "play", "session-a")
    );
    assert_eq!(h.worker.plays(), 0);

    let answer = h.accept(IntentSpec {
        session_key: Some("session-a".into()),
        ..reply("The answer.", &command)
    });

    assert_eq!(h.worker.plays(), 1);
    assert_eq!(h.finish_started().utterance_id, answer);
}

/// `control_session`: "`stop` stops its playing reply with the reason
/// `wheel_stop`: the reply returns to the head and the queue is held."
/// "`false` when the action does not apply to that session"
#[test]
fn control_session_stop_acts_on_its_own_session_only() {
    let h = Harness::new();
    let first = h.speak_in("First reply.", "session-a");
    h.speak_in("Second reply.", "session-b");
    h.start_head();

    assert!(!h.control("session-b", "stop"));
    assert!(h.flag("playing"));
    assert!(h.worker.stops().is_empty());

    assert!(h.control("session-a", "stop"));

    assert_eq!(h.worker.stops(), ["wheel_stop"]);
    let ended = h.ended(&first);
    assert_eq!(ended.stop_reason.as_deref(), Some("wheel_stop"));
    assert!(ended.requeued_as.is_some());
    assert!(h.flag("held"));
    assert_eq!(
        h.states(""),
        json!({"session-a": "play", "session-b": "play"})
    );
    // With nothing playing, stop does not apply.
    assert!(!h.control("session-a", "stop"));
}

/// `control_session`: "`play` ... brings its queued reply forward and plays it;
/// a reply that was waiting at the head is `cancelled`, keeps its
/// `utterance_id`, and is `queued` again when it returns to the head."
#[test]
fn control_session_play_brings_a_sessions_queued_reply_forward() {
    let h = Harness::new();
    let first = h.speak_in("First reply.", "session-a");
    let second = h.speak_in("Second reply.", "session-b");
    h.worker.deliver();

    assert!(h.control("session-b", "play"));

    assert_eq!(h.finish_started().utterance_id, second);
    h.worker.deliver();
    assert_eq!(h.phases(&first), ["queued", "cancelled", "queued"]);
    assert_eq!(h.entries(), [(first.clone(), first)]);
}

/// `control_session`: "`play` plays its reply waiting at the head"; `false`
/// for a session with nothing waiting or queued.
#[test]
fn control_session_play_plays_the_sessions_waiting_reply() {
    let h = Harness::new();
    let utterance_id = h.speak_in("The answer.", "session-a");
    h.worker.deliver();
    assert!(!h.control("session-b", "play"));
    assert_eq!(h.phases(&utterance_id), ["queued"]);

    assert!(h.control("session-a", "play"));
    assert_eq!(h.finish_started().utterance_id, utterance_id);
}

/// `control_session`: "`false` when the action does not apply to that
/// session, including `play` while another session's reply is playing."
#[test]
fn control_session_play_while_another_session_plays_is_not_handled() {
    let h = Harness::new();
    let first = h.speak_in("First reply.", "session-a");
    let second = h.speak_in("Second reply.", "session-b");
    h.start_head();

    assert!(!h.control("session-b", "play"));
    // Its own reply is already playing.
    assert!(h.control("session-a", "play"));
    assert_eq!(h.queue(), [first.clone(), second]);
    assert!(!h.was_cancelled(&first));
}

/// `control_session`: "`replay` replays its newest reply."
#[test]
fn control_session_replay_repeats_the_sessions_newest_reply() {
    let h = Harness::new();
    let heard = h.speak_in("Reply for session a.", "session-a");
    h.play_through();
    h.speak_in("Reply for session b.", "session-b");
    h.play_through();

    assert!(h.control("session-a", "replay"));

    let replay = h.finish_started();
    assert_eq!(replay.replay_of.as_deref(), Some(heard.as_str()));
    assert_eq!(replay.session_key, "session-a");
    assert!(!h.control("session-c", "replay"));
}

// -- Freshness ------------------------------------------------------------------------

/// "An intent is fresh when ... it has no `command_seq` and `command_id`";
/// "an unreadable or missing file names none."
#[test]
fn fresh_intent_without_a_command() {
    let h = Harness::new();
    assert!(!h.propose(reply("The answer.", &(1, "command-1".into()))));
    assert!(h.propose(uncommanded("A stored reply.", "final", "stored-1")));
    h.command();
    assert!(h.propose(uncommanded("Another stored reply.", "final", "stored-2")));
}

/// "An intent is fresh when ... its command is the current command": the
/// state file's `relay_command_seq` and `relay_command_id` name it.
#[test]
fn fresh_when_its_command_is_the_current_command() {
    let h = Harness::new();
    h.set_current(Some((7, "command-7".into())));
    assert!(!h.propose(reply("Wrong id.", &(7, "another-id".into()))));
    assert!(!h.propose(reply("Wrong seq.", &(8, "command-7".into()))));
    assert!(h.propose(reply("Right command.", &(7, "command-7".into()))));
}

/// "An intent is fresh when ... it is an explicit replay"
#[test]
fn fresh_explicit_replay_whatever_the_current_command() {
    let h = Harness::new();
    let utterance_id = h.speak("The answer.");
    h.play_through();
    h.command();
    assert!(h.coordinator.replay(None));
    assert_eq!(
        h.finish_started().replay_of.as_deref(),
        Some(utterance_id.as_str())
    );
}

/// "An intent is fresh when ... it is ... a `lifecycle` `final` with
/// `freshness_scope: "work"`"; "`work` exempts a `lifecycle` `final` from
/// command freshness."
#[test]
fn fresh_work_scoped_lifecycle_final_outlives_its_command() {
    let h = Harness::new();
    let older = h.command();
    let other = h.command();
    h.command();
    let work = |spec: IntentSpec| IntentSpec {
        freshness_scope: Some("work".into()),
        ..spec
    };

    let finished = h.accept(work(spec(
        "The worker finished.",
        &older,
        "final",
        "lifecycle",
        false,
    )));
    // The scope is honoured for a lifecycle final only.
    assert!(!h.propose(work(progress("Still working.", &older))));
    assert!(!h.propose(work(spec("Done.", &other, "final", "orchestrator", false))));

    assert_eq!(h.play_through(), finished);
}

/// "An intent is fresh when ... it is a reply that was already accepted"
#[test]
fn fresh_reply_that_was_already_accepted() {
    let h = Harness::new();
    let answer = h.speak("Earlier reply.");
    h.command();
    assert_eq!(h.play_through(), answer);
}

/// "An intent is fresh when ... it is an authoritative `final` or `fallback`
/// whose command is **preserved**"
#[test]
fn fresh_authoritative_outcome_of_a_preserved_command() {
    let h = Harness::new();
    let older = h.command();
    let other = h.command();
    h.command();
    h.preserve.store(true, Ordering::SeqCst);

    assert!(
        !h.propose(handoff("Looking into it.", &older)),
        "only a final or fallback is preserved"
    );
    assert!(
        !h.propose(spec("Probably done.", &older, "final", "messenger", false)),
        "only an authoritative outcome is preserved"
    );
    assert!(h.preserved_calls.lock().unwrap().is_empty());

    let Value::Object(disposition) = json!({"intent_id": "intent-1"}) else {
        unreachable!()
    };
    let preserved = IntentSpec {
        work_disposition: Some(disposition.clone()),
        ..reply("The earlier work is done.", &older)
    };
    assert!(h.propose(preserved));
    // The decision is the client's: it is given the intent's `work_disposition`.
    assert_eq!(
        h.preserved_calls.lock().unwrap().clone(),
        [(older, disposition)]
    );
    assert!(h.propose(IntentSpec {
        authoritative: true,
        ..fallback("I could not confirm it.", &other)
    }));

    h.preserve.store(false, Ordering::SeqCst);
    let later = h.command();
    h.command();
    assert!(!h.propose(reply("Not preserved.", &later)));
}

/// "Freshness is checked when an intent is proposed, when it reaches the head
/// of the queue, and before each sentence is played." Here: at the head.
#[test]
fn freshness_is_checked_when_an_intent_reaches_the_head() {
    let h = Harness::new();
    let command = h.command();
    let answer = h.accept(reply("The answer.", &command));
    let note = h.accept(progress("One more note.", &command));
    assert_eq!(h.queue(), [answer.clone(), note.clone()]);
    h.command();

    assert_eq!(h.play_through(), answer);

    assert!(h.queue().is_empty());
    assert!(h.events(&note).is_empty());
    assert_eq!(h.worker.enqueued(), [answer]);
}

/// "Freshness is checked ... before each sentence is played", including the
/// first, when `play` asks for the head.
#[test]
fn freshness_is_checked_before_playing() {
    // A waiting handoff that went stale is not played.
    let h = Harness::new();
    let command = h.command();
    let waiting = h.accept(handoff("Looking into it.", &command));
    h.worker.deliver();
    h.command();

    h.play();

    assert_eq!(h.worker.plays(), 1);
    let ended = h.ended(&waiting);
    assert_eq!(
        (ended.state.as_str(), ended.requeued_as),
        ("cancelled", None)
    );
    assert_eq!(h.phases(&waiting), ["queued", "cancelled"]);
    assert!(h.queue().is_empty());

    // A playing handoff stops before its next sentence.
    let h = Harness::new();
    let command = h.command();
    let playing = h.accept(handoff("Looking into it. Still looking.", &command));
    h.start_head();
    assert!(h.worker.next_sentence());
    h.command();

    assert!(!h.worker.next_sentence());

    let ended = h.ended(&playing);
    assert_eq!(
        (ended.state.as_str(), ended.requeued_as),
        ("cancelled", None)
    );
    assert!(h.queue().is_empty() && !h.flag("playing"));
}

// -- Events: reply_finished ------------------------------------------------------------

/// `reply_finished`: "A reply ended and nothing else is queued." Reason `completed`.
#[test]
fn reply_finished_when_the_last_reply_ends() {
    let h = Harness::new();
    h.speak("First reply.");
    h.speak("Second reply.");
    h.play_through();
    assert!(h.finished().is_empty());

    h.play_through();

    assert_eq!(h.finished(), ["completed"]);
}

/// `reply_finished`: `"reason": ... "user_stop"` when the user skipped the last reply.
#[test]
fn reply_finished_with_user_stop_when_the_last_reply_is_skipped() {
    let h = Harness::new();
    h.speak("The answer.");
    h.start_head();
    h.coordinator.skip("user_stop");
    assert_eq!(h.finished(), ["user_stop"]);
}

/// `reply_finished` is about replies: status speech ending reports nothing.
#[test]
fn reply_finished_is_not_reported_for_status_speech() {
    let h = Harness::new();
    let command = h.command();
    h.accept(handoff("Looking into it.", &command));
    h.play_through();
    assert!(h.finished().is_empty());
}

/// `reply_finished`: "A `final` or `fallback` ended and nothing else is
/// queued"; a clarification waits for the user's answer, so it is not one.
#[test]
fn reply_finished_is_not_reported_for_a_clarification() {
    let h = Harness::new();
    let command = h.command();
    h.accept(spec(
        "Which file do you mean?",
        &command,
        "clarification",
        "orchestrator",
        true,
    ));
    h.play_through();
    assert!(h.finished().is_empty());
}

// -- Diagnostics ----------------------------------------------------------------------

/// `played_coverage`: "What finished playing for a command, newest last, at most 8."
#[test]
fn played_coverage_lists_what_finished_newest_last_at_most_eight() {
    let h = Harness::new();
    let command = h.command();
    let ids: Vec<String> = (0..10)
        .map(|number| {
            let utterance_id = h.accept(progress(&format!("Step {number}."), &command));
            assert_eq!(h.play_through(), utterance_id);
            utterance_id
        })
        .collect();

    let coverage = h.coordinator.played_coverage(command.0, &command.1);
    let utterances: Vec<&str> = coverage
        .iter()
        .map(|item| item["utterance_id"].as_str().unwrap())
        .collect();
    assert_eq!(utterances, &ids[2..]);
    assert_eq!(
        coverage[7],
        json!({"utterance_id": ids[9], "lifecycle_role": "progress", "covered_facts": ["Step 9."], "spoken_text": "Step 9."})
    );

    // `covered_facts` and `lifecycle_role` are returned as given.
    let answer = h.accept(IntentSpec {
        covered_facts: vec!["build passed".into()],
        lifecycle_role: Some("result".into()),
        ..reply("The build passed.", &command)
    });
    h.play_through();
    let newest = json!({"utterance_id": answer, "lifecycle_role": "result", "covered_facts": ["build passed"], "spoken_text": "The build passed."});
    let coverage = h.coordinator.played_coverage(command.0, &command.1);
    assert_eq!((coverage.len(), coverage.last()), (8, Some(&newest)));

    // The same speech again, a replay, or an attempt that was stopped adds nothing.
    h.accept(IntentSpec {
        dedup_key: Some("again".into()),
        ..progress("Step 9.", &command)
    });
    h.play_through();
    assert!(h.coordinator.replay(None));
    h.finish_started();
    h.accept(progress("Step 10.", &command));
    h.start_head();
    h.coordinator.stop_playback("interrupt", None);
    let coverage = h.coordinator.played_coverage(command.0, &command.1);
    assert_eq!((coverage.len(), coverage.last()), (8, Some(&newest)));
    assert!(
        h.coordinator
            .played_coverage(command.0 + 1, &command.1)
            .is_empty()
    );
}

/// `record_missing_outcome`: "Writes one `missing_outcome` record per command;
/// `false` when the command has an accepted reply or was already recorded."
#[test]
fn record_missing_outcome_once_per_command_without_an_accepted_reply() {
    let h = Harness::new();
    let command = h.command();
    assert!(
        h.coordinator
            .record_missing_outcome(command.0, &command.1, "timeout", &[])
    );
    assert!(
        !h.coordinator
            .record_missing_outcome(command.0, &command.1, "timeout", &[])
    );

    let answered = h.command();
    h.accept(reply("The answer.", &answered));
    assert!(
        !h.coordinator
            .record_missing_outcome(answered.0, &answered.1, "timeout", &[])
    );

    let stood_in = h.command();
    h.accept(fallback("I could not confirm it.", &stood_in));
    assert!(
        !h.coordinator
            .record_missing_outcome(stood_in.0, &stood_in.1, "timeout", &[])
    );

    // Status speech is not an outcome.
    let acknowledged = h.command();
    h.accept(handoff("Looking into it.", &acknowledged));
    assert!(h.coordinator.record_missing_outcome(
        acknowledged.0,
        &acknowledged.1,
        "",
        &["provider_exit".into()]
    ));
}

/// `record_missing_outcome`: "`false` when the command has an accepted
/// `final` or `fallback`"; a clarification is not the command's outcome.
#[test]
fn record_missing_outcome_does_not_count_a_clarification_as_an_outcome() {
    let h = Harness::new();
    let command = h.command();
    h.accept(spec(
        "Which file do you mean?",
        &command,
        "clarification",
        "orchestrator",
        true,
    ));
    assert!(
        h.coordinator
            .record_missing_outcome(command.0, &command.1, "timeout", &[])
    );
}

// -- Session: reload_config -------------------------------------------------------

/// `reload_config`: "A changed voice or rate stops the current playback; the
/// reply returns to the head of the queue."
#[test]
fn reload_config_with_a_changed_voice_returns_the_reply_to_the_head() {
    let h = Harness::new();
    h.worker.voice_changed.store(true, Ordering::SeqCst);
    let utterance_id = h.speak("The answer.");
    h.start_head();

    h.coordinator.reload_config();

    let requeued = h
        .ended(&utterance_id)
        .requeued_as
        .expect("the reply returned to the queue");
    assert_eq!(h.entries(), [(requeued.clone(), utterance_id)]);
    assert_eq!(h.worker.last_enqueued().utterance_id, requeued);
}

// -- Relay Remote -------------------------------------------------------------------

fn sink(h: &Harness, id: &str) -> Arc<FakeDevice> {
    let device = FakeDevice::new(id);
    h.coordinator.attach_remote_sink(device.clone());
    device
}

fn controls(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs
        .iter()
        .map(|(action, reason)| ((*action).to_string(), (*reason).to_string()))
        .collect()
}

/// "`sink`: the device becomes the speech output instead of the Mac's
/// speaker"; "an accepted `speak` is not queued for the Mac's speaker. The
/// service calls `remote_speech`"; `queue_depth` counts "frames a Relay Remote
/// sink has not acknowledged".
#[test]
fn remote_sink_takes_speech_instead_of_the_mac_queue() {
    let h = Harness::new();
    let device = sink(&h, "device-1");
    let command = h.command();

    let utterance_id = h.accept(reply("Reply for the phone.", &command));

    assert_eq!(
        device.frames(),
        [
            json!({"kind": "final", "source": "orchestrator", "text": "Reply for the phone.",
                "relay_command_seq": command.0, "audio": false})
        ]
    );
    assert!(h.worker.enqueued().is_empty());
    assert!(h.queue().is_empty());
    assert!(!h.flag("speaking"));
    assert_eq!(h.depth(), 1);
    assert!(h.events(&utterance_id).is_empty());
}

/// Remote synthesis: "with `audio: true` when it can voice the reply itself";
/// "A `remote_ack` for the frame, or a `remote_speech_control` that covers it,
/// stops the remaining audio."
#[test]
fn remote_sink_is_voiced_until_the_frame_is_acknowledged_or_stopped() {
    let h = Harness::new();
    h.worker.remote_audio.store(true, Ordering::SeqCst);
    let device = sink(&h, "device-1");
    h.speak("Reply for the phone.");
    let seq = device.last_seq();
    assert_eq!(device.frames()[0]["audio"], json!(true));
    let job = h
        .worker
        .lock()
        .jobs
        .pop()
        .expect("the worker was asked to voice the reply");
    assert_eq!(job.text, "Reply for the phone.");

    let part = |index: i64| AudioPart {
        part: index,
        parts: 0,
        last: false,
        data: "AAAA".into(),
    };
    assert_eq!((job.emit)(&part(0)), Ok(()));
    assert_eq!(device.audio(), [(seq, part(0))]);

    assert!(h.coordinator.remote_ack("device-1", seq, true));

    assert!(job.cancelled.load(Ordering::SeqCst));
    assert_eq!((job.emit)(&part(1)), Ok(()));
    assert_eq!(device.audio().len(), 1);

    h.speak("Another reply.");
    let job = h
        .worker
        .lock()
        .jobs
        .pop()
        .expect("the worker was asked to voice the reply");
    h.coordinator.skip("user_stop");
    assert!(job.cancelled.load(Ordering::SeqCst));
}

/// `remote_ack`: "The device acknowledged the frame `seq`. `played: true`
/// counts the reply as heard"; `known` is false for a frame never sent or
/// already acknowledged.
#[test]
fn remote_ack_played_counts_the_reply_as_heard() {
    let h = Harness::new();
    let device = sink(&h, "device-1");
    let command = h.command();
    let utterance_id = h.accept(reply("The answer.", &command));
    let seq = device.last_seq();

    assert!(h.coordinator.remote_ack("device-1", seq, true));

    assert_eq!(h.depth(), 0);
    let coverage = h.coordinator.played_coverage(command.0, &command.1);
    assert_eq!(
        coverage
            .iter()
            .map(|item| item["utterance_id"].clone())
            .collect::<Vec<_>>(),
        [json!(utterance_id)]
    );
    assert!(!h.coordinator.remote_ack("device-1", seq, true));
    assert!(!h.coordinator.remote_ack("device-1", 99, true));
    assert!(!h.coordinator.remote_ack("device-2", seq, true));
}

/// `remote_ack` with `played: false` acknowledges receipt only.
#[test]
fn remote_ack_received_is_receipt_only() {
    let h = Harness::new();
    let device = sink(&h, "device-1");
    let command = h.command();
    h.accept(reply("The answer.", &command));

    assert!(
        h.coordinator
            .remote_ack("device-1", device.last_seq(), false)
    );

    assert_eq!(h.depth(), 0);
    assert!(
        h.coordinator
            .played_coverage(command.0, &command.1)
            .is_empty()
    );
}

/// "While a sink has frames it has not acknowledged, `pause` and
/// `stop_playback` send it one `stop` and `skip` sends one `skip`, with the
/// reason of the request (`speech_only_barge_in` for `pause`; `newer_command`
/// is sent as `superseded`). ... With no unacknowledged frame, no control is sent."
#[test]
fn remote_stop_and_skip_send_one_control_while_frames_are_unacknowledged() {
    let h = Harness::new();
    let device = sink(&h, "device-1");
    h.coordinator.skip("user_stop");
    h.coordinator.stop();
    h.coordinator.stop_playback("interrupt", None);
    assert!(device.controls().is_empty());

    h.speak("First reply.");
    h.coordinator.skip("user_stop");
    // The control covers the frame, so a second skip has nothing to stop.
    h.coordinator.skip("user_stop");
    h.speak("Second reply.");
    h.coordinator.stop();
    h.speak("Third reply.");
    h.coordinator.stop_playback("interrupt", None);
    h.speak("Fourth reply.");
    h.coordinator.stop_playback("newer_command", None);
    let sent = controls(&[
        ("skip", "user_stop"),
        ("stop", "speech_only_barge_in"),
        ("stop", "interrupt"),
        ("stop", "superseded"),
    ]);
    assert_eq!(device.controls(), sent);

    // An acknowledged frame needs no control.
    h.speak("Fifth reply.");
    assert!(
        h.coordinator
            .remote_ack("device-1", device.last_seq(), true)
    );
    h.coordinator.skip("user_stop");
    h.coordinator.stop();
    assert_eq!(device.controls(), sent);
}

/// "`new_turn` sends `stop` with the reason `superseded` when the sink holds
/// status speech of an older command, unless a reply it has not acknowledged
/// would be dropped with it."
#[test]
fn remote_new_turn_stops_older_status_speech_unless_a_reply_would_be_dropped() {
    let h = Harness::new();
    let device = sink(&h, "device-1");
    let older = h.command();
    h.accept(handoff("Looking into it.", &older));
    let command = h.command();
    h.coordinator.new_turn(command.0, &command.1);
    assert_eq!(device.controls(), controls(&[("stop", "superseded")]));

    let h = Harness::new();
    let device = sink(&h, "device-1");
    let older = h.command();
    h.accept(reply("The answer.", &older));
    h.accept(progress("One more note.", &older));
    let command = h.command();
    h.coordinator.new_turn(command.0, &command.1);
    assert!(device.controls().is_empty());
}

/// Newer command and Replace on a sink: an older command's unacknowledged
/// status speech, or the command's own fallback, is stopped before the newer
/// speech is sent.
#[test]
fn remote_newer_speech_stops_older_status_speech_and_the_fallback_it_replaces() {
    let h = Harness::new();
    let device = sink(&h, "device-1");
    let older = h.command();
    h.accept(handoff("Looking into it.", &older));
    let command = h.command();
    h.accept(reply("The answer.", &command));
    assert_eq!(device.controls(), controls(&[("stop", "superseded")]));
    assert!(
        h.coordinator
            .remote_ack("device-1", device.last_seq(), true)
    );

    let command = h.command();
    h.accept(fallback("I could not confirm it.", &command));
    h.accept(reply("The build passed.", &command));
    assert_eq!(
        device.controls(),
        controls(&[("stop", "superseded"), ("stop", "superseded")])
    );
    assert_eq!(
        device.texts().last().map(String::as_str),
        Some("The build passed.")
    );
}

/// `remote_detach`: "Ends the role. Replies a sink had not acknowledged return
/// to the Mac queue."
#[test]
fn remote_detach_returns_unacknowledged_replies_to_the_mac_queue() {
    let h = Harness::new();
    let device = sink(&h, "device-1");
    let first = h.speak("First reply.");
    let heard = device.last_seq();
    let second = h.speak("Second reply.");
    let command = h.command();
    let ack = h.accept(handoff("Looking into it.", &command));
    assert!(h.coordinator.remote_ack("device-1", heard, true));

    h.coordinator
        .detach_remote_sink("device-1", "remote_mode_off");

    // Only the unacknowledged reply returns; a handoff is not a reply.
    assert_eq!(h.queue(), [second.as_str()]);
    assert_eq!(h.worker.enqueued(), [second.as_str()]);
    assert!(h.events(&ack).is_empty() && h.events(&first).is_empty());
    assert_eq!(h.play_through(), second);
    // With no sink, speech is for the Mac again.
    let third = h.speak("Third reply.");
    assert_eq!(h.queue(), [third]);
    assert_eq!(device.frames().len(), 3);
}

/// `remote_routable`: "A sink that is not routable is detached."
#[test]
fn remote_sink_that_is_not_routable_is_detached() {
    let h = Harness::new();
    let device = sink(&h, "device-1");
    device.routable.store(false, Ordering::SeqCst);

    let utterance_id = h.speak("The answer.");

    assert_eq!(h.queue(), [utterance_id]);
    assert!(device.frames().is_empty());
    // It stays detached: the next reply asks nothing of it.
    device.routable.store(true, Ordering::SeqCst);
    let asked = device.routable_calls.load(Ordering::SeqCst);
    h.speak("Second reply.");
    assert_eq!(device.routable_calls.load(Ordering::SeqCst), asked);
    assert!(device.frames().is_empty());
}

/// `remote_speech`: "A failed reply means the frame was not sent, and `speak`
/// answers `accepted: false`."
#[test]
fn remote_failed_speech_call_refuses_the_speak() {
    let h = Harness::new();
    let device = sink(&h, "device-1");
    device.refuse_speech.store(true, Ordering::SeqCst);
    let command = h.command();

    assert!(!h.propose(reply("The answer.", &command)));

    assert_eq!(h.depth(), 0);
    assert!(h.worker.enqueued().is_empty());
    // It was never accepted, so it may be proposed again.
    device.refuse_speech.store(false, Ordering::SeqCst);
    assert!(h.propose(reply("The answer.", &command)));
    assert_eq!(device.frames().len(), 1);
}

/// Two sinks: the device attached last is the output.
#[test]
fn remote_newest_sink_takes_the_speech() {
    let h = Harness::new();
    let older = sink(&h, "device-1");
    let newer = sink(&h, "device-2");
    h.speak("The answer.");
    assert_eq!(newer.frames().len(), 1);
    assert!(older.frames().is_empty());
}

/// A reply sent to the device joins the replay history, and its replay goes to the device.
#[test]
fn remote_replay_is_sent_to_the_device() {
    let h = Harness::new();
    let device = sink(&h, "device-1");
    h.speak("Reply for the phone.");
    assert!(h.coordinator.replay(None));
    assert_eq!(
        device.texts(),
        ["Reply for the phone.", "Reply for the phone."]
    );
    assert!(h.queue().is_empty() && h.worker.enqueued().is_empty());
}

/// Queue rules: a `dedup_key` "accepted before" is refused, whatever the output.
#[test]
fn remote_speech_is_deduplicated() {
    let h = Harness::new();
    let device = sink(&h, "device-1");
    let command = h.command();
    assert!(h.propose(reply("The answer.", &command)));
    assert!(!h.propose(reply("The answer.", &command)));
    assert_eq!(device.frames().len(), 1);
}

/// "`mirror`: the Mac keeps speaking and the device is sent the text of each reply."
#[test]
fn remote_mirror_is_sent_the_text_of_what_the_mac_speaks() {
    let h = Harness::new();
    let mirror = FakeDevice::new("device-1");
    h.coordinator.attach_remote_mirror(mirror.clone());
    let command = h.command();

    let utterance_id = h.accept(reply("Reply for the Mac.", &command));

    assert_eq!(h.queue(), [utterance_id.as_str()]);
    assert_eq!(
        mirror.frames(),
        [
            json!({"kind": "final", "source": "orchestrator", "text": "Reply for the Mac.",
                "relay_command_seq": command.0, "spoken_by": "mac"})
        ]
    );
    assert_eq!(h.play_through(), utterance_id);
    assert_eq!(mirror.routable_calls.load(Ordering::SeqCst), 0);
    assert!(mirror.controls().is_empty() && mirror.audio().is_empty());
}

/// `mirror`: "the Mac keeps speaking", also when the device refuses the text.
#[test]
fn remote_mirror_that_fails_never_stops_mac_speech() {
    let h = Harness::new();
    let mirror = FakeDevice::new("device-1");
    mirror.refuse_speech.store(true, Ordering::SeqCst);
    h.coordinator.attach_remote_mirror(mirror);
    let utterance_id = h.speak("The answer.");
    assert_eq!(h.play_through(), utterance_id);
}

/// `remote_detach`: "Ends the role"; a detached mirror is sent nothing.
#[test]
fn remote_detached_mirror_is_sent_nothing() {
    let h = Harness::new();
    let mirror = FakeDevice::new("device-1");
    h.coordinator.attach_remote_mirror(mirror.clone());
    h.coordinator.detach_remote_mirror("device-1");
    h.speak("The answer.");
    assert!(mirror.frames().is_empty());
}

/// `remote_attach`: "Attaching a device as `sink` ends its `mirror` role."
#[test]
fn remote_attaching_as_sink_ends_the_mirror_role() {
    let h = Harness::new();
    let mirror = FakeDevice::new("device-1");
    h.coordinator.attach_remote_mirror(mirror.clone());
    let device = sink(&h, "device-1");

    h.speak("The answer.");

    assert_eq!(device.frames().len(), 1);
    assert!(device.frames()[0].get("spoken_by").is_none());
    assert!(mirror.frames().is_empty());
}
