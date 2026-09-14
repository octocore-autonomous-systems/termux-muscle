# SPDX-License-Identifier: MPL-2.0
# Reports never upload automatically. Even failed checks produce reviewable JSON.
tm_diagnostics() (
    set -euo pipefail
    umask 077
    local mode=${1:?} output= status=0 temporary= parent= filename= probe_pid=
    shift
    local -a model_args=()
    while (($#)); do
        case $1 in
            --output)
                [[ $# -ge 2 && -z $output && -n $2 ]] || { printf '%s\n' 'Choose one output file.' >&2; exit 1; }
                output=$2; shift 2 ;;
            --model)
                [[ $mode == test && $# -ge 2 ]] || { printf '%s\n' 'Only test accepts explicit --model checks, which can use account credits.' >&2; exit 1; }
                model_args+=(--model "$2"); shift 2 ;;
            *) printf '%s\n' 'Usage: doctor [--output FILE] | test [--output FILE] [--model exact-ID ...]' >&2; exit 1 ;;
        esac
    done
    [[ $mode == doctor || $mode == test ]] || exit 1
    local command=report
    [[ $mode != doctor ]] || command=doctor
    if [[ -z $output ]]; then
        exec "$TM_CORE" "$command" "$TM_ROOT" "$TM_PREFIX" "$TM_SOURCE" "${model_args[@]}"
    fi
    [[ ! -e $output && ! -L $output ]] || { printf '%s\n' 'Report output must be a new file; existing files are preserved.' >&2; exit 1; }
    parent=$(dirname -- "$output") || exit 1
    filename=$(basename -- "$output") || exit 1
    [[ $filename != . && $filename != .. && -d $parent ]] || exit 1
    parent=$(cd -- "$parent" && pwd -P) || exit 1
    output=$parent/$filename
    temporary=$(mktemp "$parent/.termux-muscle-report.XXXXXXXX") || exit 1
    tm_diagnostics_cleanup() {
        if [[ -n $probe_pid ]]; then
            kill -TERM "$probe_pid" 2>/dev/null || :
            wait "$probe_pid" 2>/dev/null || :
        fi
        [[ -z $temporary ]] || rm -f -- "$temporary"
    }
    trap tm_diagnostics_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    # A shell waiting on a foreground command defers traps. The wait builtin
    # wakes for signals so EXIT cleanup can stop the owned C probe promptly.
    "$TM_CORE" "$command" "$TM_ROOT" "$TM_PREFIX" "$TM_SOURCE" "${model_args[@]}" >"$temporary" &
    probe_pid=$!
    wait "$probe_pid" || status=$?
    probe_pid=
    "$TM_CORE" json-check "$temporary" >/dev/null || exit 1
    chmod 600 -- "$temporary" || exit 1
    # Android forbids hard links on some app filesystems; the C helper uses
    # renameat2 NOREPLACE and fsync for atomic, durable publication.
    "$TM_CORE" report --publish "$temporary" "$output" || exit 1
    temporary=
    printf '%s\n' 'Diagnostic report saved locally. Review it before sharing.' >&2
    exit "$status"
)
