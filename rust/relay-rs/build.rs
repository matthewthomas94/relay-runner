//! Compiles the app's version and build number into relay-rs from the
//! repository's Info.plist, the file scripts/build-dmg.sh copies into the bundle.

use std::path::Path;

const INFO_PLIST: &str = "../../Info.plist";

fn plist_string<'a>(plist: &'a str, key: &str) -> &'a str {
    plist
        .split_once(&format!("<key>{key}</key>"))
        .and_then(|(_, rest)| rest.trim_start().strip_prefix("<string>"))
        .and_then(|rest| rest.split_once("</string>"))
        .map(|(value, _)| value)
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| panic!("{INFO_PLIST} has no string value for {key}"))
}

fn main() {
    println!("cargo::rerun-if-changed={INFO_PLIST}");
    let plist = std::fs::read_to_string(Path::new(INFO_PLIST))
        .unwrap_or_else(|error| panic!("cannot read {INFO_PLIST}: {error}"));
    let short_version = plist_string(&plist, "CFBundleShortVersionString");
    let build = plist_string(&plist, "CFBundleVersion");
    println!("cargo::rustc-env=RELAY_BUNDLE_SHORT_VERSION={short_version}");
    println!("cargo::rustc-env=RELAY_BUNDLE_VERSION={build}");
}
