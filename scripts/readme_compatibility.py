#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Generate README's release and model tables from the compatibility manifest.

Run from the repository root; --check verifies without writing. This maintainer
helper uses only Python's standard library and is never run by installation.
"""
import argparse
import json
from pathlib import Path
import re
import sys

START = "## Claude Code and models\n"
END = "## Help build something dependable\n"


def version_key(version):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
        raise ValueError(f"expected a numeric release version, got {version!r}")
    return tuple(int(part) for part in version.split("."))


def release_pins(root, manifest):
    versions = [path.stem for path in (root / "docs/releases").glob("*.md")]
    keys = {version: version_key(version) for version in versions}
    current = manifest["project_version"]
    if current not in keys:
        raise ValueError(f"missing release notes for {current}")
    ranges = [(item["project_versions"]["first"], item["project_versions"]["last"], item["version"])
              for item in manifest["pin_history"]]
    ranges.append((manifest["claude"]["pinned_since"], current, manifest["claude"]["version"]))
    for first, last, pin in ranges:
        if first not in keys or last not in keys or version_key(first) > version_key(last):
            raise ValueError(f"invalid or incomplete pin range {first} through {last}")
        version_key(pin)
    rows = []
    for version, key in keys.items():
        pins = [pin for first, last, pin in ranges if version_key(first) <= key <= version_key(last)]
        if len(pins) != 1:
            raise ValueError(f"release {version} has {len(pins)} matching pin ranges; expected one")
        rows.append((version, pins[0]))
    return sorted(rows, key=lambda row: (version_key(row[1]), version_key(row[0])))


def model_minimums(manifest, releases):
    rows = []
    for model in manifest["models"]["documented"]:
        minimum = model["minimum_claude_version"]
        eligible = [version for version, pin in releases if version_key(pin) >= version_key(minimum)]
        first = min(eligible, key=version_key) if eligible else None
        rows.append((model, first))
    return sorted(rows, key=lambda row: (version_key(row[0]["minimum_claude_version"]),
                                        version_key(row[1]) if row[1] else (sys.maxsize,) * 3,
                                        row[0]["name"]))


def render_section(root):
    manifest = json.loads((root / "compatibility.json").read_text())
    releases = release_pins(root, manifest)
    models = model_minimums(manifest, releases)
    lines = [START.rstrip(), "",
             "Termux Muscle and Claude Code have independent version numbers. Each Termux Muscle release is device-tested with one Claude Code version, its pin; `termux-muscle update` moves beyond the pin to any release Anthropic has signed.",
             "", "| Termux Muscle version | Pinned Claude Code version |", "| --- | --- |"]
    for version, pin in releases:
        lines.append(f"| [{version}](docs/releases/{version}.md) | {pin} |")
    lines.extend(["",
                  f"The [compatibility manifest](compatibility.json) records the current pin and pin history; `termux-muscle versions --available` identifies formerly pinned clients. The musl loader remains **{manifest['musl']['version']}**.",
                  "",
                  "Model minimums describe client requirements. The Termux Muscle minimum is derived from the earliest release whose pin meets that requirement; it does not establish the model's introduction date or device verification. **—** means no listed release meets the requirement.",
                  "",
                  "| Model | Model ID | Claude Code min. version | Termux Muscle min. version |",
                  "| --- | --- | --- | --- |"])
    for model, first in models:
        termux = f"[{first}](docs/releases/{first}.md)" if first else "—"
        lines.append(f"| {model['name']} | `{model['id']}` | {model['minimum_claude_version']} | {termux} |")
    metadata = manifest["models"]
    lines.extend(["", f"Model requirements were documented on **{metadata['checked_documentation_on']}** against [Anthropic's model configuration documentation]({metadata['source']}). Availability depends on your account, provider and organization policy; a newer client does not grant model access."])
    if metadata["verified"] and manifest.get("reports"):
        names = {model["id"]: model["name"] for model in metadata["documented"]}
        verified = ", ".join(names[model] for model in metadata["verified"])
        report = str(Path(manifest["reports"][0]).with_suffix(".md"))
        lines.extend(["", f"**{verified}** passed authenticated tool acceptance with Termux Muscle **{manifest['project_version']}** and Claude Code **{manifest['claude']['version']}** on **{manifest['verified_on']}** ([scoped report]({report})). Other listed models are not verified by that report."])
    else:
        lines.extend(["", f"Model acceptance for **{manifest['project_version']}** is pending; the tables do not assert verification for this release."])
    lines.extend(["", "Earlier measurements, including mixed Fable observations, retain their dated scope in the [device compatibility reports](docs/device-compatibility.md).", "", ""])
    return "\n".join(lines)


def update_readme(root, check=False):
    path = root / "README.md"
    original = path.read_text()
    if original.count(START) != 1 or original.count(END) != 1:
        raise ValueError("README must contain one Claude Code and models section and following help section")
    start, end = original.index(START), original.index(END)
    if start >= end:
        raise ValueError("README section headings are out of order")
    updated = original[:start] + render_section(root) + original[end:]
    if check:
        if updated != original:
            raise ValueError("README compatibility tables are stale; run python3 -B scripts/readme_compatibility.py")
    elif updated != original:
        path.write_text(updated)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="verify README without writing")
    arguments = parser.parse_args()
    try:
        update_readme(Path.cwd(), check=arguments.check)
    except (ValueError, KeyError, OSError) as error:
        parser.exit(1, f"readme_compatibility: {error}\n")


if __name__ == "__main__":
    main()
