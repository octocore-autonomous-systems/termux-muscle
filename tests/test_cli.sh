#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

# Exercise the real public parser and lifecycle through independent process
# boundaries. Dependency fixtures never download, run vendor code, or change a
# live installation. Native lock/receipt validation has its own C/state tests.
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
host_bash=$(realpath -- "$BASH")
host_mkdir=$(command -v mkdir)
host_mktemp=$(command -v mktemp)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tm-cli-test.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
source_dir="$scratch/source with spaces"
root="$scratch/installation with 'quotes' and \$dollars"
missing_prefix="$scratch/missing prefix"
prefix="$scratch/test prefix"
trace="$scratch/trace"
restricted="$scratch/local-only-bin"
guards="$scratch/guard-bin"
mkdir -p -- "$source_dir/bin" "$source_dir/lib" "$source_dir/libexec" \
    "$root/cache" "$root/releases" "$trace" "$restricted" "$guards" "$prefix/bin"
cp -- "$repo/bin/termux-muscle" "$source_dir/bin/termux-muscle"
cp -- "$repo/VERSION" "$source_dir/VERSION"
cli="$source_dir/bin/termux-muscle"
export TM_FIXTURE_TRACE="$trace" TM_FIXTURE_MKDIR="$host_mkdir" TM_FIXTURE_MKTEMP="$host_mktemp"
unset TM_FIXTURE_LOCK TM_FIXTURE_FAIL_PROBE TM_FIXTURE_FAIL_CLEANUP

# The copied shell CLI consumes fixtures through its ordinary dependency paths.
cat > "$source_dir/lib/acquire.sh" <<'SH'
tm_acquire_plan() {
    printf '%s\n' acquisition-plan >> "$TM_FIXTURE_TRACE/events"
    printf '%s\n' '{"status":"ready","version":"2.1.270"}' > "$5"
}
tm_acquire() {
    printf '%s\n' acquisition-copy >> "$TM_FIXTURE_TRACE/events"
    printf '%s\n' '{"version":"2.1.270","compatibility_status":"pinned"}' > "$1/payload.json"
    printf '%s\n' '{"version":"2.1.270","compatibility_status":"pinned"}'
}
SH
cat > "$source_dir/lib/tooling.sh" <<'SH'
tm_uninstall() {
    printf '%s\n' tooling-uninstall >> "$TM_FIXTURE_TRACE/events"
    printf '%s\0' "$@" > "$TM_FIXTURE_TRACE/uninstall.argv"
}
SH
cat > "$source_dir/lib/commands.sh" <<'SH'
tm_default_claude_links() {
    printf '%s\n' default-claude-links >> "$TM_FIXTURE_TRACE/events"
}
SH
{
    printf '#!%s\n' "$host_bash"
    cat <<'SH'
set -euo pipefail
printf '%s\n' "$1" >> "$TM_FIXTURE_TRACE/events"
case $1 in
    root-check) printf '%s\n' "$2" ;;
    run)
        printf '%s\0' "$@" > "$TM_FIXTURE_TRACE/run.argv"
        case ${!#} in
            --version)
                [[ ${TM_FIXTURE_FAIL_PROBE:-0} != 1 ]] || exit 29
                printf '%s\n' '2.1.270 (Claude Code)' ;;
            --help) printf '%s\n' vendor-cli-help ;;
            *) printf '%s\n' vendor-arguments-forwarded ;;
        esac
        ;;
    with-lock)
        [[ $4 == -- ]] || exit 80
        shift 4
        printf '%s\0' "$@" > "$TM_FIXTURE_TRACE/reexec.argv"
        export TM_FIXTURE_LOCK=held
        exec "$@"
        ;;
    state)
        root=$2 action=$3
        printf 'state-%s\n' "$action" >> "$TM_FIXTURE_TRACE/events"
        case $action in
            assert-lock)
                [[ ${TM_FIXTURE_LOCK:-} == held ]] || {
                    printf '%s\n' 'termux-muscle: lock_required: fixture rejected missing inherited lock' >&2
                    exit 28
                }
                ;;
            show) printf '%s\n' '{"current":null,"previous":null,"history":[]}' ;;
            versions) printf '%s\n' 'Fixture installation history is available.' ;;
            candidate)
                id=2.1.270-0123456789abcdef01234567
                "$TM_FIXTURE_MKDIR" -p -- "$root/releases/$id"
                printf '%s\n' "$id"
                ;;
            validate) : ;;
            activate) printf '%s\n' "$4" > "$TM_FIXTURE_TRACE/active" ;;
            cleanup)
                printf '%s\0' "$@" > "$TM_FIXTURE_TRACE/cleanup.argv"
                [[ ${TM_FIXTURE_FAIL_CLEANUP:-0} != 1 ]] || {
                    printf '%s\n' 'termux-muscle: fixture_cleanup_failed: simulated inactive-release maintenance failure' >&2
                    exit 31
                }
                printf '%s\n' '[]'
                ;;
            *) printf 'Unexpected fixture state action: %s\n' "$action" >&2; exit 81 ;;
        esac
        ;;
    acquire-field)
        case $3 in
            version) printf '%s\n' 2.1.270 ;;
            *) printf 'Unexpected fixture acquire field: %s\n' "$3" >&2; exit 82 ;;
        esac
        ;;
    json-get)
        case $3 in
            compatibility_status) printf '%s\n' pinned ;;
            version) printf '%s\n' 2.1.270 ;;
            *) printf 'Unexpected fixture JSON field: %s\n' "$3" >&2; exit 83 ;;
        esac
        ;;
    context) : ;;
    links) printf '%s\0' "$@" > "$TM_FIXTURE_TRACE/links.argv" ;;
    *) printf 'Unexpected fixture helper operation: %s\n' "$1" >&2; exit 84 ;;
esac
SH
} > "$source_dir/libexec/tm-core"
chmod 700 "$source_dir/libexec/tm-core"

# Root/metadata inspection and recovery require these shell fundamentals, but
# intentionally have no proot, curl, timeout, sha256sum, or uname in PATH.
for dependency in dirname cat realpath; do
    ln -s -- "$(command -v "$dependency")" "$restricted/$dependency"
done
{
    printf '#!%s\n' "$host_bash"
    # shellcheck disable=SC2016 # Generate literal fixture script source.
    printf '%s\n' 'printf "%s\n" cache-temp-request >> "$TM_FIXTURE_TRACE/events"' \
        'exec "$TM_FIXTURE_MKTEMP" "$@"'
} > "$guards/mktemp"
{
    printf '#!%s\n' "$host_bash"
    printf '%s\n' 'printf "%s\n" aarch64'
} > "$guards/uname"
{
    printf '#!%s\n' "$host_bash"
    # shellcheck disable=SC2016 # Generate literal fixture script source.
    printf '%s\n' 'printf "%s\n" forbidden-network >> "$TM_FIXTURE_TRACE/events"' 'exit 90'
} > "$guards/curl"
chmod 700 "$guards/mktemp" "$guards/uname" "$guards/curl"
ln -s -- "$host_bash" "$prefix/bin/bash"
ln -s -- "$host_bash" "$prefix/bin/proot"

count=0
pass() { printf 'PASS CLI: %s\n' "$1"; count=$((count + 1)); }
fail() { printf 'FAIL CLI: %s\n' "$1" >&2; exit 1; }
reset_trace() { rm -f -- "$trace"/*; : > "$trace/events"; }
expect_argv() {
    local file=$1; shift
    printf '%s\0' "$@" > "$trace/expected.argv"
    cmp -- "$file" "$trace/expected.argv" || fail 'arguments changed at process boundary'
}
has_event() { grep -Fxq -- "$1" "$trace/events"; }
local_cli() { PATH="$restricted" "$host_bash" "$cli" --root "$root" --prefix "$missing_prefix" "$@"; }

reset_trace
[[ $(local_cli run --help) == vendor-cli-help ]] || fail 'run --help was consumed by manager'
expect_argv "$trace/run.argv" run "$root" "$missing_prefix" current normal -- --help
reset_trace
local_cli --help > "$trace/help"
grep -Fq -- 'Termux Muscle' "$trace/help" || fail 'manager help unavailable'
[[ ! -s $trace/events ]] || fail 'manager help unnecessarily invoked installation helper'
local_cli install --help > "$trace/install-help"
[[ ! -s $trace/events ]] || fail 'maintenance help invoked a transaction'
pass 'vendor help passes through while manager help needs no installation'

reset_trace
# shellcheck disable=SC2016 # Literal shell syntax must survive as vendor arguments.
arguments=(auth login --root 'vendor root' --prefix 'vendor prefix' '--model' 'arbitrary/model' \
    'spaces and "quotes"' "single'quote" '*' '$(touch never-run)' '`false`' '' $'line\nbreak' --help)
local_cli run "${arguments[@]}" >/dev/null
expect_argv "$trace/run.argv" run "$root" "$missing_prefix" current normal -- "${arguments[@]}"
local_cli run -- "${arguments[@]}" >/dev/null
expect_argv "$trace/run.argv" run "$root" "$missing_prefix" current normal -- "${arguments[@]}"
pass 'hostile and empty vendor arguments survive both run forms verbatim'

reset_trace
PATH="$restricted" "$host_bash" "$cli" cleanup --keep 7 --root "$root" --prefix "$missing_prefix" > "$trace/output"
expect_argv "$trace/reexec.argv" "$host_bash" "$cli" _locked "$root" "$missing_prefix" cleanup --keep 7
expect_argv "$trace/cleanup.argv" state "$root" cleanup 7
has_event state-assert-lock || fail 'maintenance reexec omitted lock assertion'
pass 'manager path options preserve arguments and reexec uses current Bash'

reset_trace
if PATH="$guards:$PATH" "$host_bash" "$cli" _locked "$root" "$missing_prefix" install \
    > "$trace/unauthorized.out" 2> "$trace/unauthorized.err"; then fail 'internal maintenance accepted no lock'; fi
grep -Fq -- lock_required "$trace/unauthorized.err" || fail 'wrong internal authority rejection'
printf '%s\n' state state-assert-lock > "$trace/expected.events"
cmp -- "$trace/events" "$trace/expected.events" || fail 'cache or acquisition work preceded lock assertion'
if PATH="$guards:$PATH" "$host_bash" "$cli" _locked "$root" "$missing_prefix" uninstall \
    > "$trace/unauthorized.out" 2> "$trace/unauthorized.err"; then fail 'internal uninstall accepted no lock'; fi
if has_event tooling-uninstall; then fail 'uninstall dependency ran before authority check'; fi
pass 'internal maintenance rejects missing authority before cache, network or removal work'

reset_trace
local_cli versions > "$trace/versions"
has_event state-versions || fail 'readable versions did not dispatch local state'
local_cli versions --json > "$trace/versions.json"
has_event state-show || fail 'machine-readable versions did not dispatch local state'
[[ ! -d $missing_prefix ]] || fail 'read-only command created a missing prefix'
pass 'both versions formats work without runtime dependencies or an existing prefix'

reset_trace
local_cli cleanup --dry-run --keep 0 > "$trace/cleanup"
expect_argv "$trace/cleanup.argv" state "$root" cleanup 0 --dry-run
destination="$scratch/command with 'quotes' and \$(false)"
local_cli link --path "$destination" --replace
expect_argv "$trace/links.argv" links "$root" install "$destination" "$root/bin/claude" --replace
local_cli uninstall
has_event tooling-uninstall || fail 'uninstall could not dispatch without runtime dependencies'
pass 'cleanup, command ownership and uninstall work after runtime dependencies disappear'

reset_trace
if TM_FIXTURE_FAIL_PROBE=1 PATH="$guards:$PATH" "$host_bash" "$cli" --root "$root" --prefix "$prefix" install \
    > "$trace/rejected-candidate.out" 2> "$trace/rejected-candidate.err"; then fail 'failed candidate startup returned success'; fi
has_event acquisition-copy || fail 'failed candidate fixture never reached candidate checks'
if has_event state-activate; then fail 'candidate activated despite failed startup'; fi
if has_event default-claude-links; then fail 'failed candidate changed default commands'; fi
[[ ! -e $trace/active ]] || fail 'failed candidate changed active selection'
(shopt -s nullglob; leftovers=("$root/cache"/.lifecycle.*); ((${#leftovers[@]} == 0))) || fail 'failed install leaked lifecycle scratch'
pass 'failed startup prevents activation and cleans transaction scratch'

reset_trace
TM_FIXTURE_FAIL_CLEANUP=1 PATH="$guards:$PATH" "$host_bash" "$cli" --root "$root" --prefix "$prefix" install \
    > "$trace/active.out" 2> "$trace/active.err" || fail 'post-activation cleanup failure masked successful install'
[[ -s $trace/active ]] || fail 'fixture never activated candidate'
has_event state-cleanup || fail 'maintenance failure fixture was not exercised'
has_event default-claude-links || fail 'normal install did not set up default Claude'
awk '/^state-activate$/ {active=1} /^default-claude-links$/ {if(!active) exit 1; found=1} END {if(!found) exit 1}' "$trace/events" || fail 'command takeover preceded activation'
grep -Fq -- 'is active' "$trace/active.out" || fail 'successful activation was not reported'
grep -Eiq -- 'cleanup.*(attention|warning)|warning.*cleanup' "$trace/active.err" || fail 'maintenance failure lacked actionable warning'
if has_event forbidden-network; then fail 'CLI regression attempted a real download'; fi
(shopt -s nullglob; leftovers=("$root/cache"/.lifecycle.*); ((${#leftovers[@]} == 0))) || fail 'successful install leaked lifecycle scratch'
pass 'successful activation survives cleanup failure with a maintenance warning'

reset_trace
PATH="$guards:$PATH" "$host_bash" "$cli" --root "$root" --prefix "$prefix" install --no-link > "$trace/no-link.out"
has_event state-activate || fail 'no-link prevented runtime installation'
if has_event default-claude-links; then fail 'no-link changed command entries'; fi
pass 'explicit no-link installs a runtime without command takeover'

printf 'PASS: %s CLI behavior groups\n' "$count"
