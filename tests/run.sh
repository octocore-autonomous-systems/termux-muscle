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
for executable in build/tests/test_*; do
    [[ -f "$executable" && -x "$executable" ]] || continue
    printf 'RUN %s\n' "$executable"
    "$executable"
    ((count += 1))
done
for script in tests/test_*.sh; do
    printf 'RUN %s\n' "$script"
    bash "$script"
    ((count += 1))
done
((count > 0)) || { printf '%s\n' 'No tests were found.' >&2; exit 1; }
printf 'PASS: %s C/shell test programs\n' "$count"
