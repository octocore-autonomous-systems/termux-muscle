#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# The test runner reports self-update progress itself, keeps the caller's
# self-update state away from test programs, and never leaves its live status
# running after a program or the runner ends.
set -euo pipefail
project=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/muscle-run-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'FAIL run: %s\n' "$*" >&2; exit 1; }
count=0
pass() { ((count += 1)); }
mkdir -p "$work/tree/tests" "$work/tree/build"
cp -- "$project/tests/run.sh" "$work/tree/tests/run.sh"
cat > "$work/tree/tests/test_a_probe.sh" <<'PROBE'
env | grep '^TM_SELF_UPDATE_' > "$PROBE_OUT" || :
if { printf '' >&3; } 2>/dev/null; then printf 'fd3-open\n' >> "$PROBE_OUT"; fi
sleep "${PROBE_SLEEP:-0}"
exit "${PROBE_EXIT:-0}"
PROBE
printf 'sleep "${PROBE_B_SLEEP:-0}"\n' > "$work/tree/tests/test_b_second.sh"
: > "$work/events"
: > "$work/transcript"
runner() {
    set +e
    env TM_SELF_UPDATE_PROGRESS_MODE=concise TM_SELF_UPDATE_EVENTS="$work/events" \
        TM_SELF_UPDATE_TRANSCRIPT_FILE="$work/transcript" TM_SELF_UPDATE_TARGET_FILE="$work/target" \
        PROBE_OUT="$work/probe" COLUMNS=80 "$@" > "$work/stdout" 3> "$work/progress"
    status=$?
    set -e
}
# A stopped live status must not write again, even after the runner has gone.
settled() {
    local size
    size=$(stat -c %s -- "$work/progress")
    sleep 1.2
    [[ $(stat -c %s -- "$work/progress") == "$size" ]] || fail "live status kept writing after $1"
}

runner bash "$work/tree/tests/run.sh"
((status == 0)) || fail 'runner failed'
[[ -f $work/probe ]] || fail 'probe did not run'
[[ ! -s $work/probe ]] || fail "test program inherited self-update state: $(tr '\n' ' ' < "$work/probe")"
[[ $(< "$work/progress") == $'..\nTests: 2 passed, 0 skipped, 0 failed.' ]] ||
    fail "non-terminal progress changed: $(< "$work/progress")"
[[ ! -s $work/events && ! -e $work/target ]] || fail 'test program wrote self-update records'
grep -q '^PASS: 2 C/shell test programs$' "$work/stdout" || fail 'runner summary missing'
pass

runner env TM_SELF_UPDATE_PROGRESS_LIVE=1 PROBE_SLEEP=1.3 PROBE_B_SLEEP=1.3 bash "$work/tree/tests/run.sh"
((status == 0)) || fail 'live runner failed'
[[ ! -s $work/probe ]] || fail 'live runner leaked its switch to test programs'
grep -aq $'\r''Running test programs:  [|/\\-] 1/2 test_a_probe.sh [01]s'$'\033''\[K' "$work/progress" ||
    fail "live status lacked spinner, position, name or elapsed time: $(od -c "$work/progress" | head -5)"
grep -aq '2/2 test_b_second.sh' "$work/progress" || fail 'live status did not advance to the second program'
# Once the first program's dot is drawn, its status must never reappear.
first_dot=$(grep -abo $'\033''\[K\.' "$work/progress" | head -1 | cut -d: -f1)
[[ -n $first_dot ]] || fail 'live progress lacked an erased status before the first dot'
if tail -c +"$((first_dot + 1))" "$work/progress" | grep -aq '1/2'; then
    fail "the first program's live status kept drawing during the second program"
fi
visible=$(sed 's/.*\r//' "$work/progress" | sed $'s/\033\\[K//g')
[[ $visible == $'Running test programs: ..\nTests: 2 passed, 0 skipped, 0 failed.' ]] ||
    fail "live status was not erased: $visible"
settled success
pass

runner env TM_SELF_UPDATE_PROGRESS_LIVE=1 PROBE_SLEEP=0.7 PROBE_EXIT=3 bash "$work/tree/tests/run.sh"
((status == 3)) || fail "failed program status changed: $status"
[[ $(tail -1 "$work/progress") == 'Tests: 0 passed, 0 skipped, 1 failed.' ]] || fail 'live failure lacked totals'
settled failure
pass

for signal in HUP INT TERM; do
    case $signal in HUP) expected=129 ;; INT) expected=130 ;; TERM) expected=143 ;; esac
    # Signal only the runner, so its own cleanup must stop the live status.
    runner env TM_SELF_UPDATE_PROGRESS_LIVE=1 PROBE_SLEEP=1.5 \
        timeout --foreground --preserve-status -s "$signal" 0.6 bash "$work/tree/tests/run.sh"
    ((status == expected)) || fail "$signal status $status, expected $expected"
    [[ $(tail -c 30 "$work/progress") == *$'\r''Running test programs: '$'\033''[K' ]] ||
        fail "$signal left a live status on the terminal"
    settled "$signal"
done
pass

printf 'PASS run: isolated tests, unchanged non-terminal progress and live status stopped on success, failure, HUP, INT and TERM (%d groups)\n' "$count"
