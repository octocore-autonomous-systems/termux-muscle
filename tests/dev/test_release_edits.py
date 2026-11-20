# SPDX-License-Identifier: MPL-2.0
"""scripts/release_edits.py on a copy of this repository, checked by the release gate."""
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/release_edits.py"
NEXT = "9.9.9"
CLAUDE = "9.9.999"
SHA256 = "ab" * 32
INTEGRITY = "sha512-" + "A" * 86 + "=="
DAY = datetime.now(timezone.utc).date().isoformat()  # the gate refuses future dates
PENDING = "Fresh device and authenticated tool acceptance for this release is pending."


def run(*args, root, check=True):
    return subprocess.run([sys.executable, "-B", str(SCRIPT), "--root", str(root), *args],
                          capture_output=True, text=True, check=check)


def copy_tree(target):
    files = subprocess.run(["git", "-C", str(ROOT), "ls-files", "-z"], capture_output=True,
                           check=True).stdout.decode().split("\0")
    for name in filter(None, files):
        source = ROOT / name
        if source.is_file():
            (target / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target / name)


class ReleaseEditsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        """The release gate compares VERSION with the helper's built-in version: build a NEXT helper."""
        cls.build = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        tree = Path(cls.build.name)
        copy_tree(tree)
        (tree / "VERSION").write_text(NEXT + "\n")
        made = subprocess.run(["make", "-s", "-C", str(tree), "build/tm-core"], capture_output=True, text=True)
        cls.tm_core = tree / "build/tm-core" if made.returncode == 0 else None
        if cls.tm_core is None and os.environ.get("CI"):
            raise RuntimeError("cannot build the helper for the release gate: " + made.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def gate(self):
        return subprocess.run([str(self.tm_core), "release-check", str(self.root)], capture_output=True, text=True)

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("TMPDIR"))
        self.root = Path(self.tmp.name) / "tree"
        copy_tree(self.root)
        self.manifest = json.loads((self.root / "compatibility.json").read_text())

    def tearDown(self):
        self.tmp.cleanup()

    def read(self, name):
        return (self.root / name).read_text()

    def write_pending_prose(self):
        """What a maintainer writes by hand for the preparation commit."""
        changelog = self.read("CHANGELOG.md").replace(
            "# Changes\n", f"# Changes\n\n## {NEXT}\n\n- A change.\n\n{PENDING}\n", 1)
        (self.root / "CHANGELOG.md").write_text(changelog)
        (self.root / f"docs/releases/{NEXT}.md").write_text(f"# Termux Muscle {NEXT}\n\n{PENDING}\n")

    def write_prose(self, report_base, day, commit, elapsed, extra=""):
        changelog = self.read("CHANGELOG.md").replace(
            PENDING, f"[Evidence from {day} UTC](compatibility/{report_base}.md) from clean commit "
            f"`{commit[:7]}`.{extra}", 1)
        (self.root / "CHANGELOG.md").write_text(changelog)
        (self.root / f"docs/releases/{NEXT}.md").write_text(
            f"# Termux Muscle {NEXT}\n\nAcceptance on {day} from commit `{commit[:7]}`; "
            f"capture exited 0 in {elapsed} ms.\n")
        (self.root / f"compatibility/{report_base}.md").write_text(
            f"# Acceptance {NEXT}\n\nVerified {day} UTC from source commit **`{commit}`** in **{elapsed} ms**.\n")
        readme = self.read("README.md").split("\n")
        readme = [f"> **{NEXT} does something.** See the report." if line.startswith("> **") else line
                  for line in readme]
        (self.root / "README.md").write_text("\n".join(readme))
        manifest = json.loads(self.read("compatibility.json"))
        manifest["models"]["availability_note"] = f"Opus 5.5 passed on {day} with {NEXT}."
        (self.root / "compatibility.json").write_text(json.dumps(manifest, indent=2) + "\n")
        matrix = self.read("docs/device-compatibility.md")
        number = matrix.split(f"| **{NEXT}, ")[1].split("|")[1].strip()[4:]
        (self.root / "docs/device-compatibility.md").write_text(matrix + f"\n{number} A footnote.\n")

    def fake_report(self, day):
        report = json.loads(self.read(self.manifest["reports"][-1]))
        report["project"]["version"] = NEXT
        report["claude_code"]["version"] = CLAUDE
        report["generated_at"] = f"{day}T00:00:00Z"
        report["source"] = {"commit": "0123456789abcdef0123456789abcdef01234567", "uncommitted_changes": False}
        path = self.root / f"compatibility/reports/acceptance-{NEXT}-{day.replace('-', '')}T000000Z.json"
        path.parent.mkdir(parents=True)
        path.write_text(json.dumps(report, indent=2) + "\n")
        return path, report

    def test_prepare_then_register(self):
        day = DAY
        outgoing = self.manifest["claude"]["version"]
        run("prepare", NEXT, "--claude-version", CLAUDE, "--claude-integrity", INTEGRITY,
            "--claude-binary-sha256", SHA256, "--date", day, root=self.root)
        self.assertEqual(self.read("VERSION"), NEXT + "\n")
        self.assertIn(f'VERSION="{NEXT}"', self.read("install.sh"))
        self.assertIn(f'.TH TERMUX-MUSCLE 1 "{day}" "Termux Muscle {NEXT}"', self.read("docs/man/termux-muscle.1"))
        self.assertIn(f"releases/download/v{NEXT}/install.sh", self.read("README.md"))
        manifest = json.loads(self.read("compatibility.json"))
        self.assertEqual(manifest["project_version"], NEXT)
        self.assertEqual((manifest["claude"]["version"], manifest["claude"]["pinned_since"]), (CLAUDE, NEXT))
        self.assertEqual((manifest["claude"]["integrity"], manifest["claude"]["binary_sha256"]), (INTEGRITY, SHA256))
        self.assertTrue(manifest["claude"]["tarball"].endswith(f"-{CLAUDE}.tgz"))
        history = manifest["pin_history"][-1]
        self.assertEqual(history["version"], outgoing)
        self.assertEqual(history["project_versions"]["last"], self.manifest["project_version"])
        self.assertEqual((history["verified_on"], history["report"]),
                         (self.manifest["verified_on"], self.manifest["reports"][-1]))
        self.assertEqual((manifest["models"]["verified"], manifest["reports"]), ([], []))
        self.assertNotIn("verified_on", manifest)
        self.assertIn(f"Model acceptance for {NEXT} is pending.", manifest["models"]["availability_note"])
        self.write_pending_prose()
        if self.tm_core:
            result = self.gate()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("asserts no device acceptance", result.stderr + result.stdout)

        path, report = self.fake_report(day)
        out = run("register", str(path.relative_to(self.root)), root=self.root).stdout
        base = f"galaxy-s26-ultra-{NEXT}-{day.replace('-', '')}"
        self.assertIn(day, out)
        self.assertFalse(path.exists())
        registered = json.loads(self.read(f"compatibility/{base}.json"))
        self.assertEqual(registered["evidence_notes"], f"{base}.md")
        manifest = json.loads(self.read("compatibility.json"))
        self.assertEqual(manifest["verified_on"], day)
        self.assertEqual(manifest["reports"], [f"compatibility/{base}.json"])
        self.assertEqual(manifest["models"]["verified"], ["claude-opus-5-5"])
        row = next(line for line in self.read("docs/device-compatibility.md").split("\n")
                   if line.startswith(f"| **{NEXT}, {day} UTC** ·"))
        self.assertIn("| — | PASS | PASS | PASS | [Maintainer report]", row)
        self.assertIn(f"| [{NEXT}](docs/releases/{NEXT}.md) | {CLAUDE} |", self.read("README.md"))
        if self.tm_core:
            result = self.gate()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"Release gate PASS: {NEXT}", result.stdout + result.stderr)

        elapsed = report["authenticated_workflow"]["capture"]["elapsed_ms"]
        self.assertNotEqual(run("check", root=self.root, check=False).returncode, 0)  # prose not written yet
        self.write_prose(base, day, report["source"]["commit"], elapsed)
        result = run("check", root=self.root, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_check_finds_wrong_numbers(self):
        day = DAY
        run("prepare", NEXT, "--date", day, root=self.root)
        self.write_pending_prose()
        path, report = self.fake_report(day)
        report["claude_code"]["version"] = self.manifest["claude"]["version"]
        path.write_text(json.dumps(report, indent=2) + "\n")
        run("register", str(path.relative_to(self.root)), root=self.root)
        base = f"galaxy-s26-ultra-{NEXT}-{day.replace('-', '')}"
        self.write_prose(base, day, "fedcba9876543210", "None", extra=" Still pending.")
        result = run("check", root=self.root, check=False)
        self.assertNotEqual(result.returncode, 0)
        for problem in ("'None ms' differs", "commit fedcba9", "still says pending"):
            self.assertIn(problem, result.stderr)

    def test_refusals(self):
        self.assertIn("already names", run("prepare", self.manifest["project_version"], root=self.root,
                                           check=False).stderr)
        self.assertIn("need a new --claude-version", run("prepare", NEXT, "--claude-integrity", INTEGRITY,
                                                         root=self.root, check=False).stderr)
        run("prepare", NEXT, "--date", DAY, root=self.root)
        path, _ = self.fake_report(DAY)
        self.assertIn("does not match", run("register", str(path), root=self.root, check=False).stderr)


if __name__ == "__main__":
    unittest.main()
