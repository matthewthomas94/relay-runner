//! The loopback HTTP/1.0 server: `BoundedThreadingHTTPServer` with
//! `BaseHTTPRequestHandler`'s framing.
//!
//! One thread per connection, at most [`MAX_REQUEST_THREADS`] at once; a
//! connection beyond that gets the fixed 503 Python writes before any thread
//! starts. The five program routes share [`MAX_PROGRAM_REQUEST_THREADS`] of
//! those slots. Each connection carries one request: Python's handler speaks
//! HTTP/1.0 and closes after every response.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::os::fd::AsRawFd;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use relay_intents::json::{self, Value};

use crate::request::Request;

pub const SERVER_VERSION: &str = "RelayOrchestrator/0.1";
pub const MAX_REQUEST_THREADS: usize = 32;
pub const MAX_PROGRAM_REQUEST_THREADS: usize = 8;
/// The paths that take a program slot, compared with `urlparse(path).path`.
pub const PROGRAM_PATHS: [&str; 5] = [
    "/v1/program/status",
    "/v1/program/dashboard",
    "/v1/ready-sweep",
    "/v1/program/ready-sweep",
    "/v1/queue-drain/reconcile",
];
const OVERLOADED_BODY: &[u8] =
    br#"{"error":"The local workspace service is busy; retry shortly.","retryable":true}"#;
const PROGRAM_BUSY: &str = "Program Workspace is busy refreshing; retry shortly.";
/// Python reads without a timeout; a stuck client still must not hold a slot
/// forever.
const READ_TIMEOUT: Duration = Duration::from_secs(300);
const MAX_LINE: usize = 65_536;
const MAX_HEADERS: usize = 100;

/// What the routes answer: a status and JSON body, or `None` to close the
/// connection without a response (an exception outside the handler's chain).
pub type Handler = dyn Fn(&Request) -> Option<(u16, Value)> + Send + Sync;

/// `_bind_port`: the preferred port on 127.0.0.1, or an ephemeral one when
/// it is taken or `0`.
pub fn bind(preferred: u16) -> io::Result<(TcpListener, u16)> {
    let listener = match TcpListener::bind(("127.0.0.1", preferred)) {
        Ok(listener) => listener,
        Err(_) => TcpListener::bind(("127.0.0.1", 0))?,
    };
    let port = listener.local_addr()?.port();
    Ok((listener, port))
}

struct Slots {
    requests: AtomicUsize,
    programs: AtomicUsize,
}

/// A slot counter taken with `try_acquire` and released on drop.
struct Slot<'s>(&'s AtomicUsize);

impl<'s> Slot<'s> {
    fn try_acquire(counter: &'s AtomicUsize, limit: usize) -> Option<Self> {
        counter
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < limit).then_some(active + 1)
            })
            .ok()
            .map(|_| Slot(counter))
    }
}

impl Drop for Slot<'_> {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

/// `serve_forever(poll_interval=0.5)` until `stop` is set.
pub fn serve(listener: TcpListener, handler: Arc<Handler>, stop: &AtomicBool) -> io::Result<()> {
    listener.set_nonblocking(true)?;
    let slots = Arc::new(Slots {
        requests: AtomicUsize::new(0),
        programs: AtomicUsize::new(0),
    });
    while !stop.load(Ordering::Acquire) {
        if !readable(&listener, 500) {
            continue;
        }
        let (stream, peer) = match listener.accept() {
            Ok(accepted) => accepted,
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => continue,
            Err(error) if error.kind() == io::ErrorKind::Interrupted => continue,
            Err(error) => {
                eprintln!("[orchestrator] accept failed: {error}");
                std::thread::sleep(Duration::from_millis(50));
                continue;
            }
        };
        let _ = stream.set_nonblocking(false);
        if slots.requests.load(Ordering::Acquire) >= MAX_REQUEST_THREADS {
            reject_overloaded(stream);
            continue;
        }
        let slots = slots.clone();
        let handler = handler.clone();
        let spawned = std::thread::Builder::new()
            .name("orchestrator-http".into())
            .spawn(move || {
                let Some(_slot) = Slot::try_acquire(&slots.requests, MAX_REQUEST_THREADS) else {
                    reject_overloaded(stream);
                    return;
                };
                handle_connection(stream, peer, handler.as_ref(), &slots.programs);
            });
        if let Err(error) = spawned {
            eprintln!("[orchestrator] could not start a request thread: {error}");
        }
    }
    Ok(())
}

fn readable(listener: &TcpListener, timeout_ms: i32) -> bool {
    let mut descriptor = libc::pollfd {
        fd: listener.as_raw_fd(),
        events: libc::POLLIN,
        revents: 0,
    };
    // SAFETY: one valid pollfd for the duration of the call.
    let ready = unsafe { libc::poll(&mut descriptor, 1, timeout_ms) };
    ready > 0
}

fn reject_overloaded(mut stream: TcpStream) {
    let mut response = format!(
        "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\n\
         Content-Length: {}\r\nConnection: close\r\nRetry-After: 1\r\n\r\n",
        OVERLOADED_BODY.len()
    )
    .into_bytes();
    response.extend_from_slice(OVERLOADED_BODY);
    let _ = stream.set_write_timeout(Some(Duration::from_millis(250)));
    let _ = stream.write_all(&response);
    let _ = stream.shutdown(std::net::Shutdown::Both);
}

struct Head {
    method: String,
    target: String,
    content_length: usize,
    request_line: String,
}

enum HeadError {
    /// The client closed or sent nothing: no answer, as Python.
    Closed,
    /// A malformed request: `send_error(400, ...)`.
    Bad(String),
}

fn read_line(reader: &mut BufReader<TcpStream>) -> Result<String, HeadError> {
    let mut line = Vec::new();
    let read = reader
        .by_ref()
        .take(MAX_LINE as u64 + 1)
        .read_until(b'\n', &mut line)
        .map_err(|_| HeadError::Closed)?;
    if read == 0 {
        return Err(HeadError::Closed);
    }
    if line.len() > MAX_LINE {
        return Err(HeadError::Bad("Line too long".into()));
    }
    Ok(String::from_utf8_lossy(&line).into_owned())
}

fn read_head(reader: &mut BufReader<TcpStream>) -> Result<Head, HeadError> {
    let request_line = read_line(reader)?;
    let request_line = request_line.trim_end_matches(['\r', '\n']).to_string();
    let words: Vec<&str> = request_line.split_whitespace().collect();
    let (method, target, version) = match words.as_slice() {
        [method, target, version] => (*method, *target, *version),
        _ => {
            return Err(HeadError::Bad(format!(
                "Bad request syntax ({})",
                json::str_repr(&request_line)
            )));
        }
    };
    if !version.starts_with("HTTP/") {
        return Err(HeadError::Bad(format!(
            "Bad request version ({})",
            json::str_repr(version)
        )));
    }
    let mut content_length = 0usize;
    for _ in 0..=MAX_HEADERS {
        let line = read_line(reader)?;
        let line = line.trim_end_matches(['\r', '\n']);
        if line.is_empty() {
            return Ok(Head {
                method: method.to_string(),
                target: target.to_string(),
                content_length,
                request_line: request_line.clone(),
            });
        }
        if let Some((name, value)) = line.split_once(':')
            && name.trim().eq_ignore_ascii_case("content-length")
        {
            // `int(headers.get("Content-Length", "0") or "0")`; a negative
            // length reads nothing.
            content_length = json::py_int_from_str(value.trim())
                .map_or(0, |length| usize::try_from(length).unwrap_or(0));
        }
    }
    Err(HeadError::Bad("Too many headers".into()))
}

fn handle_connection(
    stream: TcpStream,
    peer: SocketAddr,
    handler: &Handler,
    programs: &AtomicUsize,
) {
    let _ = stream.set_read_timeout(Some(READ_TIMEOUT));
    let Ok(writer) = stream.try_clone() else {
        return;
    };
    let mut reader = BufReader::new(stream);
    let head = match read_head(&mut reader) {
        Ok(head) => head,
        Err(HeadError::Closed) => return,
        Err(HeadError::Bad(message)) => {
            write_error(writer, 400, &message, peer, "-");
            return;
        }
    };
    if head.method != "GET" && head.method != "POST" {
        let message = format!("Unsupported method ({})", json::str_repr(&head.method));
        write_error(writer, 501, &message, peer, &head.request_line);
        return;
    }
    let mut body = vec![0u8; head.content_length];
    if head.content_length > 0 && reader.read_exact(&mut body).is_err() {
        return;
    }
    let request = Request::new(&head.method, &head.target, &body);
    let program = PROGRAM_PATHS.contains(&request.path.as_str());
    let slot = if program {
        match Slot::try_acquire(programs, MAX_PROGRAM_REQUEST_THREADS) {
            Some(slot) => Some(slot),
            None => {
                let mut busy = json::Dict::new();
                busy.insert("error", PROGRAM_BUSY);
                busy.insert("retryable", true);
                write_json(writer, 503, &Value::Dict(busy), peer, &head);
                return;
            }
        }
    } else {
        None
    };
    let answer = handler(&request);
    drop(slot);
    if let Some((status, payload)) = answer {
        write_json(writer, status, &payload, peer, &head);
    } else {
        eprintln!(
            "[orchestrator-http] {} request {:?} failed outside the route handler; closing",
            peer.ip(),
            head.request_line
        );
    }
}

fn reason(status: u16) -> &'static str {
    match status {
        200 => "OK",
        201 => "Created",
        202 => "Accepted",
        400 => "Bad Request",
        404 => "Not Found",
        409 => "Conflict",
        422 => "Unprocessable Content",
        500 => "Internal Server Error",
        501 => "Not Implemented",
        503 => "Service Unavailable",
        _ => "",
    }
}

fn log_request(peer: SocketAddr, request_line: &str, status: u16) {
    eprintln!(
        "[orchestrator-http] {} \"{}\" {} -",
        peer.ip(),
        request_line,
        status
    );
}

fn write_json(mut stream: TcpStream, status: u16, payload: &Value, peer: SocketAddr, head: &Head) {
    let body = json::dumps(payload).into_bytes();
    log_request(peer, &head.request_line, status);
    let mut response = format!(
        "HTTP/1.0 {status} {}\r\nServer: {SERVER_VERSION}\r\nDate: {}\r\n\
         Content-Type: application/json\r\nContent-Length: {}\r\n\r\n",
        reason(status),
        http_date(SystemTime::now()),
        body.len()
    )
    .into_bytes();
    response.extend_from_slice(&body);
    // A client that timed out may have closed already; Python suppresses the
    // write error too.
    let _ = stream.write_all(&response);
    let _ = stream.flush();
    let _ = stream.shutdown(std::net::Shutdown::Write);
}

fn explanation(status: u16) -> &'static str {
    match status {
        400 => "Bad request syntax or unsupported method.",
        501 => "Server does not support this operation.",
        _ => "",
    }
}

/// `send_error(status, message)`: Python's HTML error page.
fn write_error(mut stream: TcpStream, status: u16, message: &str, peer: SocketAddr, line: &str) {
    log_request(peer, line, status);
    let escape = |text: &str| {
        text.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
    };
    let body = format!(
        "<!DOCTYPE HTML>\n<html lang=\"en\">\n    <head>\n        <meta charset=\"utf-8\">\n        \
         <title>Error response</title>\n    </head>\n    <body>\n        <h1>Error response</h1>\n        \
         <p>Error code: {status}</p>\n        <p>Message: {}.</p>\n        \
         <p>Error code explanation: {status} - {}</p>\n    </body>\n</html>\n",
        escape(message),
        explanation(status)
    );
    let response = format!(
        "HTTP/1.0 {status} {}\r\nServer: {SERVER_VERSION}\r\nDate: {}\r\nConnection: close\r\n\
         Content-Type: text/html;charset=utf-8\r\nContent-Length: {}\r\n\r\n{body}",
        reason(status),
        http_date(SystemTime::now()),
        body.len()
    );
    let _ = stream.write_all(response.as_bytes());
    let _ = stream.shutdown(std::net::Shutdown::Write);
}

/// RFC 7231 `Date`, as `email.utils.formatdate(usegmt=True)`.
pub fn http_date(now: SystemTime) -> String {
    let seconds = now
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| elapsed.as_secs() as i64);
    let days = seconds.div_euclid(86_400);
    let rest = seconds.rem_euclid(86_400);
    // Howard Hinnant's civil-from-days.
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    const WEEKDAYS: [&str; 7] = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"];
    const MONTHS: [&str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    format!(
        "{}, {:02} {} {} {:02}:{:02}:{:02} GMT",
        WEEKDAYS[days.rem_euclid(7) as usize],
        day,
        MONTHS[(month - 1) as usize],
        year,
        rest / 3600,
        rest % 3600 / 60,
        rest % 60
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates_are_rfc_7231() {
        let at = UNIX_EPOCH + Duration::from_secs(1_786_000_000);
        assert_eq!(http_date(at), "Thu, 06 Aug 2026 09:46:40 GMT");
        assert_eq!(http_date(UNIX_EPOCH), "Thu, 01 Jan 1970 00:00:00 GMT");
    }

    #[test]
    fn slots_refuse_past_their_limit() {
        let counter = AtomicUsize::new(0);
        let first = Slot::try_acquire(&counter, 1);
        assert!(first.is_some());
        assert!(Slot::try_acquire(&counter, 1).is_none());
        drop(first);
        assert!(Slot::try_acquire(&counter, 1).is_some());
    }
}
