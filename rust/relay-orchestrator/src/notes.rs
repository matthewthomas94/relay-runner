//! The notes routes (`artifact_note_*`).

use crate::daemon::Daemon;
use crate::failure::{Failure, Outcome};
use crate::request::Request;
use crate::router::Reply;

impl Daemon {
    pub fn artifact_note_list(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_note_list"))
    }

    pub fn artifact_note_get(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_note_get"))
    }

    pub fn artifact_note_create(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_note_create"))
    }

    pub fn artifact_note_update(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_note_update"))
    }

    pub fn artifact_note_metadata_retry(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime(
            "not ported yet: artifact_note_metadata_retry",
        ))
    }

    pub fn artifact_note_archive(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_note_archive"))
    }

    pub fn artifact_note_delete(&self, _request: &Request) -> Outcome<Reply> {
        Err(Failure::runtime("not ported yet: artifact_note_delete"))
    }
}
