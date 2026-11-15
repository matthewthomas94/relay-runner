//! The Codex model catalogue, as `services/codex_model_catalog.py` resolves
//! it: families, concrete model versions, the app-server's `model/list` and
//! the reasoning efforts each model advertises.

use std::collections::HashMap;
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use relay_intents::json::{self, Dict, Value, py_strip};

use super::process::{Proc, read_json_lines};

pub const CODEX_FAMILIES: [&str; 4] = ["astra", "sol", "terra", "luna"];
pub const CODEX_DEFAULT_FAMILY: &str = "sol";
pub const CODEX_MESSENGER_DEFAULT_FAMILY: &str = "luna";
/// `CODEX_WORKER_TIER_FAMILIES`: the family each shared worker tier runs on.
pub const CODEX_WORKER_TIER_FAMILIES: [(&str, &str); 3] =
    [("fast", "luna"), ("balanced", "sol"), ("strong", "astra")];
/// `CODEX_PROVIDER_DEFAULT_EFFORT`: the effort that means the model's own default.
pub const PROVIDER_DEFAULT_EFFORT: &str = "default";

#[derive(Clone, Debug, PartialEq)]
pub struct CodexModel {
    pub id: String,
    pub model: String,
    pub hidden: bool,
    pub is_default: bool,
    pub default_reasoning_effort: String,
    pub supported_reasoning_efforts: Vec<String>,
    pub input_modalities: Vec<String>,
}

impl CodexModel {
    pub fn launch_model(&self) -> &str {
        if self.model.is_empty() {
            &self.id
        } else {
            &self.model
        }
    }

    fn is_text_compatible(&self) -> bool {
        self.input_modalities.is_empty() || self.input_modalities.iter().any(|m| m == "text")
    }
}

fn is_version(text: &str) -> bool {
    !text.is_empty()
        && text
            .split('.')
            .all(|part| !part.is_empty() && part.bytes().all(|b| b.is_ascii_digit()))
}

fn is_word(text: &str) -> bool {
    !text.is_empty()
        && text
            .bytes()
            .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
}

/// `^gpt-(?P<version>\d+(?:\.\d+)*)(?:-[a-z0-9]+)*-(?P<family>astra|sol|terra|luna)$`
/// as (version, family).
fn family_match(text: &str) -> Option<(&str, &str)> {
    let parts: Vec<&str> = text.strip_prefix("gpt-")?.split('-').collect();
    let (family, rest) = parts.split_last()?;
    let (version, middle) = rest.split_first()?;
    (CODEX_FAMILIES.contains(family) && is_version(version) && middle.iter().all(|p| is_word(p)))
        .then_some((version, family))
}

/// `normalize_codex_family`: anything that names no family, a generic
/// `gpt-<version>` included, takes the default.
pub fn normalize_codex_family(value: &str, default_family: &str) -> String {
    let text = py_strip(value).to_lowercase();
    if CODEX_FAMILIES.contains(&text.as_str()) {
        return text;
    }
    if let Some((_, family)) = family_match(&text) {
        return family.to_string();
    }
    default_family.to_string()
}

/// `codex_family_for_model`.
pub fn codex_family_for_model(value: &str) -> Option<String> {
    let text = py_strip(value).to_lowercase();
    if CODEX_FAMILIES.contains(&text.as_str()) {
        return Some(text);
    }
    family_match(&text).map(|(_, family)| family.to_string())
}

/// `is_codex_family`: a bare family name, not a concrete model id.
pub fn is_codex_family(value: &str) -> bool {
    CODEX_FAMILIES.contains(&py_strip(value).to_lowercase().as_str())
}

fn family_version(value: &str) -> Option<Vec<u64>> {
    let text = py_strip(value).to_lowercase();
    let (version, _) = family_match(&text)?;
    version.split('.').map(|part| part.parse().ok()).collect()
}

fn supported_efforts(raw: Option<&Value>) -> Vec<String> {
    let mut efforts: Vec<String> = Vec::new();
    for item in raw.and_then(Value::as_list).unwrap_or_default() {
        let value = match item {
            Value::Dict(dict) => dict
                .truthy("reasoningEffort")
                .or_else(|| dict.truthy("value"))
                .or_else(|| dict.truthy("id"))
                .cloned()
                .unwrap_or(Value::Null),
            other => other.clone(),
        };
        let text = if value.truthy() {
            py_strip(&value.py_str()).to_lowercase()
        } else {
            String::new()
        };
        if !text.is_empty() && !efforts.contains(&text) {
            efforts.push(text);
        }
    }
    efforts
}

/// `codex_models_from_model_list`.
pub fn models_from_model_list(payload: &Value) -> Vec<CodexModel> {
    let empty = Vec::new();
    let raw_models: &[Value] = match payload {
        Value::List(items) => items,
        Value::Dict(dict) => ["data", "models", "items"]
            .iter()
            .find_map(|key| dict.truthy(key))
            .or_else(|| {
                dict.get("result")
                    .and_then(Value::as_dict)
                    .and_then(|r| r.truthy("data"))
            })
            .and_then(Value::as_list)
            .unwrap_or(&empty),
        _ => &empty,
    };
    let lower = |dict: &Dict, first: &str, second: &str| {
        dict.truthy(first)
            .or_else(|| dict.truthy(second))
            .map(|value| py_strip(&value.py_str()).to_lowercase())
            .unwrap_or_default()
    };
    let mut models = Vec::new();
    for raw in raw_models {
        let Some(raw) = raw.as_dict() else { continue };
        let model_id = lower(raw, "id", "model");
        let concrete = lower(raw, "model", "id");
        if model_id.is_empty() && concrete.is_empty() {
            continue;
        }
        let efforts = supported_efforts(raw.get("supportedReasoningEfforts"));
        let mut default_effort = raw.text("defaultReasoningEffort").to_lowercase();
        if default_effort.is_empty() {
            default_effort = efforts.first().cloned().unwrap_or_default();
        }
        if default_effort.is_empty() {
            default_effort = PROVIDER_DEFAULT_EFFORT.to_string();
        }
        let input_modalities = raw
            .get("inputModalities")
            .and_then(Value::as_list)
            .unwrap_or_default()
            .iter()
            .filter(|m| m.truthy())
            .map(|m| py_strip(&m.py_str()).to_lowercase())
            .filter(|m| !m.is_empty())
            .collect();
        models.push(CodexModel {
            id: if model_id.is_empty() {
                concrete.clone()
            } else {
                model_id.clone()
            },
            model: if concrete.is_empty() {
                model_id
            } else {
                concrete
            },
            hidden: raw.get("hidden").is_some_and(Value::truthy),
            is_default: raw.get("isDefault").is_some_and(Value::truthy),
            default_reasoning_effort: default_effort,
            supported_reasoning_efforts: efforts,
            input_modalities,
        });
    }
    models
}

/// `resolve_codex_family`: the newest visible, text-capable model of a family.
pub fn resolve_family(family: &str, models: &[CodexModel]) -> Result<CodexModel, String> {
    let family = normalize_codex_family(family, CODEX_DEFAULT_FAMILY);
    let mut best: Option<(&CodexModel, Vec<u64>)> = None;
    for model in models {
        if model.hidden
            || !model.is_text_compatible()
            || codex_family_for_model(model.launch_model()).as_deref() != Some(family.as_str())
        {
            continue;
        }
        let Some(version) = family_version(model.launch_model()) else {
            continue;
        };
        if best.as_ref().is_none_or(|(_, current)| version > *current) {
            best = Some((model, version));
        }
    }
    best.map(|(model, _)| model.clone()).ok_or_else(|| {
        format!("Codex model family '{family}' is unavailable in the provider catalogue")
    })
}

/// `resolve_codex_effort`.
pub fn resolve_effort(effort: &str, model: &CodexModel) -> Result<String, String> {
    let value = py_strip(effort).to_lowercase();
    if value.is_empty() || value == PROVIDER_DEFAULT_EFFORT {
        return Ok(model.default_reasoning_effort.clone());
    }
    if model.supported_reasoning_efforts.contains(&value) {
        return Ok(value);
    }
    Err(format!(
        "Codex model {} does not advertise reasoning effort '{value}'; supported efforts: {}",
        model.launch_model(),
        model.supported_reasoning_efforts.join(", ")
    ))
}

/// `fetch_codex_models_from_cli`: `model/list` from a short-lived
/// `codex app-server`, or the `RELAY_CODEX_MODEL_LIST_JSON` fixture.
pub fn fetch_models(prefix: &[String], timeout: Duration) -> Result<Vec<CodexModel>, String> {
    fetch_models_with_hidden(prefix, timeout, false)
}

/// `fetch_codex_models_from_cli(include_hidden=...)`: `fetch_models`, also
/// asking the app-server for hidden models when `include_hidden` is set.
pub fn fetch_models_with_hidden(
    prefix: &[String],
    timeout: Duration,
    include_hidden: bool,
) -> Result<Vec<CodexModel>, String> {
    if let Some(fixture) = std::env::var("RELAY_CODEX_MODEL_LIST_JSON")
        .ok()
        .filter(|f| !f.is_empty())
    {
        let payload = json::parse(&fixture).ok_or("RELAY_CODEX_MODEL_LIST_JSON is not JSON")?;
        return Ok(models_from_model_list(&payload));
    }
    let mut command = Command::new(&prefix[0]);
    command
        .args(&prefix[1..])
        .args(["app-server", "--stdio", "-c", "mcp_servers={}"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let (proc, stdout) =
        Proc::spawn(&mut command).map_err(|e| format!("could not start Codex app-server: {e}"))?;
    let responses: Arc<(Mutex<HashMap<i64, Dict>>, Condvar)> = Arc::default();
    let sink = Arc::clone(&responses);
    thread::spawn(move || {
        read_json_lines(stdout, |message| {
            if let Some(Value::Int(id)) = message.get("id") {
                let (lock, changed) = &*sink;
                lock.lock().unwrap().insert(*id, message.clone());
                changed.notify_all();
            }
            true
        });
    });
    let result = list_models(&proc, &responses, timeout, include_hidden);
    proc.stop();
    result
}

fn list_models(
    proc: &Proc,
    responses: &(Mutex<HashMap<i64, Dict>>, Condvar),
    timeout: Duration,
    include_hidden: bool,
) -> Result<Vec<CodexModel>, String> {
    let write = |payload: Dict| {
        if !proc.is_running() {
            return Err("Codex app-server is not writable".to_string());
        }
        proc.write_line(&json::dumps_compact(&Value::Dict(payload)))
            .map_err(|e| format!("could not write to Codex app-server: {e}"))
    };
    let wait = |request_id: i64, timeout: Duration| -> Result<Dict, String> {
        let deadline = Instant::now() + timeout;
        let (lock, changed) = responses;
        let mut guard = lock.lock().unwrap();
        loop {
            if let Some(response) = guard.remove(&request_id) {
                if let Some(error) = response.get("error") {
                    return Err(format!(
                        "Codex app-server request {request_id} failed: {}",
                        error_message(error)
                    ));
                }
                return Ok(response);
            }
            let now = Instant::now();
            if now >= deadline {
                return Err(format!("Codex app-server request {request_id} timed out"));
            }
            guard = changed.wait_timeout(guard, deadline - now).unwrap().0;
        }
    };
    let mut client_info = Dict::new();
    client_info.insert("name", "relay-runner-model-resolver");
    client_info.insert("title", "Relay Runner Model Resolver");
    client_info.insert("version", "1");
    let mut capabilities = Dict::new();
    capabilities.insert("experimentalApi", true);
    let mut params = Dict::new();
    params.insert("clientInfo", client_info);
    params.insert("capabilities", capabilities);
    write(request(Some(1), "initialize", params))?;
    wait(1, timeout.min(Duration::from_secs(5)))?;
    write(request(None, "initialized", Dict::new()))?;

    let mut models = Vec::new();
    let mut cursor = Value::Null;
    let mut request_id = 2;
    let deadline = Instant::now() + timeout;
    loop {
        let mut params = Dict::new();
        params.insert("cursor", cursor);
        params.insert("includeHidden", include_hidden);
        params.insert("limit", 100_i64);
        write(request(Some(request_id), "model/list", params))?;
        let remaining = deadline
            .saturating_duration_since(Instant::now())
            .max(Duration::from_millis(100));
        let response = wait(request_id, remaining)?;
        let result = response
            .truthy("result")
            .cloned()
            .unwrap_or(Value::Dict(Dict::new()));
        models.extend(models_from_model_list(&result));
        cursor = result
            .as_dict()
            .and_then(|r| r.get("nextCursor"))
            .cloned()
            .unwrap_or(Value::Null);
        if !cursor.truthy() {
            return Ok(models);
        }
        request_id += 1;
    }
}

/// A JSON-RPC message in the order `json.dumps` wrote Python's literals.
pub fn request(id: Option<i64>, method: &str, params: Dict) -> Dict {
    let mut message = Dict::new();
    message.insert("jsonrpc", "2.0");
    if let Some(id) = id {
        message.insert("id", id);
    }
    message.insert("method", method);
    message.insert("params", params);
    message
}

/// `response.get("error", {}).get("message") or response["error"]`.
pub fn error_message(error: &Value) -> String {
    error
        .as_dict()
        .and_then(|e| e.truthy("message"))
        .unwrap_or(error)
        .py_str()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn models() -> Vec<CodexModel> {
        models_from_model_list(&json::parse(r#"{"data": [
            {"id": "gpt-6-sol", "model": "gpt-6-sol", "isDefault": true,
             "supportedReasoningEfforts": [{"reasoningEffort": "low"}, {"reasoningEffort": "High"}, "low"],
             "defaultReasoningEffort": "medium"},
            {"id": "gpt-6-luna", "supportedReasoningEfforts": ["low", "medium"]},
            {"id": "gpt-6.1-luna", "inputModalities": ["image"]},
            {"id": "gpt-5.9-luna", "supportedReasoningEfforts": []},
            {"id": "gpt-7-luna", "hidden": true},
            {"model": "gpt-6-terra"},
            {"id": ""}
        ], "nextCursor": null}"#).unwrap())
    }

    #[test]
    fn the_daemons_family_names() {
        assert!(is_codex_family(" Astra "));
        assert!(!is_codex_family("gpt-6-astra"));
        assert_eq!(
            CODEX_WORKER_TIER_FAMILIES.map(|(_, family)| family),
            ["luna", "sol", "astra"]
        );
    }

    #[test]
    fn families_and_versions_parse_like_the_python_patterns() {
        assert_eq!(normalize_codex_family(" SOL ", "luna"), "sol");
        assert_eq!(
            normalize_codex_family("gpt-6.2-codex-mini-astra", "luna"),
            "astra"
        );
        assert_eq!(normalize_codex_family("gpt-6", "luna"), "luna");
        assert_eq!(normalize_codex_family("", "sol"), "sol");
        assert_eq!(
            codex_family_for_model("gpt-6-Luna").as_deref(),
            Some("luna")
        );
        assert_eq!(codex_family_for_model("gpt-6--luna"), None);
        assert_eq!(codex_family_for_model("gpt-x-luna"), None);
        assert_eq!(codex_family_for_model("gpt-6.-luna"), None);
        assert_eq!(family_version("gpt-6.10-luna"), Some(vec![6, 10]));
    }

    #[test]
    fn the_model_list_reads_like_python() {
        let models = models();
        assert_eq!(models.len(), 6);
        assert_eq!(models[0].supported_reasoning_efforts, vec!["low", "high"]);
        assert_eq!(models[0].default_reasoning_effort, "medium");
        assert!(models[0].is_default);
        assert_eq!(models[1].model, "gpt-6-luna");
        assert_eq!(models[1].default_reasoning_effort, "low");
        assert_eq!(models[3].default_reasoning_effort, "default");
        assert_eq!(models[5].id, "gpt-6-terra");
    }

    #[test]
    fn resolution_picks_the_newest_visible_text_model() {
        let models = models();
        let luna = resolve_family("luna", &models).unwrap();
        assert_eq!(luna.launch_model(), "gpt-6-luna");
        assert_eq!(resolve_effort("default", &luna).unwrap(), "low");
        assert_eq!(resolve_effort("MEDIUM", &luna).unwrap(), "medium");
        assert_eq!(
            resolve_effort("xhigh", &luna).unwrap_err(),
            "Codex model gpt-6-luna does not advertise reasoning effort 'xhigh'; supported efforts: low, medium"
        );
        assert_eq!(
            resolve_family("astra", &models).unwrap_err(),
            "Codex model family 'astra' is unavailable in the provider catalogue"
        );
    }
}
