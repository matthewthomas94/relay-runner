//! `verification.*` operations (RR-495).
//!
//! Every answer is `Ok`: a refusal comes back as `{"$error": <class>,
//! "message", "code", "recovery"}`, so the parity test can compare the
//! `code` and `recovery` attributes the driver's ordinary error reply does
//! not carry.

use std::path::{Path, PathBuf};

use relay_artifacts::verification::{
    self, CommandOutput, InstalledBundleIdentity, SignedInstalledAppGate, SourceVerificationHarness,
};
use relay_artifacts::{Error, ErrorKind};
use relay_intents::json::{Dict, Value};

use crate::{Answer, Driver, dict, optional_text, text};

fn refusal(error: Error) -> Value {
    let mut answer = Dict::new();
    answer.insert("$error", error.kind.python_class());
    answer.insert("message", error.message);
    answer.insert("code", error.code.map_or(Value::Null, Value::Str));
    answer.insert("recovery", error.recovery.map_or(Value::Null, Value::Str));
    Value::Dict(answer)
}

/// A canned `codesign` result: `{"returncode", "stdout", "stderr"}`.
fn canned(spec: &Dict) -> CommandOutput {
    CommandOutput {
        returncode: spec
            .get("returncode")
            .and_then(Value::py_int)
            .unwrap_or_default() as i32,
        stdout: spec.string("stdout").into_bytes(),
        stderr: spec.string("stderr").into_bytes(),
    }
}

fn gate(request: &Dict) -> SignedInstalledAppGate {
    let runner = dict(request, "runner");
    if runner.is_empty() {
        return SignedInstalledAppGate::new(None);
    }
    let verify = canned(&dict(&runner, "verify"));
    let details = canned(&dict(&runner, "details"));
    SignedInstalledAppGate::new(Some(Box::new(move |command: &[String]| {
        Ok(if command.iter().any(|argument| argument == "-dv") {
            details.clone()
        } else {
            verify.clone()
        })
    })))
}

fn operation(function: &str, request: &Dict) -> Result<Value, Error> {
    Ok(match function {
        "run" => {
            let mut harness = SourceVerificationHarness::default();
            if let Some(root) = optional_text(request, "source_root") {
                harness.source_root = PathBuf::from(root);
            }
            if let Some(git) = optional_text(request, "git_binary") {
                harness.git_binary = git;
            }
            harness.run()?
        }
        "source_matrix_status" => {
            verification::source_matrix_status(Path::new(&text(request, "root")))?
        }
        "audit_source_matrix" => {
            verification::audit_source_matrix(Path::new(&text(request, "root")))?
        }
        "inspect" => gate(request)
            .inspect(
                &text(request, "app"),
                request
                    .get("require_applications")
                    .is_none_or(Value::truthy),
            )?
            .as_dict(),
        "evaluate" => gate(request).evaluate(
            &InstalledBundleIdentity::from_dict(&dict(request, "identity")),
            &dict(request, "evidence"),
        )?,
        "evidence_template" => SignedInstalledAppGate::evidence_template(
            &InstalledBundleIdentity::from_dict(&dict(request, "identity")),
        ),
        "bundle_digest" => Value::Str(verification::bundle_digest(Path::new(&text(
            request, "app",
        )))?),
        _ => return Err(Error::new(ErrorKind::Type, "unknown operation")),
    })
}

pub(crate) fn handle(_driver: &mut Driver, function: &str, request: &Dict) -> Answer {
    match operation(function, request) {
        Err(error) if error.message == "unknown operation" && error.kind == ErrorKind::Type => {
            Err(error)
        }
        Err(error) => Ok(refusal(error)),
        Ok(value) => Ok(value),
    }
}
