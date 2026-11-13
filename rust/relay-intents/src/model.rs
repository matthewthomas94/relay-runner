//! The states and identities the inbox and the broker share with the Python
//! modules. Each state is spelt in SQL and JSON exactly as Python spells it.

use crate::json::{Dict, Value};

/// Defines a closed set of wire names: `as_str` writes one, `parse` reads one.
macro_rules! wire_enum {
    ($(#[$meta:meta])* $name:ident { $($(#[$variant_meta:meta])* $variant:ident => $text:literal,)+ }) => {
        $(#[$meta])*
        #[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, PartialOrd, Ord)]
        pub enum $name {
            $($(#[$variant_meta])* $variant,)+
        }

        impl $name {
            pub const ALL: &'static [$name] = &[$($name::$variant,)+];

            pub const fn as_str(self) -> &'static str {
                match self {
                    $($name::$variant => $text,)+
                }
            }

            pub fn parse(text: &str) -> Option<Self> {
                match text {
                    $($text => Some($name::$variant),)+
                    _ => None,
                }
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                formatter.write_str(self.as_str())
            }
        }
    };
}
pub(crate) use wire_enum;

wire_enum! {
    /// Where one intent is in the inbox: `pending → delivered → claimed →
    /// acked`, or `cancelled`; after a restart an uncertain lease is
    /// `review_required` and held work `recovery_pending`.
    IntentState {
        Pending => "pending",
        Delivered => "delivered",
        Claimed => "claimed",
        Acked => "acked",
        Cancelled => "cancelled",
        ReviewRequired => "review_required",
        RecoveryPending => "recovery_pending",
    }
}

wire_enum! {
    /// A provider turn: `active` until exactly one terminal state.
    TurnState {
        Active => "active",
        Cancelled => "cancelled",
        CompletedFinal => "completed_final",
        CompletedManual => "completed_manual",
        Empty => "empty",
        Failed => "failed",
        FailedManual => "failed_manual",
        LegacyObservation => "legacy_observation",
        Orphaned => "orphaned",
        Stale => "stale",
        Terminated => "terminated",
    }
}

impl TurnState {
    /// `TERMINAL_STATES`: everything but `active`.
    pub const fn is_terminal(self) -> bool {
        !matches!(self, TurnState::Active)
    }

    /// `ALLOWED_TRANSITIONS`: only an active turn moves, and only to a
    /// terminal state.
    pub const fn may_become(self, next: TurnState) -> bool {
        matches!(self, TurnState::Active) && next.is_terminal()
    }

    /// `EFFECT_REVOKED_TURN_STATES`: a turn in one of these may not deliver
    /// its reply.
    pub const fn revokes_effects(self) -> bool {
        matches!(
            self,
            TurnState::Cancelled | TurnState::Orphaned | TurnState::Stale | TurnState::Terminated
        )
    }
}

wire_enum! {
    /// A reply effect: reserved once per authority, then authorised against
    /// revocation, then delivered or failed.
    EffectState {
        Reserved => "reserved",
        Authorized => "authorized",
        Delivered => "delivered",
        Failed => "failed",
    }
}

/// `OWNERSHIP_FIELDS`, in identity order.
pub const OWNERSHIP_FIELDS: [&str; 4] = [
    "app_session_id",
    "recovery_generation",
    "actor_role",
    "foreground_gate_handle",
];

/// `FOREGROUND_ACTOR_ROLES`.
pub const FOREGROUND_ACTOR_ROLES: [&str; 2] = ["foreground_pm", "foreground_manual"];

/// The foreground owner a record names: every ownership field set and a
/// foreground actor role. `_ownership` in the broker.
pub fn foreground_ownership(record: &Dict) -> Option<Dict> {
    let mut values = Dict::new();
    for field in OWNERSHIP_FIELDS {
        values.insert(field, record.text(field));
    }
    let role = values.string("actor_role");
    let complete = OWNERSHIP_FIELDS
        .iter()
        .all(|field| values.truthy(field).is_some());
    (FOREGROUND_ACTOR_ROLES.contains(&role.as_str()) && complete).then_some(values)
}

/// One voice command: its sequence number and id. `_key` in the inbox.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CommandKey {
    pub seq: i64,
    pub id: String,
}

impl CommandKey {
    /// `int(relay_command_seq)` and a non-empty stripped `relay_command_id`.
    pub fn of(payload: &Dict) -> Option<Self> {
        let seq = payload.get("relay_command_seq")?.py_int()?;
        let id = payload.text("relay_command_id");
        (!id.is_empty()).then_some(Self { seq, id })
    }

    pub fn of_value(payload: Option<&Value>) -> Option<Self> {
        payload.and_then(Value::as_dict).and_then(Self::of)
    }
}

/// The voice session that owns an intent; `""` for unrouted legacy rows.
pub fn session_key(metadata: &Dict) -> String {
    metadata.text("voice_target_session_key")
}

/// `continuity_incidents.normalize_recovery_generation`: a non-negative
/// integer or 1 to 128 characters of `[A-Za-z0-9._:-]` starting with a letter
/// or digit. `None` where Python raises `ValueError`.
pub fn normalize_recovery_generation(value: &Value) -> Option<String> {
    let text = match value {
        Value::Int(number) if *number >= 0 => number.to_string(),
        Value::BigInt(digits) if !digits.starts_with('-') => digits.clone(),
        Value::Str(text) => text.clone(),
        _ => return None,
    };
    recovery_generation_text(&text).then_some(text)
}

/// Whether `text` is a well-formed recovery generation.
pub fn recovery_generation_text(text: &str) -> bool {
    let mut characters = text.chars();
    let Some(first) = characters.next() else {
        return false;
    };
    first.is_ascii_alphanumeric()
        && text.len() <= 128
        && characters.all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | ':' | '-')
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::json;

    fn dict(text: &str) -> Dict {
        match json::parse(text) {
            Some(Value::Dict(dict)) => dict,
            other => panic!("not an object: {other:?}"),
        }
    }

    #[test]
    fn states_round_trip_their_wire_names() {
        for state in IntentState::ALL {
            assert_eq!(IntentState::parse(state.as_str()), Some(*state));
        }
        for state in TurnState::ALL {
            assert_eq!(TurnState::parse(state.as_str()), Some(*state));
        }
        assert_eq!(IntentState::parse("acknowledged"), None);
        let terminal = TurnState::ALL
            .iter()
            .filter(|state| state.is_terminal())
            .count();
        assert_eq!(terminal, 10);
        assert!(TurnState::Active.may_become(TurnState::Empty));
        assert!(!TurnState::Empty.may_become(TurnState::Failed));
        assert!(!TurnState::Active.may_become(TurnState::Active));
    }

    #[test]
    fn command_keys_follow_python_int_and_strip() {
        let key = |text: &str| CommandKey::of(&dict(text));
        assert_eq!(
            key(r#"{"relay_command_seq": "7", "relay_command_id": " cmd "}"#),
            Some(CommandKey {
                seq: 7,
                id: "cmd".into()
            })
        );
        assert_eq!(
            key(r#"{"relay_command_seq": 7.9, "relay_command_id": "c"}"#).map(|key| key.seq),
            Some(7)
        );
        assert_eq!(
            key(r#"{"relay_command_seq": true, "relay_command_id": "c"}"#).map(|key| key.seq),
            Some(1)
        );
        assert_eq!(
            key(r#"{"relay_command_seq": null, "relay_command_id": "c"}"#),
            None
        );
        assert_eq!(
            key(r#"{"relay_command_seq": 1, "relay_command_id": "  "}"#),
            None
        );
    }

    #[test]
    fn recovery_generations_are_validated_like_continuity_incidents() {
        let normalize = |text: &str| normalize_recovery_generation(&json::parse(text).unwrap());
        assert_eq!(normalize("0"), Some("0".into()));
        assert_eq!(normalize("12"), Some("12".into()));
        assert_eq!(normalize(r#""gen-1:a.b_c""#), Some("gen-1:a.b_c".into()));
        assert_eq!(normalize("-1"), None);
        assert_eq!(normalize("true"), None);
        assert_eq!(normalize("1.5"), None);
        assert_eq!(normalize(r#""-gen""#), None);
        assert_eq!(normalize(r#""gen\n""#), None);
        assert_eq!(normalize(r#""""#), None);
        assert_eq!(
            normalize(&format!("\"{}\"", "a".repeat(128))).map(|g| g.len()),
            Some(128)
        );
        assert_eq!(normalize(&format!("\"{}\"", "a".repeat(129))), None);
    }

    #[test]
    fn ownership_needs_every_field_and_a_foreground_role() {
        let complete = dict(
            r#"{"app_session_id": "a", "recovery_generation": "g", "actor_role": "foreground_pm", "foreground_gate_handle": "h"}"#,
        );
        assert!(foreground_ownership(&complete).is_some());
        let mut bridge = complete.clone();
        bridge.insert("actor_role", "voice_bridge");
        assert!(foreground_ownership(&bridge).is_none());
        let mut missing = complete.clone();
        missing.insert("foreground_gate_handle", " ");
        assert!(foreground_ownership(&missing).is_none());
    }
}
