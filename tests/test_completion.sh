#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if command -v python3 >/dev/null 2>&1; then
    python3 "$repo/scripts/cli_schema.py" --check
fi
source "$repo/docs/completions/termux-muscle.sh"
fail() { printf 'FAIL completion: %s\n' "$1" >&2; exit 1; }
complete_for() {
    COMP_WORDS=(termux-muscle "$@")
    COMP_CWORD=$((${#COMP_WORDS[@]} - 1))
    _termux_muscle_complete
}
contains() {
    local expected=$1 value
    for value in "${COMPREPLY[@]}"; do [[ $value != "$expected" ]] || return 0; done
    fail "missing $expected in ${COMPREPLY[*]}"
}
excludes() {
    local excluded=$1 value
    for value in "${COMPREPLY[@]}"; do [[ $value != "$excluded" ]] || fail "unexpected $excluded"; done
}
complete_for ''
contains install
contains self-update
excludes bootstrap
excludes _locked
complete_for --ro
contains --root
complete_for install --
contains --claude-version
contains --no-link
excludes --force
complete_for self-update -
contains -f
contains --force
contains -V
contains --verbose
contains --json
complete_for --root /tmp install --
contains --offline
complete_for install --claude-version latest --
contains --offline
complete_for update --claude-version l
contains latest
complete_for run --mo
((${#COMPREPLY[@]} == 0)) || fail 'manager completed vendor options'
complete_for run -- --mo
((${#COMPREPLY[@]} == 0)) || fail 'manager completed pass-through arguments'
complete_for run --root ''
((${#COMPREPLY[@]} == 0)) || fail 'manager completed vendor path option'
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tm-completion.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
touch "$scratch/report.json"
complete_for doctor --output "$scratch/re"
contains "$scratch/report.json"
complete_for test --model ''
((${#COMPREPLY[@]} == 0)) || fail 'completion guessed a model identifier'

# The generated Bash validator and displayed help are loaded without the C
# helper, network, an installed Claude runtime, or Python at command runtime.
help=$("$repo/bin/termux-muscle" self-update --help)
[[ $help == *'--force'* && $help == *'--verbose'* && $help == *'--json'* ]] || fail 'help differs from completion options'
if "$repo/bin/termux-muscle" repair --claude-version latest > /dev/null 2> "$scratch/error"; then
    fail 'parser accepted an option absent from the repair schema'
fi
grep -Fq 'Unknown repair option' "$scratch/error" || fail 'repair rejected before schema validation'
if "$repo/bin/termux-muscle" install --claude-version > /dev/null 2> "$scratch/error"; then
    fail 'parser accepted an option without its value'
fi
grep -Fq -- '--claude-version needs a value' "$scratch/error" || fail 'missing value was not reported by schema validation'
if "$repo/bin/termux-muscle" install --not-a-manager-option > /dev/null 2> "$scratch/error"; then
    fail 'parser accepted an unknown option'
fi
grep -Fq 'Unknown install option' "$scratch/error" || fail 'unknown option was not reported by schema validation'
printf '%s\n' 'PASS completion: ArgParse generation, Bash completion and runtime grammar'
