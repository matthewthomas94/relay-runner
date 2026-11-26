//! Relay Remote agent routing (RR-532 seam; RR-534 fills it in).
//!
//! A phone's `utterance` and `control` may name an `agent` slug
//! (docs/specs/relay-remote.md, "Agents"). The codec accepts the field and,
//! until RR-534, the bridge ignores it: every remote item goes to the voice
//! target focused on the Mac, exactly as before the field existed. RR-534
//! carries the slug through `Event::Item` and `RemoteItem`, resolves it here
//! to that agent's live voice target, and tags the agent on the `accepted`,
//! `speech`, `speech_audio`, `speech_control` and `status` frames it sends.

use super::remote_link::RemoteItem;
use super::targets::{self, VoiceTarget};

/// The voice target a Relay Remote item is delivered to: today the focused one.
pub fn voice_target(_item: &RemoteItem) -> Option<VoiceTarget> {
    targets::current_voice_target()
}
