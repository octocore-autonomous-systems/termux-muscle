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
import textwrap


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCHEMA = ROOT / "lib/cli_schema.sh"
COMPLETION = ROOT / "docs/completions/termux-muscle.sh"
# Generated help must not depend on the terminal: argparse otherwise sizes it
# from COLUMNS, and Python 3.14 may add color when stdout is a terminal.
FORMAT = {"formatter_class": functools.partial(argparse.HelpFormatter, width=78)}
if sys.version_info >= (3, 14):
    FORMAT["color"] = False


# The overview groups commands by what they act on; argparse cannot group
# subcommands, so it is rendered from this table with the same width.
GROUPS = (
    ("Claude Code:", ("install", "run", "update", "rollback", "repair", "versions", "cleanup", "link")),
    ("Termux Muscle:", ("self-update", "uninstall", "help")),
    ("Troubleshooting (checks the device, Termux Muscle and Claude Code together; "
     "read-only, nothing is uploaded):", ("doctor", "test", "migration")),
)
SUMMARIES = {
    "help": "Show this overview, or 'help <command>' for one command",
    "install": "Install Claude Code and put claude on PATH",
    "run": "Run Claude Code, passing all following arguments through",
    "update": "Move to the newest Claude Code release once it passes local checks",
    "rollback": "Switch back to the previous validated release",
    "repair": "Rebuild the active release from verified original artifacts",
    "versions": "List installed releases; --available lists installable ones",
    "doctor": "Check that the device, the claude launcher and the active Claude Code "
              "release all work, without contacting Anthropic",
    "migration": "Find leftover pre-Termux-Muscle workarounds in Claude Code's settings, "
                 "plugin paths and PATH",
    "test": "Run the doctor checks and save a sanitized device report; --model also "
            "makes one real model request",
    "link": "Take over the claude command, recording how to restore it",
    "cleanup": "Remove inactive releases, protecting running sessions",
    "self-update": "Upgrade Termux Muscle itself (not Claude Code)",
    "uninstall": "Remove Termux Muscle and restore the original claude command",
}
ROOT_TAIL = """\
Global options:
  --root DIR     managed installation root
                 (default: ~/.local/share/termux-muscle)
  --prefix DIR   Termux package prefix (default: $PREFIX)
  --version      print Termux Muscle and active Claude Code versions
  -h, --help     show this help

Common tasks:
  termux-muscle versions --available    what can I install?
  termux-muscle update                  move to the newest Claude Code release
  termux-muscle update --claude-version pinned
                                        use the release this project tested
  termux-muscle rollback                undo the last update
  termux-muscle doctor                  something's wrong; start here
  termux-muscle self-update             upgrade the manager

Run 'termux-muscle <command> --help' for its options and exit codes.
Full manual: man termux-muscle

Termux Muscle is an independent open-source project, not affiliated with or
authorized by Anthropic."""
SELECTION_EPILOG = (
    "Without --claude-version, the release named by Anthropic's latest channel is used "
    "(the project pin with --offline). stable names Anthropic's delayed channel and "
    "pinned the release this Termux Muscle version was tested with. A release other "
    "than the pin is installed only when Anthropic's signature on its release manifest "
    "verifies and the executable matches the signed SHA-256; --allow-unverified skips "
    "that check. A channel never replaces the active release with an older one. Run "
    "'versions --available' to see installable versions."
)


def root_help() -> str:
    lines = [
        "usage: termux-muscle [--root DIR] [--prefix DIR] <command> [options]",
        "       termux-muscle --version | --help",
        "",
        "Install, run and maintain Claude Code on Termux.",
    ]
    for title, names in GROUPS:
        lines += ["", *textwrap.wrap(title, 78)]
        for name in names:
            lines += textwrap.wrap(SUMMARIES[name], 78, initial_indent=f"  {name:<11}  ",
                                   subsequent_indent=" " * 15)
    return "\n".join(lines) + "\n\n" + ROOT_TAIL


def parser() -> tuple[argparse.ArgumentParser, dict[str, argparse.ArgumentParser]]:
    root = argparse.ArgumentParser(prog="termux-muscle", allow_abbrev=False, **FORMAT)
    root.add_argument("--root", metavar="DIR", help="managed installation root")
    root.add_argument("--prefix", metavar="DIR", help="native Termux package prefix")
    root.add_argument("--version", action="store_true", help="print manager version")
    sub = root.add_subparsers(dest="command", metavar="COMMAND")
    commands: dict[str, argparse.ArgumentParser] = {}

    def command(name: str, epilog: str | None = None, raw: bool = False) -> argparse.ArgumentParser:
        summary = SUMMARIES[name] + "."
        style = dict(FORMAT)
        if raw:
            style["formatter_class"] = functools.partial(argparse.RawDescriptionHelpFormatter, width=78)
        p = sub.add_parser(name, help=summary, description=summary, epilog=epilog,
                           allow_abbrev=False, add_help=name != "run", **style)
        if name != "run":
            p.add_argument("--root", metavar="DIR", help="managed installation root")
            p.add_argument("--prefix", metavar="DIR", help="native Termux package prefix")
        commands[name] = p
        return p

    p = command("help")
    p.add_argument("topic", nargs="?", metavar="COMMAND", help="show help for this command")
    p = command("install", SELECTION_EPILOG)
    p.add_argument("--claude-version", metavar="X.Y.Z|latest|stable|pinned",
                   help="choose the Claude Code release (default: latest)")
    p.add_argument("--allow-unverified", action="store_true",
                   help="skip Anthropic's signature check for this release")
    p.add_argument("--backend", metavar="native|proot",
                   help="run without PRoot (native) or inside it (proot)")
    p.add_argument("--offline", action="store_true", help="use verified cached archives")
    p.add_argument("--no-link", action="store_true", help="preserve existing Claude command entries")
    p = command("run")
    p.usage = "termux-muscle run [--] CLAUDE_ARGUMENTS..."
    p.add_argument("claude_arguments", nargs=argparse.REMAINDER, metavar="CLAUDE_ARGUMENTS")
    p = command("update", SELECTION_EPILOG)
    p.add_argument("--claude-version", metavar="X.Y.Z|latest|stable|pinned",
                   help="choose the Claude Code release (default: latest)")
    p.add_argument("--allow-unverified", action="store_true",
                   help="skip Anthropic's signature check for this release")
    p.add_argument("--backend", metavar="native|proot",
                   help="run without PRoot (native) or inside it (proot)")
    p.add_argument("--offline", action="store_true", help="use verified cached archives")
    command("rollback")
    p = command("repair")
    p.add_argument("--offline", action="store_true", help="use verified cached archives")
    p = command("versions", (
        "--available reads the official npm registry and never installs anything. The "
        "pinned release passed device acceptance with this Termux Muscle version and a "
        "formerly pinned release passed with the Termux Muscle releases shown; every "
        "other version is unverified by this project. update --claude-version X.Y.Z "
        "installs any of them once Anthropic's release signature verifies."
    ))
    p.add_argument("--available", action="store_true", help="list installable Claude Code releases")
    p.add_argument("--all", action="store_true", help="with --available, list every release")
    p.add_argument("--json", action="store_true", help="print machine readable output")
    p = command("doctor")
    p.add_argument("--output", metavar="FILE", help="write a sanitized local report")
    command("migration")
    p = command("test")
    p.add_argument("--output", metavar="FILE", help="write a new local report")
    p.add_argument("--model", metavar="MODEL_ID", action="append",
                   help="also make one authenticated request with this model (repeatable)")
    p = command("link")
    p.add_argument("--replace", action="store_true", help="back up and replace a foreign entry")
    p.add_argument("--path", metavar="PATH", help="choose the command entry")
    p = command("cleanup")
    p.add_argument("--keep", metavar="N", help="retention count")
    p.add_argument("--dry-run", action="store_true", help="report without deleting")
    p = command("self-update", """\
By default, one progress dot is shown per completed test program.

exit status:
  0  installed    2  already current    3  target is older    1  failed""", raw=True)
    p.add_argument("--version", metavar="X.Y.Z", help="install this manager release (default: newest)")
    p.add_argument("-f", "--force", action="store_true", help="reinstall the same release, or downgrade if compatible")
    p.add_argument("-V", "--verbose", action="store_true", help="stream the full build and test log")
    p.add_argument("--json", action="store_true", help="print a versioned result with the bounded test transcript")
    command("uninstall")
    return root, commands


def generate_schema(root: argparse.ArgumentParser, commands: dict[str, argparse.ArgumentParser]) -> str:
    lines = ["#!/usr/bin/env bash", "# SPDX-License-Identifier: MPL-2.0", "# Generated by scripts/cli_schema.py. Edit the argparse definition instead.", "tm_schema_help() {", "    case ${1:-} in"]
    for name, p in [("", root), *commands.items()]:
        label = shlex.quote(name)
        tag = "TM_SCHEMA_HELP_" + (name.upper().replace("-", "_") or "ROOT")
        text = root_help() if p is root else p.format_help().rstrip()
        lines += [f"        {label}) cat <<'{tag}'", text, tag, "            ;;" ]
    lines += ["        *) tm_error usage \"Unknown command: $1. Run termux-muscle --help.\" ;;", "    esac", "}", "", "tm_schema_validate() {", "    local command=$1; shift", "    while (($#)); do", "        case $command/$1 in"]
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
                kind = "directory" if action.dest in ("root", "prefix") else "file" if action.dest in ("output", "path") else "selector" if action.dest == "claude_version" else "backend" if action.dest == "backend" else "none"
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
    if [[ $command == help && $current != -* && $previous == help ]]; then
        mapfile -t COMPREPLY < <(compgen -W "$commands" -- "$current")
        return 0
    fi
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
        selector) mapfile -t COMPREPLY < <(compgen -W 'latest stable pinned' -- "$current"); return 0 ;;
        backend) mapfile -t COMPREPLY < <(compgen -W 'native proot' -- "$current"); return 0 ;;
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
