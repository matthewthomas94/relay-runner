//! Relay command action classification: `services/command_actions.py`, the
//! part the voice bridge imports (`resolve_command_action`,
//! `format_command_for_agent`, `is_mixed_query_and_mutation`) and everything
//! they reach.
//!
//! The foreground Codex or Claude session is the PM frontstage. Command
//! handling stays explicit before work routes backstage: controls are
//! intentional no-ticket actions, ticket references attach to existing work,
//! and new project-work requests become refined management tickets before any
//! worker implementation starts. Raw Relay captures stay private.
//!
//! Each pattern is the Python module's, compiled with the same meaning (see
//! `relay_intents::pattern::compile`). Ticket authoring
//! (`create_ticket_for_command` and its summary and worker-sizing helpers) and
//! `set_session_work_style` are not reached by the bridge and are not here.

use std::fs;
use std::path::{Component, Path, PathBuf};
use std::sync::LazyLock;

use relay_intents::arbitration::explicit_cancel_requested;
use relay_intents::pattern::{self, Regex, compile, search};
use relay_intents::qualification::{
    discussion_only_requested, foreground_action_requested, mixed_bucket_request,
};

use crate::json::{self, Dict, Value};
use crate::support::env_optional;

/// `CONTROL_COMMANDS`: the internal controls and their reasons.
const CONTROL_COMMANDS: [(&str, &str); 5] = [
    ("__TTS_STOP__", "tts_stop"),
    ("__PLAY__", "play"),
    ("__REPLAY__", "replay"),
    ("__INTERRUPT__", "interrupt"),
    ("__CANCEL__", "cancel"),
];

const WORK_STYLES: [&str; 3] = ["auto", "direct", "orchestrated"];
const WORK_STYLE_FILE: &str = ".relay-runner.toml";

static TICKET_ID_RE: LazyLock<Regex> =
    LazyLock::new(|| compile(r"\b(GEN-[A-Fa-f0-9]{16}|[A-Za-z][A-Za-z0-9]*-\d+)\b", false));
static INSPECT_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(status|state|how'?s|how\s+is|what'?s|what\s+is|show|summarize|check)\b",
        true,
    )
});
static INLINE_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(inline|in\s+this\s+session|do\s+it\s+(?:here|now)|just\s+do\s+it|don'?t\s+dispatch|without\s+(a\s+)?ticket)\b",
        true,
    )
});
static SESSION_OPERATION_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"\b(?:rebuild|build)\b[^.?!]{0,80}\binstall\b",
            r"|\bcommit\b[^.?!]{0,80}\b(?:remote|push|everything|all\s+changes|changes)\b",
            r"|\bpush\b[^.?!]{0,80}\b(?:remote|origin|main)\b",
        ),
        true,
    )
});
static SCREEN_OBSERVATION_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"\bwhat(?:'s|\s+is)\s+(?:on\s+)?(?:my|the)\s+(?:screen|display|desktop)\b",
            r"|\b(?:look|check|describe|read)\s+(?:at\s+)?(?:my|the)\s+(?:screen|display|desktop)\b",
            r"|\b(?:take|capture)\s+(?:a\s+)?screenshot\b",
            r"|\bcan\s+you\s+see\b[^.?!]{0,80}\b(?:screen|display|desktop|window)\b",
        ),
        true,
    )
});
static DESKTOP_CONTROL_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"^\s*(?:please\s+)?(?:open|launch|reveal|bring\s+up|focus|switch\s+to|close|quit)\b",
            r"|\bshow\b[^.?!]{0,80}\b(?:finder|chrome|safari|browser|app|application|folder|directory|file|window)\b",
            r"|^\s*(?:please\s+)?(?:click|double[- ]click|right[- ]click|scroll|press|tap|drag|type|select)\b",
        ),
        true,
    )
});
/// `PENDING_WORK_RE`, anchored to a clause start: "interpret when tickets are
/// done" is a topic, while "once those tickets are done, merge them" is an
/// instruction.
static PENDING_WORK_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"(?:^|[.,;:!?]\s*|\b(?:and|then|so|okay|ok)\s+)(?:once|when|after)\s+",
            r"(?:(?:all|any|the|these|those|this|that)\s+)?",
            r"(?:[A-Za-z][A-Za-z0-9]*-\d+|ticket|tickets|run|runs|worker|workers|it|they|these|those)\b",
            r"[^.?!]*\b(done|finish|finished|complete|completed|merge|merged|review|reviewed)\b",
        ),
        true,
    )
});
/// `_WORK_STYLE_RE`, compiled with `re.MULTILINE`: `^` also matches after a
/// newline and `$` before any newline, which `pattern::compile` would read
/// as the end of the text, so the lookahead is spelled out.
static WORK_STYLE_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r#"(?m)^\s*work_style\s*=\s*["']?(\w+)["']?\s*(?=\n|\z)"#,
        false,
    )
});
/// `EXPLICIT_TRACKING_RE`: words that ask for tracked or delegated work
/// rather than an immediate change.
static EXPLICIT_TRACKING_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"\b(?:ticket|tickets|backlog|board|worker|workers|sub[- ]?agents?|delegate|dispatch|",
            r"hand\s+(?:it|this|that)\s+off|in\s+the\s+background|track\s+(?:it|this|that))\b",
        ),
        true,
    )
});
static NEGATED_TICKET_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(?:do\s+not|don['’]?t|no|never|without)\s+(?:(?:write|create|make|open|need)\s+)?(?:an?\s+)?ticket",
        true,
    )
});
/// `WORK_STYLE_SWITCH_RE`: "Switch to direct mode", "set the work style to
/// orchestrated", "use auto mode".
static WORK_STYLE_SWITCH_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"^\s*(?:(?:hey|hi|okay|ok|so|please|can\s+you|could\s+you)\b[,!\s]*)*",
            r"(?:switch|change|set|use|go|move|put)\b[^.?!]{0,40}?\b(?P<style>auto|direct|orchestrated)\s+",
            r"(?:mode|work\s*style|style)\b",
            r"|^\s*(?:(?:okay|ok|so|please)\b[,!\s]*)*(?:set|change|switch)\s+(?:the\s+)?(?:work\s*style|mode)\s+",
            r"(?:to\s+|into\s+)?(?P<style2>auto|direct|orchestrated)\b",
        ),
        true,
    )
});
static ORCHESTRATION_CORRECTION_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"\bwhy\s+did\s+you\s+(?:write|create|make|dispatch)\b.*\b(ticket|orchestrator)\b",
            r"|\bthe\s+(?:entire\s+)?point\s+is\b.*\borchestrator\b.*\b(?:write|create|author)\b.*\bticket\b",
            r"|\bso\s+(?:i|we)\s+can\s+continue\s+talking\b.*\b(ticket|orchestrator)\b",
        ),
        true,
    )
});
static RELAY_RUNNER_NAME_RE: LazyLock<Regex> =
    LazyLock::new(|| compile(r"\b(?:the\s+)?relay\s+runner\b", true));
static RELAY_RUNNER_DEMO_CONTEXT_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(?:demo(?:ing|nstrat(?:e|ing|ion))?|audience|viewers?)\b",
        true,
    )
});
static RELAY_RUNNER_EXPLANATION_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"\b(?:explain|describe|introduce|summari[sz]e)\b[^.?!]{0,160}",
            r"\b(?:what(?:\s+it|\s+what\s+it)+\s+(?:is|does)|",
            r"what\s+(?:the\s+)?relay\s+runner\s+(?:is|does))\b",
            r"|\b(?:explain|describe|introduce|summari[sz]e)\s+",
            r"(?:the\s+)?relay\s+runner\s*(?:[?.!]|$)",
        ),
        true,
    )
});
static RELAY_RUNNER_DIRECT_QUESTION_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"^\s*(?:(?:hey|hi|okay|ok|so)\b[,!\s]*)*",
            r"(?:what\s+is\s+(?:the\s+)?relay\s+runner\b(?!['’]s\b)",
            r"|what\s+does\s+(?:the\s+)?relay\s+runner\s+do\b)",
        ),
        true,
    )
});
static RELAY_RUNNER_OVERVIEW_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"\btell\s+(?:me|us|the\s+audience)\s+about\s+(?:the\s+)?relay\s+runner\b",
            r"|\b(?:give|provide)\b[^.?!]{0,80}\b(?:overview|introduction)\b",
            r"[^.?!]{0,80}\b(?:the\s+)?relay\s+runner\b",
            r"|^\s*(?:(?:hey|hi|okay|ok|so)\b[,!\s]*)*what\s+(?:is|are)\s+",
            r"(?:the\s+)?(?:core\s+)?(?:functionality|capabilities|purpose)\s+of\s+",
            r"(?:the\s+)?relay\s+runner\b",
        ),
        true,
    )
});
/// The explanation verbs `is_relay_runner_self_explanation` pairs with a
/// demo context.
static RELAY_RUNNER_EXPLAIN_WORD_RE: LazyLock<Regex> =
    LazyLock::new(|| compile(r"\b(?:explain|describe|introduce|overview)\b", true));

/// `_COMMAND_LEAD`.
const COMMAND_LEAD: &str = r"(?:(?:hey|hi|okay|ok|so|actually|no)\b[,!\s]*)*";
/// `_MUTATION_VERB`.
const MUTATION_VERB: &str = concat!(
    r"(?:add|build|change|clean\s+up|create|debug|delete|design|fix|implement|",
    r"install|make|merge|migrate|refactor|remove|repair|ship|test|wire|write|",
    r"swap|move|trim|shorten|lengthen|slow\s+down|speed\s+up|render|export|rename|replace|",
    r"resize|crop|mute|tweak|adjust|turn\s+(?:it|this|that|the\s+\w+)\s+(?:up|down)|",
    r"update(?!\s+(?:me|us)\b)|run(?!\s+(?:me|us)\s+through\b))",
);

static LEADING_TARGET_CONTEXT_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        &[
            r"^\s*",
            COMMAND_LEAD,
            r"(?:",
            r"(?:for|in|on|regarding|about)\s+[^,;:?!]{1,120}",
            r"|[A-Za-z][A-Za-z0-9]*-\d+",
            r")\s*[,;:]\s*(?P<command>.+)$",
        ]
        .concat(),
        true,
    )
});
static EXPLICIT_MUTATION_REQUEST_RE: LazyLock<Regex> = LazyLock::new(|| {
    let lead = COMMAND_LEAD;
    let verb = MUTATION_VERB;
    compile(
        &[
            r"^\s*",
            lead,
            r"(?:(?:i\s+mean|please|go\s+ahead\s+and)\s+)?(?:",
            verb,
            r"\b|(?:do|perform)\s+(?:an?|the)\b)",
            r"|^\s*",
            lead,
            r"(?:please\s+)?(?:can|could|would|will)\s+",
            r"you\s+(?:please\s+)?(?:",
            verb,
            r"\b|(?:do|perform)\s+(?:an?|the)\b)",
            r"|^\s*",
            lead,
            r"(?:i|we)\s+(?:need|want|would\s+like)\s+",
            r"(?:you\s+|us\s+)?to\s+",
            verb,
            r"\b",
            r"|^\s*",
            lead,
            r"(?:i|we)\s+(?:need|want|would\s+like)\s+",
            r"(?:an?\s+)?clean\s+build\b",
            r"|^\s*",
            lead,
            r"let['’]?s\s+",
            verb,
            r"\b",
        ]
        .concat(),
        true,
    )
});
static EXPLICIT_DISPATCH_REQUEST_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        &[
            r"^\s*",
            COMMAND_LEAD,
            r"(?:(?:i\s+mean|please)\s+)?",
            r"(?:dispatch|delegate|hand\s+off|kick\s+off|start|spin\s+up|work\s+on|",
            r"run(?!\s+(?:me|us)\s+through\b))\b",
            r"|^\s*",
            COMMAND_LEAD,
            r"(?:please\s+)?(?:can|could|would|will)\s+",
            r"you\s+(?:please\s+)?",
            r"(?:dispatch|delegate|hand\s+off|kick\s+off|start|spin\s+up|work\s+on|",
            r"run(?!\s+(?:me|us)\s+through\b))\b",
        ]
        .concat(),
        true,
    )
});
static DURABLE_WORK_ESCALATION_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        &[
            r"^\s*",
            COMMAND_LEAD,
            r"(?:(?:please|also)\s+)?(?:queue|track)\b[^.?!]{0,120}",
            r"\b(?:analysis|audit|investigation|research|review|spike)\b",
        ]
        .concat(),
        true,
    )
});
static WORKER_DELEGATION_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        &[
            r"^\s*",
            COMMAND_LEAD,
            r"(?:(?:i\s+mean|please)\s+)?",
            r"(?:have|ask|tell)\s+(?:(?:the|a|another)\s+)?(?:worker|agent)\s+",
            r"(?:to\s+)?(?:",
            MUTATION_VERB,
            r"|investigate|review)\b",
        ]
        .concat(),
        true,
    )
});
static WH_QUESTION_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"^\s*(?:(?:hey|hi|okay|ok|so|actually|just)\b[,!\s]*)*",
            r"(?:(?:my\s+question\s+is|i\s+(?:wanted|want)\s+to\s+(?:ask|know))\b[:,\s]*)?",
            r"(?:what|which|who|when|where|why|how)\b",
        ),
        true,
    )
});
static AUXILIARY_QUESTION_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"^\s*(?:(?:hey|hi|okay|ok|so|actually|just)\b[,!\s]*)*",
            r"(?:(?:my\s+question\s+is|i\s+(?:wanted|want)\s+to\s+(?:ask|know))\b[:,\s]*)?",
            r"(?:is|are|am|was|were|do|does|did|has|have|had|should|would|can|could|will)\s+",
            r"(?:i|you|we|they|he|she|it|there|this|that|these|those|the\b)",
        ),
        true,
    )
});
static EPISTEMIC_QUERY_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"\b(?:can|could|would)\s+you\s+(?:please\s+)?",
            r"(?:check|explain|find\s+out|show|tell)\b",
            r"|\b(?:do|does|did)\s+(?:you|we)\s+know\b",
            r"|\bi(?:'m|\s+am|\s+was)\s+(?:just\s+)?(?:asking|wondering)\b",
            r"|\b(?:my\s+question\s+is|i\s+(?:wanted|want)\s+to\s+know)\b",
            r"|^\s*(?:(?:no|sorry)\b[,!\s]*)*(?:i\s+mean|to\s+clarify|clarification)\b",
        ),
        true,
    )
});
static READ_ONLY_REQUEST_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"^\s*(?:(?:hey|hi|okay|ok|so|actually|just|please)\b[,!\s]*)*",
            r"(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)?",
            r"(?:update\s+(?:me|us)\b",
            r"|(?:give|provide)\s+(?:me|us)\s+(?:(?:an?|the)\s+)?(?:update|status)\b",
            r"|(?:run|walk)\s+(?:me|us)\s+through\b",
            r"|(?:any|an|the\s+latest)\s+(?:status\s+)?updates?\b)",
        ),
        true,
    )
});
static INFORMATION_IMPERATIVE_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"^\s*(?:(?:hey|hi|okay|ok|so|actually|just|please)\b[,!\s]*)*",
            r"(?:(?:can|could|would|will)\s+you\s+(?:please\s+)?)?",
            r"(?:",
            r"(?:answer|describe|explain|summari[sz]e)\b",
            r"|(?:review|investigate)\b",
            r"|check\s+(?:whether|if|why|how)\b",
            r"|(?:show|tell)\s+(?:me|us)\b",
            r"|(?:find\s+(?:evidence|out)\b|compare\b)",
            r"|(?:check|give|list|present|provide|report|show)\b[^.?!]{0,100}",
            r"\b(?:answer|comparison|details?|differences?|evidence|history|overview|results?|status|summary)\b",
            r")",
        ),
        true,
    )
});
static CONDITIONAL_WORK_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        r"\b(?:and|but)\s+(?P<condition>(?:if|unless)\b[^,;.!?]{0,60})\s*,",
        true,
    )
});
static MIXED_WORK_CLAUSE_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"(?:\s*[.;]\s*|\s+\b(?:and(?:\s+then)?|but|then)\b\s+)",
            r"(?P<work>(?:please\s+)?(?:add|build|change|clean\s+up|create|debug|delete|",
            r"delegate|design|dispatch|fix|hand\s+off|implement|install|kick\s+off|make|",
            r"merge|migrate|queue|refactor|remove|repair|run|ship|spin\s+up|start|test|track|",
            r"update|wire|work\s+on|write)\b.*)$",
        ),
        true,
    )
});
/// The short local draft `classify_command` keeps in the foreground.
static BOUNDED_DRAFT_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"^\s*(?:please\s+)?(?:create|write|draft)\s+(?:a\s+)?",
            r"(?:(?:short|brief|one[- ]paragraph)\s+)+(?:local\s+)?(?:draft|note|text)\b",
        ),
        true,
    )
});
/// The substantial deliverable `classify_command` makes a ticket.
static PREPARED_DELIVERABLE_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"^\s*(?:please\s+)?prepare\s+(?:a\s+)?(?:multi[- ]file\s+|detailed\s+)?",
            r"(?:report|research package|presentation|document set)\b",
        ),
        true,
    )
});
static EXPLICIT_TICKET_RE: LazyLock<Regex> =
    LazyLock::new(|| compile(r"\b(?:create|write|draft)\s+(?:a\s+)?ticket\b", true));
/// Wording that names repository work, which a General session cannot own.
static PROJECT_REQUEST_RE: LazyLock<Regex> = LazyLock::new(|| {
    compile(
        concat!(
            r"\b(?:repo(?:sitory)?|codebase|source[- ]code|pull request|bug|unit tests?|test suite|compiler)\b",
            r"|\b[A-Za-z0-9_-]+\.(?:swift|py|js|ts|tsx|rs|go)\b",
        ),
        true,
    )
});

/// `ROUTE_UNDECIDED_GUIDANCE`.
const ROUTE_UNDECIDED_GUIDANCE: &str = concat!(
    "Relay Runner command action:\n",
    "- action: route_undecided\n",
    "- mutation_authorized: pending your route decision\n",
    "- work_style: auto. The request asks for a change but doesn't say whether to do it now or track it.\n",
    "- Do it now (Action) when it is small, reversible, quick to verify and the user is iterating.\n",
    "- Make it a ticket (Task) when it is multi-step or long, needs an isolated branch and review, can run in ",
    "parallel, or the user wants it tracked.\n",
    "- If neither is clearly true, ask one short question offering only the routes that fit, for example ",
    "\"Want me to change that now, put it on the board for a worker, or talk it through first?\"\n",
    "- Name the route you took in the reply.\n",
    "- You are the foreground orchestrator/PM. If you then create or dispatch a ticket, pass relay_command_seq and ",
    "relay_command_id; doing the change now uses no ticket.",
);

/// The `kind` of a `CommandAction`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ActionKind {
    Control,
    Conversation,
    DirectAction,
    InlineWork,
    CreateTicket,
    UpdateTicket,
    DispatchTicket,
    InspectTicket,
    NeedsProject,
}

impl ActionKind {
    /// The Python module's spelling, as the mailbox metadata carries it.
    pub fn as_str(self) -> &'static str {
        match self {
            ActionKind::Control => "control",
            ActionKind::Conversation => "conversation",
            ActionKind::DirectAction => "direct_action",
            ActionKind::InlineWork => "inline_work",
            ActionKind::CreateTicket => "create_ticket",
            ActionKind::UpdateTicket => "update_ticket",
            ActionKind::DispatchTicket => "dispatch_ticket",
            ActionKind::InspectTicket => "inspect_ticket",
            ActionKind::NeedsProject => "needs_project",
        }
    }
}

/// `CommandAction`: the explicit action one command resolves to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandAction {
    pub kind: ActionKind,
    pub source_text: String,
    pub requires_ticket: bool,
    /// `"general"` or `"project"`.
    pub scope: Option<&'static str>,
    pub ticket_id: Option<String>,
    pub ticket_path: Option<String>,
    pub repo_path: Option<String>,
    /// Empty where Python's default `""` applies.
    pub reason: &'static str,
    pub relay_command_id: Option<String>,
    pub relay_command_seq: Option<i64>,
    /// A change verb with no word about tracking or timing; the project's
    /// work style decides whether that is done now, tracked, or left to the PM.
    pub implicit_route: bool,
}

impl CommandAction {
    /// `CommandAction(kind=..., source_text=..., reason=...)` with every other
    /// field at its default.
    fn new(kind: ActionKind, source_text: &str, reason: &'static str) -> Self {
        Self {
            kind,
            source_text: source_text.to_string(),
            requires_ticket: false,
            scope: None,
            ticket_id: None,
            ticket_path: None,
            repo_path: None,
            reason,
            relay_command_id: None,
            relay_command_seq: None,
            implicit_route: false,
        }
    }

    /// `outcome`: the PM outcome the reply should name.
    pub fn outcome(&self) -> String {
        use ActionKind::*;
        match (self.kind, self.ticket_id.as_deref()) {
            (CreateTicket, Some(id)) => format!("created ticket {id}"),
            (CreateTicket, None) if self.scope == Some("general") => {
                "general work needs refined ticket".to_string()
            }
            (CreateTicket, None) => "project work needs refined ticket".to_string(),
            (DispatchTicket, Some(id)) => format!("dispatch ticket {id}"),
            (UpdateTicket, Some(id)) => format!("edit ticket {id}"),
            (InspectTicket, Some(id)) => format!("inspect ticket {id}"),
            (InlineWork, _) if self.reason == "work_style_direct" => {
                "done now in this session (work style: direct)".to_string()
            }
            (InlineWork, _) => "inline work explicitly requested".to_string(),
            (DirectAction, _) => "foreground computer action".to_string(),
            (NeedsProject, _) => "waiting on target-project choice".to_string(),
            (Control, _) => format!("control action {}", self.reason),
            _ => "normal conversation".to_string(),
        }
    }
}

/// The process environment `resolve_command_action` reads on each call.
struct Environment {
    /// `RELAY_WORK_STYLE`.
    work_style: String,
    /// `session_work_style_file()`.
    session_work_style_file: PathBuf,
    /// `RELAY_SESSION_SCOPE`.
    session_scope: Option<String>,
    /// `RELAY_GENERAL_FILES_ROOT`.
    general_files_root: Option<String>,
}

impl Environment {
    fn current() -> Self {
        let session_work_style_file = match env_optional("RELAY_SESSION_WORK_STYLE_FILE") {
            Some(path) if !path.is_empty() => PathBuf::from(expand_user(&path)),
            _ => Path::new(&expand_user("~"))
                .join("Library/Application Support/relay-runner/session-work-style.json"),
        };
        Self {
            work_style: env_optional("RELAY_WORK_STYLE").unwrap_or_default(),
            session_work_style_file,
            session_scope: env_optional("RELAY_SESSION_SCOPE"),
            general_files_root: env_optional("RELAY_GENERAL_FILES_ROOT"),
        }
    }
}

fn known_work_style(style: &str) -> Option<&'static str> {
    WORK_STYLES.iter().copied().find(|known| *known == style)
}

/// `Path.read_text()`: UTF-8 with universal newlines.
fn read_text(path: &Path) -> Option<String> {
    let text = fs::read_to_string(path).ok()?;
    Some(text.replace("\r\n", "\n").replace('\r', "\n"))
}

/// `session_work_style`: the session-wide choice from the Start button's
/// menu, or `None` when none is saved.
fn session_work_style(path: &Path) -> Option<&'static str> {
    let Value::Dict(saved) = json::parse(&read_text(path)?)? else {
        return None;
    };
    known_work_style(&saved.get("work_style")?.as_str()?.to_lowercase())
}

/// `work_style_and_source`: the effective work style and where it came from.
///
/// Precedence: `RELAY_WORK_STYLE` ("env"), then the session-wide choice in
/// `session-work-style.json` ("session"), then `work_style` in the project's
/// `.relay-runner.toml` ("project"), then auto ("default"). An unknown
/// `RELAY_WORK_STYLE` means auto; other unknown values are ignored.
fn work_style_and_source(
    environment: &Environment,
    repo_path: Option<&str>,
) -> (&'static str, &'static str) {
    let style = json::py_strip(&environment.work_style).to_lowercase();
    if !style.is_empty() {
        return (known_work_style(&style).unwrap_or("auto"), "env");
    }
    if let Some(style) = session_work_style(&environment.session_work_style_file) {
        return (style, "session");
    }
    if let Some(repo_path) = repo_path {
        let file = Path::new(&expand_user(repo_path)).join(WORK_STYLE_FILE);
        let style = read_text(&file)
            .and_then(|text| pattern::group(&WORK_STYLE_RE, &text, 1).map(str::to_lowercase))
            .and_then(|style| known_work_style(&style));
        if let Some(style) = style {
            return (style, "project");
        }
    }
    ("auto", "default")
}

/// `project_work_style`: auto (default), direct or orchestrated.
fn project_work_style(environment: &Environment, repo_path: Option<&str>) -> &'static str {
    work_style_and_source(environment, repo_path).0
}

/// `requested_work_style`: the style a "switch to direct mode" turn names.
fn requested_work_style(text: &str) -> Option<String> {
    let found = WORK_STYLE_SWITCH_RE.captures(text).ok().flatten()?;
    let style = found.name("style").or_else(|| found.name("style2"))?;
    Some(style.as_str().to_lowercase())
}

fn control_reason(value: &str) -> Option<&'static str> {
    CONTROL_COMMANDS
        .iter()
        .find(|(command, _)| *command == value)
        .map(|(_, reason)| *reason)
}

/// `is_control_command`.
fn is_control_command(text: &str) -> bool {
    let value = json::py_strip(text);
    control_reason(value).is_some()
        || value.starts_with("__STATUS__:")
        || value.starts_with("__TRACE__:")
        || value.starts_with("__ORCHESTRATOR_REPLY__:")
}

/// `is_relay_runner_self_explanation`: whether a turn asks for Relay
/// Runner's short product introduction.
pub fn is_relay_runner_self_explanation(text: &str) -> bool {
    let source = json::py_strip(text);
    if !search(&RELAY_RUNNER_NAME_RE, source) {
        return false;
    }
    if search(&RELAY_RUNNER_EXPLANATION_RE, source)
        || search(&RELAY_RUNNER_DIRECT_QUESTION_RE, source)
        || search(&RELAY_RUNNER_OVERVIEW_RE, source)
    {
        return true;
    }
    search(&RELAY_RUNNER_DEMO_CONTEXT_RE, source) && search(&RELAY_RUNNER_EXPLAIN_WORD_RE, source)
}

/// `is_information_query`: whether a turn asks for knowledge without
/// authorizing mutation.
fn is_information_query(text: &str) -> bool {
    let source = json::py_strip(text);
    if source.is_empty() {
        return false;
    }
    if discussion_only_requested(source) {
        return true;
    }
    let command = command_clause(source);
    if search(&READ_ONLY_REQUEST_RE, source) || search(&READ_ONLY_REQUEST_RE, command) {
        return true;
    }
    if explicit_project_work_kind(source, extract_ticket_id(source).as_deref()).is_some() {
        return false;
    }
    [
        &*WH_QUESTION_RE,
        &*AUXILIARY_QUESTION_RE,
        &*EPISTEMIC_QUERY_RE,
        &*INFORMATION_IMPERATIVE_RE,
    ]
    .iter()
    .any(|pattern| search(pattern, source) || search(pattern, command))
}

/// `_command_clause`: the operative clause after a punctuated leading target
/// context.
fn command_clause(source: &str) -> &str {
    LEADING_TARGET_CONTEXT_RE
        .captures(source)
        .ok()
        .flatten()
        .and_then(|found| found.name("command"))
        .map_or(source, |command| json::py_strip(command.as_str()))
}

/// `_explicit_project_work_kind`: the mutation route authorized by command
/// grammar, if any.
fn explicit_project_work_kind(source: &str, ticket_id: Option<&str>) -> Option<ActionKind> {
    let command = command_clause(source);
    if search(&DURABLE_WORK_ESCALATION_RE, command) {
        return Some(ActionKind::CreateTicket);
    }
    if search(&WORKER_DELEGATION_RE, command) || search(&EXPLICIT_DISPATCH_REQUEST_RE, command) {
        return Some(if ticket_id.is_some() {
            ActionKind::DispatchTicket
        } else {
            ActionKind::CreateTicket
        });
    }
    if search(&EXPLICIT_MUTATION_REQUEST_RE, command) {
        return Some(if ticket_id.is_some() {
            ActionKind::UpdateTicket
        } else {
            ActionKind::CreateTicket
        });
    }
    None
}

/// Whether the query half of a split turn is a question and its work half a
/// mutation request.
fn query_then_work(query_clause: &str, work_clause: &str) -> bool {
    is_information_query(query_clause)
        && explicit_project_work_kind(work_clause, extract_ticket_id(work_clause).as_deref())
            .is_some()
}

/// `is_mixed_query_and_mutation`: a mutation clause attached to a read-only
/// query.
pub fn is_mixed_query_and_mutation(text: &str) -> bool {
    let source = json::py_strip(text);
    for found in CONDITIONAL_WORK_RE.find_iter(source).map_while(Result::ok) {
        let query_clause = source[..found.start()].trim_end_matches([' ', ',']);
        let work_clause = source[found.end()..].trim_start_matches([' ', ',']);
        if query_then_work(query_clause, work_clause) {
            return true;
        }
    }
    if let Some(found) = MIXED_WORK_CLAUSE_RE.captures(source).ok().flatten() {
        let start = found.get(0).map_or(0, |whole| whole.start());
        let query_clause = source[..start].trim_end_matches([' ', ',']);
        let work_clause = found.name("work").map_or("", |work| work.as_str());
        if query_then_work(query_clause, work_clause) {
            return true;
        }
    }
    false
}

/// `classify_command`: the action a command's wording asks for, before the
/// project, the work style and the Relay command are known.
pub fn classify_command(text: &str) -> CommandAction {
    use ActionKind::*;
    let source = json::py_strip(text);
    if is_control_command(source) {
        let reason = control_reason(source).unwrap_or(if source.starts_with("__TRACE__:") {
            "trace"
        } else if source.starts_with("__ORCHESTRATOR_REPLY__:") {
            "orchestrator_reply"
        } else {
            "status"
        });
        return CommandAction::new(Control, source, reason);
    }

    if search(&ORCHESTRATION_CORRECTION_RE, source) {
        return CommandAction::new(Control, source, "orchestration_process_correction");
    }

    if explicit_cancel_requested(source) {
        return CommandAction::new(Control, source, "cancel");
    }

    if requested_work_style(source).is_some() {
        return CommandAction::new(DirectAction, source, "set_work_style");
    }

    // Qualify the complete turn before a positive opening clause can create work.
    if discussion_only_requested(source) {
        return CommandAction::new(Conversation, source, "discussion_only");
    }

    if is_mixed_query_and_mutation(source) {
        return CommandAction::new(
            Conversation,
            source,
            "mixed_query_and_mutation_clarification",
        );
    }

    if mixed_bucket_request(source) {
        return CommandAction::new(Conversation, source, "mixed_scope_resolution");
    }

    if search(&BOUNDED_DRAFT_RE, source) {
        return CommandAction {
            scope: Some("general"),
            ..CommandAction::new(DirectAction, source, "bounded_local_draft")
        };
    }

    if search(&PREPARED_DELIVERABLE_RE, source) {
        return CommandAction {
            requires_ticket: true,
            ..CommandAction::new(CreateTicket, source, "")
        };
    }

    if search(&SCREEN_OBSERVATION_RE, source) {
        return CommandAction::new(DirectAction, source, "screen_observation");
    }

    if search(&DESKTOP_CONTROL_RE, source) {
        return CommandAction::new(DirectAction, source, "desktop_control");
    }

    if foreground_action_requested(source) {
        return CommandAction::new(DirectAction, source, "foreground_operation");
    }

    if is_relay_runner_self_explanation(source) {
        return CommandAction::new(Conversation, source, "relay_runner_self_explanation");
    }

    let explicit_ticket =
        search(&EXPLICIT_TICKET_RE, source) && !search(&NEGATED_TICKET_RE, source);
    if search(&INLINE_RE, source) && !explicit_ticket {
        return CommandAction::new(InlineWork, source, "");
    }

    if search(&PENDING_WORK_RE, source) {
        return CommandAction::new(Control, source, "pending_work_instruction");
    }

    let ticket_id = extract_ticket_id(source);
    if let Some(kind) = explicit_project_work_kind(source, ticket_id.as_deref()) {
        if search(&SESSION_OPERATION_RE, source) {
            return CommandAction::new(InlineWork, source, "");
        }
        let implicit = kind == CreateTicket
            && !search(&EXPLICIT_TRACKING_RE, source)
            && !search(&DURABLE_WORK_ESCALATION_RE, command_clause(source));
        return CommandAction {
            requires_ticket: true,
            ticket_id: if kind != CreateTicket {
                ticket_id
            } else {
                None
            },
            implicit_route: implicit,
            ..CommandAction::new(kind, source, "")
        };
    }

    if is_mixed_query_and_mutation(source) {
        return CommandAction::new(
            Conversation,
            source,
            "mixed_query_and_mutation_clarification",
        );
    }

    let information_query = is_information_query(source);

    if search(&SESSION_OPERATION_RE, source) && !information_query {
        return CommandAction::new(InlineWork, source, "");
    }

    if information_query {
        if ticket_id.is_some() {
            return CommandAction {
                ticket_id,
                ..CommandAction::new(InspectTicket, source, "information_query")
            };
        }
        return CommandAction::new(Conversation, source, "information_query");
    }

    if ticket_id.is_some() {
        let reason = if search(&INSPECT_RE, source) {
            "ticket_inspection"
        } else {
            "ticket_reference"
        };
        return CommandAction {
            ticket_id,
            ..CommandAction::new(InspectTicket, source, reason)
        };
    }

    CommandAction::new(Conversation, source, "")
}

/// `resolve_command_action`: classifies a command and settles it against
/// the target project, the work style and the General session scope.
///
/// `repo_path` is the bridge's `Path` argument: any `Some`, even an empty
/// one (the working directory), counts as given.
pub fn resolve_command_action(
    text: &str,
    repo_path: Option<&str>,
    relay_command: Option<&Dict>,
) -> CommandAction {
    resolve_in(&Environment::current(), text, repo_path, relay_command)
}

fn resolve_in(
    environment: &Environment,
    text: &str,
    repo_path: Option<&str>,
    relay_command: Option<&Dict>,
) -> CommandAction {
    use ActionKind::*;
    let mut action = classify_command(text);
    let managed_general = environment.session_scope.as_deref() == Some("general")
        && match repo_path {
            None => true,
            Some(path) => environment
                .general_files_root
                .as_deref()
                .is_some_and(|root| !root.is_empty() && resolve_path(path) == resolve_path(root)),
        };
    if action
        .ticket_id
        .as_deref()
        .is_some_and(|id| id.starts_with("GEN-"))
    {
        action.scope = Some("general");
        return with_relay(action, relay_command);
    }
    let project_request = search(&PROJECT_REQUEST_RE, text);
    if action.kind == CreateTicket
        && action.implicit_route
        && repo_path.is_some()
        && !managed_general
    {
        // A change verb alone doesn't say whether the user wants it now or
        // tracked; the work style decides, and auto defers to the PM.
        match project_work_style(environment, repo_path) {
            "direct" => {
                action = CommandAction::new(InlineWork, &action.source_text, "work_style_direct")
            }
            "auto" => {
                action = CommandAction::new(Conversation, &action.source_text, "route_undecided")
            }
            _ => {}
        }
    } else if action.kind == CreateTicket
        && action.implicit_route
        && managed_general
        && !project_request
        && project_work_style(environment, None) == "direct"
    {
        // General keeps its own routing; only a session-wide direct choice
        // (RELAY_WORK_STYLE or the Start menu) makes its changes inline.
        action = CommandAction::new(InlineWork, &action.source_text, "work_style_direct");
    }
    if action.kind != CreateTicket {
        if !managed_general && let Some(path) = repo_path {
            action.repo_path = Some(resolve_path(path));
        }
        return with_relay(action, relay_command);
    }
    let Some(repo_path) = repo_path.filter(|_| !managed_general) else {
        // A General cwd is storage, never implicit project-mutation authority.
        if project_request
            || action
                .ticket_id
                .as_deref()
                .is_some_and(|id| !id.starts_with("GEN-"))
        {
            let needs_project = CommandAction {
                requires_ticket: true,
                ..CommandAction::new(
                    NeedsProject,
                    &action.source_text,
                    "Project implementation needs a confirmed target repository",
                )
            };
            return with_relay(needs_project, relay_command);
        }
        let general = CommandAction {
            requires_ticket: true,
            scope: Some("general"),
            ..CommandAction::new(
                CreateTicket,
                &action.source_text,
                "Substantial or explicitly tracked general work needs a refined General ticket",
            )
        };
        return with_relay(general, relay_command);
    };
    let project = CommandAction {
        requires_ticket: true,
        scope: Some("project"),
        repo_path: Some(resolve_path(repo_path)),
        ..CommandAction::new(
            CreateTicket,
            &action.source_text,
            "project work needs a refined visible ticket before dispatch; keep raw Relay transcript private",
        )
    };
    with_relay(project, relay_command)
}

/// `format_command_for_agent`: the prompt the foreground PM receives for
/// one action, with the work-intent disposition appended when given.
pub fn format_command_for_agent(action: &CommandAction, disposition: Option<&Dict>) -> String {
    use ActionKind::*;
    if matches!(action.kind, Conversation | Control) {
        let mut prompt = action.source_text.clone();
        if action.reason == "route_undecided" {
            prompt = format!(
                "{prompt}\n\n{ROUTE_UNDECIDED_GUIDANCE}\n{}",
                relay_prompt_lines(action).trim_end_matches('\n')
            );
        }
        if matches!(
            action.reason,
            "mixed_query_and_mutation_clarification" | "mixed_scope_resolution"
        ) {
            prompt = format!(
                "{prompt}\n\n\
                 Relay Runner command action:\n\
                 - action: conversation\n\
                 - mutation_authorized: false\n\
                 - Resolve the original ordered requests and constraints with the PM before any mutation. \
                 Ask one concise clarification if scope is ambiguous. A conditional work clause is not \
                 durable mutation authority; do not discard separately authorized work."
            );
        }
        return append_work_disposition(prompt, disposition);
    }

    if action.scope == Some("general") && (action.ticket_id.is_some() || action.requires_ticket) {
        let prompt = format!(
            "{}\n\nRelay Runner General work contract:\n\
             - action: {}\n- scope: general\n- ticket_id: {}\n\
             {}\
             - Use the daemon general_task tool for canonical General tickets; never invent a source repository.\n\
             - Refine substantial work into title, description and acceptance criteria. Create is backlog only; dispatch only with execution authority.\n\
             - Respect no-dispatch/backlog-only instructions. Discussion and elapsed research time never authorize work.\n\
             - Review exact output files and acceptance evidence before approving the current run. Preserve run provenance and report failures precisely.\n\
             - A task label does not grant permission to send, publish, purchase or delete. Keep ordered mixed intents and cancel only the requested task/run.\n\
             - Project mutation requires a separately confirmed repository scope. Messenger remains tool-free.",
            action.source_text,
            action.kind.as_str(),
            action.ticket_id.as_deref().unwrap_or("null"),
            relay_prompt_lines(action),
        );
        return append_work_disposition(prompt, disposition);
    }

    if action.kind == DirectAction {
        let mut lines: Vec<String> = vec![
            action.source_text.clone(),
            String::new(),
            "Relay Runner command action:".to_string(),
            "- action: direct_action".to_string(),
            "- ticket_id: null".to_string(),
            "- outcome_to_report: foreground computer action".to_string(),
            format!("- reason: {}", action.reason),
        ];
        if let Some(repo_path) = &action.repo_path {
            lines.push(format!("- repo_path: {repo_path}"));
        }
        lines.extend(relay_prompt_lines(action).lines().map(str::to_string));
        if action.reason == "set_work_style" {
            let style =
                requested_work_style(&action.source_text).unwrap_or_else(|| "None".to_string());
            lines.push(format!("- work_style_requested: {style}"));
            lines.push(format!(
                "- Set the session's work style now with `relay-work-style set {style}` (installed at \
                 /Applications/Relay Runner.app/Contents/SharedSupport/scripts/relay-work-style), then confirm in one \
                 sentence what the style now does. It applies to every project from the next request; no ticket."
            ));
        }
        lines.extend(
            [
                "",
                "Foreground computer-action contract:",
                "- Handle this directly in the foreground PM. Do not create a ticket, dispatch a worker, or send this to the Relay daemon.",
                "- The messenger remains tool-free; it may acknowledge and speak the PM's final result, but it never executes the action.",
                "- Prefer a deterministic shell or operating-system command when it can fully complete the request, including launching an app, opening or revealing a known path, or locating a file.",
                "- Do not inspect the screen merely to navigate toward an action that a direct command can complete.",
                "- Use Relay Vision when the request genuinely requires observing pixels or visible UI state.",
                "- Use Relay Actions only when visual interaction is necessary after direct-command options are exhausted. Never use native computer-use tools while the Relay stack is connected.",
                "- Check that this Relay command is still current immediately before every side effect. Ask in normal chat before a genuinely high-stakes or irreversible action.",
                "- Report the completed action or exact blocker concisely through the normal authoritative reply path so the messenger can speak it.",
            ]
            .map(str::to_string),
        );
        return append_work_disposition(lines.join("\n"), disposition);
    }

    if action.kind == InlineWork && action.reason == "work_style_direct" {
        let prompt = format!(
            "{}\n\n\
             Relay Runner command action:\n\
             - action: inline_work\n\
             - ticket_id: null\n\
             - work_style: direct\n\
             - outcome_to_report: done now in this session\n\
             {}\
             - This session's work style is direct: make the change yourself now, verify it, and say it is done. \
             Create a ticket only if the user asks for tracking, a worker, or background work, or if the change is \
             clearly too large to finish here; then ask before writing one.\n",
            action.source_text,
            relay_prompt_lines(action),
        );
        return append_work_disposition(prompt, disposition);
    }

    if action.kind == InlineWork {
        let prompt = format!(
            "{}\n\n\
             Relay Runner command action:\n\
             - action: inline_work\n\
             - ticket_id: null\n\
             - outcome_to_report: inline work explicitly requested\n\
             {}",
            action.source_text,
            relay_prompt_lines(action),
        );
        return append_work_disposition(prompt, disposition);
    }

    let mut lines: Vec<String> = vec![
        "Relay Runner command action:".to_string(),
        format!("- action: {}", action.kind.as_str()),
        format!(
            "- ticket_id: {}",
            action.ticket_id.as_deref().unwrap_or("null")
        ),
        format!("- outcome_to_report: {}", action.outcome()),
    ];
    if let Some(ticket_path) = &action.ticket_path {
        lines.push(format!("- ticket_path: {ticket_path}"));
    }
    if let Some(repo_path) = &action.repo_path {
        lines.push(format!("- repo_path: {repo_path}"));
    }
    if !action.reason.is_empty() {
        lines.push(format!("- reason: {}", action.reason));
    }
    lines.extend(relay_prompt_lines(action).lines().map(str::to_string));

    lines.extend(
        [
            "",
            "PM frontstage contract:",
            "- You are the PM frontstage for the user, not the implementation worker.",
            "- Keep the user-facing response concise and status-oriented; do not perform substantive source-code implementation directly unless the source command explicitly asks for inline work.",
            "- The foreground orchestrator/PM owns command classification and visible-ticket authoring for new raw work requests.",
            "- Raw Relay command captures are private metadata, not board cards; visible `.orchestrator/` tickets must use refined, user-safe summaries and acceptance criteria instead of transcript dumps.",
            "- Creating or editing visible `.orchestrator/` tickets is PM management work. Implementation belongs to workers unless the user explicitly asks to keep it inline.",
            "- Relay command metadata has two provider-neutral checks: newest-turn freshness gates user-visible replies, traces, and TTS; mutation authorization gates ticket edits, dispatches, and orchestrator actions.",
            "- Before any user-visible follow-up, trace, or TTS, verify this command is still current; if a newer command exists, stop the stale output and let Relay Runner deliver the newer turn.",
            "- Before any ticket edit, dispatch, or orchestrator action, pass relay_command_seq and relay_command_id. The daemon allows an older command only when Relay Runner registered that bounded mutation authorization and no replacement, redirect, interrupt, or cancel turn has revoked it. Acknowledgement, inspection/status, and additive turns do not revoke prior authorized mutations.",
            "- When a later dispatch request goes through relay-orchestrator, pass relay_command_seq and relay_command_id when they are present.",
            "- Your user-facing response must name the PM outcome, such as created ticket, edited ticket, dispatched worker, waiting on refined ticket content, or waiting on a target-project choice.",
        ]
        .map(str::to_string),
    );

    let instruction = match action.kind {
        CreateTicket => Some(
            "- Create or refine a visible ticket now if the target project and scope are clear; otherwise ask one concise clarification. Do not implement the ticket yourself.",
        ),
        DispatchTicket => Some(
            "- Dispatch the named ticket through relay-orchestrator; do not implement the ticket yourself.",
        ),
        UpdateTicket => Some(
            "- Edit/refine the named ticket so it can survive a cold worker run; dispatch only after it is ready.",
        ),
        InspectTicket => {
            Some("- Inspect/report ticket or run state; do not implement the ticket yourself.")
        }
        NeedsProject => Some(
            "- No ticket was created because no active Workspace project was found; ask the user which repo/project should own the work.",
        ),
        _ => None,
    };
    lines.extend(instruction.map(str::to_string));

    lines.extend([
        String::new(),
        "Source command:".to_string(),
        action.source_text.clone(),
    ]);
    append_work_disposition(lines.join("\n"), disposition)
}

/// `", ".join(str(value) for value in values or []) or "none"`; the bridge
/// passes `IntentDisposition::to_dict()`, whose ids are lists, and anything
/// else reads as empty.
fn joined_or_none(values: Option<&Value>) -> String {
    let joined = values
        .and_then(Value::as_list)
        .unwrap_or_default()
        .iter()
        .map(Value::py_str)
        .collect::<Vec<_>>()
        .join(", ");
    if joined.is_empty() {
        "none".to_string()
    } else {
        joined
    }
}

/// `_append_work_disposition`.
fn append_work_disposition(prompt: String, disposition: Option<&Dict>) -> String {
    let Some(disposition) = disposition else {
        return prompt;
    };
    let route = disposition.text("route");
    if route.is_empty() {
        return prompt;
    }
    let or_default = |key: &str, default: &str| {
        disposition
            .truthy(key)
            .map_or_else(|| default.to_string(), Value::py_str)
    };
    let question = disposition.text("clarification_question");
    let mut lines = vec![
        prompt,
        String::new(),
        "Relay work-intent disposition:".to_string(),
        format!("- route: {route}"),
        format!("- target_work_ids: {}", joined_or_none(disposition.get("target_work_ids"))),
        format!(
            "- conflicting_work_ids: {}",
            joined_or_none(disposition.get("conflicting_work_ids"))
        ),
        format!(
            "- mutation_authorization_effect: {}",
            or_default("authorization_effect", "preserve")
        ),
        format!(
            "- public_reason: {}",
            or_default("public_reason", "Resolved by the bridge policy.")
        ),
        "- Treat this as the provider-neutral relationship to already accepted work.".to_string(),
        "- Do not preempt accepted work unless this route is replace_current.".to_string(),
        "- queue_project_work stays on the native Relay ticket/worktree path.".to_string(),
        "- run_sidecar is read-only, bounded, independently verifiable, resource-safe, and never speaks directly."
            .to_string(),
    ];
    if !question.is_empty() {
        lines.push(format!("- clarification_question: {question}"));
    }
    lines.join("\n")
}

/// `_with_relay` with `_relay_fields`: the command identity a Relay command
/// carries, a truthy id and an integer sequence.
fn with_relay(mut action: CommandAction, relay_command: Option<&Dict>) -> CommandAction {
    if let Some(command) = relay_command {
        action.relay_command_id = command.truthy("relay_command_id").map(Value::py_str);
        action.relay_command_seq = command.present("relay_command_seq").and_then(Value::py_int);
    }
    action
}

/// `_relay_prompt_lines`.
fn relay_prompt_lines(action: &CommandAction) -> String {
    let mut lines = String::new();
    if let Some(seq) = action.relay_command_seq {
        lines.push_str(&format!("- relay_command_seq: {seq}\n"));
    }
    if let Some(command_id) = action
        .relay_command_id
        .as_deref()
        .filter(|id| !id.is_empty())
    {
        lines.push_str(&format!("- relay_command_id: {command_id}\n"));
    }
    lines
}

/// `_extract_ticket_id`.
fn extract_ticket_id(text: &str) -> Option<String> {
    pattern::group(&TICKET_ID_RE, text, 1).map(str::to_uppercase)
}

/// `os.path.expanduser` for `~` and `~/…`, from `HOME`.
fn expand_user(path: &str) -> String {
    let rest = match path.strip_prefix('~') {
        Some(rest) if rest.is_empty() || rest.starts_with('/') => rest,
        _ => return path.to_string(),
    };
    let Some(home) = env_optional("HOME") else {
        return path.to_string();
    };
    let expanded = format!("{}{rest}", home.trim_end_matches('/'));
    if expanded.is_empty() {
        "/".to_string()
    } else {
        expanded
    }
}

/// `str(Path(path).expanduser().resolve())`: absolute, symbolic links
/// followed, and a part that does not exist kept as written.
fn resolve_path(path: &str) -> String {
    let path = PathBuf::from(expand_user(path));
    let absolute = if path.is_absolute() {
        path
    } else {
        std::env::current_dir().unwrap_or_default().join(path)
    };
    let mut missing = Vec::new();
    let mut existing = absolute.as_path();
    let mut resolved = loop {
        if let Ok(resolved) = fs::canonicalize(existing) {
            break resolved;
        }
        match (existing.parent(), existing.components().next_back()) {
            (Some(parent), Some(last)) => {
                missing.push(last);
                existing = parent;
            }
            _ => break PathBuf::from("/"),
        }
    };
    for component in missing.into_iter().rev() {
        match component {
            Component::ParentDir => {
                resolved.pop();
            }
            Component::Normal(name) => resolved.push(name),
            _ => {}
        }
    }
    resolved.to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::ActionKind::*;
    use super::*;
    use relay_intents::arbitration::{DispositionRequest, resolve_intent_disposition};
    use relay_intents::qualification::qualify_intent;

    /// A scratch folder, removed when dropped.
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(name: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "relay-rs-command-actions-{}-{name}",
                std::process::id()
            ));
            let _ = fs::remove_dir_all(&path);
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }

        fn path(&self) -> &str {
            self.0.to_str().unwrap()
        }

        fn write(&self, name: &str, text: &str) {
            fs::write(self.0.join(name), text).unwrap();
        }

        /// What `set_session_work_style` writes.
        fn save_session_style(&self, style: &str) {
            self.write(
                "session-work-style.json",
                &format!("{{\"work_style\": \"{style}\"}}"),
            );
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// The environment the Python tests set up: no work style, no General
    /// scope, and a session work-style file in `scratch` that is not saved.
    fn environment(scratch: &Scratch) -> Environment {
        Environment {
            work_style: String::new(),
            session_work_style_file: scratch.0.join("session-work-style.json"),
            session_scope: None,
            general_files_root: None,
        }
    }

    fn relay(seq: i64, id: &str) -> Dict {
        let mut command = Dict::new();
        command.insert("relay_command_seq", seq);
        command.insert("relay_command_id", id);
        command
    }

    /// Asserts a classification; a `None` reason is not checked.
    #[track_caller]
    fn assert_classified(
        text: &str,
        kind: ActionKind,
        requires_ticket: bool,
        ticket_id: Option<&str>,
        reason: Option<&str>,
    ) {
        let action = classify_command(text);
        assert_eq!(
            (
                action.kind,
                action.requires_ticket,
                action.ticket_id.as_deref()
            ),
            (kind, requires_ticket, ticket_id),
            "{text}"
        );
        if let Some(reason) = reason {
            assert_eq!(action.reason, reason, "{text}");
        }
    }

    #[test]
    fn internal_controls_are_no_ticket_actions() {
        for (command, reason) in CONTROL_COMMANDS {
            assert_classified(command, Control, false, None, Some(reason));
            assert_eq!(
                format_command_for_agent(&classify_command(command), None),
                command
            );
        }
        for (text, reason) in [
            (
                r#"__TRACE__:{"kind":"ticket-created","ticket_id":"RR-9"}"#,
                "trace",
            ),
            (
                r#"__ORCHESTRATOR_REPLY__:{"text":"Done"}"#,
                "orchestrator_reply",
            ),
            (
                "Once these tickets are done, review it, merge it, and rebuild and install the app.",
                "pending_work_instruction",
            ),
            (
                "Once those tickets are done, merge them",
                "pending_work_instruction",
            ),
            (
                "Why did you write the ticket? The entire point is so that you can dispatch my raw \
                 response straight to the orchestrator. So the orchestrator can write the ticket. \
                 Therefore, I can continue talking to you without interrupting the ticket writing process.",
                "orchestration_process_correction",
            ),
            ("Cancel RR-400", "cancel"),
        ] {
            assert_classified(text, Control, false, None, Some(reason));
        }
        assert_ne!(
            classify_command("I want to improve how we interpret when tickets are done").kind,
            Control
        );
        for text in ["__TTS_STOP__", "Cancel RR-400"] {
            let action = classify_command(text);
            let hint = qualify_intent(text, action.kind.as_str(), Some(action.reason), None, None);
            assert_eq!(hint.bucket, None, "{text}");
        }
    }

    #[test]
    fn project_work_with_orchestrator_process_words_still_creates_ticket() {
        assert_classified(
            "Add radiuses to the notch edges. When I hover to expand to see what the traces are \
             doing, add easing too. Those can be two separate tickets, and I am watching to see if \
             the PM writes and dispatches the tickets or if the orchestrator does.",
            CreateTicket,
            true,
            None,
            None,
        );
        assert_classified(
            "fix the open source login retry bug",
            CreateTicket,
            true,
            None,
            None,
        );
        assert_classified(
            "Queue a spike to investigate the release history",
            CreateTicket,
            true,
            None,
            None,
        );
    }

    #[test]
    fn relay_runner_self_explanations_stay_in_fast_conversation() {
        for text in [
            "What is Relay Runner?",
            "Could you explain what Relay Runner is and what it does?",
            "What is the core functionality of Relay Runner?",
            "Tell the audience about Relay Runner.",
            "I'm demoing Relay Runner right now; please explain what it what it does to the audience.",
            "I might add this to the demo: when I present Relay Runner, briefly explain it to the audience.",
            "I'm demoing Relay Runner; please explain what it does to the audience.",
        ] {
            assert!(is_relay_runner_self_explanation(text), "{text}");
            assert_classified(
                text,
                Conversation,
                false,
                None,
                Some("relay_runner_self_explanation"),
            );
        }
        for text in [
            "Change what Relay Runner does when recording commands.",
            "Add a self-explanation shortcut to Relay Runner.",
            "Explain how to change Relay Runner's command routing.",
            "What is Relay Runner's command classification architecture?",
        ] {
            assert!(!is_relay_runner_self_explanation(text), "{text}");
        }
        assert_eq!(
            classify_command("Change what Relay Runner does when recording commands.").kind,
            CreateTicket
        );
        assert_eq!(
            classify_command("Add a self-explanation shortcut to Relay Runner.").kind,
            CreateTicket
        );
    }

    #[test]
    fn foreground_actions_and_session_operations_need_no_ticket() {
        for (text, reason) in [
            ("what's on my screen", "screen_observation"),
            ("open this folder in Finder", "desktop_control"),
            ("open Chrome", "desktop_control"),
            ("open Slack", "desktop_control"),
            ("click the Add project button", "desktop_control"),
        ] {
            assert_classified(text, DirectAction, false, None, Some(reason));
        }
        for text in [
            "commit everything to remote",
            "rebuild and install when everything is ready and commit to remote",
            "push main to origin",
        ] {
            assert_classified(text, InlineWork, false, None, None);
        }
    }

    #[test]
    fn information_queries_do_not_inherit_mutation_from_work_words() {
        for text in [
            "Was there a build?",
            "Which release included these tickets?",
            "Did we ship this?",
            "Why did the build fail?",
            "So my question is, did we release a build containing RR-325 through RR-343?",
            "No, I mean a release, not a build.",
        ] {
            assert!(is_information_query(text), "{text}");
            let action = classify_command(text);
            assert!(
                matches!(action.kind, Conversation | InspectTicket),
                "{text}"
            );
            assert!(!action.requires_ticket, "{text}");
            assert_eq!(action.reason, "information_query", "{text}");
        }
        for text in [
            "Can you tell me whether RR-325 is done?",
            "Did we ship RR-325?",
            "What is the status of RR-325?",
            "RR-325",
        ] {
            assert_classified(text, InspectTicket, false, Some("RR-325"), None);
        }
        for text in [
            "Will we ship RR-325 in the next release?",
            "Can we ship RR-325 in the next release?",
            "For RR-325, will we ship it in the next release?",
            "In RR-325, could we update the acceptance criteria?",
        ] {
            assert!(is_information_query(text), "{text}");
            assert_classified(
                text,
                InspectTicket,
                false,
                Some("RR-325"),
                Some("information_query"),
            );
        }
    }

    #[test]
    fn mutation_requests_retain_work_routing() {
        for (text, kind, ticket_id) in [
            ("Build the release", CreateTicket, None),
            ("Can you build a release?", CreateTicket, None),
            ("Update RR-325", UpdateTicket, Some("RR-325")),
            ("Dispatch RR-325", DispatchTicket, Some("RR-325")),
            ("For RR-325, fix the auth bug", UpdateTicket, Some("RR-325")),
            (
                "In RR-325, update the acceptance criteria",
                UpdateTicket,
                Some("RR-325"),
            ),
            ("RR-325: fix the auth bug", UpdateTicket, Some("RR-325")),
            (
                "Regarding RR-325, can you update the acceptance criteria?",
                UpdateTicket,
                Some("RR-325"),
            ),
            ("dispatch rr-7 to a worker", DispatchTicket, Some("RR-7")),
            (
                "update RR-8 with the auth context",
                UpdateTicket,
                Some("RR-8"),
            ),
        ] {
            assert_classified(text, kind, true, ticket_id, None);
        }
        assert!(
            format_command_for_agent(&classify_command("dispatch rr-7 to a worker"), None)
                .contains("action: dispatch_ticket")
        );
    }

    #[test]
    fn classifier_applies_authority_precedence_before_ticket_references() {
        for (text, kind, requires_ticket, ticket_id, reason) in [
            ("__PLAY__", Control, false, None, "play"),
            ("Open Chrome", DirectAction, false, None, "desktop_control"),
            (
                "Track an investigation into RR-325",
                CreateTicket,
                true,
                None,
                "",
            ),
            ("Queue a review of RR-325", CreateTicket, true, None, ""),
            ("Do a clean build", CreateTicket, true, None, ""),
            (
                "Have the worker fix RR-325",
                DispatchTicket,
                true,
                Some("RR-325"),
                "",
            ),
            (
                "Tell the worker to investigate RR-325",
                DispatchTicket,
                true,
                Some("RR-325"),
                "",
            ),
            (
                "Ask the agent to review RR-325",
                DispatchTicket,
                true,
                Some("RR-325"),
                "",
            ),
            ("I need a clean build", CreateTicket, true, None, ""),
            (
                "Go ahead and build the release",
                CreateTicket,
                true,
                None,
                "",
            ),
            (
                "Please review RR-325 and merge it",
                Conversation,
                false,
                None,
                "mixed_query_and_mutation_clarification",
            ),
            (
                "Have we shipped RR-325?",
                InspectTicket,
                false,
                Some("RR-325"),
                "information_query",
            ),
            (
                "Do we have a clean build?",
                Conversation,
                false,
                None,
                "information_query",
            ),
            (
                "RR-325",
                InspectTicket,
                false,
                Some("RR-325"),
                "ticket_reference",
            ),
            ("Sounds good", Conversation, false, None, ""),
        ] {
            assert_classified(text, kind, requires_ticket, ticket_id, Some(reason));
        }
    }

    #[test]
    fn classifier_uses_grammatical_role_not_bare_work_verbs() {
        let rr = Some("RR-325");
        for (text, kind, requires_ticket, ticket_id) in [
            (
                "Answer whether the release included RR-325.",
                InspectTicket,
                false,
                rr,
            ),
            ("Explain why the build failed.", Conversation, false, None),
            ("Show me the build history.", Conversation, false, None),
            ("Summarize the latest build.", Conversation, false, None),
            (
                "Can you summarize the latest build?",
                Conversation,
                false,
                None,
            ),
            ("Review the build history", Conversation, false, None),
            (
                "Please review whether the release shipped.",
                Conversation,
                false,
                None,
            ),
            (
                "Investigate why the build failed",
                Conversation,
                false,
                None,
            ),
            (
                "Could you investigate whether RR-325 shipped?",
                InspectTicket,
                false,
                rr,
            ),
            ("Check whether the build shipped", Conversation, false, None),
            (
                "Check if the latest build included RR-325.",
                InspectTicket,
                false,
                rr,
            ),
            ("Report the status of RR-325.", InspectTicket, false, rr),
            (
                "Compare the latest build with the last release.",
                Conversation,
                false,
                None,
            ),
            (
                "Explain the RR-325 build failure.",
                InspectTicket,
                false,
                rr,
            ),
            (
                "Find evidence that RR-325 shipped in the build.",
                InspectTicket,
                false,
                rr,
            ),
            (
                "Can you tell me whether RR-325 is done?",
                InspectTicket,
                false,
                rr,
            ),
            ("What is the status of RR-325?", InspectTicket, false, rr),
            ("Can you update me on RR-325?", InspectTicket, false, rr),
            ("Give me an update on RR-325.", InspectTicket, false, rr),
            ("Can you run me through RR-325?", InspectTicket, false, rr),
            ("Any status update on RR-325?", InspectTicket, false, rr),
            (
                "Run me through the latest build.",
                Conversation,
                false,
                None,
            ),
            ("Fix RR-325.", UpdateTicket, true, rr),
            ("Update RR-325.", UpdateTicket, true, rr),
            ("Build the release.", CreateTicket, true, None),
            ("Run RR-325.", DispatchTicket, true, rr),
            ("Dispatch RR-325.", DispatchTicket, true, rr),
            (
                "Track an investigation into the build failure.",
                CreateTicket,
                true,
                None,
            ),
            (
                "Delegate an investigation into why the build failed.",
                CreateTicket,
                true,
                None,
            ),
            (
                "Queue a spike to compare release history.",
                CreateTicket,
                true,
                None,
            ),
            (
                "Track an investigation into RR-325.",
                CreateTicket,
                true,
                None,
            ),
            ("Queue a review of RR-325.", CreateTicket, true, None),
            ("Do a clean build.", CreateTicket, true, None),
            ("Have the worker fix RR-325.", DispatchTicket, true, rr),
            (
                "Tell the worker to investigate RR-325.",
                DispatchTicket,
                true,
                rr,
            ),
            ("Ask the agent to review RR-325.", DispatchTicket, true, rr),
            ("I need a clean build.", CreateTicket, true, None),
            ("Go ahead and build the release.", CreateTicket, true, None),
        ] {
            let reason = (!requires_ticket).then_some("information_query");
            assert_classified(text, kind, requires_ticket, ticket_id, reason);
        }
    }

    #[test]
    fn mixed_conditional_request_requires_clarification_without_authority() {
        for text in [
            "Is there a release, and if not, build one",
            "Can you run me through RR-325, and if it needs changes, update RR-325",
            "Why did the build fail, and then fix it",
            "Can you tell me whether RR-325 is done, then dispatch it",
            "Summarize the build history, then queue a spike to investigate gaps",
            "Explain why the build failed, and if needed, delegate an investigation",
            "Review the build history, then build the release",
            "Investigate why the build failed, then repair it",
            "Check whether the build shipped, and if not, build it",
            "What is the status of RR-325, then update RR-325.",
        ] {
            assert!(is_mixed_query_and_mutation(text), "{text}");
            assert_classified(
                text,
                Conversation,
                false,
                None,
                Some("mixed_query_and_mutation_clarification"),
            );
            let prompt = format_command_for_agent(&classify_command(text), None);
            assert!(prompt.contains("Ask one concise clarification"), "{text}");
            assert!(prompt.contains("mutation_authorized: false"), "{text}");
        }
        assert!(!is_mixed_query_and_mutation(
            "fix the login bug and update the readme"
        ));
    }

    #[test]
    fn labelled_development_regressions() {
        let corpus = json::parse(include_str!(
            "../../../../tests/fixtures/intent_qualification.json"
        ))
        .unwrap();
        let cases = corpus
            .as_dict()
            .unwrap()
            .get("cases")
            .unwrap()
            .as_list()
            .unwrap();
        assert!(!cases.is_empty());
        for case in cases {
            let case = case.as_dict().unwrap();
            let text = case.string("text");
            let action = classify_command(&text);
            let hint = qualify_intent(&text, action.kind.as_str(), Some(action.reason), None, None);
            assert_eq!(
                action.kind.as_str(),
                case.string("expected_action_kind"),
                "{text}"
            );
            assert_eq!(
                hint.bucket.map(|bucket| bucket.as_str()),
                case.get("expected_bucket").and_then(Value::as_str),
                "{text}"
            );
        }
    }

    #[test]
    fn switching_style_by_voice_is_a_foreground_action_not_a_ticket() {
        for (text, style) in [
            ("Switch to direct mode", "direct"),
            ("Okay, can you change to orchestrated mode?", "orchestrated"),
            ("Set the work style to auto", "auto"),
            ("Use direct mode for this project", "direct"),
        ] {
            assert_classified(text, DirectAction, false, None, Some("set_work_style"));
            let prompt = format_command_for_agent(&classify_command(text), None);
            assert!(
                prompt.contains(&format!("relay-work-style set {style}")),
                "{text}"
            );
            assert!(
                prompt.contains(&format!("- work_style_requested: {style}")),
                "{text}"
            );
            assert!(prompt.contains("Do not create a ticket"), "{text}");
        }
        assert_ne!(
            classify_command("What does direct mode do?").reason,
            "set_work_style"
        );
    }

    #[test]
    fn negated_stop_status_request_is_not_a_cancel_control() {
        let scratch = Scratch::new("negated-stop");
        let action = resolve_in(
            &environment(&scratch),
            "don't stop the current work; just give me status",
            None,
            Some(&relay(2, "cmd-2")),
        );
        assert_eq!(
            (action.kind, action.reason, action.requires_ticket),
            (Conversation, "", false)
        );
        assert_eq!(
            (action.relay_command_seq, action.relay_command_id.as_deref()),
            (Some(2), Some("cmd-2"))
        );
    }

    #[test]
    fn direct_computer_prompt_is_shell_first_and_keeps_messenger_tool_free() {
        let scratch = Scratch::new("direct-prompt");
        let action = resolve_in(
            &environment(&scratch),
            "open this folder in Finder",
            Some("/tmp/repo"),
            Some(&relay(4, "cmd-4")),
        );
        assert_eq!(
            action.repo_path.as_deref(),
            Some(resolve_path("/tmp/repo").as_str())
        );
        let prompt = format_command_for_agent(&action, None);
        for expected in [
            "action: direct_action",
            "Handle this directly in the foreground PM",
            "Do not create a ticket, dispatch a worker, or send this to the Relay daemon",
            "Prefer a deterministic shell or operating-system command",
            "Relay Vision",
            "Relay Actions",
            "The messenger remains tool-free",
            "- relay_command_seq: 4\n- relay_command_id: cmd-4\n",
        ] {
            assert!(prompt.contains(expected), "{expected}");
        }
    }

    #[test]
    fn new_project_work_requires_refined_management_ticket() {
        let repo = Scratch::new("orchestrated-repo");
        // Orchestrated keeps the ticket-first route; auto and direct are
        // covered by tests/fixtures/work_style_routing.json.
        repo.write(".relay-runner.toml", "work_style = \"orchestrated\"\n");
        for text in ["fix the login retry bug", "implement the sidebar"] {
            let action = resolve_in(&environment(&repo), text, Some(repo.path()), None);
            assert_eq!((action.kind, action.requires_ticket), (CreateTicket, true));
            assert_eq!(
                (action.ticket_id.as_deref(), action.ticket_path.as_deref()),
                (None, None)
            );
            assert_eq!(action.scope, Some("project"));
            assert_eq!(
                action.repo_path.as_deref(),
                Some(resolve_path(repo.path()).as_str())
            );
            let prompt = format_command_for_agent(&action, None);
            for expected in [
                "action: create_ticket",
                "ticket_id: null",
                "Create or refine a visible ticket now",
                "You are the PM frontstage",
                "foreground orchestrator/PM owns command classification",
                "Raw Relay command captures are private metadata",
                "Creating or editing visible `.orchestrator/` tickets is PM management work",
                "Do not implement the ticket yourself",
            ] {
                assert!(prompt.contains(expected), "{expected}");
            }
            assert!(!prompt.contains("You are the foreground orchestrator"));
        }
        assert!(!repo.0.join(".orchestrator").exists());
    }

    #[test]
    fn relay_command_metadata_is_preserved_without_visible_ticket() {
        let repo = Scratch::new("auto-repo");
        let action = resolve_in(
            &environment(&repo),
            "fix the login retry bug",
            Some(repo.path()),
            Some(&relay(7, "cmd-7")),
        );
        assert_eq!(
            (action.kind, action.reason),
            (Conversation, "route_undecided")
        );
        assert_eq!(
            (action.relay_command_seq, action.relay_command_id.as_deref()),
            (Some(7), Some("cmd-7"))
        );
        let prompt = format_command_for_agent(&action, None);
        for expected in [
            "relay_command_seq: 7",
            "relay_command_id: cmd-7",
            "pass relay_command_seq and relay_command_id",
            "foreground orchestrator/PM",
        ] {
            assert!(prompt.contains(expected), "{expected}");
        }
        assert!(
            prompt.ends_with("uses no ticket.\n- relay_command_seq: 7\n- relay_command_id: cmd-7")
        );
        // Without a Relay command the guidance keeps its trailing newline.
        let bare = resolve_in(
            &environment(&repo),
            "fix the login retry bug",
            Some(repo.path()),
            None,
        );
        assert!(format_command_for_agent(&bare, None).ends_with("uses no ticket.\n"));
    }

    #[test]
    fn relay_fields_follow_python_truthiness_and_int() {
        let scratch = Scratch::new("relay-fields");
        let mut command = Dict::new();
        command.insert("relay_command_seq", "12");
        command.insert("relay_command_id", 5);
        let action = resolve_in(&environment(&scratch), "hello", None, Some(&command));
        assert_eq!(
            (action.relay_command_seq, action.relay_command_id.as_deref()),
            (Some(12), Some("5"))
        );
        let mut command = Dict::new();
        command.insert("relay_command_seq", "soon");
        command.insert("relay_command_id", "");
        let action = resolve_in(&environment(&scratch), "hello", None, Some(&command));
        assert_eq!(
            (action.relay_command_seq, action.relay_command_id),
            (None, None)
        );
    }

    #[test]
    fn work_style_precedence_and_unknown_values() {
        let scratch = Scratch::new("precedence");
        let mut environment = environment(&scratch);
        let repo = Scratch::new("precedence-repo");
        let text = "Make the title fade in slower";
        assert_eq!(project_work_style(&environment, Some(repo.path())), "auto");
        repo.write(
            ".relay-runner.toml",
            "# Remotion project\nwork_style = \"direct\"\n",
        );
        assert_eq!(
            project_work_style(&environment, Some(repo.path())),
            "direct"
        );
        let action = resolve_in(&environment, text, Some(repo.path()), None);
        assert_eq!(
            (action.kind, action.reason),
            (InlineWork, "work_style_direct")
        );
        assert!(format_command_for_agent(&action, None).contains("work_style: direct"));
        repo.write(".relay-runner.toml", "work_style = \"sometimes\"\n");
        assert_eq!(project_work_style(&environment, Some(repo.path())), "auto");

        repo.write(".relay-runner.toml", "work_style = \"orchestrated\"\n");
        assert_eq!(
            work_style_and_source(&environment, Some(repo.path())),
            ("orchestrated", "project")
        );
        for saved in [
            r#"{"work_style": "sometimes"}"#,
            r#"{"work_style": 1}"#,
            r#"["direct"]"#,
            "not json",
            "",
        ] {
            scratch.write("session-work-style.json", saved);
            assert_eq!(
                session_work_style(&environment.session_work_style_file),
                None,
                "{saved}"
            );
            assert_eq!(
                work_style_and_source(&environment, Some(repo.path())),
                ("orchestrated", "project"),
                "{saved}"
            );
        }
        scratch.write("session-work-style.json", r#"{"work_style": "Direct"}"#);
        assert_eq!(
            session_work_style(&environment.session_work_style_file),
            Some("direct")
        );
        assert_eq!(
            work_style_and_source(&environment, Some(repo.path())),
            ("direct", "session")
        );
        assert_eq!(
            resolve_in(&environment, text, Some(repo.path()), None).kind,
            InlineWork
        );
        environment.work_style = "auto".to_string();
        assert_eq!(
            work_style_and_source(&environment, Some(repo.path())),
            ("auto", "env")
        );
        environment.work_style = " Weird ".to_string();
        assert_eq!(
            work_style_and_source(&environment, Some(repo.path())),
            ("auto", "env")
        );
    }

    #[test]
    fn labelled_routes_for_every_work_style() {
        let corpus = json::parse(include_str!(
            "../../../../tests/fixtures/work_style_routing.json"
        ))
        .unwrap();
        let cases = corpus
            .as_dict()
            .unwrap()
            .get("cases")
            .unwrap()
            .as_list()
            .unwrap();
        assert!(!cases.is_empty());
        let scratch = Scratch::new("routes");
        let repo = Scratch::new("routes-repo");
        let mut environment = environment(&scratch);
        for source in ["env", "session"] {
            for style in WORK_STYLES {
                if source == "env" {
                    environment.work_style = style.to_string();
                } else {
                    environment.work_style.clear();
                    scratch.save_session_style(style);
                }
                for case in cases {
                    let case = case.as_dict().unwrap();
                    let text = case.string("text");
                    let action = resolve_in(&environment, &text, Some(repo.path()), None);
                    let hint = qualify_intent(
                        &text,
                        action.kind.as_str(),
                        Some(action.reason),
                        None,
                        None,
                    );
                    let expected: Vec<&str> = case
                        .get(style)
                        .and_then(Value::as_list)
                        .unwrap()
                        .iter()
                        .filter_map(Value::as_str)
                        .collect();
                    let bucket = hint.bucket.map_or("", |bucket| bucket.as_str());
                    assert_eq!(
                        vec![bucket, action.kind.as_str()],
                        expected,
                        "{source} {style} {}",
                        case.string("id")
                    );
                    if bucket == "undecided" {
                        assert!(hint.unresolved);
                        let prompt = format_command_for_agent(&action, None);
                        assert!(prompt.contains("ask one short question"));
                        assert!(!prompt.contains("action: create_ticket"));
                    }
                }
            }
        }
    }

    #[test]
    fn the_bridge_environment_switches_route_a_change_request() {
        let scratch = Scratch::new("bridge-environment");
        let repo = Scratch::new("bridge-environment-repo");
        let mut environment = environment(&scratch);
        let change = "fix the login button colour";
        let action = resolve_in(&environment, change, Some(repo.path()), None);
        assert_eq!(
            (action.kind, action.reason),
            (Conversation, "route_undecided")
        );
        environment.work_style = "direct".to_string();
        let action = resolve_in(&environment, change, Some(repo.path()), None);
        assert_eq!(
            (action.kind, action.reason),
            (InlineWork, "work_style_direct")
        );
        assert!(format_command_for_agent(&action, None).contains("- work_style: direct"));
        environment.work_style.clear();
        scratch.save_session_style("direct");
        assert_eq!(
            resolve_in(&environment, change, Some(repo.path()), None).kind,
            InlineWork
        );
        environment.work_style = "orchestrated".to_string();
        assert_eq!(
            resolve_in(
                &environment,
                "fix the logout button colour",
                Some(repo.path()),
                None
            )
            .kind,
            CreateTicket
        );
    }

    #[test]
    fn change_requests_without_a_confirmed_project_need_a_target() {
        let scratch = Scratch::new("no-project");
        let mut environment = environment(&scratch);
        for text in ["Fix the login bug", "Fix the source code in report.py"] {
            let action = resolve_in(&environment, text, None, None);
            assert_eq!(
                (action.kind, action.repo_path.as_deref()),
                (NeedsProject, None),
                "{text}"
            );
            assert_eq!(action.outcome(), "waiting on target-project choice");
            let prompt = format_command_for_agent(&action, None);
            assert!(prompt.contains("no active Workspace project was found"));
        }
        environment.work_style = "direct".to_string();
        assert_eq!(
            resolve_in(
                &environment,
                "Fix the login retry bug in the repo",
                None,
                None
            )
            .kind,
            NeedsProject
        );
        environment.work_style = "orchestrated".to_string();
        let project = resolve_in(
            &environment,
            "Fix the source code in report.py",
            Some("/tmp/confirmed-project"),
            None,
        );
        assert_eq!(project.scope, Some("project"));
        let expected = if cfg!(target_os = "macos") {
            "/private/tmp/confirmed-project"
        } else {
            "/tmp/confirmed-project"
        };
        assert_eq!(project.repo_path.as_deref(), Some(expected));
    }

    #[test]
    fn general_routing_without_a_project() {
        let scratch = Scratch::new("general-routing");
        let environment = environment(&scratch);
        assert_classified(
            "Create a short local draft for my introduction",
            DirectAction,
            false,
            None,
            Some("bounded_local_draft"),
        );
        for text in [
            "Just discuss preparing a multi-file report",
            "Research whether this is feasible",
            "What is the status?",
        ] {
            assert!(
                !resolve_in(&environment, text, None, None).requires_ticket,
                "{text}"
            );
        }
        let tracked = resolve_in(
            &environment,
            "Track research into public transport options",
            None,
            None,
        );
        assert_eq!(
            (tracked.requires_ticket, tracked.scope),
            (true, Some("general"))
        );
        assert_eq!(tracked.outcome(), "general work needs refined ticket");

        let general = resolve_in(
            &environment,
            "Dispatch GEN-0123456789ABCDEF",
            Some("/tmp/unrelated-repo"),
            Some(&relay(3, "cmd-3")),
        );
        assert_eq!(
            (general.kind, general.scope, general.repo_path),
            (DispatchTicket, Some("general"), None)
        );
        assert_eq!(general.relay_command_seq, Some(3));
        let mixed = resolve_in(
            &environment,
            "Explain the options and create a report",
            None,
            None,
        );
        assert_eq!((mixed.kind, mixed.requires_ticket), (Conversation, false));

        let inspection = resolve_in(
            &environment,
            "What is the status of GEN-0123456789ABCDEF?",
            None,
            None,
        );
        assert_eq!(inspection.kind, InspectTicket);
        assert_eq!(
            inspection.ticket_id.as_deref(),
            Some("GEN-0123456789ABCDEF")
        );
        let prompt = format_command_for_agent(&inspection, None);
        assert!(prompt.contains("Relay Runner General work contract:\n- action: inspect_ticket\n"));
        assert!(prompt.contains("general_task"));
    }

    #[test]
    fn a_general_session_keeps_ticket_work_off_the_project() {
        let scratch = Scratch::new("general-session");
        let root = Scratch::new("general-session-root");
        let mut environment = Environment {
            session_scope: Some("general".to_string()),
            general_files_root: Some(root.path().to_string()),
            ..environment(&scratch)
        };
        let report = resolve_in(
            &environment,
            "Prepare a multi-file report",
            Some(root.path()),
            None,
        );
        assert_eq!(
            (report.scope, report.repo_path.as_deref()),
            (Some("general"), None)
        );
        assert!(format_command_for_agent(&report, None).contains("general_task"));
        let newsletter = resolve_in(
            &environment,
            "create a ticket to write the quarterly newsletter",
            Some(root.path()),
            None,
        );
        assert_eq!(
            (newsletter.kind, newsletter.repo_path.as_deref()),
            (CreateTicket, None)
        );
        assert_eq!(newsletter.outcome(), "general work needs refined ticket");

        // No choice, auto, orchestrated and a project file all keep
        // General's own routing.
        let text = "Make the title fade in slower";
        root.write(".relay-runner.toml", "work_style = \"direct\"\n");
        for style in [None, Some("auto"), Some("orchestrated")] {
            if let Some(style) = style {
                scratch.save_session_style(style);
            }
            let action = resolve_in(&environment, text, Some(root.path()), None);
            assert_eq!(
                (action.kind, action.scope),
                (CreateTicket, Some("general")),
                "{style:?}"
            );
        }
        for source in ["session", "env"] {
            if source == "session" {
                scratch.save_session_style("direct");
            } else {
                scratch.save_session_style("auto");
                environment.work_style = "direct".to_string();
            }
            let action = resolve_in(&environment, text, Some(root.path()), None);
            assert_eq!(
                (action.kind, action.reason),
                (InlineWork, "work_style_direct"),
                "{source}"
            );
            assert_eq!(action.repo_path, None);
            assert!(
                format_command_for_agent(&action, None)
                    .contains("This session's work style is direct")
            );
            // Project work still needs a confirmed repository, and tracking
            // wording still wins.
            assert_eq!(
                resolve_in(
                    &environment,
                    "Fix the login retry bug in the repo",
                    Some(root.path()),
                    None
                )
                .kind,
                NeedsProject
            );
            assert_eq!(
                resolve_in(
                    &environment,
                    "Create a ticket to make the title fade in slower",
                    Some(root.path()),
                    None
                )
                .kind,
                CreateTicket
            );
        }
        // Another folder in a General session is a project.
        let other = Scratch::new("general-session-other");
        environment.work_style = "orchestrated".to_string();
        let project = resolve_in(&environment, text, Some(other.path()), None);
        assert_eq!(project.scope, Some("project"));
    }

    #[test]
    fn the_work_disposition_follows_the_prompt() {
        let text = "what is left on the release checklist";
        let action = classify_command(text);
        let disposition = resolve_intent_disposition(&DispositionRequest {
            intent_id: "cmd-1:item:1",
            action_kind: action.kind.as_str(),
            action_reason: Some(action.reason),
            source_text: text,
            ..DispositionRequest::default()
        })
        .to_dict();
        let prompt = format_command_for_agent(&action, Some(&disposition));
        assert!(prompt.starts_with(&format!(
            "{text}\n\nRelay work-intent disposition:\n- route: continue_current\n\
             - target_work_ids: none\n- conflicting_work_ids: none\n\
             - mutation_authorization_effect: preserve\n- public_reason: "
        )));
        assert!(prompt.ends_with("resource-safe, and never speaks directly."));

        let mut custom = Dict::new();
        custom.insert("route", " queue_project_work ");
        custom.insert(
            "target_work_ids",
            Value::List(vec![Value::from("a"), Value::Int(2)]),
        );
        custom.insert("clarification_question", " Which one? ");
        let prompt = format_command_for_agent(&action, Some(&custom));
        assert!(prompt.contains(
            "- route: queue_project_work\n- target_work_ids: a, 2\n- conflicting_work_ids: none\n\
             - mutation_authorization_effect: preserve\n- public_reason: Resolved by the bridge policy.\n"
        ));
        assert!(prompt.ends_with("never speaks directly.\n- clarification_question: Which one?"));

        let mut routeless = Dict::new();
        routeless.insert("route", "  ");
        assert_eq!(format_command_for_agent(&action, Some(&routeless)), text);
    }
}
