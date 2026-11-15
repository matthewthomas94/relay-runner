//! General tasks (RR-499): the RR-485 contract case at library level, the
//! real worker process path, cancellation, the worker result contract and
//! prompt, and a state root read back by a second store.

mod common;

use std::fs;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::thread;
use std::time::{Duration, Instant};

use relay_intents::json;
use relay_services::general_work::{
    Cancellation, GeneralWork, GeneralWorkOptions, Runner, manifest, prompt, validate_result,
};
use relay_services::{Dict, Result, Value};

use common::TempRoot;

fn text(value: &str) -> Value {
    Value::Str(value.to_string())
}

fn list(values: &[&str]) -> Value {
    Value::List(values.iter().map(|value| text(value)).collect())
}

const RESULT: &str = r#"{"summary": "Drafted.", "criteria": [{"criterion": "A draft exists.", "evidence": "output.md holds it."}], "artifacts": ["output.md"]}"#;

/// Writes `output.md` and a valid `result.json`, like a finished worker.
struct Drafting;

impl Runner for Drafting {
    fn run(
        &self,
        _work: &GeneralWork,
        _command: &[String],
        workspace: &Path,
        prompt: &str,
        _run_id: &str,
        _cancelled: &Cancellation,
    ) -> Result<i32> {
        assert!(prompt.contains("\"acceptance_criteria\": [\n    \"A draft exists.\"\n  ]"));
        fs::write(workspace.join("output.md"), "# Draft\n")?;
        fs::write(workspace.join("result.json"), RESULT)?;
        Ok(0)
    }
}

/// Waits until its run is cancelled.
struct Waiting;

impl Runner for Waiting {
    fn run(
        &self,
        _work: &GeneralWork,
        _command: &[String],
        _workspace: &Path,
        _prompt: &str,
        _run_id: &str,
        cancelled: &Cancellation,
    ) -> Result<i32> {
        let deadline = Instant::now() + Duration::from_secs(10);
        while !cancelled.is_set() && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(10));
        }
        Ok(-15)
    }
}

fn claude(_provider: Option<&str>) -> Result<(String, Vec<String>)> {
    Ok(("claude".to_string(), vec!["claude".to_string()]))
}

fn open(root: &Path, runner: Option<Box<dyn Runner>>) -> Arc<GeneralWork> {
    Arc::new(
        GeneralWork::open(
            root,
            GeneralWorkOptions {
                command_factory: Some(Box::new(claude)),
                preflight: None,
                runner,
                personal_storage: None,
            },
        )
        .unwrap(),
    )
}

fn task_of(answer: &Dict) -> Dict {
    answer
        .get("task")
        .and_then(Value::as_dict)
        .cloned()
        .unwrap()
}

fn field(task: &Dict, key: &str) -> String {
    task.get(key).map(Value::py_str).unwrap_or_default()
}

fn wait_for_status(work: &GeneralWork, task_id: &str, status: &str) -> Dict {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let task = task_of(&work.get(task_id).unwrap());
        if field(&task, "status") == status {
            return task;
        }
        assert!(
            Instant::now() < deadline,
            "task never reached {status}: {task:?}"
        );
        thread::sleep(Duration::from_millis(20));
    }
}

fn last_run(task: &Dict) -> Dict {
    task.get("runs")
        .and_then(Value::as_list)
        .and_then(|runs| runs.last())
        .and_then(Value::as_dict)
        .cloned()
        .unwrap()
}

fn create(work: &GeneralWork, request_id: &str) -> Result<Dict> {
    work.create(
        &text("Draft"),
        &text("Write a draft."),
        &list(&["A draft exists."]),
        &text(request_id),
    )
}

/// GeneralTaskTests.test_general_task_is_created_run_reviewed.
#[test]
fn contract_general_task_is_created_run_reviewed() {
    let root = TempRoot::new("general-contract");
    let work = open(&root.state_root(), Some(Box::new(Drafting)));

    let created = create(&work, "general-1").unwrap();
    let task = task_of(&created);
    assert_eq!(
        (field(&task, "scope"), field(&task, "status")),
        ("general".into(), "backlog".into())
    );
    assert!(matches!(
        created.get("idempotent"),
        Some(Value::Bool(false))
    ));
    let again = create(&work, "general-1").unwrap();
    assert!(matches!(again.get("idempotent"), Some(Value::Bool(true))));
    let task_id = field(&task, "id");

    let dispatched = work.dispatch(&task_id, None).unwrap();
    assert!(matches!(
        dispatched.get("already_active"),
        Some(Value::Bool(false))
    ));
    let waiting = wait_for_status(&work, &task_id, "awaiting_review");
    let run = last_run(&waiting);
    assert_eq!(field(&run, "provider"), "claude");
    let paths: Vec<String> = run
        .get("artifact_manifest")
        .and_then(Value::as_list)
        .unwrap()
        .iter()
        .map(|item| field(item.as_dict().unwrap(), "path"))
        .collect();
    assert_eq!(paths, ["output.md"]);
    let files_tasks = root.state_root().join("files").join("tasks");
    assert!(field(&run, "workspace_path").starts_with(&*files_tasks.to_string_lossy()));

    let refused = work
        .review(&task_id, run.get("id").unwrap(), &Value::Null, &Value::Null)
        .unwrap_err();
    assert_eq!(
        refused.message,
        "Review requires approve true/false and an evidence-based summary"
    );
    let reviewed = work
        .review(
            &task_id,
            run.get("id").unwrap(),
            &Value::Bool(true),
            &text("output.md covers the criterion."),
        )
        .unwrap();
    assert_eq!(field(&task_of(&reviewed), "status"), "done");
    let listed = work.list(100).unwrap();
    assert_eq!(listed.get("total_count").and_then(Value::py_int), Some(1));
    assert_eq!(listed.get("scope").and_then(Value::as_str), Some("general"));
    let missing = work
        .create(&text("x"), &Value::Null, &Value::Null, &Value::Null)
        .unwrap_err();
    assert_eq!(
        missing.message,
        "title, description and request_id are required"
    );

    // The event log records each step, in order.
    let events: Vec<String> = work
        .get(&task_id)
        .unwrap()
        .get("events")
        .and_then(Value::as_list)
        .unwrap()
        .iter()
        .map(|event| field(event.as_dict().unwrap(), "kind"))
        .collect();
    assert_eq!(
        events,
        ["created", "dispatched", "awaiting_review", "reviewed"]
    );

    // A done task cannot run again.
    let error = work.dispatch(&task_id, None).unwrap_err();
    assert_eq!(
        error.message,
        "Only backlog, failed, interrupted or changes-requested General tasks can run"
    );
}

#[test]
fn process_runner_runs_the_command_in_its_workspace() {
    let root = TempRoot::new("general-process");
    let script = format!(
        "cat > prompt.txt; printf '%s' \"$RELAY_SESSION_SCOPE\" > output.md; \
         printf '%s' \"${{RELAY_PROJECT_SCOPE_TOKEN:-unset}}\" >> output.md; printf '%s' '{}' > result.json",
        RESULT.replace('\'', "'\\''")
    );
    let factory = move |_provider: Option<&str>| -> Result<(String, Vec<String>)> {
        Ok((
            "codex".to_string(),
            vec!["/bin/sh".to_string(), "-c".to_string(), script.clone()],
        ))
    };
    let work = Arc::new(
        GeneralWork::open(
            &root.state_root(),
            GeneralWorkOptions {
                command_factory: Some(Box::new(factory)),
                ..GeneralWorkOptions::default()
            },
        )
        .unwrap(),
    );
    let task_id = field(&task_of(&create(&work, "process-1").unwrap()), "id");
    work.dispatch(&task_id, Some("codex")).unwrap();
    let task = wait_for_status(&work, &task_id, "awaiting_review");
    let run = last_run(&task);
    let workspace = PathBuf::from(field(&run, "workspace_path"));
    assert_eq!(
        fs::read_to_string(workspace.join("output.md")).unwrap(),
        "generalunset"
    );
    assert!(
        fs::read_to_string(workspace.join("prompt.txt"))
            .unwrap()
            .starts_with("You are a Relay Runner General task worker.")
    );
    assert!(workspace.join("worker.log").is_file());
    assert!(run.get("worker_pid").and_then(Value::py_int).is_some());
    assert!(run.iter().any(|(key, _)| key == "process_identity"));

    // A failing worker leaves a recoverable failed task naming its status.
    let failing = |_provider: Option<&str>| -> Result<(String, Vec<String>)> {
        Ok((
            "claude".to_string(),
            vec!["/bin/sh".into(), "-c".into(), "exit 3".into()],
        ))
    };
    let other = TempRoot::new("general-process-fail");
    let work = Arc::new(
        GeneralWork::open(
            &other.state_root(),
            GeneralWorkOptions {
                command_factory: Some(Box::new(failing)),
                ..GeneralWorkOptions::default()
            },
        )
        .unwrap(),
    );
    let task_id = field(&task_of(&create(&work, "process-2").unwrap()), "id");
    work.dispatch(&task_id, None).unwrap();
    let failed = wait_for_status(&work, &task_id, "failed");
    assert_eq!(
        field(&last_run(&failed), "error"),
        "claude worker exited with status 3; inspect this run's local worker.log"
    );
}

#[test]
fn cancel_stops_the_current_run() {
    let root = TempRoot::new("general-cancel");
    let work = open(&root.state_root(), Some(Box::new(Waiting)));
    let task_id = field(&task_of(&create(&work, "cancel-1").unwrap()), "id");
    work.dispatch(&task_id, None).unwrap();
    let active = work.dispatch(&task_id, None).unwrap();
    assert!(matches!(
        active.get("already_active"),
        Some(Value::Bool(true))
    ));
    let error = work.cancel(&task_id, &text("not-the-run")).unwrap_err();
    assert_eq!(
        error.message,
        "Cancellation must target the current General run"
    );
    let canceled = work.cancel(&task_id, &Value::Null).unwrap();
    assert_eq!(field(&task_of(&canceled), "status"), "canceled");
    let task = wait_for_status(&work, &task_id, "canceled");
    assert_eq!(field(&last_run(&task), "state"), "canceled");
    // The worker thread records the cancellation once it returns.
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let kinds: Vec<String> = work
            .get(&task_id)
            .unwrap()
            .get("events")
            .and_then(Value::as_list)
            .unwrap()
            .iter()
            .map(|event| field(event.as_dict().unwrap(), "kind"))
            .collect();
        if kinds == ["created", "dispatched", "canceled", "canceled"] {
            break;
        }
        assert!(Instant::now() < deadline, "events: {kinds:?}");
        thread::sleep(Duration::from_millis(20));
    }
    // Reviewing a canceled run is refused.
    let run = last_run(&task);
    let error = work
        .review(
            &task_id,
            run.get("id").unwrap(),
            &Value::Bool(false),
            &text("no"),
        )
        .unwrap_err();
    assert_eq!(
        error.message,
        "Review must target the current General run awaiting review"
    );
}

/// Workspaces for the result-contract cases, each `(name, workspace)`.
fn result_cases(root: &Path) -> Vec<(String, PathBuf)> {
    let write = |name: &str, result: Option<&str>| -> (String, PathBuf) {
        let workspace = root.join(name);
        fs::create_dir_all(workspace.join("sub")).unwrap();
        fs::write(workspace.join("output.md"), "# Draft\n").unwrap();
        fs::write(workspace.join("sub").join("note.txt"), "note").unwrap();
        if let Some(result) = result {
            fs::write(workspace.join("result.json"), result).unwrap();
        }
        (name.to_string(), workspace)
    };
    let with = |artifacts: &str, criteria: &str| {
        format!(r#"{{"summary": "ok", "criteria": {criteria}, "artifacts": {artifacts}}}"#)
    };
    let good = r#"[{"criterion": "A draft exists.", "evidence": "e"}, {"criterion": "B", "evidence": "f"}]"#;
    let mut cases = vec![
        write("missing", None),
        write("not-object", Some("[]")),
        write("blank-summary", Some(r#"{"summary": "  "}"#)),
        write(
            "no-evidence",
            Some(r#"{"summary": "ok", "criteria": [{"criterion": "A draft exists."}]}"#),
        ),
        write(
            "wrong-criteria",
            Some(&with(
                r#"["output.md"]"#,
                r#"[{"criterion": "A draft exists.", "evidence": "e"}]"#,
            )),
        ),
        write(
            "number-criterion",
            Some(&with(
                r#"["output.md"]"#,
                r#"[{"criterion": "A draft exists.", "evidence": "e"}, {"criterion": 7, "evidence": "f"}]"#,
            )),
        ),
        write("no-artifacts", Some(&with("[]", good))),
        write("parent", Some(&with(r#"["../output.md"]"#, good))),
        write("absolute", Some(&with(r#"["/etc/hosts"]"#, good))),
        write("reserved", Some(&with(r#"["result.json"]"#, good))),
        write("absent", Some(&with(r#"["nothing.md"]"#, good))),
        write(
            "duplicate",
            Some(&with(r#"["output.md", "output.md"]"#, good)),
        ),
        write("directory", Some(&with(r#"["sub"]"#, good))),
        write(
            "valid",
            Some(&with(r#"["output.md", "./sub//note.txt"]"#, good)),
        ),
    ];
    let linked = write("symlink", Some(&with(r#"["link.md"]"#, good)));
    symlink(linked.1.join("output.md"), linked.1.join("link.md")).unwrap();
    cases.push(linked);
    let directory_link = write("symlink-parent", Some(&with(r#"["alias/note.txt"]"#, good)));
    symlink(directory_link.1.join("sub"), directory_link.1.join("alias")).unwrap();
    cases.push(directory_link);
    let result_link = write("result-link", None);
    fs::write(
        result_link.1.join("real.json"),
        with(r#"["output.md"]"#, good),
    )
    .unwrap();
    symlink(
        result_link.1.join("real.json"),
        result_link.1.join("result.json"),
    )
    .unwrap();
    cases.push(result_link);
    cases
}

/// Each result-contract case and the refusal it gets (`None` accepts it).
const RESULT_OUTCOMES: &[(&str, Option<&str>)] = &[
    (
        "missing",
        Some("Worker did not produce a valid bounded result.json"),
    ),
    ("not-object", Some("Worker result needs a summary")),
    ("blank-summary", Some("Worker result needs a summary")),
    (
        "no-evidence",
        Some("Worker result needs evidence for each acceptance criterion"),
    ),
    (
        "wrong-criteria",
        Some("Worker result must cover every acceptance criterion exactly once"),
    ),
    (
        "number-criterion",
        Some("Worker result must cover every acceptance criterion exactly once"),
    ),
    (
        "no-artifacts",
        Some("Worker result must name at least one local artifact"),
    ),
    (
        "parent",
        Some("Worker artifact path is outside its output contract"),
    ),
    (
        "absolute",
        Some("Worker artifact path is outside its output contract"),
    ),
    (
        "reserved",
        Some("Worker artifact path is outside its output contract"),
    ),
    (
        "absent",
        Some("Worker artifact is missing or outside its managed run"),
    ),
    ("duplicate", Some("Worker artifacts must be unique")),
    (
        "directory",
        Some("Worker artifact is missing or outside its managed run"),
    ),
    ("valid", None),
    ("symlink", Some("Worker artifacts cannot contain symlinks")),
    (
        "symlink-parent",
        Some("Worker artifacts cannot contain symlinks"),
    ),
    (
        "result-link",
        Some("Worker did not produce a valid bounded result.json"),
    ),
];

/// The `valid` case's manifest.
const VALID_MANIFEST: &str = r#"[{"path": "output.md", "size_bytes": 8, "sha256": "c47fffce7ab6215da4633829b59605e9bdf14fb3d49b6ac0fe8105e639b9c4f9"}, {"path": "./sub//note.txt", "size_bytes": 4, "sha256": "edb465624291e4053c6c5ea4b7eb320dec773e10a57d26b95dcf0564f8e310f8"}]"#;

/// The worker prompt for the result-contract task.
const RESULT_PROMPT: &str = r#"
You are a Relay Runner General task worker. Work only on this bounded task in the current managed output directory. This is not a source repository; do not initialize Git, edit project boards, dispatch workers, or commit. Preserve unrelated files and accepted work. Task classification does not authorize sending messages, publishing, purchasing, deleting existing user data or other external effects. If completing the task needs an effect not explicitly authorized in the description, stop with an exact blocker instead of doing it. Create local drafts for review. Do not copy credentials, machine logs or provider transcripts into artifacts. Do not change your task's canonical lifecycle.

{
  "id": "GEN-0123456789ABCDEF",
  "title": "Draft \u00e9",
  "description": "Write it.",
  "acceptance_criteria": [
    "A draft exists.",
    "B"
  ]
}

When finished, write result.json containing {"summary":"...", "criteria":[{"criterion":"exact acceptance criterion", "evidence":"specific result and validation"}], "artifacts":["relative/output.md"]}. Cover each criterion exactly once. Include all deliverable files, not worker.log or result.json. Outputs remain pending PM review. If blocked, exit without a success result and write a local blocker.md explaining the resume path.
"#;

#[test]
fn result_contract_and_prompt() {
    let root = TempRoot::new("general-results");
    let cases = result_cases(&root.path);
    let task = json::parse(
        r#"{"id": "GEN-0123456789ABCDEF", "title": "Draft é", "description": "Write it.",
            "acceptance_criteria": ["A draft exists.", "B"], "status": "in_progress"}"#,
    )
    .unwrap();
    let Value::Dict(task) = task else {
        unreachable!()
    };
    assert_eq!(cases.len(), RESULT_OUTCOMES.len());
    for ((name, workspace), (expected_name, refusal)) in cases.iter().zip(RESULT_OUTCOMES) {
        assert_eq!(name, expected_name);
        match (validate_result(&task, workspace), refusal) {
            (Ok((result, manifest)), None) => {
                assert_eq!(
                    json::dumps(result.get("artifacts").unwrap()),
                    r#"["output.md", "./sub//note.txt"]"#,
                    "case {name}"
                );
                assert_eq!(
                    json::dumps(&Value::List(
                        manifest.into_iter().map(Value::Dict).collect()
                    )),
                    VALID_MANIFEST,
                    "case {name}"
                );
            }
            (Err(error), Some(refusal)) => assert_eq!(error.message, *refusal, "case {name}"),
            (outcome, _) => panic!("case {name}: {:?}", outcome.map(|_| ()).err()),
        }
    }
    assert_eq!(prompt(&task), RESULT_PROMPT.strip_prefix('\n').unwrap());
    // `_manifest` refuses anything but a non-empty list of strings.
    for paths in [Value::Null, list(&[]), Value::List(vec![Value::Int(1)])] {
        assert_eq!(
            manifest(&cases[0].1, &paths).unwrap_err().message,
            "Worker result must name at least one local artifact"
        );
    }
}

#[test]
fn a_reopened_state_root_reads_the_same_general_tasks() {
    let root = TempRoot::new("general-reopen");
    let work = open(&root.state_root(), Some(Box::new(Drafting)));

    // A task through a requested change; a second store on the same state
    // root reads it as the first does.
    let task_id = field(&task_of(&create(&work, "rust-1").unwrap()), "id");
    work.dispatch(&task_id, None).unwrap();
    let waiting = wait_for_status(&work, &task_id, "awaiting_review");
    let run = last_run(&waiting);
    work.review(
        &task_id,
        run.get("id").unwrap(),
        &Value::Bool(false),
        &text("Needs more."),
    )
    .unwrap();
    let ours = work.get(&task_id).unwrap();
    let listed = work.list(1).unwrap();
    assert_eq!(field(&task_of(&ours), "status"), "changes_requested");

    let reopened = open(&root.state_root(), None);
    assert_eq!(
        json::dumps(&Value::Dict(reopened.get(&task_id).unwrap())),
        json::dumps(&Value::Dict(ours))
    );
    assert_eq!(
        json::dumps(&Value::Dict(reopened.list(1).unwrap())),
        json::dumps(&Value::Dict(listed))
    );
}
