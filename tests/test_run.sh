#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The test runner reports self-update progress itself and keeps the caller's
# self-update variables and progress descriptor away from test programs.
set -euo pipefail
project=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/muscle-run-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL run: %s\n' "$*" >&2; exit 1; }
mkdir -p "$work/tree/tests" "$work/tree/build"
cp -- "$project/tests/run.sh" "$work/tree/tests/run.sh"
cat > "$work/tree/tests/test_probe.sh" <<'PROBE'
env | grep '^TM_SELF_UPDATE_' > "$PROBE_OUT" || :
if { printf '' >&3; } 2>/dev/null; then printf 'fd3-open\n' >> "$PROBE_OUT"; fi
PROBE
: > "$work/events"
: > "$work/transcript"
env TM_SELF_UPDATE_PROGRESS_MODE=concise TM_SELF_UPDATE_EVENTS="$work/events" \
    TM_SELF_UPDATE_TRANSCRIPT_FILE="$work/transcript" TM_SELF_UPDATE_TARGET_FILE="$work/target" \
    PROBE_OUT="$work/probe" bash "$work/tree/tests/run.sh" > "$work/stdout" 3> "$work/progress" ||
    fail 'runner failed'
[[ -f $work/probe ]] || fail 'probe did not run'
[[ ! -s $work/probe ]] || fail "test program inherited self-update state: $(tr '\n' ' ' < "$work/probe")"
[[ $(< "$work/progress") == $'.\nTests: 1 passed, 0 skipped, 0 failed.' ]] ||
    fail "runner progress changed: $(< "$work/progress")"
[[ ! -s $work/events && ! -e $work/target ]] || fail 'test program wrote self-update records'
grep -q '^PASS: 1 C/shell test programs$' "$work/stdout" || fail 'runner summary missing'
printf 'PASS run: self-update progress stays with the runner; tests see no self-update state\n'
