#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Maintainer release helper: register the maintainer acceptance report for release P.

Run from the root of the release worktree, after the preparation commit and a passing
`make check` + `scripts/maintainer_acceptance.sh` from that clean commit:

    python3 -B scripts/release_register.py [--tests 15]

It finds the single report under compatibility/reports/, renames it to the device-and-date
convention, writes its .md notes, and fills compatibility.json, README, CHANGELOG and the
release notes. Every number comes from the report or the tree. It assumes a pin-only release
(no harness code changed), the Galaxy S26 Ultra, an Opus 5.5 model check, and the same two
deterministic-suite skips as 0.12.0-0.15.0 (runtime host probes, cross-UID fixture): check
make-check.log for exactly those SKIP lines first, and edit the prose by hand if any of that
differs. It refuses to run if an anchor is missing, and it never commits.
"""
import argparse
import glob
import json
import pathlib
import re
import subprocess
import sys

ap = argparse.ArgumentParser()
ap.add_argument("--tests", type=int, default=15, help="test programs reported by make check")
a = ap.parse_args()
MODEL, MODEL_NAME, SLUG = "claude-opus-5-5", "Opus 5.5", "galaxy-s26-ultra"


def die(msg):
    sys.exit(f"release_register: {msg}")


def sub1(path, old, new, regex=False):
    p = pathlib.Path(path)
    s = p.read_text()
    n = len(re.findall(old, s, flags=re.M)) if regex else s.count(old)
    if n != 1:
        die(f"{path}: expected exactly one match for {old!r}, found {n}")
    s = re.sub(old, lambda m: new, s, flags=re.M) if regex else s.replace(old, new)
    p.write_text(s)


reports = glob.glob("compatibility/reports/acceptance-*.json")
if len(reports) != 1:
    die(f"expected one report in compatibility/reports/, found {len(reports)}")
r = json.loads(pathlib.Path(reports[0]).read_text())
c = json.loads(pathlib.Path("compatibility.json").read_text())
P, X = c["project_version"], c["claude"]["version"]
head = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
aw, env = r["authenticated_workflow"], r["environment"]
if r["project"]["version"] != P or r["claude_code"]["version"] != X:
    die("report is for a different project or Claude Code version")
if r["source"]["commit"] != head or r["source"]["uncommitted_changes"]:
    die("report was not generated from a clean checkout of HEAD")
if c["reports"] or c["models"]["verified"] or "verified_on" in c:
    die("compatibility.json is not in the prepared (pending) state")
if not any(m.get("requested") == MODEL and m.get("status") == "PASS" for m in r["models"]):
    die(f"report has no PASS for {MODEL}")
if not (aw["final_success"] and aw["capture"]["exit_code"] == 0 and not aw["capture"]["timeout"]):
    die("authenticated workflow did not succeed")
if env["device_name"] != "Samsung Galaxy S26 Ultra":
    die("device is not the Galaxy S26 Ultra; write the evidence prose by hand")

date = r["generated_at"][:10]
base = f"compatibility/{SLUG}-{P}-{date.replace('-', '')}"
last = c["pin_history"][-1]
prevX, prevP, since = last["version"], last["project_versions"]["last"], last["project_versions"]["first"]
pinned_by = prevP if since == prevP else f"{since} through {prevP}"
ms = aw["capture"]["elapsed_ms"]
short = head[:7]
android = f"Android {env['android_version']} / API {env['android_api']}"
src = env["termux_source"]
src = "GitHub" if src == "GITHUB" else src
termux = f"Termux {env['termux_version']}"
musl = c["musl"]["version"]
sha = c["claude"]["binary_sha256"]
budget = f"${aw['maximum_budget_usd']:.2f}"
prev = json.loads(subprocess.check_output(["git", "show", "HEAD~1:compatibility.json"], text=True))
if prev["project_version"] != prevP:
    die("HEAD~1 is not the previous registered release")

# report + notes
text = pathlib.Path(reports[0]).read_text()
old_notes = f'"evidence_notes": "{r["evidence_notes"]}"'
if text.count(old_notes) != 1:
    die("evidence_notes line not found in report")
pathlib.Path(base + ".json").write_text(text.replace(old_notes, f'"evidence_notes": "{SLUG}-{P}-{date.replace("-", "")}.md"'))
pathlib.Path(reports[0]).unlink()
try:
    pathlib.Path("compatibility/reports").rmdir()
except OSError:
    pass
pathlib.Path(base + ".md").write_text(f"""# Galaxy S26 Ultra acceptance: Termux Muscle {P}

Verified {date} UTC on {env['device_name']} ({env['model']}), {android}, {termux} from {src}. The [JSON report]({SLUG}-{P}-{date.replace('-', '')}.json) records the exact kernel, page size, package versions, check results and sanitized workflow metadata. The unmodified payload is Claude Code **{X}** with musl **{musl}**. The report was generated at **{r['generated_at']}** by `scripts/maintainer_acceptance.sh` from a clean checkout of source commit **`{head}`** (`source.uncommitted_changes: false`). Only the report's relative `evidence_notes` filename was adjusted when registering it; measured results are unchanged.

Immediately before acceptance, `make check` ran from the same checkout in an untraced native Termux shell. All **{a.tests} C and shell test programs passed**, including pin history and release-gate regressions. The optional runtime host-probe group was skipped without `TM_RUNTIME_HOST_PROBES=1`; real vendor startup and namespace checks passed separately during acceptance. The cross-UID executable tooling fixture was skipped because no readable Bash executable owned by another UID was available.

A private source bootstrap with `--no-link` passed isolated version, help and initialization checks and activated pinned {X}. An offline update activated a fresh candidate from the verified cache, rollback restored the previous candidate offline, and uninstall removed the owned root. Local diagnostics passed runtime integrity, DNS configuration, command link and namespace checks. The live installation's commands, manual, completion and state records were fingerprinted before and after and were unchanged.

The authenticated workflow recorded at **{aw['generated_at']}** used the private runtime with only the Bash tool available. **{MODEL_NAME}** (`{MODEL}`) made exactly one Bash call on a nonce fixture using a portable shebang and `rg`. The script matched the successful tool result, fixture attestation and final response. Every assistant message came from exactly `{MODEL}`. Capture exited 0 in **{ms} ms**, without timeout, under a **{budget} API budget cap**. Raw events and session identifiers were not retained in the public report.

The official npm archive's SHA-512 was independently verified before promotion, and fresh extraction reproduced the executable SHA-256 `{sha}` recorded in `compatibility.json`. Separately, the live installation on the same device ran {X} through the manager's unverified-version acquisition and startup path and passed `termux-muscle test --model {MODEL}` before this release was prepared. The outgoing {prevX} pin is preserved as formerly pinned by {pinned_by}, backed by the {prevP} maintainer report.

Ordinary command takeover, indexed manual discovery, public HTTPS installer delivery, interactive UI, background/screen-off operation, custom hooks, MCP tool calls and other models were not exercised by this acceptance run. The lifecycle update/rollback checks create and switch local candidates of the new pin; they do not by themselves prove a cross-version upgrade. Earlier reports retain their dated scope. Public delivery can be tested only after publication.
""")

# compatibility.json
m = re.match(r"(.*?)Opus 5\.5 passed an exact authenticated Bash-tool workflow on \S+ with \S+ on the \S+ pin on "
             r"the reported Galaxy S26 Ultra\. Earlier (.*)$", prev["models"]["availability_note"])
if not m:
    die("previous availability_note has an unexpected shape")
c["models"]["verified"] = [MODEL]
c["models"]["availability_note"] = (
    f"{m.group(1)}Opus 5.5 passed an exact authenticated Bash-tool workflow on {date} with {P} on the {X} pin on "
    f"the reported Galaxy S26 Ultra. Earlier {prevP} checks on {prevX}, {m.group(2)}")
c["reports"] = [base + ".json"]
c["verified_on"] = date
pathlib.Path("compatibility.json").write_text(json.dumps(c, indent=2, ensure_ascii=False) + "\n")

# README
readme = pathlib.Path("README.md").read_text()
row = re.search(rf"^\| \*\*{re.escape(prevP)}, .*?PASS([⁰¹²³⁴-⁹]+) .*$", readme, flags=re.M)
if not row:
    die("README: previous device matrix row not found")
sup = "⁰¹²³⁴⁵⁶⁷⁸⁹"
n = int("".join(str(sup.index(ch)) for ch in row.group(1))) + 1
mark = "".join(sup[int(d)] for d in str(n))
sub1("README.md", rf"^> \*\*{re.escape(P)} prepares the Claude Code {re.escape(X)} pin\*\*.*$",
     f"> **{P} pins Claude Code {X}** on Android **ARM64 / aarch64** and preserves {prevX} as formerly pinned by {pinned_by}. Private source installation, startup, update, rollback, removal and an authenticated **{MODEL_NAME}** tool workflow passed on **{env['device_name']}, Android {env['android_version']}, {termux} ({src})**. See the scoped [{P} report]({base}.md); other configurations need volunteer evidence.",
     regex=True)
sub1("README.md", row.group(0),
     f"| **{P}, {date} UTC** · {env['device_name']} · {env['model']} · {android} · {termux} ({src}) | PASS{mark} | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report]({base}.md) · [JSON]({base}.json) |\n" + row.group(0))
foot = re.search(rf"^{row.group(1)} Version {re.escape(prevP)} .*$", pathlib.Path("README.md").read_text(), flags=re.M)
if not foot:
    die("README: previous footnote not found")
sub1("README.md", foot.group(0),
     f"{mark} Version {P} moves the pin to Claude Code {X} and retains {prevX} in pin history. All {a.tests} test programs passed in a native Termux shell; optional host probes and the unavailable cross-UID executable fixture were skipped as detailed in the report. Acceptance ran from a clean checkout and verified {MODEL_NAME} on the new pin, with the live installation unchanged. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.\n\n" + foot.group(0))
anchor = "it is documented, not verified. Opus 5.5 passed exact authenticated tool acceptance with "
sub1("README.md", anchor, f"{anchor}{P} on the {X} pin on {date} UTC, with ")

# CHANGELOG
sub1("CHANGELOG.md", "Fresh device and authenticated tool acceptance for this release is pending.\n",
     f"""- Verify **{MODEL_NAME}** on the new pin with an exact authenticated Bash-tool fixture.

[Galaxy S26 Ultra evidence from {date} UTC]({base}.md) covers all {a.tests} test programs and fresh maintainer acceptance from clean commit `{short}`, with install, isolated startup, authenticated tools, offline update/rollback and removal passing. The live installation was unchanged. Optional runtime host probes and the unavailable cross-UID fixture were skipped in the deterministic suite; real vendor startup and namespace checks passed in acceptance. Claude Code {X} exposed no Termux Muscle defects, so this release changes no harness code.
""")

# release notes
sub1(f"docs/releases/{P}.md",
     f"Fresh device and authenticated tool acceptance is pending. This preparation does not assert verification for {P}.\n",
     f"""[Fresh device evidence](../../{base}.md) from {env['device_name']}, {android}, {termux} ({src}) records all **{a.tests} C and shell test programs passing** in a native shell and acceptance from clean commit `{short}`. Private source install, isolated version/help/init, shell namespace, offline update and rollback, and uninstall passed with the live installation unchanged.

One bounded authenticated **{MODEL_NAME}** (`{MODEL}`) request produced exactly one successful Bash-tool fixture call, verifying native shell, portable shebang and ripgrep. The exact model was observed; capture exited 0 in {ms} ms.

The optional runtime host probes and unavailable cross-UID executable fixture were skipped in the deterministic suite; real vendor startup and namespace checks passed separately during acceptance. Public HTTPS delivery and command/manual takeover were not retested. Sonnet 5.5 and Fable 5.1 remain documented, not verified. Claude Code {X} exposed no Termux Muscle defects; this release changes no harness code.
""")

print(f"registered {base}.json (generated {r['generated_at']}, workflow {aw['generated_at']}, {ms} ms, commit {short}, footnote {n})")
