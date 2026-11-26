//! Ticket history chat (RR-550): `answer` over a fake archive with a fake
//! provider, for the whole history and for one ticket, and the guarantee
//! that a chat only ever reads the archive offline.

use std::sync::Mutex;
use std::sync::atomic::AtomicBool;

use relay_artifacts::instant::Instant;
use relay_artifacts::retention::{
    HistoricalCard, HistoricalDetail, HistoryAccess, HistoryAvailability, RetentionState,
};
use relay_intents::json::{self, Dict, Value};
use relay_services::history_chat::{self, TicketArchive};
use relay_services::notes::chat::Chat;

/// Records every prompt and answers a fixed reply.
#[derive(Default)]
struct FakeChat {
    prompts: Mutex<Vec<String>>,
}

impl Chat for FakeChat {
    fn chat(&self, prompt: &str, _cancel: &AtomicBool) -> relay_services::Result<String> {
        self.prompts.lock().unwrap().push(prompt.to_string());
        Ok("From the history: RR-2 fixed it.".into())
    }
}

/// An archived ticket: its Markdown, and whether that text is only online.
struct Entry {
    card: HistoricalCard,
    markdown: String,
    online_only: bool,
}

/// An archive that hands out an online-only ticket's text only to an online
/// read, as the real one does after deepening, and records every read.
#[derive(Default)]
struct FakeArchive {
    entries: Vec<Entry>,
    online_reads: Mutex<Vec<String>>,
    offline_reads: Mutex<Vec<String>>,
}

impl FakeArchive {
    fn with(mut self, ticket_id: &str, at: &str, title: &str, markdown: &str) -> Self {
        self.entries.push(Entry {
            card: card(ticket_id, at, title),
            markdown: markdown.into(),
            online_only: false,
        });
        self
    }

    fn with_online(mut self, ticket_id: &str, at: &str, title: &str, markdown: &str) -> Self {
        self.entries.push(Entry {
            card: card(ticket_id, at, title),
            markdown: markdown.into(),
            online_only: true,
        });
        self
    }
}

fn card(ticket_id: &str, at: &str, title: &str) -> HistoricalCard {
    HistoricalCard {
        artifact_id: format!("ticket-{ticket_id}"),
        ticket_id: ticket_id.into(),
        title: title.into(),
        status: "done".into(),
        activity_at: Instant::fromisoformat_z(at).unwrap().unwrap(),
        state: RetentionState::Archived,
        attachment_count: 0,
        attachment_bytes: 0,
    }
}

impl TicketArchive for FakeArchive {
    fn cards(&self) -> relay_services::Result<Vec<HistoricalCard>> {
        Ok(self
            .entries
            .iter()
            .map(|entry| entry.card.clone())
            .collect())
    }

    fn detail(
        &self,
        artifact_id: &str,
        access: HistoryAccess<'_>,
    ) -> relay_services::Result<HistoricalDetail> {
        let online = access.online || access.deepen.is_some();
        if online {
            self.online_reads.lock().unwrap().push(artifact_id.into());
        } else {
            self.offline_reads.lock().unwrap().push(artifact_id.into());
        }
        let Some(entry) = self
            .entries
            .iter()
            .find(|entry| entry.card.artifact_id == artifact_id)
        else {
            return Ok(HistoricalDetail {
                availability: HistoryAvailability::NotFound,
                card: None,
                ticket_bytes: None,
                attachments: Vec::new(),
                recovery: None,
            });
        };
        let available = online || !entry.online_only;
        Ok(HistoricalDetail {
            availability: if available {
                HistoryAvailability::Available
            } else {
                HistoryAvailability::NeedsNetwork
            },
            card: Some(entry.card.clone()),
            ticket_bytes: available.then(|| entry.markdown.clone().into_bytes()),
            attachments: Vec::new(),
            recovery: (!available).then(|| "Connect and explicitly deepen.".to_string()),
        })
    }
}

fn body(artifact_id: Option<&str>, messages: &[(&str, &str)]) -> Dict {
    let mut body = Dict::new();
    body.insert("request_id", "chat-1");
    if let Some(artifact_id) = artifact_id {
        body.insert("artifact_id", artifact_id);
    }
    body.insert(
        "messages",
        Value::List(
            messages
                .iter()
                .map(|(role, text)| {
                    let mut message = Dict::new();
                    message.insert("role", *role);
                    message.insert("text", *text);
                    Value::Dict(message)
                })
                .collect(),
        ),
    );
    body
}

fn ids(result: &Dict) -> Vec<String> {
    result
        .get("artifact_ids")
        .and_then(Value::as_list)
        .unwrap()
        .iter()
        .map(Value::py_str)
        .collect()
}

fn sent(fake: &FakeChat) -> Dict {
    let prompts = fake.prompts.lock().unwrap();
    assert_eq!(prompts.len(), 1);
    json::parse(&prompts[0])
        .and_then(|value| value.as_dict().cloned())
        .expect("a JSON prompt")
}

fn tickets(prompt: &Dict) -> Vec<Dict> {
    prompt
        .get("tickets")
        .and_then(Value::as_list)
        .unwrap()
        .iter()
        .map(|ticket| ticket.as_dict().unwrap().clone())
        .collect()
}

fn archive() -> FakeArchive {
    FakeArchive::default()
        .with(
            "RR-1",
            "2026-11-01T09:00:00Z",
            "Offsite planning",
            "---\nid: RR-1\n---\n\nWe picked a venue in Lisbon.\n",
        )
        .with(
            "RR-3",
            "2026-11-20T09:00:00Z",
            "Pricing page",
            "---\nid: RR-3\n---\n\nAlice shipped the pricing tiers.\n",
        )
        .with(
            "RR-2",
            "2026-11-10T09:00:00Z",
            "Login redirect bug",
            "---\nid: RR-2\n---\n\nBob fixed the login redirect loop.\n",
        )
}

#[test]
fn a_history_chat_lists_every_ticket_and_the_matching_markdown() {
    let archive = archive();
    let fake = FakeChat::default();
    let result = history_chat::answer(
        &archive,
        &fake,
        &body(None, &[("user", "Who fixed the login redirect loop?")]),
    )
    .unwrap();
    assert_eq!(result.string("reply"), "From the history: RR-2 fixed it.");
    assert_eq!(ids(&result), ["ticket-RR-2"]);
    let prompt = sent(&fake);
    assert_eq!(prompt.string("scope"), "history");
    assert_eq!(
        prompt.string("question"),
        "Who fixed the login redirect loop?"
    );
    let listed = tickets(&prompt);
    // Every ticket's id, title, status and date, newest first.
    let listed_ids: Vec<String> = listed.iter().map(|t| t.string("ticket_id")).collect();
    assert_eq!(listed_ids, ["RR-3", "RR-2", "RR-1"]);
    assert_eq!(listed[1].string("title"), "Login redirect bug");
    assert_eq!(listed[1].string("status"), "done");
    assert_eq!(listed[1].string("date"), "2026-11-10");
    // Only the best match carries its Markdown.
    assert!(listed[0].get("markdown").is_none());
    assert!(
        listed[1]
            .string("markdown")
            .contains("Bob fixed the login redirect loop.")
    );
    assert!(listed[2].get("markdown").is_none());
    assert!(
        listed
            .iter()
            .all(|t| t.get("markdown_available").unwrap().truthy())
    );
}

#[test]
fn a_ticket_chat_answers_from_that_ticket() {
    let archive = archive();
    let fake = FakeChat::default();
    let result = history_chat::answer(
        &archive,
        &fake,
        &body(
            Some("ticket-RR-3"),
            &[
                ("user", "Who shipped it?"),
                ("assistant", "Alice."),
                ("user", "What exactly?"),
            ],
        ),
    )
    .unwrap();
    assert_eq!(ids(&result), ["ticket-RR-3"]);
    let prompt = sent(&fake);
    assert_eq!(prompt.string("scope"), "ticket");
    let listed = tickets(&prompt);
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].string("ticket_id"), "RR-3");
    assert_eq!(
        listed[0].string("markdown"),
        "---\nid: RR-3\n---\n\nAlice shipped the pricing tiers.\n"
    );
    assert!(!listed[0].get("markdown_cut").unwrap().truthy());
    let conversation = prompt.get("conversation").and_then(Value::as_list).unwrap();
    assert_eq!(conversation.len(), 2);
    assert_eq!(prompt.string("question"), "What exactly?");
    // The single-ticket chat reads only that ticket.
    assert_eq!(*archive.offline_reads.lock().unwrap(), ["ticket-RR-3"]);
}

#[test]
fn a_ticket_named_by_id_is_the_best_match() {
    let archive = archive();
    let fake = FakeChat::default();
    let result = history_chat::answer(
        &archive,
        &fake,
        &body(None, &[("user", "What did rr-1 do?")]),
    )
    .unwrap();
    assert_eq!(ids(&result), ["ticket-RR-1"]);
}

#[test]
fn the_chat_never_reads_the_archive_online() {
    let archive = archive().with_online(
        "RR-9",
        "2026-11-25T09:00:00Z",
        "Login redirect follow-up",
        "Secret online-only text about the login redirect.",
    );
    // Asking for an online read or a GitHub exposure confirmation changes
    // nothing: the chat route has no such option.
    let mut asking_online = body(None, &[("user", "Who fixed the login redirect?")]);
    asking_online.insert("online", true);
    asking_online.insert("confirm_github_exposure", true);
    let fake = FakeChat::default();
    let result = history_chat::answer(&archive, &fake, &asking_online).unwrap();
    assert!(archive.online_reads.lock().unwrap().is_empty());
    assert_eq!(archive.offline_reads.lock().unwrap().len(), 4);
    // The online-only ticket is listed by title and marked; its text is not
    // in the prompt and it is not among the tickets answered from.
    assert_eq!(ids(&result), ["ticket-RR-2"]);
    let prompt = sent(&fake);
    let listed = tickets(&prompt);
    assert_eq!(listed[0].string("ticket_id"), "RR-9");
    assert_eq!(listed[0].string("title"), "Login redirect follow-up");
    assert!(!listed[0].get("markdown_available").unwrap().truthy());
    assert_eq!(listed[0].string("availability"), "needs_network");
    assert!(listed[0].get("markdown").is_none());
    assert!(!fake.prompts.lock().unwrap()[0].contains("Secret online-only text"));
    assert!(history_chat::SYSTEM_PROMPT.contains("only in\nthe project's GitHub archive"));

    // A chat about that one ticket also stays offline.
    let fake = FakeChat::default();
    let result = history_chat::answer(
        &archive,
        &fake,
        &body(Some("ticket-RR-9"), &[("user", "What happened here?")]),
    )
    .unwrap();
    assert!(archive.online_reads.lock().unwrap().is_empty());
    assert!(ids(&result).is_empty());
    let listed = tickets(&sent(&fake));
    assert_eq!(listed[0].string("availability"), "needs_network");
    assert!(listed[0].get("markdown").is_none());
}

#[test]
fn history_markdown_stops_at_the_budget() {
    let big = "budget ".repeat(history_chat::HISTORY_MARKDOWN_BUDGET / 7 - 10);
    let archive = FakeArchive::default()
        .with(
            "RR-3",
            "2026-11-03T00:00:00Z",
            "A",
            &format!("budget words {big}"),
        )
        .with(
            "RR-2",
            "2026-11-02T00:00:00Z",
            "B",
            &format!("budget words {big}"),
        )
        .with("RR-1", "2026-11-01T00:00:00Z", "C", "budget small");
    let fake = FakeChat::default();
    let result =
        history_chat::answer(&archive, &fake, &body(None, &[("user", "budget words")])).unwrap();
    // The best (and newest) match fits; the second does not and is skipped;
    // the small one still fits.
    assert_eq!(ids(&result), ["ticket-RR-3", "ticket-RR-1"]);
    let listed = tickets(&sent(&fake));
    assert!(listed[1].get("markdown").is_none());
    let total: usize = listed
        .iter()
        .map(|ticket| ticket.string("markdown").chars().count())
        .sum();
    assert!(total <= history_chat::HISTORY_MARKDOWN_BUDGET);
}

#[test]
fn malformed_bodies_and_unknown_tickets_are_refused() {
    let archive = archive();
    let fake = FakeChat::default();
    let mut no_request = body(None, &[("user", "q")]);
    no_request.insert("request_id", "  ");
    let mut bad_ticket = body(None, &[("user", "q")]);
    bad_ticket.insert("artifact_id", 7);
    let refused = |body: &Dict| history_chat::answer(&archive, &fake, body).unwrap_err();
    assert_eq!(refused(&no_request).class, "ValueError");
    assert_eq!(refused(&bad_ticket).class, "ValueError");
    assert_eq!(
        refused(&body(None, &[("assistant", "a")])).class,
        "ValueError"
    );
    assert_eq!(
        refused(&body(Some("ticket-RR-404"), &[("user", "q")])).class,
        "ArtifactValidationError"
    );
    assert!(fake.prompts.lock().unwrap().is_empty());
}
