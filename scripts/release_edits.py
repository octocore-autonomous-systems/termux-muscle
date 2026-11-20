#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Make the mechanical edits of a Termux Muscle release, so only prose is written by hand.

  release_edits.py prepare P [--claude-version X [--claude-integrity SRI --claude-binary-sha256 HEX]]
  release_edits.py register compatibility/reports/acceptance-P-....json [--device-slug SLUG]
  release_edits.py check

prepare sets VERSION, install.sh, the man page date and version, the README install address and
the manifest (project_version, models.verified, reports, verified_on removed, the
acceptance-pending model note and, when --claude-version moves the pin, the claude block and
pin_history). Without --claude-integrity and --claude-binary-sha256 the pin values are read from
npm and from Anthropic's release manifest. The date is today's UTC date.

register moves the acceptance report to compatibility/<device>-P-YYYYMMDD.json, points its
evidence_notes at the matching .md, sets models.verified, reports and verified_on from the report,
and adds the device matrix row. Dates, durations and commits come from the report.

check confirms that the prose written by hand agrees with the registered report: no "pending" left,
every "N ms" equals the measured duration, every cited commit is the report's source commit, and
the report's date appears in each evidence paragraph.

Changelog, release notes, report notes, the README banner, the model availability note and the
device matrix footnote stay hand-written. Each command prints what is left to write.
"""
import argparse
import json
import re
import subprocess
import sys
import urllib.request
from collections import OrderedDict
from datetime import datetime, timezone
from pathlib import Path

NPM = "https://registry.npmjs.org/@anthropic-ai/claude-code-linux-arm64-musl"
ANTHROPIC = "https://downloads.claude.ai/claude-code-releases"
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
SUPERSCRIPT = str.maketrans("0123456789", "⁰¹²³⁴⁵⁶⁷⁸⁹")
FROM_SUPERSCRIPT = str.maketrans("⁰¹²³⁴⁵⁶⁷⁸⁹", "0123456789")


def fail(message):
    sys.exit(f"release_edits: {message}")


def read_json(path):
    return json.loads(Path(path).read_text(), object_pairs_hook=OrderedDict)


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def replace_once(path, pattern, replacement, flags=0):
    text = path.read_text()
    new, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        fail(f"{path}: expected text not found: {pattern}")
    path.write_text(new)


def fetch_json(url):
    with urllib.request.urlopen(url, timeout=60) as response:  # noqa: S310 (fixed https URLs)
        return json.load(response)


def claude_pin(version, integrity, binary_sha256):
    if bool(integrity) != bool(binary_sha256):
        fail("give both --claude-integrity and --claude-binary-sha256, or neither")
    if not integrity:
        dist = fetch_json(f"{NPM}/{version}")["dist"]
        integrity = dist["integrity"]
        binary_sha256 = fetch_json(f"{ANTHROPIC}/{version}/manifest.json")["platforms"]["linux-arm64-musl"]["checksum"]
    if not integrity.startswith("sha512-") or not re.fullmatch(r"[0-9a-f]{64}", binary_sha256):
        fail("the Claude Code integrity must be sha512-… and the binary SHA-256 64 hex digits")
    return OrderedDict([
        ("tarball", f"{NPM}/-/claude-code-linux-arm64-musl-{version}.tgz"),
        ("integrity", integrity),
        ("binary_sha256", binary_sha256),
    ])


def model_note_prefix(note):
    """The documented-minimum sentences that open every availability note."""
    match = re.match(r"(.*? or later\.)\s", note)
    if not match:
        fail("models.availability_note no longer starts with the documented minimum client versions")
    return match.group(1)


def regenerate_readme(root):
    subprocess.run([sys.executable, "-B", str(root / "scripts/readme_compatibility.py")], cwd=root, check=True)


def prepare(root, args):
    version = args.version
    if not VERSION_RE.match(version):
        fail(f"not a version: {version}")
    day = args.date or datetime.now(timezone.utc).date().isoformat()
    manifest_path = root / "compatibility.json"
    manifest = read_json(manifest_path)
    previous = manifest["project_version"]
    if previous == version:
        fail(f"compatibility.json already names {version}")

    (root / "VERSION").write_text(version + "\n")
    replace_once(root / "install.sh", r'^VERSION="[^"]*"', f'VERSION="{version}"', re.M)
    replace_once(root / "docs/man/termux-muscle.1",
                 r'^\.TH TERMUX-MUSCLE 1 "[^"]*" "Termux Muscle [^"]*"',
                 f'.TH TERMUX-MUSCLE 1 "{day}" "Termux Muscle {version}"', re.M)
    replace_once(root / "README.md", r"releases/download/v[0-9.]+/install\.sh",
                 f"releases/download/v{version}/install.sh")

    claude = manifest["claude"]
    if args.claude_version and args.claude_version != claude["version"]:
        if not VERSION_RE.match(args.claude_version):
            fail(f"not a Claude Code version: {args.claude_version}")
        if "verified_on" not in manifest or not manifest["reports"]:
            fail("the outgoing pin has no registered acceptance to record in pin_history")
        manifest["pin_history"].append(OrderedDict([
            ("version", claude["version"]),
            ("project_versions", OrderedDict([("first", claude["pinned_since"]), ("last", previous)])),
            ("verified_on", manifest["verified_on"]),
            ("report", manifest["reports"][-1]),
        ]))
        claude["version"] = args.claude_version
        claude["pinned_since"] = version
        claude.update(claude_pin(args.claude_version, args.claude_integrity, args.claude_binary_sha256))
    elif args.claude_integrity or args.claude_binary_sha256:
        fail("--claude-integrity and --claude-binary-sha256 need a new --claude-version")

    manifest["project_version"] = version
    models = manifest["models"]
    models["verified"] = []
    models["availability_note"] = (
        f"{model_note_prefix(models['availability_note'])} Model acceptance for {version} is pending. "
        "Earlier reports retain their dated results for their own project and client versions. "
        "Model availability depends on account, provider and organization policy.")
    manifest["reports"] = []
    manifest.pop("verified_on", None)
    write_json(manifest_path, manifest)
    notes = root / f"docs/releases/{version}.md"
    if notes.exists():
        regenerate_readme(root)
    print(f"Prepared {version} (Claude Code pin {claude['version']}, dated {day}).")
    print("Write by hand: CHANGELOG.md '## " + version + "' ending 'Fresh device and authenticated tool "
          "acceptance for this release is pending.', docs/releases/" + version + ".md, and the README "
          "banner; then run scripts/readme_compatibility.py"
          + (" again." if notes.exists() else ", which needs the release notes."))


def device_slug(environment):
    name = environment["device_name"].lower()
    maker = environment.get("manufacturer", "").lower()
    if maker and name.startswith(maker + " "):
        name = name[len(maker) + 1:]
    slug = re.sub(r"[^a-z0-9]+", "-", name).strip("-")
    if not slug:
        fail("the report names no device; pass --device-slug")
    return slug


def matrix_row(version, day, report, base, note):
    environment = report["environment"]
    status = {check["id"]: check["status"] for check in report["checks"]}

    def cell(*ids):
        values = [status.get(i) for i in ids]
        if any(v is None for v in values):
            return "—"
        if all(v == "PASS" for v in values):
            return "PASS"
        return "FAIL" if "FAIL" in values else "SKIP"

    source = "GitHub" if environment["termux_source"].upper() == "GITHUB" else environment["termux_source"]
    configuration = (f"**{version}, {day} UTC** · {environment['device_name']} · {environment['model']} · "
                     f"Android {environment['android_version']} / API {environment['android_api']} · "
                     f"Termux {environment['termux_version']} ({source})")
    cells = [cell("install") + str(note).translate(SUPERSCRIPT),
             cell("startup_version", "startup_help", "startup_init"), cell("namespace_shell"),
             cell("shell_tools"), cell("manual"), cell("update"), cell("rollback"), cell("uninstall")]
    evidence = f"[Maintainer report](../compatibility/{base}.md) · [JSON](../compatibility/{base}.json)"
    return "| " + " | ".join([configuration] + cells + [evidence]) + " |"


def add_matrix_row(root, version, day, report, base):
    path = root / "docs/device-compatibility.md"
    text = path.read_text()
    if f"**{version}, " in text:
        fail(f"{path.name} already has a {version} row")
    numbers = [int(n.translate(FROM_SUPERSCRIPT)) for n in re.findall(r"^([⁰¹²³⁴⁵⁶⁷⁸⁹]+) ", text, flags=re.M)]
    note = max(numbers, default=0) + 1
    lines = text.split("\n")
    header = next((i for i, line in enumerate(lines) if line.startswith("| --- |")), None)
    if header is None:
        fail(f"{path.name} has no matrix table")
    lines.insert(header + 1, matrix_row(version, day, report, base, note))
    path.write_text("\n".join(lines))
    return note


def register(root, args):
    source = Path(args.report)
    if not source.is_absolute():
        source = root / source
    report = read_json(source)
    manifest_path = root / "compatibility.json"
    manifest = read_json(manifest_path)
    version = manifest["project_version"]
    if report["project"]["version"] != version or report["claude_code"]["version"] != manifest["claude"]["version"]:
        fail("the report's Termux Muscle or Claude Code version does not match compatibility.json")
    if report["source"].get("uncommitted_changes") is not False:
        fail("the report was not made from a clean commit")
    generated = report["generated_at"]
    day = generated[:10]
    base = f"{args.device_slug or device_slug(report['environment'])}-{version}-{day.replace('-', '')}"
    target = root / "compatibility" / f"{base}.json"
    if target.exists():
        fail(f"{target.relative_to(root)} already exists")
    report["evidence_notes"] = f"{base}.md"
    write_json(target, report)
    source.unlink()
    if source.parent.name == "reports" and not any(source.parent.iterdir()):
        source.parent.rmdir()

    manifest["models"]["verified"] = [
        model["requested"] for model in report["models"]
        if model["status"] == "PASS" and model.get("observed") == [model["requested"]]]
    manifest["reports"] = [f"compatibility/{base}.json"]
    manifest["verified_on"] = day
    write_json(manifest_path, manifest)
    note = add_matrix_row(root, version, day, report, base)
    regenerate_readme(root)
    capture = report.get("authenticated_workflow", {}).get("capture", {})
    print(f"Registered compatibility/{base}.json: {day}, source commit {report['source']['commit'][:7]}, "
          f"tool workflow {capture.get('elapsed_ms', 'not measured')} ms, "
          f"verified models {', '.join(manifest['models']['verified']) or 'none'}.")
    print(f"Write by hand, copying those values: compatibility/{base}.md, the CHANGELOG evidence paragraph, "
          f"the device evidence in docs/releases/{version}.md, the README banner, models.availability_note "
          f"and footnote {str(note).translate(SUPERSCRIPT)} in docs/device-compatibility.md. "
          "Then run: release_edits.py check")


def section(text, heading):
    match = re.search(rf"^## {re.escape(heading)}\n(.*?)(?=^## |\Z)", text, flags=re.M | re.S)
    return match.group(1) if match else ""


def check(root, _args):
    manifest = read_json(root / "compatibility.json")
    version = manifest["project_version"]
    if not manifest.get("reports"):
        fail(f"{version} has no registered report yet")
    report = read_json(root / manifest["reports"][-1])
    day = report["generated_at"][:10]
    commit = report["source"]["commit"]
    elapsed = report.get("authenticated_workflow", {}).get("capture", {}).get("elapsed_ms")
    notes = root / "compatibility" / report["evidence_notes"]
    matrix = (root / "docs/device-compatibility.md").read_text()
    row = next((line for line in matrix.split("\n") if line.startswith(f"| **{version}, ")), "")
    note = re.search(r"PASS([⁰¹²³⁴⁵⁶⁷⁸⁹]+)", row)
    banner = next((line for line in (root / "README.md").read_text().split("\n") if line.startswith("> **")), "")
    prose = {
        "CHANGELOG.md": section((root / "CHANGELOG.md").read_text(), version),
        f"docs/releases/{version}.md": (root / f"docs/releases/{version}.md").read_text()
        if (root / f"docs/releases/{version}.md").exists() else "",
        str(notes.relative_to(root)): notes.read_text() if notes.exists() else "",
        "README.md banner": banner,
        "models.availability_note": manifest["models"]["availability_note"],
        "device matrix footnote": next((line for line in matrix.split("\n")
                                        if note and line.startswith(note.group(1) + " ")), ""),
    }
    problems = []
    for name, text in prose.items():
        if not text:
            problems.append(f"{name}: missing")
            continue
        if re.search(r"\bpending\b", text, flags=re.I):
            problems.append(f"{name}: still says pending")
        dated = day in text or day.replace("-", "") in text
        if not dated and name not in ("README.md banner", "device matrix footnote"):
            problems.append(f"{name}: does not give the report's date {day}")
        for value in re.findall(r"(\S+) ms\b", text):
            if value.strip("*`") != str(elapsed):
                problems.append(f"{name}: '{value} ms' differs from the measured {elapsed} ms")
        for cited in re.findall(r"commit[^`\n]{0,40}`([0-9a-f]{7,40})`", text):
            if not commit.startswith(cited):
                problems.append(f"{name}: commit {cited} is not the report's source commit {commit[:7]}")
    if problems:
        print("\n".join(problems), file=sys.stderr)
        fail(f"{len(problems)} problem(s) in the release prose")
    print(f"Release prose agrees with compatibility/{notes.stem}.json ({day}, {commit[:7]}, {elapsed} ms).")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", default=Path(__file__).resolve().parent.parent, type=Path,
                        help="repository root (default: this script's repository)")
    commands = parser.add_subparsers(dest="command", required=True)
    p = commands.add_parser("prepare", help="the preparation commit's mechanical edits")
    p.add_argument("version")
    p.add_argument("--claude-version", help="move the tested pin to this Claude Code release")
    p.add_argument("--claude-integrity", help="npm SHA-512 integrity (default: read from npm)")
    p.add_argument("--claude-binary-sha256", help="linux-arm64-musl checksum (default: read from Anthropic)")
    p.add_argument("--date", help=argparse.SUPPRESS)  # tests only: a release is dated today, UTC
    r = commands.add_parser("register", help="the registration commit's mechanical edits")
    r.add_argument("report", help="the acceptance report under compatibility/reports/")
    r.add_argument("--device-slug", help="file name prefix (default: from the report's device name)")
    commands.add_parser("check", help="compare the release prose with the registered report")
    args = parser.parse_args(argv)
    {"prepare": prepare, "register": register, "check": check}[args.command](args.root.resolve(), args)


if __name__ == "__main__":
    main()
