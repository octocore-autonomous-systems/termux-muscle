#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Maintainer release helper: write the preparation edits for release P pinning Claude Code X.

Run from the root of the release worktree (a clean checkout of origin/main on release/P):

    python3 -B scripts/release_prepare.py P X INTEGRITY BINARY_SHA256 WHY_FILE [--date YYYY-MM-DD]

WHY_FILE holds the one-paragraph "Why" text for docs/releases/P.md (summarise the upstream
release notes by hand; it must start with the linked version). Everything about the outgoing
pin is read from the tree, so nothing else is typed. The script refuses to run if any anchor
it expects is missing, and it never commits.
"""
import argparse
import datetime
import json
import pathlib
import re
import sys

ap = argparse.ArgumentParser()
ap.add_argument("P")
ap.add_argument("X")
ap.add_argument("integrity")
ap.add_argument("binary_sha256")
ap.add_argument("why_file")
ap.add_argument("--date", default=datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d"))
a = ap.parse_args()
P, X = a.P, a.X


def die(msg):
    sys.exit(f"release_prepare: {msg}")


def sub1(path, old, new, regex=False):
    p = pathlib.Path(path)
    s = p.read_text()
    n = len(re.findall(old, s, flags=re.M)) if regex else s.count(old)
    if n != 1:
        die(f"{path}: expected exactly one match for {old!r}, found {n}")
    s = re.sub(old, lambda m: new, s, flags=re.M) if regex else s.replace(old, new)
    p.write_text(s)


if not re.fullmatch(r"sha512-[A-Za-z0-9+/]+=*", a.integrity) or not re.fullmatch(r"[0-9a-f]{64}", a.binary_sha256):
    die("integrity must be sha512-<base64> and binary_sha256 must be 64 hex characters")

raw = pathlib.Path("compatibility.json").read_text()
c = json.loads(raw)
if json.dumps(c, indent=2, ensure_ascii=False) + "\n" != raw:
    die("compatibility.json does not round-trip; edit it by hand")
prevP = pathlib.Path("VERSION").read_text().strip()
prevX = c["claude"]["version"]
since = c["claude"].get("pinned_since", prevP)
if c["project_version"] != prevP or not c.get("reports") or "verified_on" not in c:
    die("tree is not a registered release (project_version, reports or verified_on missing)")
if prevP == P or prevX == X:
    die(f"tree already at {prevP} / {prevX}")
prev_report = c["reports"][0]
prev_md = prev_report[:-5] + ".md"
why = pathlib.Path(a.why_file).read_text().strip()
if X not in why or "\n" in why:
    die("WHY_FILE must be one paragraph that names the new version")
pinned_by = f"**{prevP}**" if since == prevP else f"**{since}** through **{prevP}**"

# VERSION, installer, manual
pathlib.Path("VERSION").write_text(P + "\n")
sub1("install.sh", f'VERSION="{prevP}"', f'VERSION="{P}"')
sub1("docs/man/termux-muscle.1", r'^\.TH TERMUX-MUSCLE 1 "[0-9-]+" "Termux Muscle [0-9.]+"',
     f'.TH TERMUX-MUSCLE 1 "{a.date}" "Termux Muscle {P}"', regex=True)

# compatibility.json
c["project_version"] = P
c["claude"].update(version=X, pinned_since=P, integrity=a.integrity, binary_sha256=a.binary_sha256,
                   tarball=c["claude"]["tarball"].replace(prevX, X))
if X not in c["claude"]["tarball"]:
    die("tarball URL did not pick up the new version")
c["pin_history"].append({"version": prevX, "project_versions": {"first": since, "last": prevP},
                         "verified_on": c["verified_on"], "report": prev_report})
c["models"]["verified"] = []
note = c["models"]["availability_note"]
head = re.match(r"(.*? Opus 5\.5 requires [0-9.]+ or later\. )", note)
if not head:
    die("availability_note has no recognisable opening")
c["models"]["availability_note"] = (
    head.group(1) + f"Model acceptance for {P} is pending. Earlier reports retain their dated results for "
    "their own project and client versions. Model availability depends on account, provider and organization policy.")
c["reports"] = []
del c["verified_on"]
pathlib.Path("compatibility.json").write_text(json.dumps(c, indent=2, ensure_ascii=False) + "\n")

# CHANGELOG
sub1("CHANGELOG.md", "# Changes\n\n", f"""# Changes

## {P}

- Move the default pin from Claude Code **{prevX}** to **{X}**, the current upstream release. Record the official ARM64 musl npm tarball, its registry SHA-512 integrity and the extracted executable SHA-256, independently checked against the downloaded archive. The vendor payload is unmodified; musl stays at **{c['musl']['version']}**.
- Preserve **{prevX}** in `pin_history` as formerly pinned by {pinned_by}, backed by the {prevP} maintainer report; set `claude.pinned_since` to **{P}**.

Fresh device and authenticated tool acceptance for this release is pending.

""")

# Release notes
pathlib.Path(f"docs/releases/{P}.md").write_text(f"""# Termux Muscle {P}

The default Claude Code pin moves from **{prevX}** to **{X}**. Musl stays at **{c['musl']['version']}**. The official vendor executable is unmodified; the npm archive integrity and extracted binary digest are recorded in `compatibility.json`.

## Why

{why}

## Pin history

Claude Code **{prevX}** is retained as formerly pinned by Termux Muscle {pinned_by}, using the [{prevP} maintainer report](../../{prev_md}). The current pin starts with **{P}**. Earlier history is unchanged.

## Device evidence

Fresh device and authenticated tool acceptance is pending. This preparation does not assert verification for {P}.

## Updating an existing installation

After this release is published, run from a native Termux shell:

```sh
termux-muscle self-update
termux-muscle update
claude --version
```

The final command should report `{X} (Claude Code)`. A previous validated runtime remains available through `termux-muscle rollback`.

## Known limitations

Acceptance covers one device and configuration. Interactive UI, background and screen-off operation, custom hooks, MCP tool calls, and other models require separate evidence. Documented model minimums and account entitlements are unchanged. Installing any version other than the current pin still requires `--allow-unverified`.

Termux Muscle is an independent OAS community project, unaffiliated with Anthropic. Source is MPL-2.0; Claude Code and downloaded dependencies retain their own licenses and terms.
""")

# README
sub1("README.md", rf"^> \*\*{re.escape(prevP)} pins Claude Code {re.escape(prevX)}\*\*.*$",
     f"> **{P} prepares the Claude Code {X} pin** on Android **ARM64 / aarch64**. Fresh device and authenticated tool acceptance is pending; earlier release reports retain their original scope.",
     regex=True)
sub1("README.md", f"releases/download/v{prevP}/install.sh", f"releases/download/v{P}/install.sh")
sub1("README.md", f"**{prevP}** moves the pin to **Claude Code {prevX}**;",
     f"**{P}** moves the pin to **Claude Code {X}**; **{prevP}** moved it to **{prevX}**;")

print(f"prepared {P} with Claude Code {X} (outgoing: {prevP} with {prevX}, pinned since {since})")
