//! Relay Remote inside the bridge: the RR-491 server in-process, its items
//! on the relay loop's ordered stream, its devices' speech sinks on the
//! speech service, and its device events on the app's state socket
//! (`relay_remote.py` `RemoteIngress`, `RemoteItem`, `post_device_event` and
//! `RustRelayRemoteServer._dispatch`).

use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::Instant;

use super::ports::Speech;
use super::settings::settings;
use super::store;
use crate::json::{self, Dict, Value};
use crate::remote::server::{Event, Server};

/// `relay_remote.INPUT_SOURCE`.
pub const INPUT_SOURCE: &str = "relay_remote";

/// `RemoteItem`: one utterance or mapped control token for the relay loop.
#[derive(Clone, Debug)]
pub struct RemoteItem {
    pub text: String,
    pub device_id: String,
    pub client_id: String,
    /// A control has no `on_accepted`.
    pub control: bool,
}

/// `RemoteIngress` and the server it drains.
pub struct RemoteLink {
    read_fd: i32,
    write_fd: i32,
    items: Mutex<VecDeque<RemoteItem>>,
    server: OnceLock<Arc<Server>>,
}

/// `post_device_event`: a `remote_device` event for the app's StateEventBus
/// (RR-454).
fn post_device_event(state: &str, device_id: &str, device_name: &str) {
    let mut event = Dict::new();
    event.insert("source", "remote_device");
    event.insert("state", state);
    event.insert("device_id", device_id);
    event.insert("device_name", device_name);
    store::send_state_datagram(json::dumps(&Value::Dict(event)).as_bytes());
}

fn set_nonblocking(fd: i32) {
    // SAFETY: fcntl on an fd this module owns.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFL);
        libc::fcntl(fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
    }
}

impl RemoteLink {
    /// Starts the server on `RELAY_REMOTE_SOCK`. `None` when the socket is
    /// unavailable; the bridge runs without Relay Remote then.
    pub fn start(speech: Arc<dyn Speech>) -> Option<Arc<Self>> {
        let mut fds = [0i32; 2];
        // SAFETY: pipe writes two fds into the array.
        if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
            eprintln!("[voice_bridge] Relay Remote socket unavailable: {}", std::io::Error::last_os_error());
            return None;
        }
        set_nonblocking(fds[0]);
        set_nonblocking(fds[1]);
        let link = Arc::new(Self {
            read_fd: fds[0],
            write_fd: fds[1],
            items: Mutex::new(VecDeque::new()),
            server: OnceLock::new(),
        });
        let weak: Weak<Self> = Arc::downgrade(&link);
        let started = Instant::now();
        let server = Server::new(
            &PathBuf::from(&settings().remote_sock),
            Arc::new(move |event| {
                if let Some(link) = weak.upgrade() {
                    link.dispatch(event, speech.as_ref());
                }
            }),
            Arc::new(move || started.elapsed().as_secs_f64()),
        );
        if let Err(error) = server.start() {
            eprintln!("[voice_bridge] Relay Remote socket unavailable: {error}");
            server.close();
            link.close_fds();
            return None;
        }
        let _ = link.server.set(server);
        Some(link)
    }

    /// `RustRelayRemoteServer._dispatch`.
    fn dispatch(self: &Arc<Self>, event: Event, speech: &dyn Speech) {
        match event {
            Event::Item {
                text,
                device_id,
                client_id,
                control,
            } => self.put(RemoteItem {
                text,
                device_id,
                client_id,
                control,
            }),
            Event::Device {
                state,
                device_id,
                device_name,
            } => post_device_event(state, &device_id, &device_name),
            Event::AttachSink { device_id } => {
                if let Some(session) = self.server.get().and_then(|server| server.session(&device_id)) {
                    speech.attach_remote_sink(session);
                }
            }
            Event::DetachSink { device_id, reason } => {
                let reason = if reason.is_empty() { "closed".to_string() } else { reason };
                speech.detach_remote_sink(&device_id, &reason);
            }
            Event::AttachMirror { device_id } => {
                if let Some(session) = self.server.get().and_then(|server| server.session(&device_id)) {
                    speech.attach_remote_mirror(session);
                }
            }
            Event::DetachMirror { device_id } => speech.detach_remote_mirror(&device_id),
            Event::Ack { device_id, seq, played } => {
                speech.remote_ack(&device_id, seq, played);
            }
        }
    }

    /// `RemoteIngress.put`: queue the item and wake the relay loop.
    fn put(&self, item: RemoteItem) {
        self.items
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .push_back(item);
        // SAFETY: a one-byte write to this link's own pipe; a full pipe
        // already holds a pending wake byte.
        unsafe { libc::write(self.write_fd, [0u8].as_ptr().cast(), 1) };
    }

    /// `RemoteIngress.fileno`.
    pub fn fileno(&self) -> i32 {
        self.read_fd
    }

    /// `RemoteIngress.drain`.
    pub fn drain(&self) -> Vec<RemoteItem> {
        let mut buffer = [0u8; 4096];
        // SAFETY: reads from this link's own non-blocking pipe.
        while unsafe { libc::read(self.read_fd, buffer.as_mut_ptr().cast(), buffer.len()) } > 0 {}
        self.items
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
            .drain(..)
            .collect()
    }

    /// `ingress.attached = value`: no loop means no session.
    pub fn set_attached(&self, attached: bool) {
        if let Some(server) = self.server.get() {
            server.set_attached(attached);
        }
    }

    /// `remote_item.on_accepted(relay_command)`: the device learns which
    /// command its utterance became.
    pub fn accept(&self, item: &RemoteItem, relay_command: &Dict) {
        if item.control {
            return;
        }
        let Some((seq, id)) = store::relay_command_key(relay_command) else {
            return;
        };
        if let Some(session) = self.server.get().and_then(|server| server.session(&item.device_id)) {
            session.accept(&item.client_id, seq, &id);
        }
    }

    fn close_fds(&self) {
        for fd in [self.read_fd, self.write_fd] {
            // SAFETY: fds this link owns, closed once.
            unsafe { libc::close(fd) };
        }
    }

    /// `remote_server.close()`.
    pub fn close(&self) {
        if let Some(server) = self.server.get() {
            server.close();
        }
        self.close_fds();
    }
}
