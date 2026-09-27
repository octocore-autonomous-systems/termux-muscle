#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Maintainer-only release discovery. Never installs or executes vendor code."""

import argparse
import base64
import binascii
import json
import re
import subprocess
import sys
import urllib.request
from pathlib import Path


REPOSITORY = "octocore-autonomous-systems/termux-muscle"
PACKAGE = "@anthropic-ai/claude-code-linux-arm64-musl"
REGISTRY = "https://registry.npmjs.org/"
LATEST_URL = REGISTRY + "@anthropic-ai%2fclaude-code-linux-arm64-musl/latest"
MAX_METADATA = 1024 * 1024
VERSION = re.compile(r"(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})")


def version_tuple(value):
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise ValueError("Expected a stable X.Y.Z version")
    return tuple(map(int, value.split(".")))


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise ValueError("Registry redirects are not accepted")


def fetch_latest():
    request = urllib.request.Request(
        LATEST_URL,
        headers={"Accept": "application/json", "User-Agent": "termux-muscle-release-tracker"},
    )
    # No GitHub credentials, npm configuration or lifecycle scripts are used here.
    with urllib.request.build_opener(NoRedirect).open(request, timeout=30) as response:
        data = response.read(MAX_METADATA + 1)
    if len(data) > MAX_METADATA:
        raise ValueError("Registry metadata exceeds the size limit")
    return json.loads(data)


def candidate_from(manifest, metadata):
    if not isinstance(manifest, dict) or not isinstance(metadata, dict):
        raise ValueError("Expected JSON objects")
    if manifest.get("schema") != 1 or manifest["claude"]["package"] != PACKAGE:
        raise ValueError("Unexpected compatibility manifest")
    pinned = manifest["claude"]["version"]
    version = metadata["version"]
    pinned_tuple, latest_tuple = version_tuple(pinned), version_tuple(version)
    if metadata["name"] != PACKAGE or any(
        metadata.get(key) != [value]
        for key, value in (("os", "linux"), ("cpu", "arm64"), ("libc", "musl"))
    ):
        raise ValueError("Registry package identity or platform does not match")
    expected_tarball = REGISTRY + PACKAGE + "/-/claude-code-linux-arm64-musl-" + version + ".tgz"
    if metadata["dist"]["tarball"] != expected_tarball:
        raise ValueError("Unexpected registry tarball URL")
    integrity = metadata["dist"]["integrity"]
    if not isinstance(integrity, str) or not integrity.startswith("sha512-"):
        raise ValueError("Expected SHA-512 registry integrity")
    try:
        digest = base64.b64decode(integrity[7:], validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("Invalid registry integrity") from error
    if len(digest) != 64 or base64.b64encode(digest).decode("ascii") != integrity[7:]:
        raise ValueError("Invalid registry integrity")
    status = "candidate" if latest_tuple > pinned_tuple else "up_to_date"
    if latest_tuple < pinned_tuple:
        status = "registry_behind_pin"
    return {
        "schema": 1,
        "status": status,
        "pinned_version": pinned,
        "upstream_version": version,
        "package": PACKAGE,
        "metadata_url": LATEST_URL,
        "tarball": expected_tarball,
        "integrity": integrity,
        "compatibility_status": "not_tested",
    }


def marker(version):
    return "<!-- termux-muscle:upstream-claude:" + version + " -->"


def issue_body(report):
    version = report["upstream_version"]
    return f"""{marker(version)}
## Upstream release awaiting compatibility testing

The official ARM64 musl package's `latest` tag was observed at **{version}**.
The checked-out project compatibility pin is **{report['pinned_version']}**.

**Discovery only: no archive downloaded, executable run, compatibility pin changed,
or user installation updated. Registry metadata is not Android acceptance evidence.**

- Package: `{PACKAGE}`
- Metadata: {LATEST_URL}
- Candidate archive: {report['tarball']}
- Registry integrity: `{report['integrity']}`

## Promotion checklist

- [ ] Download using the existing experimental-version acquisition path in a disposable installation; verify archive integrity and obtain the executable SHA-256.
- [ ] Run isolated version/help/initialization acceptance on Android; preserve the working runtime on failure.
- [ ] Run device/workflow acceptance from `docs/testing.md`, including actual shell/file tools and lifecycle recovery; record FAIL/SKIP limits explicitly.
- [ ] Submit a reviewed compatibility PR with the exact source hashes, updated versioned evidence, release metadata and known limits; do not copy old device PASS results.
- [ ] Publish through the existing verified-tag release workflow after review and required checks.

See [release tracking](https://github.com/{REPOSITORY}/blob/main/docs/release-tracking.md)
and [release policy](https://github.com/{REPOSITORY}/blob/main/docs/releasing.md).

Close this issue with the promotion PR or a reason to defer/reject this version.
Closed issues are not reopened by the tracker. Reopen manually to reconsider.
The tracker never overwrites this body or maintainer checkboxes.
"""


def gh_api(arguments, payload=None):
    command = ["gh", "api", "--hostname", "github.com", *arguments]
    if payload is not None:
        command += ["--input", "-"]
    result = subprocess.run(
        command,
        input=json.dumps(payload) if payload is not None else None,
        text=True,
        capture_output=True,
        timeout=120,
        check=False,
    )
    if result.returncode:
        # Do not echo API bodies, credentials, or issue content in error logs.
        raise RuntimeError("GitHub API request failed; inspect Actions permissions and service status")
    return json.loads(result.stdout)


def publish_candidate(report):
    if report["status"] != "candidate":
        return report
    endpoint = f"repos/{REPOSITORY}/issues"
    # Do not use search: its eventual indexing can duplicate a just-created issue.
    pages = gh_api([
        endpoint, "--method", "GET", "-f", "state=all", "-f", "per_page=100",
        "--paginate", "--slurp",
    ])
    if not isinstance(pages, list) or any(not isinstance(page, list) for page in pages):
        raise ValueError("Unexpected issue-list response")
    wanted = marker(report["upstream_version"])
    for page in pages:
        for issue in page:
            if not isinstance(issue, dict) or not isinstance(issue.get("body") or "", str):
                raise ValueError("Unexpected issue response")
            if "pull_request" not in issue and wanted in (issue.get("body") or ""):
                return dict(report, status="already_tracked", issue_url=issue_url(issue))
    created = gh_api([endpoint, "--method", "POST"], {
        "title": f"Test Claude Code {report['upstream_version']} compatibility",
        "body": issue_body(report),
    })
    return dict(report, status="issue_created", issue_url=issue_url(created))


def issue_url(issue):
    number = issue["number"]
    if type(number) is not int or number < 1:
        raise ValueError("Unexpected issue number")
    return f"https://github.com/{REPOSITORY}/issues/{number}"


def summary(report):
    return (
        "## Claude Code release tracking\n\n"
        f"- Result: `{report['status']}`\n"
        f"- Project pin: `{report['pinned_version']}`\n"
        f"- Upstream latest: `{report['upstream_version']}`\n"
        + (f"- Testing issue: {report['issue_url']}\n" if "issue_url" in report else "")
        + "\nDiscovery only; compatibility and installed runtimes are unchanged.\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", type=Path, default=Path("compatibility.json"))
    parser.add_argument("--publish", action="store_true", help="Create a deduplicated testing issue")
    parser.add_argument("--output", type=Path, help="Write the discovery report as JSON")
    parser.add_argument("--summary", type=Path, help="Write a Markdown run summary")
    args = parser.parse_args()
    try:
        report = candidate_from(json.loads(args.manifest.read_text()), fetch_latest())
        if args.publish:
            report = publish_candidate(report)
        rendered = json.dumps(report, indent=2) + "\n"
        if args.output:
            args.output.write_text(rendered)
        if args.summary:
            args.summary.write_text(summary(report))
        print(rendered, end="")
    except (OSError, ValueError, KeyError, TypeError, RuntimeError, subprocess.TimeoutExpired):
        print("Release tracking failed; no compatibility pin or runtime was changed. "
              "Check registry metadata, network access, and GitHub permissions. "
              "If publication timed out, inspect existing issues before retrying.", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
