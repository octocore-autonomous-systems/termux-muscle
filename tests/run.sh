#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
export LC_ALL=C
# A running older manager exports TM_CORE while invoking the downloaded
# installer. Always exercise this checkout's freshly built helper.
export TM_CORE="$PWD/build/tm-core"
shopt -s nullglob
count=0
skipped=0
failed=0
progress_count=0
progress_result() {
    [[ ${TM_SELF_UPDATE_PROGRESS_MODE:-} == concise ]] || return 0
    case $1 in
        passed)
            printf '.' >&3
            ((progress_count += 1))
            if ((progress_count % 60 == 0)); then printf '\n' >&3; fi
            ;;
        failed)
            if ((progress_count == 0 || progress_count % 60 != 0)); then printf '\n' >&3; fi
            printf 'Tests: %d passed, %d skipped, %d failed.\n' "$count" "$skipped" "$failed" >&3
            ;;
    esac
}
run_program() {
    local label=$1 status; shift
    printf 'RUN %s\n' "$label"
    if "$@"; then
        ((count += 1))
        progress_result passed
    else
        status=$?
        if ((status == 77)); then
            ((skipped += 1))
            return 0
        fi
        ((failed += 1))
        progress_result failed
        return "$status"
    fi
}
for executable in build/tests/test_*; do
    [[ -f "$executable" && -x "$executable" ]] || continue
    run_program "$executable" "$executable"
done
for script in tests/test_*.sh; do
    run_program "$script" bash "$script"
done
((count + skipped > 0)) || { printf '%s\n' 'No tests were found.' >&2; exit 1; }
if [[ ${TM_SELF_UPDATE_PROGRESS_MODE:-} == concise ]]; then
    if ((progress_count % 60 != 0)); then printf '\n' >&3; fi
    printf 'Tests: %d passed, %d skipped, %d failed.\n' "$count" "$skipped" "$failed" >&3
fi
printf 'PASS: %s C/shell test programs\n' "$count"
