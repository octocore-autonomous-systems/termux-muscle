# SPDX-License-Identifier: MPL-2.0
"""Offline maintainer-tool regressions; no network, account, or vendor code."""
import base64
import contextlib
import copy
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("tracker", ROOT / "scripts/track_upstream.py")
tracker = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tracker)


def manifest(version="2.1.9"):
    return {"schema": 1, "claude": {"package": tracker.PACKAGE, "version": version}}


def metadata(version="2.1.10"):
    return {
        "name": tracker.PACKAGE, "version": version,
        "os": ["linux"], "cpu": ["arm64"], "libc": ["musl"],
        "dist": {
            "tarball": tracker.REGISTRY + tracker.PACKAGE + "/-/claude-code-linux-arm64-musl-" + version + ".tgz",
            "integrity": "sha512-" + base64.b64encode(bytes(64)).decode("ascii"),
        },
    }


class SelectionTests(unittest.TestCase):
    def test_numeric_ordering_and_no_downgrade(self):
        for pin, latest, status in (
            ("2.1.9", "2.1.10", "candidate"),
            ("2.1.10", "2.1.9", "registry_behind_pin"),
            ("2.1.10", "2.1.10", "up_to_date"),
            ("2.9.99", "2.10.0", "candidate"),
            ("2.99.99", "3.0.0", "candidate"),
        ):
            with self.subTest(pin=pin, latest=latest):
                result = tracker.candidate_from(manifest(pin), metadata(latest))
                self.assertEqual(result["status"], status)
                self.assertEqual(result["compatibility_status"], "not_tested")

    def test_reject_prereleases_malformed_and_injection_versions(self):
        for version in ("2.1.10-beta.1", "v2.1.10", "02.1.10", "2.1", "2.1.10\n", "$(id)", 42):
            with self.subTest(version=version), self.assertRaises(ValueError):
                tracker.version_tuple(version)

    def test_reject_wrong_identity_platform_and_manifest(self):
        for key, value in (("name", "other"), ("os", ["android"]), ("cpu", ["x64"]),
                           ("libc", ["glibc"]), ("libc", ["musl", "glibc"])):
            data = metadata()
            data[key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                tracker.candidate_from(manifest(), data)
        for data in ({}, {"schema": 2, "claude": manifest()["claude"]}):
            with self.assertRaises((ValueError, KeyError)):
                tracker.candidate_from(data, metadata())

    def test_reject_foreign_urls_wrong_versions_and_integrity(self):
        good = metadata()
        for field, value in (
            ("tarball", "https://evil.example/payload.tgz"),
            ("tarball", good["dist"]["tarball"].replace("https:", "http:")),
            ("tarball", good["dist"]["tarball"].replace("2.1.10", "2.1.11")),
            ("tarball", good["dist"]["tarball"] + "?token=private"),
            ("integrity", "sha1-abc"), ("integrity", "sha512-!!!!"),
            ("integrity", "sha512-YQ=="), ("integrity", None),
        ):
            data = copy.deepcopy(good)
            data["dist"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                tracker.candidate_from(manifest(), data)


class PublicationTests(unittest.TestCase):
    def setUp(self):
        self.report = tracker.candidate_from(manifest(), metadata())

    def test_new_candidate_creates_one_issue_with_acceptance_limits(self):
        with patch.object(tracker, "gh_api", side_effect=[[[]], {"number": 8}]) as api:
            result = tracker.publish_candidate(self.report)
        self.assertEqual(result["status"], "issue_created")
        self.assertTrue(result["issue_url"].endswith("/issues/8"))
        self.assertEqual(api.call_count, 2)
        payload = api.call_args.args[1]
        self.assertIn(tracker.marker("2.1.10"), payload["body"])
        self.assertIn("no archive downloaded", payload["body"])
        self.assertIn("FAIL/SKIP", payload["body"])

    def test_open_closed_and_later_page_issues_are_not_modified(self):
        for state in ("open", "closed"):
            pages = [[{"number": 1, "body": "unrelated"}], [{
                "number": 4, "state": state,
                "body": tracker.marker("2.1.10") + "\n- [x] Maintainer progress",
            }]]
            with self.subTest(state=state), patch.object(tracker, "gh_api", return_value=pages) as api:
                self.assertEqual(tracker.publish_candidate(self.report)["status"], "already_tracked")
                self.assertEqual(api.call_count, 1)
                self.assertIn("state=all", api.call_args.args[0])
                self.assertIn("--paginate", api.call_args.args[0])

    def test_other_version_and_pull_request_do_not_suppress_candidate(self):
        pages = [[
            {"number": 1, "body": tracker.marker("2.1.9")},
            {"number": 2, "body": tracker.marker("2.1.10"), "pull_request": {}},
        ]]
        with patch.object(tracker, "gh_api", side_effect=[pages, {"number": 3}]) as api:
            self.assertEqual(tracker.publish_candidate(self.report)["status"], "issue_created")
            self.assertEqual(api.call_count, 2)

    def test_equal_or_older_latest_never_contacts_github(self):
        with patch.object(tracker, "gh_api") as api:
            for version in ("2.1.9", "2.1.8"):
                report = tracker.candidate_from(manifest(), metadata(version))
                self.assertEqual(tracker.publish_candidate(report), report)
            api.assert_not_called()

    def test_issue_listing_failure_cannot_create_issue(self):
        with patch.object(tracker, "gh_api", side_effect=RuntimeError("unavailable")) as api:
            with self.assertRaises(RuntimeError):
                tracker.publish_candidate(self.report)
            self.assertEqual(api.call_count, 1)
        with patch.object(tracker, "gh_api", return_value={"message": "unavailable"}) as api:
            with self.assertRaises(ValueError):
                tracker.publish_candidate(self.report)
            self.assertEqual(api.call_count, 1)

    def test_api_error_does_not_echo_response_or_retry_post(self):
        failed = subprocess.CompletedProcess([], 1, "private response", "private diagnostic")
        with patch.object(tracker.subprocess, "run", return_value=failed) as run:
            with self.assertRaisesRegex(RuntimeError, "GitHub API request failed") as error:
                tracker.gh_api(["endpoint", "--method", "POST"], {"body": "body"})
            self.assertNotIn("private", str(error.exception))
            self.assertEqual(run.call_count, 1)
            self.assertEqual(json.loads(run.call_args.kwargs["input"]), {"body": "body"})


class NetworkAndCliTests(unittest.TestCase):
    def test_fetch_is_bounded_and_has_no_authorization(self):
        response = Mock()
        response.read.return_value = json.dumps(metadata()).encode()
        opener = Mock()
        opener.open.return_value.__enter__ = Mock(return_value=response)
        opener.open.return_value.__exit__ = Mock(return_value=False)
        with patch.object(tracker.urllib.request, "build_opener", return_value=opener):
            self.assertEqual(tracker.fetch_latest(), metadata())
        request = opener.open.call_args.args[0]
        self.assertEqual(request.full_url, tracker.LATEST_URL)
        self.assertIsNone(request.get_header("Authorization"))
        self.assertEqual(opener.open.call_args.kwargs["timeout"], 30)
        response.read.assert_called_once_with(tracker.MAX_METADATA + 1)

    def test_reject_oversize_metadata_and_redirects(self):
        opener, response = Mock(), Mock()
        response.read.return_value = b" " * (tracker.MAX_METADATA + 1)
        opener.open.return_value.__enter__ = Mock(return_value=response)
        opener.open.return_value.__exit__ = Mock(return_value=False)
        with patch.object(tracker.urllib.request, "build_opener", return_value=opener):
            with self.assertRaisesRegex(ValueError, "size limit"):
                tracker.fetch_latest()
        with self.assertRaisesRegex(ValueError, "redirects"):
            tracker.NoRedirect().redirect_request(None, None, 302, None, None, "https://other.example")

    def test_default_cli_is_read_only_and_writes_discovery_artifacts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "compatibility.json"
            original = json.dumps(manifest())
            path.write_text(original)
            args = ["tracker", "--manifest", str(path), "--output", str(root / "result.json"),
                    "--summary", str(root / "summary.md")]
            with patch.object(sys, "argv", args), patch.object(tracker, "fetch_latest", return_value=metadata()), \
                    patch.object(tracker, "gh_api") as api, contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(tracker.main(), 0)
                api.assert_not_called()
            self.assertEqual(path.read_text(), original)
            self.assertEqual(json.loads((root / "result.json").read_text())["status"], "candidate")
            self.assertIn("Discovery only", (root / "summary.md").read_text())

    def test_bad_registry_data_fails_before_publication_and_preserves_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest()))
            original = path.read_bytes()
            for result in ({}, [], None, {**metadata(), "cpu": ["x64"]}):
                with patch.object(sys, "argv", ["tracker", "--manifest", str(path), "--publish"]), \
                        patch.object(tracker, "fetch_latest", return_value=result), \
                        patch.object(tracker, "gh_api") as api, contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(tracker.main(), 1)
                    api.assert_not_called()
            self.assertEqual(path.read_bytes(), original)

    def test_explicit_publication_preserves_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest()))
            original = path.read_bytes()
            with patch.object(sys, "argv", ["tracker", "--manifest", str(path), "--publish"]), \
                    patch.object(tracker, "fetch_latest", return_value=metadata()), \
                    patch.object(tracker, "gh_api", side_effect=[[[]], {"number": 9}]) as api, \
                    contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(tracker.main(), 0)
                self.assertEqual(api.call_count, 2)
                self.assertEqual(json.loads(output.getvalue())["status"], "issue_created")
            self.assertEqual(path.read_bytes(), original)

    def test_network_failure_does_not_publish_or_write_success_report(self):
        with tempfile.TemporaryDirectory() as directory:
            path, output = Path(directory) / "manifest.json", Path(directory) / "report.json"
            path.write_text(json.dumps(manifest()))
            with patch.object(sys, "argv", ["tracker", "--manifest", str(path), "--publish", "--output", str(output)]), \
                    patch.object(tracker, "fetch_latest", side_effect=OSError("offline")), \
                    patch.object(tracker, "gh_api") as api, contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(tracker.main(), 1)
                api.assert_not_called()
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
