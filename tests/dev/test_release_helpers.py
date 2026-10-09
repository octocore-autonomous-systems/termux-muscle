# SPDX-License-Identifier: MPL-2.0
"""Offline regressions for the maintainer release helpers; no network, account, or vendor code.

They replay the next pin move on a copy of this tree, so an edit that removes an anchor the
helpers rely on (README banner, device matrix row, footnote, model sentence, changelog heading)
fails here instead of during a release.
"""
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COPIED = ["VERSION", "install.sh", "compatibility.json", "CHANGELOG.md", "README.md",
          "docs/device-compatibility.md"]
INTEGRITY = "sha512-" + "A" * 86 + "=="
BINARY = "ab" * 32
GIT = ["git", "-c", "user.name=fixture", "-c", "user.email=fixture@example.invalid",
       "-c", "commit.gpgsign=false", "-c", "init.defaultBranch=main"]


def bump(version, index):
    parts = [int(part) for part in version.split(".")]
    parts[index] += 1
    return ".".join(str(part) for part in parts[: index + 1] + [0] * (len(parts) - index - 1))


class ReleaseHelpers(unittest.TestCase):
    def setUp(self):
        self.manifest = json.loads((ROOT / "compatibility.json").read_text())
        if "verified_on" not in self.manifest:
            self.skipTest("tree is a prepared release awaiting device evidence")
        self.scratch = tempfile.TemporaryDirectory()
        self.tree = Path(self.scratch.name) / "tree"
        self.tree.mkdir()
        for name in COPIED:
            (self.tree / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, self.tree / name)
        (self.tree / "docs/man").mkdir(parents=True)
        shutil.copy2(ROOT / "docs/man/termux-muscle.1", self.tree / "docs/man/termux-muscle.1")
        (self.tree / "docs/releases").mkdir()
        (self.tree / "compatibility").mkdir()
        self.old_report = self.manifest["reports"][0]
        shutil.copy2(ROOT / self.old_report, self.tree / self.old_report)
        self.old_version = (ROOT / "VERSION").read_text().strip()
        self.old_claude = self.manifest["claude"]["version"]
        self.new_version = bump(self.old_version, 1)
        self.new_claude = bump(self.old_claude, 2)
        self.why = Path(self.scratch.name) / "why.txt"
        self.why.write_text(f"Claude Code {self.new_claude} is a fixture release.\n")
        self.git("init", "-q")
        self.commit("registered")

    def tearDown(self):
        if hasattr(self, "scratch"):
            self.scratch.cleanup()

    def git(self, *arguments):
        return subprocess.run(GIT + list(arguments), cwd=self.tree, check=True, text=True,
                              capture_output=True).stdout.strip()

    def commit(self, message):
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)
        return self.git("rev-parse", "HEAD")

    def helper(self, name, *arguments):
        return subprocess.run([sys.executable, "-B", str(ROOT / "scripts" / name), *arguments],
                              cwd=self.tree, text=True, capture_output=True)

    def prepare(self):
        return self.helper("release_prepare.py", self.new_version, self.new_claude, INTEGRITY, BINARY,
                           str(self.why), "--date", "2030-01-02")

    def read(self, name):
        return (self.tree / name).read_text()

    def test_prepare_then_register_replays_a_pin_move(self):
        result = self.prepare()
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(self.read("compatibility.json"))
        self.assertEqual(self.read("VERSION"), self.new_version + "\n")
        self.assertIn(f'VERSION="{self.new_version}"', self.read("install.sh"))
        self.assertIn(f'"2030-01-02" "Termux Muscle {self.new_version}"', self.read("docs/man/termux-muscle.1"))
        self.assertEqual(manifest["project_version"], self.new_version)
        self.assertEqual(manifest["claude"]["version"], self.new_claude)
        self.assertEqual(manifest["claude"]["pinned_since"], self.new_version)
        self.assertEqual(manifest["claude"]["integrity"], INTEGRITY)
        self.assertEqual(manifest["claude"]["binary_sha256"], BINARY)
        self.assertIn(self.new_claude, manifest["claude"]["tarball"])
        self.assertEqual(manifest["pin_history"][:-1], self.manifest["pin_history"])
        self.assertEqual(manifest["pin_history"][-1], {
            "version": self.old_claude,
            "project_versions": {"first": self.manifest["claude"]["pinned_since"], "last": self.old_version},
            "verified_on": self.manifest["verified_on"], "report": self.old_report})
        self.assertEqual((manifest["models"]["verified"], manifest["reports"]), ([], []))
        self.assertNotIn("verified_on", manifest)
        self.assertIn("is pending", manifest["models"]["availability_note"])
        self.assertTrue(self.read("CHANGELOG.md").startswith(f"# Changes\n\n## {self.new_version}\n"))
        self.assertIn(f"**{self.new_version} prepares the Claude Code {self.new_claude} pin**", self.read("README.md"))
        self.assertIn(f"download/v{self.new_version}/install.sh", self.read("README.md"))
        note = self.read(f"docs/releases/{self.new_version}.md")
        self.assertIn("is a fixture release.", note)
        self.assertIn("acceptance is pending", note)
        self.assertEqual(self.git("status", "--porcelain", "--", "compatibility").strip(), "")

        head = self.commit("prepared")
        report = json.loads(self.read(self.old_report))
        report["generated_at"] = "2030-01-02T03:04:05Z"
        report["project"]["version"] = self.new_version
        report["claude_code"]["version"] = self.new_claude
        report["source"] = {"commit": head, "uncommitted_changes": False}
        report["evidence_notes"] = "acceptance-fixture.md"
        report["authenticated_workflow"]["generated_at"] = "2030-01-02T03:04:01Z"
        report["authenticated_workflow"]["capture"]["elapsed_ms"] = 4321
        (self.tree / "compatibility/reports").mkdir()
        raw = self.tree / "compatibility/reports/acceptance-fixture.json"
        raw.write_text(json.dumps(report, indent=2) + "\n")

        result = self.helper("release_register.py", "--tests", "15")
        self.assertEqual(result.returncode, 0, result.stderr)
        base = f"compatibility/galaxy-s26-ultra-{self.new_version}-20300102"
        self.assertFalse(raw.exists())
        registered = json.loads(self.read(base + ".json"))
        self.assertEqual(registered["evidence_notes"], Path(base).name + ".md")
        registered["evidence_notes"] = report["evidence_notes"]
        self.assertEqual(registered, report)
        manifest = json.loads(self.read("compatibility.json"))
        self.assertEqual(manifest["models"]["verified"], ["claude-opus-5-5"])
        self.assertEqual((manifest["reports"], manifest["verified_on"]), ([base + ".json"], "2030-01-02"))
        self.assertIn(f"on 2030-01-02 with {self.new_version} on the {self.new_claude} pin",
                      manifest["models"]["availability_note"])
        self.assertIn(f"Earlier {self.old_version} checks on {self.old_claude}, ",
                      manifest["models"]["availability_note"])
        readme = self.read("README.md")
        self.assertIn(f"> **{self.new_version} pins Claude Code {self.new_claude}**", readme)
        matrix = self.read("docs/device-compatibility.md")
        rows = [line for line in matrix.splitlines() if line.startswith("| **")]
        self.assertTrue(rows[0].startswith(f"| **{self.new_version}, 2030-01-02 UTC**"))
        self.assertTrue(rows[1].startswith(f"| **{self.old_version}, "))
        self.assertEqual(matrix.count(f" Version {self.new_version} moves the pin to Claude Code {self.new_claude}"), 1)
        self.assertIn("[device compatibility matrix](docs/device-compatibility.md)", readme)
        self.assertNotIn("| Tested configuration |", readme)
        self.assertNotIn(f" Version {self.new_version} moves the pin", readme)
        previous_rows = [line for line in (ROOT / "docs/device-compatibility.md").read_text().splitlines()
                         if line.startswith("| **")]
        self.assertEqual(rows[1:], previous_rows)
        for suffix in ("md", "json"):
            relative = f"../{base}.{suffix}"
            self.assertIn(f"]({relative})", rows[0])
            self.assertTrue((self.tree / "docs" / relative).is_file())
        self.assertIn(f"acceptance with {self.new_version} on the {self.new_claude} pin on 2030-01-02 UTC, with ",
                      readme)
        for name in ("CHANGELOG.md", f"docs/releases/{self.new_version}.md", "README.md"):
            self.assertNotIn("acceptance is pending", self.read(name))
            self.assertNotIn("for this release is pending", self.read(name))
        self.assertIn(f"clean commit `{head[:7]}`", self.read("CHANGELOG.md"))
        self.assertIn("4321 ms", self.read(base + ".md"))
        self.assertIn(head, self.read(base + ".md"))

    def test_prepare_refuses_bad_input_without_writing(self):
        cases = [
            (self.old_version, self.new_claude, INTEGRITY, BINARY),
            (self.new_version, self.old_claude, INTEGRITY, BINARY),
            (self.new_version, self.new_claude, "sha256-short", BINARY),
            (self.new_version, self.new_claude, INTEGRITY, "not-a-digest"),
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments):
                result = self.helper("release_prepare.py", *arguments, str(self.why))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("release_prepare:", result.stderr)
                self.assertEqual(self.git("status", "--porcelain"), "")

    def test_register_refuses_a_report_from_another_commit(self):
        self.assertEqual(self.prepare().returncode, 0)
        self.commit("prepared")
        report = json.loads(self.read(self.old_report))
        report["project"]["version"] = self.new_version
        report["claude_code"]["version"] = self.new_claude
        report["source"] = {"commit": "0" * 40, "uncommitted_changes": False}
        (self.tree / "compatibility/reports").mkdir()
        (self.tree / "compatibility/reports/acceptance-fixture.json").write_text(json.dumps(report))
        result = self.helper("release_register.py")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("clean checkout of HEAD", result.stderr)
        self.assertEqual(self.git("status", "--porcelain", "--", "README.md", "docs/device-compatibility.md", "compatibility.json"), "")


if __name__ == "__main__":
    unittest.main()
