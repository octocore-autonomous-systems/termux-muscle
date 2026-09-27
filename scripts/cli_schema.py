#!/usr/bin/env python3
"""Generate the runtime Bash CLI contract from one argparse definition.

Python is a contributor tool here. Installed Termux Muscle uses the generated
Bash files and does not need a Python runtime.
"""
from __future__ import annotations

import argparse
import difflib
import functools
import pathlib
import shlex
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "lib/cli_schema.sh"
COMPLETION = ROOT / "docs/completions/termux-muscle.sh"
# Generated help must not depend on the terminal: argparse otherwise sizes it
# from COLUMNS, and Python 3.14 may add color when stdout is a terminal.
FORMAT = {"formatter_class": functools.partial(argparse.HelpFormatter, width=78)}
if sys.version_info >= (3, 14):
    FORMAT["color"] = False


def parser() -> tuple[argparse.ArgumentParser, dict[str, argparse.ArgumentParser]]:
    root = argparse.ArgumentParser(
        prog="termux-muscle",
        description="Install, run and maintain Claude Code on Termux.",
        epilog=(
            "Install/update: --claude-version X.Y.Z|latest with --allow-unverified "
            "requests an upstream release beyond the project pin. Repair/update "
            "--offline uses verified cached artifacts. Test --model permits an "
            "authenticated model request. Self-update exits 0 when installed, "
            "2 when current, 3 for an older target, and 1 on failure. "
            "Use --force to reinstall or compatibly downgrade. By default, "
            "self-update shows one progress dot per completed test program; "
            "--verbose streams the full log and --json includes its full bounded "
            "transcript. This independent OAS project is not affiliated with "
            "or authorized by Anthropic. Full manual: man termux-muscle."
        ),
        allow_abbrev=False,
        **FORMAT,
    )
    root.add_argument("--root", metavar="DIR", help="managed installation root")
    root.add_argument("--prefix", metavar="DIR", help="native Termux package prefix")
    root.add_argument("--version", action="store_true", help="print manager version")
    sub = root.add_subparsers(dest="command", metavar="COMMAND")
    commands: dict[str, argparse.ArgumentParser] = {}

    def command(name: str, summary: str) -> argparse.ArgumentParser:
        p = sub.add_parser(name, help=summary, description=summary, allow_abbrev=False,
                           add_help=name != "run", **FORMAT)
        if name != "run":
            p.add_argument("--root", metavar="DIR", help="managed installation root")
            p.add_argument("--prefix", metavar="DIR", help="native Termux package prefix")
        commands[name] = p
        return p

    command("help", "Show the manager command overview.")
    p = command("install", "Install the pinned Claude Code runtime and set up claude on PATH.")
    p.add_argument("--claude-version", metavar="X.Y.Z|latest", help="select an upstream version")
    p.add_argument("--allow-unverified", action="store_true", help="permit a version beyond the project pin")
    p.add_argument("--offline", action="store_true", help="use verified cached archives")
    p.add_argument("--no-link", action="store_true", help="preserve existing Claude command entries")
    p = command("run", "Run Claude Code and forward all following arguments unchanged.")
    p.usage = "termux-muscle run [--] CLAUDE_ARGUMENTS..."
    p.add_argument("claude_arguments", nargs=argparse.REMAINDER, metavar="CLAUDE_ARGUMENTS")
    p = command("update", "Validate a runtime candidate before changing the active release.")
    p.add_argument("--claude-version", metavar="X.Y.Z|latest", help="select an upstream version")
    p.add_argument("--allow-unverified", action="store_true", help="permit a version beyond the project pin")
    p.add_argument("--offline", action="store_true", help="use verified cached archives")
    command("rollback", "Restore the previous validated runtime release.")
    p = command("repair", "Rebuild the current runtime from verified original artifacts.")
    p.add_argument("--offline", action="store_true", help="use verified cached archives")
    p = command("versions", "Show current, previous and retained runtime releases.")
    p.add_argument("--json", action="store_true", help="print machine readable state")
    p = command("doctor", "Check local installation health without model requests.")
    p.add_argument("--output", metavar="FILE", help="write a sanitized local report")
    command("migration", "Report read-only settings and path migration advisories.")
    p = command("test", "Write a sanitized local device report; no uploads.")
    p.add_argument("--output", metavar="FILE", help="write a new local report")
    p.add_argument("--model", metavar="MODEL_ID", action="append", help="permit an authenticated model request")
    p = command("link", "Own a Claude command entry with restoration evidence.")
    p.add_argument("--replace", action="store_true", help="back up and replace a foreign entry")
    p.add_argument("--path", metavar="PATH", help="choose the command entry")
    p = command("cleanup", "Remove inactive releases while protecting active sessions.")
    p.add_argument("--keep", metavar="N", help="retention count")
    p.add_argument("--dry-run", action="store_true", help="report without deleting")
    p = command("self-update", "Install a newer Termux Muscle manager release.")
    p.add_argument("--version", metavar="X.Y.Z", help="select an exact manager release")
    p.add_argument("-f", "--force", action="store_true", help="permit compatible reinstall or downgrade")
    p.add_argument("-V", "--verbose", action="store_true", help="stream the full build and test log")
    p.add_argument("--json", action="store_true", help="print a versioned result with full transcript")
    command("uninstall", "Remove owned files and restore eligible original entries.")
    return root, commands


def generate_schema(root: argparse.ArgumentParser, commands: dict[str, argparse.ArgumentParser]) -> str:
    lines = ["#!/usr/bin/env bash", "# SPDX-License-Identifier: MPL-2.0", "# Generated by scripts/cli_schema.py. Edit the argparse definition instead.", "tm_schema_help() {", "    case ${1:-} in"]
    for name, p in [("", root), *commands.items()]:
        label = shlex.quote(name)
        tag = "TM_SCHEMA_HELP_" + (name.upper().replace("-", "_") or "ROOT")
        lines += [f"        {label}) cat <<'{tag}'", p.format_help().rstrip(), tag, "            ;;" ]
    lines += ["        *) tm_error usage 'Unknown command help target.' ;;", "    esac", "}", "", "tm_schema_validate() {", "    local command=$1; shift", "    while (($#)); do", "        case $command/$1 in"]
    for name, p in commands.items():
        if name == "run":
            continue
        for action in p._actions:
            if not action.option_strings or action.dest == "help":
                continue
            patterns = "|".join(f"{name}/{flag}" for flag in action.option_strings)
            if action.nargs == 0:
                lines.append(f"            {patterns}) shift ;;")
            else:
                lines.append(f"            {patterns}) (($# > 1)) || tm_error usage '{action.option_strings[-1]} needs a value.'; shift 2 ;;")
    lines += ["            */--help|*/-h) tm_schema_help \"$command\"; exit 0 ;;", "            *) tm_error usage \"Unknown $command option or argument: $1\" ;;", "        esac", "    done", "}", ""]
    return "\n".join(lines)


def generate_completion(root: argparse.ArgumentParser, commands: dict[str, argparse.ArgumentParser]) -> str:
    names = " ".join(commands)
    option_cases = []
    value_cases = []
    for name, p in commands.items():
        options = [flag for action in p._actions for flag in action.option_strings]
        option_cases.append(f"        {name}) options={' '.join(options)!r} ;;")
        for action in p._actions:
            if action.option_strings and action.nargs != 0:
                pattern = "|".join(f"{name}/{flag}" for flag in action.option_strings)
                kind = "directory" if action.dest in ("root", "prefix") else "file" if action.dest in ("output", "path") else "latest" if action.dest == "claude_version" else "none"
                value_cases.append(f"        {pattern}) kind={kind} ;;")
    return f'''#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Generated by scripts/cli_schema.py from the argparse command definition.
_termux_muscle_complete() {{
    local current=${{COMP_WORDS[COMP_CWORD]}} previous='' command='' options='' kind='' word i
    local globals='--root --prefix --help --version'
    local commands={names!r}
    COMPREPLY=()
    ((COMP_CWORD > 0)) && previous=${{COMP_WORDS[COMP_CWORD-1]}}
    for ((i=1; i<COMP_CWORD; i++)); do
        word=${{COMP_WORDS[i]}}
        case $word in
            --root|--prefix) ((i++)); continue ;;
            --) return 0 ;;
        esac
        if [[ -z $command ]]; then
            case $word in
                { '|'.join(commands) }) command=$word ;;
                -*) ;;
                *) return 0 ;;
            esac
        elif [[ $command == run ]]; then
            return 0
        else
            case $command/$word in
{chr(10).join(f'                {name}/{flag}) ((i++)); continue ;;' for name, p in commands.items() for action in p._actions if action.option_strings and action.nargs != 0 for flag in action.option_strings)}
            esac
        fi
    done
    if [[ $command == run ]]; then return 0; fi
    case $previous in
        --root|--prefix)
            mapfile -t COMPREPLY < <(compgen -d -- "$current")
            return 0 ;;
    esac
    case $command/$previous in
{chr(10).join(value_cases)}
    esac
    case $kind in
        directory) mapfile -t COMPREPLY < <(compgen -d -- "$current"); return 0 ;;
        file) mapfile -t COMPREPLY < <(compgen -f -- "$current"); return 0 ;;
        latest) mapfile -t COMPREPLY < <(compgen -W latest -- "$current"); return 0 ;;
        none) return 0 ;;
    esac
    if [[ -z $command ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$commands $globals" -- "$current")
    elif [[ $current == -* ]]; then
        case $command in
{chr(10).join(option_cases)}
        esac
        mapfile -t COMPREPLY < <(compgen -W "$options --root --prefix" -- "$current")
    fi
}}
complete -F _termux_muscle_complete termux-muscle
'''


def main() -> int:
    if sys.argv[1:] not in ([], ["--check"]):
        print("usage: scripts/cli_schema.py [--check]", file=sys.stderr)
        return 2
    root, commands = parser()
    outputs = {SCHEMA: generate_schema(root, commands), COMPLETION: generate_completion(root, commands)}
    if sys.argv[1:] == ["--check"]:
        stale = [path for path, content in outputs.items() if not path.is_file() or path.read_text() != content]
        if stale:
            print("stale generated CLI artifacts: " + ", ".join(str(path.relative_to(ROOT)) for path in stale), file=sys.stderr)
            for path in stale:
                name = str(path.relative_to(ROOT))
                current = path.read_text().splitlines(keepends=True) if path.is_file() else []
                sys.stderr.writelines(difflib.unified_diff(current, outputs[path].splitlines(keepends=True), name, name + " (generated)"))
            return 1
        return 0
    for path, content in outputs.items():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(content)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
