"""Rust workspace: pinned toolchain, licence allow list and generated notices."""

import importlib.machinery
import importlib.util
import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "rust-licenses"


def load_script():
    loader = importlib.machinery.SourceFileLoader("rust_licenses", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


rust_licenses = load_script()


def crate(name, license, version="1.0.0", member=False):
    return {"id": f"{name}@{version}", "name": name, "version": version, "license": license, "member": member}


def metadata(*crates, unresolved=()):
    return {
        "packages": [*crates, *unresolved],
        "workspace_members": [entry["id"] for entry in crates if entry["member"]],
        "resolve": {"nodes": [{"id": entry["id"]} for entry in crates]},
    }


class RustLicenseTests(unittest.TestCase):
    def test_allow_list_is_explicit_and_has_no_gpl_family_licence(self):
        self.assertIn("MIT", rust_licenses.ALLOWED_LICENSES)
        for entry in rust_licenses.ALLOWED_LICENSES:
            self.assertNotRegex(entry, r"(?i)GPL")

    def test_permissive_expressions_are_allowed(self):
        for expression in (
            "MIT",
            "MIT OR Apache-2.0",
            "MIT/Apache-2.0",
            "Apache-2.0 WITH LLVM-exception",
            "(MIT OR Apache-2.0) AND Unicode-3.0",
            "Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT",
            # A dual licence is satisfied by its permissive side.
            "MIT OR GPL-3.0-or-later",
            "(GPL-2.0-only OR BSD-3-Clause) AND ISC",
        ):
            with self.subTest(expression=expression):
                self.assertTrue(rust_licenses.license_allowed(expression))

    def test_gpl_family_unknown_and_malformed_expressions_are_refused(self):
        for expression in (
            "GPL-3.0-only",
            "GPL-3.0-or-later",
            "GPL-2.0+",
            "AGPL-3.0-only",
            "LGPL-2.1-or-later",
            "MIT AND GPL-3.0-only",
            "GPL-3.0-only AND MIT",
            "(MIT OR Apache-2.0) AND AGPL-3.0-or-later",
            "GPL-2.0-only WITH Classpath-exception-2.0",
            # An exception is allowed only for the licence it is listed with.
            "MIT WITH LLVM-exception",
            "MPL-2.0",
            "Proprietary",
            "mit",
            "MIT or GPL-3.0-only",
            "MIT OR",
            "(MIT",
            "MIT)",
            "MIT Apache-2.0",
            "",
            None,
        ):
            with self.subTest(expression=expression):
                self.assertFalse(rust_licenses.license_allowed(expression))

    def test_only_resolved_third_party_crates_are_checked_and_listed(self):
        tree = metadata(
            crate("relay-rs", "MIT", "0.0.0", member=True),
            crate("zeta", "MIT OR Apache-2.0"),
            crate("alpha", "GPL-3.0-only", "2.1.0"),
            unresolved=[crate("windows-only", "AGPL-3.0-only")],
        )
        crates = rust_licenses.third_party_crates(tree)
        self.assertEqual([entry["name"] for entry in crates], ["alpha", "zeta"])
        self.assertEqual(rust_licenses.refused_crates(crates), ["alpha 2.1.0: GPL-3.0-only"])
        self.assertEqual(
            rust_licenses.refused_crates([crate("unlabelled", None)]),
            ["unlabelled 1.0.0: no licence expression"],
        )

    def test_rendered_block_lists_each_crate_and_replaces_only_the_generated_block(self):
        block = rust_licenses.render([crate("zeta", "MIT OR Apache-2.0", "1.4.0")], "1.2.3")
        self.assertIn("| [zeta](https://crates.io/crates/zeta/1.4.0) | 1.4.0 | MIT OR Apache-2.0 |", block)
        self.assertIn("with Rust 1.2.3", block)
        self.assertIn("resolves no third-party crates", rust_licenses.render([], "1.2.3"))
        document = f"before\n{rust_licenses.BEGIN}\nold\n{rust_licenses.END}\nafter\n"
        self.assertEqual(rust_licenses.replace_block(document, block), f"before\n{block}\nafter\n")
        with self.assertRaises(SystemExit):
            rust_licenses.replace_block("no markers", block)


class RustWorkspaceTests(unittest.TestCase):
    def test_workspace_pins_a_stable_toolchain_and_commits_its_lockfile(self):
        self.assertRegex(rust_licenses.pinned_toolchain(), r"^\d+\.\d+\.\d+$")
        for name in ("Cargo.toml", "Cargo.lock", "relay-rs/Cargo.toml"):
            self.assertTrue((ROOT / "rust" / name).is_file(), name)
        self.assertNotIn("Cargo.lock", (ROOT / ".gitignore").read_text())

    def test_ci_checks_the_workspace_and_licences_before_packaging(self):
        workflow = (ROOT / ".github/workflows/build-dmg.yml").read_text()
        steps = (
            "rustup toolchain install",
            "cargo fmt --all --check",
            "cargo clippy --workspace --all-targets --locked -- -D warnings",
            "cargo test --workspace --locked",
            "python3 scripts/rust-licenses --check",
            "run: ./scripts/build-dmg.sh",
        )
        positions = [workflow.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertIn('- "rust/**"', workflow)
        self.assertRegex(workflow, r"hashFiles\('rust/rust-toolchain.toml', 'rust/Cargo.lock'\)")

    @unittest.skipUnless(shutil.which("cargo"), "cargo is not installed")
    def test_committed_notices_match_the_dependency_tree(self):
        check = subprocess.run(
            [sys.executable, str(SCRIPT), "--check"], cwd=ROOT, capture_output=True, text=True)
        self.assertEqual(check.returncode, 0, check.stderr)
        notices = (ROOT / "THIRD_PARTY_NOTICES.md").read_text()
        self.assertEqual(len(re.findall(re.escape(rust_licenses.BEGIN), notices)), 1)


if __name__ == "__main__":
    unittest.main()
