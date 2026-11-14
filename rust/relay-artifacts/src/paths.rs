//! `pathlib` path normalisation, `Path.expanduser()` and `Path.resolve()`, as
//! Python 3.14 implements them on POSIX (`posixpath.realpath` with
//! `strict=False`). Follow-up batch ids hash the resolved repository path,
//! so both daemons must resolve it to the same text.

use std::collections::HashMap;
use std::ffi::{CStr, CString};

use crate::{Error, ErrorKind, Result};

/// `str(Path(text))`: repeated and trailing separators and `.` components
/// dropped; exactly two leading slashes kept, as POSIX allows.
pub fn normalize(text: &str) -> String {
    let root = if text.starts_with("//") && !text.starts_with("///") {
        "//"
    } else if text.starts_with('/') {
        "/"
    } else {
        ""
    };
    let parts: Vec<&str> = text
        .split('/')
        .filter(|part| !part.is_empty() && *part != ".")
        .collect();
    let joined = format!("{root}{}", parts.join("/"));
    if joined.is_empty() {
        ".".to_string()
    } else {
        joined
    }
}

fn home_of(name: Option<&str>) -> Option<String> {
    // SAFETY: getpwnam/getpwuid return a pointer into static storage that
    // stays valid until the next call; the home directory is copied out at
    // once, and Python's `pwd` module makes the same calls.
    unsafe {
        let entry = match name {
            Some(name) => {
                let name = CString::new(name).ok()?;
                libc::getpwnam(name.as_ptr())
            }
            None => libc::getpwuid(libc::getuid()),
        };
        if entry.is_null() || (*entry).pw_dir.is_null() {
            return None;
        }
        Some(
            CStr::from_ptr((*entry).pw_dir)
                .to_string_lossy()
                .into_owned(),
        )
    }
}

/// `os.path.expanduser(text)`: `None` where Python returns it unchanged.
fn expand_tilde(text: &str) -> Option<String> {
    let end = text[1..].find('/').map_or(text.len(), |index| index + 1);
    let home = if end == 1 {
        match std::env::var("HOME") {
            Ok(home) => home,
            Err(_) => home_of(None)?,
        }
    } else {
        home_of(Some(&text[1..end]))?
    };
    let expanded = format!("{}{}", home.trim_end_matches('/'), &text[end..]);
    Some(if expanded.is_empty() {
        "/".to_string()
    } else {
        expanded
    })
}

/// `str(Path(text).expanduser())`. An unknown user is Python's
/// `RuntimeError("Could not determine home directory.")`.
pub fn expanduser(text: &str) -> Result<String> {
    let normalized = normalize(text);
    if !normalized.starts_with('~') {
        return Ok(normalized);
    }
    let (first, rest) = match normalized.split_once('/') {
        Some((first, rest)) => (first, Some(rest)),
        None => (normalized.as_str(), None),
    };
    let home = expand_tilde(first).filter(|home| !home.starts_with('~'));
    let Some(home) = home else {
        return Err(Error::new(
            ErrorKind::Runtime,
            "Could not determine home directory.",
        ));
    };
    Ok(normalize(&match rest {
        Some(rest) => format!("{home}/{rest}"),
        None => home,
    }))
}

/// `os.path.realpath(text)` without `strict`: symlinks resolved as far as
/// the path exists, `..` applied to the resolved prefix.
pub fn realpath(text: &str) -> String {
    let mut rest: Vec<Option<String>> = text
        .split('/')
        .rev()
        .map(|part| Some(part.to_string()))
        .collect();
    let mut part_count = rest.len();
    let mut path = if text.starts_with('/') {
        "/".to_string()
    } else {
        std::env::current_dir()
            .map(|cwd| cwd.to_string_lossy().into_owned())
            .unwrap_or_else(|_| "/".to_string())
    };
    let mut seen: HashMap<String, Option<String>> = HashMap::new();
    while part_count > 0 {
        let Some(name) = rest.pop().expect("part_count bounds the stack") else {
            let link = rest.pop().flatten().expect("a marker follows its link");
            seen.insert(link, Some(path.clone()));
            continue;
        };
        part_count -= 1;
        if name.is_empty() || name == "." {
            continue;
        }
        if name == ".." {
            let cut = path.rfind('/').unwrap_or(0);
            path.truncate(cut);
            if path.is_empty() {
                path.push('/');
            }
            continue;
        }
        let new_path = if path == "/" {
            format!("/{name}")
        } else {
            format!("{path}/{name}")
        };
        let target = match std::fs::symlink_metadata(&new_path) {
            Ok(metadata) if !metadata.file_type().is_symlink() => {
                path = new_path;
                continue;
            }
            Ok(_) => {
                if let Some(resolved) = seen.get(&new_path) {
                    match resolved {
                        Some(resolved) => path = resolved.clone(),
                        // An unresolved link seen again is a loop.
                        None => path = new_path,
                    }
                    continue;
                }
                match std::fs::read_link(&new_path) {
                    Ok(target) => target.to_string_lossy().into_owned(),
                    Err(_) => {
                        path = new_path;
                        continue;
                    }
                }
            }
            Err(_) => {
                path = new_path;
                continue;
            }
        };
        if target.starts_with('/') {
            path = "/".to_string();
        }
        seen.insert(new_path.clone(), None);
        rest.push(Some(new_path));
        rest.push(None);
        let parts: Vec<Option<String>> = target
            .split('/')
            .rev()
            .map(|part| Some(part.to_string()))
            .collect();
        part_count += parts.len();
        rest.extend(parts);
    }
    path
}

/// `str(Path(text).resolve())`.
pub fn resolve(text: &str) -> String {
    normalize(&realpath(&normalize(text)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalises_like_pathlib() {
        assert_eq!(normalize("a//b/./c/"), "a/b/c");
        assert_eq!(normalize("./a"), "a");
        assert_eq!(normalize(""), ".");
        assert_eq!(normalize("."), ".");
        assert_eq!(normalize("//x/"), "//x");
        assert_eq!(normalize("///x"), "/x");
        assert_eq!(normalize("/a/../b"), "/a/../b");
    }

    #[test]
    fn resolves_links_and_parents() {
        let root = std::env::temp_dir().join(format!("relay-paths-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("real/inner")).unwrap();
        std::os::unix::fs::symlink(root.join("real"), root.join("link")).unwrap();
        std::os::unix::fs::symlink("loop", root.join("loop")).unwrap();
        let base = realpath(&root.to_string_lossy());
        assert_eq!(
            resolve(&format!("{base}/link/inner/..")),
            format!("{base}/real")
        );
        assert_eq!(
            resolve(&format!("{base}/link/missing/x")),
            format!("{base}/real/missing/x")
        );
        assert_eq!(resolve(&format!("{base}/loop/x")), format!("{base}/loop/x"));
        assert_eq!(resolve("/.."), "/");
        std::fs::remove_dir_all(&root).unwrap();
    }

    #[test]
    fn expands_the_home_directory() {
        let home = std::env::var("HOME").unwrap();
        assert_eq!(expanduser("~/x").unwrap(), normalize(&format!("{home}/x")));
        assert_eq!(expanduser("a/~").unwrap(), "a/~");
        assert!(expanduser("~no-such-user-relay/x").is_err());
    }
}
