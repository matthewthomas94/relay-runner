//! A provider child on pipes, as the Python backends drive `subprocess.Popen`:
//! JSON lines in and out, `poll()`, `terminate()` then `kill()`.

use std::io::{self, BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, ChildStdout, Command};
use std::sync::Mutex;
use std::thread;
use std::time::{Duration, Instant};

use crate::json::{self, Dict, Value};

pub struct Proc {
    child: Mutex<Child>,
    stdin: Mutex<Option<ChildStdin>>,
}

impl Proc {
    /// Starts `command` (with piped stdin and stdout) and hands back its stdout
    /// for a reader thread.
    pub fn spawn(command: &mut Command) -> io::Result<(Self, ChildStdout)> {
        let mut child = command.spawn()?;
        let stdin = child.stdin.take();
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| io::Error::other("no stdout pipe"))?;
        Ok((
            Self {
                child: Mutex::new(child),
                stdin: Mutex::new(stdin),
            },
            stdout,
        ))
    }

    /// `proc.poll() is None`.
    pub fn is_running(&self) -> bool {
        matches!(self.child.lock().unwrap().try_wait(), Ok(None))
    }

    /// Writes one line and flushes it.
    pub fn write_line(&self, line: &str) -> io::Result<()> {
        let mut guard = self.stdin.lock().unwrap();
        let stdin = guard
            .as_mut()
            .ok_or_else(|| io::Error::new(io::ErrorKind::BrokenPipe, "stdin is closed"))?;
        stdin.write_all(line.as_bytes())?;
        stdin.write_all(b"\n")?;
        stdin.flush()
    }

    /// `proc.kill()`, reaping the child.
    pub fn kill(&self) {
        let mut child = self.child.lock().unwrap();
        if matches!(child.try_wait(), Ok(None)) {
            let _ = child.kill();
        }
        let _ = child.wait();
    }

    /// Closes stdin, then `terminate()`, waits a second and `kill()`s.
    pub fn stop(&self) {
        self.stdin.lock().unwrap().take();
        let pid = {
            let mut child = self.child.lock().unwrap();
            if !matches!(child.try_wait(), Ok(None)) {
                return;
            }
            child.id()
        };
        // SAFETY: plain signal delivery to the child this handle owns; it has
        // not been reaped, so the pid cannot have been reused.
        unsafe {
            libc::kill(pid as libc::pid_t, libc::SIGTERM);
        }
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline {
            if !matches!(self.child.lock().unwrap().try_wait(), Ok(None)) {
                return;
            }
            thread::sleep(Duration::from_millis(10));
        }
        self.kill();
    }
}

impl Drop for Proc {
    fn drop(&mut self) {
        let child = self.child.get_mut().unwrap();
        if matches!(child.try_wait(), Ok(None)) {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}

/// Reads JSON lines until EOF, a read error, text that is not UTF-8 (where
/// Python's text pipe raises) or `handle` returning `false`. Lines that are
/// not JSON objects are skipped.
pub fn read_json_lines(stdout: ChildStdout, mut handle: impl FnMut(&Dict) -> bool) {
    let mut reader = BufReader::new(stdout);
    let mut line = Vec::new();
    loop {
        line.clear();
        match reader.read_until(b'\n', &mut line) {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
        let Ok(text) = std::str::from_utf8(&line) else {
            return;
        };
        if let Some(Value::Dict(message)) = json::parse(text)
            && !handle(&message)
        {
            return;
        }
    }
}
