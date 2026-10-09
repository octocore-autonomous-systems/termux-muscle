# SPDX-License-Identifier: MPL-2.0
"""Offline README table regressions: numeric joins, drift and release inventory."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
from readme_compatibility import END, START, model_minimums, release_pins, update_readme


class ReadmeCompatibility(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.notes = self.root / "docs/releases"
        self.notes.mkdir(parents=True)
        for version in ("0.1.0", "0.8.0", "0.9.0", "0.10.0"):
            (self.notes / f"{version}.md").write_text("fixture release\n")
        self.manifest = {
            "project_version": "0.10.0",
            "claude": {"version": "2.1.10", "pinned_since": "0.9.0"},
            "musl": {"version": "1.2.6-r2"},
            "pin_history": [{"version": "2.1.9", "project_versions": {"first": "0.1.0", "last": "0.8.0"}}],
            "models": {
                "documented": [
                    {"name": "Second", "id": "claude-second", "minimum_claude_version": "2.1.10"},
                    {"name": "Future", "id": "claude-future", "minimum_claude_version": "2.1.11"},
                    {"name": "First", "id": "claude-first", "minimum_claude_version": "2.1.8"},
                    {"name": "Also second", "id": "claude-also-second", "minimum_claude_version": "2.1.10"}],
                "verified": [], "checked_documentation_on": "2026-09-29", "source": "https://example.invalid/models"},
            "reports": []}
        (self.root / "README.md").write_text("prefix\n" + START + "\nstale\n\n" + END + "suffix\n")

    def save_manifest(self):
        (self.root / "compatibility.json").write_text(json.dumps(self.manifest))

    def test_numeric_order_and_derived_minimums_for_multiple_models(self):
        releases = release_pins(self.root, self.manifest)
        self.assertEqual(releases, [("0.1.0", "2.1.9"), ("0.8.0", "2.1.9"),
                                    ("0.9.0", "2.1.10"), ("0.10.0", "2.1.10")])
        models = model_minimums(self.manifest, releases)
        self.assertEqual([(m["name"], minimum) for m, minimum in models],
                         [("First", "0.1.0"), ("Also second", "0.9.0"),
                          ("Second", "0.9.0"), ("Future", None)])

    def test_check_detects_stale_table_without_writing_and_generation_preserves_surroundings(self):
        self.save_manifest()
        path = self.root / "README.md"
        before = path.read_bytes()
        with self.assertRaisesRegex(ValueError, "stale"):
            update_readme(self.root, check=True)
        self.assertEqual(path.read_bytes(), before)
        update_readme(self.root)
        self.assertTrue(path.read_text().startswith("prefix\n" + START))
        self.assertTrue(path.read_text().endswith(END + "suffix\n"))
        self.assertIn("| Future | `claude-future` | 2.1.11 | — |", path.read_text())
        self.assertIn("acceptance for **0.10.0** is pending", path.read_text())
        generated = path.read_bytes()
        update_readme(self.root, check=True)
        update_readme(self.root)
        self.assertEqual(path.read_bytes(), generated)

    def test_uncovered_and_overlapping_release_ranges_are_rejected(self):
        (self.notes / "0.8.1.md").write_text("uncovered\n")
        with self.assertRaisesRegex(ValueError, "0.8.1 has 0 matching"):
            release_pins(self.root, self.manifest)
        (self.notes / "0.8.1.md").unlink()
        self.manifest["claude"]["pinned_since"] = "0.8.0"
        with self.assertRaisesRegex(ValueError, "0.8.0 has 2 matching"):
            release_pins(self.root, self.manifest)

    def test_missing_pin_boundary_is_rejected_instead_of_misstating_first_model_release(self):
        (self.notes / "0.1.0.md").unlink()
        with self.assertRaisesRegex(ValueError, "incomplete pin range"):
            release_pins(self.root, self.manifest)

    def test_checked_in_tables_match_manifest(self):
        update_readme(ROOT, check=True)


if __name__ == "__main__":
    unittest.main()
