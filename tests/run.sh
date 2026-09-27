#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
export LC_ALL=C
# A running older manager exports TM_CORE while invoking the downloaded
# installer. Always exercise this checkout's freshly built helper.
export TM_CORE="$PWD/build/tm-core"
# A self-update runs this suite with its stage-event and progress variables
# set and progress on FD 3. Only this runner reports progress: some tests run
# nested installers, which must not see the caller's variables or files.
progress_mode=${TM_SELF_UPDATE_PROGRESS_MODE:-}
# On a terminal, also show the running program, its position and elapsed
# seconds after the dots. TM_SELF_UPDATE_PROGRESS_LIVE=0 turns this off and 1
# forces it; logs, CI and JSON transcripts receive only dots and totals.
live=0
if [[ $progress_mode == concise ]]; then
    case ${TM_SELF_UPDATE_PROGRESS_LIVE:-} in
        1) live=1 ;;
        0) ;;
        *) if [[ -t 3 ]]; then live=1; fi ;;
    esac
fi
unset TM_SELF_UPDATE_EVENTS TM_SELF_UPDATE_TRANSCRIPT_FILE TM_SELF_UPDATE_PROGRESS_MODE TM_SELF_UPDATE_TARGET_FILE \
    TM_SELF_UPDATE_PROGRESS_LIVE
shopt -s nullglob
count=0
skipped=0
failed=0
progress_count=0
# The installer has already printed this prefix; live redraws repeat it.
line='Running test programs: '
ticker=
runner=$$
columns() {
    local size
    if size=$(stty size <&3 2>/dev/null) && [[ $size =~ ^[0-9]+\ ([1-9][0-9]*)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        printf '%s\n' "${COLUMNS:-80}"
    fi
}
live_draw() {
    local cols status
    cols=$(columns)
    for status in "$1 $2/${#programs[@]} $3 $4s" "$1 $2/${#programs[@]} $4s" "$1" ''; do
        ((${#line} + 1 + ${#status} < cols)) && break
    done
    printf '\r%s %s\033[K' "$line" "$status" >&3
}
live_start() {
    ((live)) || return 0
    local index=$1 name=${2##*/} started now frame=0 frames='|/-\'
    printf -v started '%(%s)T' -1
    (
        trap - EXIT HUP INT TERM
        # Stop by itself if the runner disappears without cleaning up.
        while kill -0 "$runner" 2>/dev/null; do
            printf -v now '%(%s)T' -1
            live_draw "${frames:frame:1}" "$index" "$name" $((now - started)) || exit 0
            frame=$(((frame + 1) % 4))
            sleep 0.5 || exit 0
        done
    ) &
    ticker=$!
}
live_stop() {
    [[ -n $ticker ]] || return 0
    kill "$ticker" 2>/dev/null || :
    wait "$ticker" 2>/dev/null || :
    ticker=
    printf '\r%s\033[K' "$line" >&3
}
trap live_stop EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
progress_result() {
    [[ $progress_mode == concise ]] || return 0
    case $1 in
        passed)
            if ((live)); then
                # Wrap at the terminal width so each redraw stays on one row.
                if ((${#line} + 2 >= $(columns))); then printf '\n' >&3; line=''; fi
                printf '.' >&3
                line+=.
                ((progress_count += 1))
                return 0
            fi
            printf '.' >&3
            ((progress_count += 1))
            if ((progress_count % 60 == 0)); then printf '\n' >&3; fi
            ;;
        failed)
            if ((live)); then
                [[ -z $line ]] || printf '\n' >&3
                line=''
            elif ((progress_count == 0 || progress_count % 60 != 0)); then
                printf '\n' >&3
            fi
            printf 'Tests: %d passed, %d skipped, %d failed.\n' "$count" "$skipped" "$failed" >&3
            ;;
    esac
}
run_program() {
    local index=$1 label=$2 status; shift 2
    printf 'RUN %s\n' "$label"
    live_start "$index" "$label"
    if "$@" 3>&-; then
        live_stop
        ((count += 1))
        progress_result passed
    else
        status=$?
        live_stop
        if ((status == 77)); then
            ((skipped += 1))
            return 0
        fi
        ((failed += 1))
        progress_result failed
        return "$status"
    fi
}
programs=()
for executable in build/tests/test_*; do
    [[ -f "$executable" && -x "$executable" ]] || continue
    programs+=("$executable")
done
programs+=(tests/test_*.sh)
index=0
for program in "${programs[@]}"; do
    ((index += 1))
    if [[ $program == *.sh ]]; then
        run_program "$index" "$program" bash "$program"
    else
        run_program "$index" "$program" "$program"
    fi
done
((count + skipped > 0)) || { printf '%s\n' 'No tests were found.' >&2; exit 1; }
if [[ $progress_mode == concise ]]; then
    if ((live)); then
        [[ -z $line ]] || printf '\n' >&3
    elif ((progress_count % 60 != 0)); then
        printf '\n' >&3
    fi
    printf 'Tests: %d passed, %d skipped, %d failed.\n' "$count" "$skipped" "$failed" >&3
fi
printf 'PASS: %s C/shell test programs\n' "$count"
