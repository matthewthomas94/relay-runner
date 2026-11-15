//! The part of Python's `argparse` the ported command-line tools use: long
//! options with `--name value`, `--name=value` and unique prefixes, flags,
//! choices, required options, one mutually exclusive group and optional
//! positionals. Errors print the usage line and `<prog>: error: <message>`
//! to stderr and exit 2; `-h`/`--help` prints the help text and exits 0.

use std::io;
use std::path::Path;

/// `str(OSError)`: `[Errno N] <strerror>`, with the file name when known.
pub fn os_error_text(error: &io::Error, path: Option<&Path>) -> String {
    let Some(code) = error.raw_os_error() else {
        return error.to_string();
    };
    let text = io::Error::from_raw_os_error(code).to_string();
    let strerror = text
        .strip_suffix(&format!(" (os error {code})"))
        .unwrap_or(&text);
    match path {
        Some(path) => format!(
            "[Errno {code}] {strerror}: {}",
            relay_artifacts::pystr::repr(&path.to_string_lossy())
        ),
        None => format!("[Errno {code}] {strerror}"),
    }
}

/// One long option.
pub struct Opt {
    pub name: &'static str,
    /// Whether it takes a value; otherwise it is a `store_true` flag.
    pub valued: bool,
    pub choices: &'static [&'static str],
    pub required: bool,
}

impl Opt {
    pub const fn flag(name: &'static str) -> Self {
        Self {
            name,
            valued: false,
            choices: &[],
            required: false,
        }
    }

    pub const fn value(name: &'static str) -> Self {
        Self {
            name,
            valued: true,
            choices: &[],
            required: false,
        }
    }

    pub const fn choice(name: &'static str, choices: &'static [&'static str]) -> Self {
        Self {
            name,
            valued: true,
            choices,
            required: false,
        }
    }

    pub const fn required(mut self) -> Self {
        self.required = true;
        self
    }
}

/// An optional positional (`nargs="?"`), with its choices.
pub struct Positional {
    pub dest: &'static str,
    pub choices: &'static [&'static str],
}

pub struct Spec {
    pub prog: &'static str,
    /// The usage line, after `usage: `.
    pub usage: &'static str,
    /// Everything `--help` prints after the usage line.
    pub help: &'static str,
    pub options: &'static [Opt],
    pub positionals: &'static [Positional],
    /// Options at most one of which may be given.
    pub exclusive: &'static [&'static str],
}

/// What parsing produced: the last value of each option given, in order.
#[derive(Debug, Default)]
pub struct Parsed {
    values: Vec<(&'static str, Option<String>)>,
    positionals: Vec<(&'static str, String)>,
}

impl Parsed {
    pub fn value(&self, name: &str) -> Option<&str> {
        self.values
            .iter()
            .rev()
            .find(|(option, _)| *option == name)
            .and_then(|(_, value)| value.as_deref())
    }

    pub fn flag(&self, name: &str) -> bool {
        self.values.iter().any(|(option, _)| *option == name)
    }

    pub fn positional(&self, dest: &str) -> Option<&str> {
        self.positionals
            .iter()
            .find(|(name, _)| *name == dest)
            .map(|(_, value)| value.as_str())
    }
}

/// A parse that ends the process: help (exit 0) or a usage error (exit 2).
#[derive(Debug, PartialEq, Eq)]
pub enum Exit {
    Help(String),
    Usage(String),
}

impl Exit {
    /// Prints the message where argparse prints it and returns the status.
    pub fn report(&self) -> u8 {
        match self {
            Exit::Help(text) => {
                println!("{text}");
                0
            }
            Exit::Usage(text) => {
                eprintln!("{text}");
                2
            }
        }
    }
}

/// `repr()` of a plain string, as argparse quotes choices.
fn repr(text: &str) -> String {
    relay_artifacts::pystr::repr(text)
}

fn choices_text(choices: &[&str]) -> String {
    choices
        .iter()
        .map(|choice| repr(choice))
        .collect::<Vec<_>>()
        .join(", ")
}

/// Whether argparse reads `text` as a negative number rather than an option.
fn is_negative_number(text: &str) -> bool {
    let Some(rest) = text.strip_prefix('-') else {
        return false;
    };
    let (whole, fraction) = rest.split_once('.').unwrap_or((rest, ""));
    !(whole.is_empty() && fraction.is_empty())
        && whole.bytes().all(|byte| byte.is_ascii_digit())
        && fraction.bytes().all(|byte| byte.is_ascii_digit())
}

impl Spec {
    pub fn error(&self, message: &str) -> Exit {
        Exit::Usage(format!(
            "usage: {}\n{}: error: {message}",
            self.usage, self.prog
        ))
    }

    fn help_text(&self) -> String {
        format!("usage: {}\n{}", self.usage, self.help)
    }

    /// The option `name` names exactly or as a unique prefix; `Ok(None)`
    /// when it names none, an error when it is ambiguous.
    fn lookup(&self, name: &str) -> Result<Option<&Opt>, Exit> {
        if let Some(option) = self.options.iter().find(|option| option.name == name) {
            return Ok(Some(option));
        }
        let matches: Vec<&Opt> = self
            .options
            .iter()
            .filter(|option| option.name.starts_with(name))
            .collect();
        match matches.as_slice() {
            [] => Ok(None),
            [only] => Ok(Some(only)),
            several => Err(self.error(&format!(
                "ambiguous option: {name} could match {}",
                several
                    .iter()
                    .map(|option| option.name)
                    .collect::<Vec<_>>()
                    .join(", ")
            ))),
        }
    }

    pub fn parse(&self, arguments: &[String]) -> Result<Parsed, Exit> {
        let mut parsed = Parsed::default();
        let mut unrecognized: Vec<String> = Vec::new();
        let mut positional_index = 0;
        let mut seen_exclusive: Option<&'static str> = None;
        let mut only_positionals = false;
        let mut index = 0;
        while index < arguments.len() {
            let argument = &arguments[index];
            index += 1;
            if !only_positionals && argument == "--" {
                only_positionals = true;
                continue;
            }
            let is_option = !only_positionals && argument.starts_with('-') && argument.len() > 1;
            if is_option && (argument == "-h" || argument == "--help") {
                return Err(Exit::Help(self.help_text()));
            }
            if !is_option || is_negative_number(argument) {
                match self.positionals.get(positional_index) {
                    Some(positional) => {
                        if !positional.choices.is_empty()
                            && !positional.choices.contains(&argument.as_str())
                        {
                            return Err(self.error(&format!(
                                "argument {}: invalid choice: {} (choose from {})",
                                positional.dest,
                                repr(argument),
                                choices_text(positional.choices)
                            )));
                        }
                        parsed.positionals.push((positional.dest, argument.clone()));
                        positional_index += 1;
                    }
                    None => unrecognized.push(argument.clone()),
                }
                continue;
            }
            if !argument.starts_with("--") {
                unrecognized.push(argument.clone());
                continue;
            }
            let (name, inline) = match argument.split_once('=') {
                Some((name, value)) => (name, Some(value.to_string())),
                None => (argument.as_str(), None),
            };
            let Some(option) = self.lookup(name)? else {
                unrecognized.push(argument.clone());
                continue;
            };
            let value = if option.valued {
                let value = match inline {
                    Some(value) => value,
                    None => match arguments.get(index) {
                        Some(next)
                            if !next.starts_with('-')
                                || next.len() == 1
                                || is_negative_number(next) =>
                        {
                            index += 1;
                            next.clone()
                        }
                        _ => {
                            return Err(self.error(&format!(
                                "argument {}: expected one argument",
                                option.name
                            )));
                        }
                    },
                };
                if !option.choices.is_empty() && !option.choices.contains(&value.as_str()) {
                    return Err(self.error(&format!(
                        "argument {}: invalid choice: {} (choose from {})",
                        option.name,
                        repr(&value),
                        choices_text(option.choices)
                    )));
                }
                Some(value)
            } else {
                if let Some(value) = inline {
                    return Err(self.error(&format!(
                        "argument {}: ignored explicit argument {}",
                        option.name,
                        repr(&value)
                    )));
                }
                None
            };
            if self.exclusive.contains(&option.name) {
                match seen_exclusive {
                    Some(previous) if previous != option.name => {
                        return Err(self.error(&format!(
                            "argument {}: not allowed with argument {previous}",
                            option.name
                        )));
                    }
                    _ => seen_exclusive = Some(option.name),
                }
            }
            parsed.values.push((option.name, value));
        }
        let missing: Vec<&str> = self
            .options
            .iter()
            .filter(|option| option.required && !parsed.flag(option.name))
            .map(|option| option.name)
            .collect();
        if !missing.is_empty() {
            return Err(self.error(&format!(
                "the following arguments are required: {}",
                missing.join(", ")
            )));
        }
        if !unrecognized.is_empty() {
            return Err(self.error(&format!(
                "unrecognized arguments: {}",
                unrecognized.join(" ")
            )));
        }
        Ok(parsed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SPEC: Spec = Spec {
        prog: "tool",
        usage: "tool [-h] [--alpha ALPHA] [--beta {x,y}] [--gamma] [--delta DELTA] [{show,set}]",
        help: "\nA tool.",
        options: &[
            Opt::value("--alpha"),
            Opt::choice("--beta", &["x", "y"]),
            Opt::flag("--gamma"),
            Opt::value("--delta").required(),
        ],
        positionals: &[Positional {
            dest: "action",
            choices: &["show", "set"],
        }],
        exclusive: &["--alpha", "--gamma"],
    };

    fn parse(values: &[&str]) -> Result<Parsed, Exit> {
        let arguments: Vec<String> = values.iter().map(|value| value.to_string()).collect();
        SPEC.parse(&arguments)
    }

    fn error(message: &str) -> Exit {
        SPEC.error(message)
    }

    #[test]
    fn reads_values_flags_prefixes_and_positionals() {
        let parsed = parse(&["--al=1", "--delta", "-2", "--beta", "y", "set"]).unwrap();
        assert_eq!(parsed.value("--alpha"), Some("1"));
        assert_eq!(parsed.value("--delta"), Some("-2"));
        assert_eq!(parsed.value("--beta"), Some("y"));
        assert_eq!(parsed.positional("action"), Some("set"));
        assert!(!parsed.flag("--gamma"));
        let parsed = parse(&["--delta", "a", "--delta", "b", "--gamma"]).unwrap();
        assert_eq!(parsed.value("--delta"), Some("b"));
        assert!(parsed.flag("--gamma"));
    }

    #[test]
    fn reports_errors_as_argparse_does() {
        assert_eq!(
            parse(&[]).err(),
            Some(error("the following arguments are required: --delta"))
        );
        assert_eq!(
            parse(&["--delta", "d", "--beta", "z"]).err(),
            Some(error(
                "argument --beta: invalid choice: 'z' (choose from 'x', 'y')"
            ))
        );
        assert_eq!(
            parse(&["--delta", "d", "nope"]).err(),
            Some(error(
                "argument action: invalid choice: 'nope' (choose from 'show', 'set')"
            ))
        );
        assert_eq!(
            parse(&["--delta"]).err(),
            Some(error("argument --delta: expected one argument"))
        );
        assert_eq!(
            parse(&["--delta", "d", "--gamma=1"]).err(),
            Some(error("argument --gamma: ignored explicit argument '1'"))
        );
        assert_eq!(
            parse(&["--delta", "d", "--alpha", "a", "--gamma"]).err(),
            Some(error("argument --gamma: not allowed with argument --alpha"))
        );
        assert_eq!(
            parse(&["--delta", "d", "show", "extra", "--zeta"]).err(),
            Some(error("unrecognized arguments: extra --zeta"))
        );
        assert!(matches!(parse(&["--bogus", "-h"]), Err(Exit::Help(_))));
    }
}
