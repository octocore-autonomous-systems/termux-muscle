#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
ulimit -c 0
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
repository=$PWD
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
cc -std=c11 -Wall -Wextra -Wpedantic -Isrc $(pkg-config --cflags json-c libcrypto) \
    tests/diagnostics_fixture.c src/common.c src/state.c src/links.c $(pkg-config --libs json-c libcrypto) -o "$temporary/fixture"
"$temporary/fixture" tests "$temporary/probe.pid"
export TM_CORE=${TM_DIAGNOSTICS_TEST_CORE:-$repository/build/tm-core} TM_SOURCE=$repository TM_ROOT=$temporary/absent TM_PREFIX=${PREFIX:-/usr}
source lib/diagnostics.sh
export ANTHROPIC_API_KEY=PRIVATE_SECRET TERMUX_APK_RELEASE=PRIVATE_SECRET TERMUX_VERSION=/PRIVATE_SECRET
if tm_diagnostics doctor --output "$temporary/report.json" 2>"$temporary/message"; then
    printf '%s\n' 'Expected absent runtime doctor failure.' >&2; exit 1
fi
"$temporary/fixture" validate "$temporary/report.json"
[[ $(stat -c %a "$temporary/report.json") == 600 ]]
digest=$("$TM_CORE" sha256 "$temporary/report.json")
if tm_diagnostics doctor --output "$temporary/report.json" 2>/dev/null; then exit 1; fi
[[ $("$TM_CORE" sha256 "$temporary/report.json") == "$digest" ]]
ln -s "$temporary/report.json" "$temporary/report-link"
if tm_diagnostics doctor --output "$temporary/report-link" 2>/dev/null; then exit 1; fi
[[ -L $temporary/report-link ]]
if tm_diagnostics doctor --model claude-fable-5-1 --output "$temporary/no-auth.json" 2>/dev/null; then exit 1; fi
[[ ! -e $temporary/no-auth.json ]]
if tm_diagnostics test --model opus --output "$temporary/no-alias.json" 2>/dev/null; then exit 1; fi
[[ ! -e $temporary/no-alias.json ]]
if tm_diagnostics test --model claude-fable-5-1 --model claude-fable-5-1 --output "$temporary/no-duplicate.json" 2>/dev/null; then exit 1; fi
[[ ! -e $temporary/no-duplicate.json ]]
printf '%s\n' 'PASS diagnostics local report, unknown-runtime evidence, allowlist, mode0600, no overwrite, and explicit model gating'

# A FIFO without a writer must fail promptly rather than hanging in open().
mkfifo "$temporary/source-fifo"
status=0
timeout --kill-after=1 2 "$TM_CORE" report --publish "$temporary/source-fifo" "$temporary/fifo-report.json" 2>/dev/null || status=$?
[[ $status == 1 && -p $temporary/source-fifo && ! -e $temporary/fifo-report.json ]]

mkdir "$temporary/output-real"
ln -s "$temporary/output-real" "$temporary/output-link"
if tm_diagnostics doctor --output "$temporary/output-link/linked-report.json" 2>/dev/null; then exit 1; fi
"$temporary/fixture" validate "$temporary/output-real/linked-report.json"
[[ $(stat -c %a "$temporary/output-real/linked-report.json") == 600 ]]

# Test the internal no-replace boundary directly, bypassing Bash's precheck.
cp "$temporary/report.json" "$temporary/completed.json"
if "$TM_CORE" report --publish "$temporary/completed.json" "$temporary/report.json" 2>/dev/null; then exit 1; fi
[[ -f $temporary/completed.json && $("$TM_CORE" sha256 "$temporary/report.json") == "$digest" ]]
if "$TM_CORE" report --publish "$temporary/completed.json" "$temporary/report-link" 2>/dev/null; then exit 1; fi
[[ -f $temporary/completed.json && -L $temporary/report-link ]]
"$TM_CORE" report --publish "$temporary/completed.json" "$temporary/output-link/direct-report.json"
[[ ! -e $temporary/completed.json && -f $temporary/output-real/direct-report.json ]]

for signal in HUP INT TERM; do
    directory=$temporary/interrupt-$signal
    mkdir "$directory"
    # Async test jobs inherit ignored SIGINT from Bash. Restore the foreground
    # terminal disposition before starting the shell whose traps we exercise.
    TM_CORE=$temporary/fixture TM_REPORT_TEST_PIDFILE=$directory/probe.pid \
        timeout --kill-after=1 5 "$temporary/fixture" exec-reset-signals "$(command -v bash)" \
        -c 'source "$TM_SOURCE/lib/diagnostics.sh"; tm_diagnostics doctor --output "$1"' \
        bash "$directory/report.json" >"$directory/stdout" 2>"$directory/stderr" &
    controller=$!
    for ((attempt=0; attempt<200; attempt++)); do
        [[ -s $directory/probe.pid ]] && break
        sleep 0.01
    done
    read -r probe_pid wrapper_pid <"$directory/probe.pid"
    kill -s "$signal" "$wrapper_pid"
    status=0
    wait "$controller" || status=$?
    case $signal in HUP) [[ $status == 129 ]];; INT) [[ $status == 130 ]];; TERM) [[ $status == 143 ]];; esac
    ! kill -0 "$probe_pid" 2>/dev/null
    [[ ! -e $directory/report.json ]]
    shopt -s nullglob
    leftovers=("$directory"/.termux-muscle-report.*)
    [[ ${#leftovers[@]} == 0 ]]
done
printf '%s\n' 'PASS publication FIFO rejection, symlinked parents, internal no-replace, and shell HUP/INT/TERM cleanup'

mkdir -p "$temporary/resolver/etc"
env -u TM_RESOLV_CONF "$temporary/fixture" resolver "$temporary/resolver" resolver_unavailable
printf '%s\n' '# nameserver 203.0.113.53' 'search PRIVATE_SECRET' 'nameserver invalid' >"$temporary/resolver/etc/resolv.conf"
env -u TM_RESOLV_CONF "$temporary/fixture" resolver "$temporary/resolver" nameserver_missing_or_invalid
printf '%s\n' 'nameserver 203.0.113.53 # fixture only; no network query' >"$temporary/resolver/etc/resolv.conf"
env -u TM_RESOLV_CONF "$temporary/fixture" resolver "$temporary/resolver" nameserver_configured
printf '%s\n' 'nameserver 2001:db8::53' >"$temporary/resolver/override.conf"
TM_RESOLV_CONF="$temporary/resolver/override.conf" "$temporary/fixture" resolver "$temporary/absent-prefix" nameserver_configured
printf '%s\n' 'nameserver fe80::53%wlan0' >"$temporary/resolver/override.conf"
TM_RESOLV_CONF="$temporary/resolver/override.conf" "$temporary/fixture" resolver "$temporary/absent-prefix" nameserver_configured
ln -s "$temporary/resolver/override.conf" "$temporary/resolver/override-link"
TM_RESOLV_CONF="$temporary/resolver/override-link" "$temporary/fixture" resolver "$temporary/absent-prefix" nameserver_configured
TM_RESOLV_CONF="$temporary/source-fifo" timeout --kill-after=1 3 "$temporary/fixture" resolver "$temporary/resolver" resolver_not_regular
printf 'nameserver 203.0.113.53\0PRIVATE_SECRET\n' >"$temporary/resolver/override.conf"
TM_RESOLV_CONF="$temporary/resolver/override.conf" "$temporary/fixture" resolver "$temporary/resolver" resolver_contents_invalid
TM_RESOLV_CONF="$temporary/resolver/missing-override" "$temporary/fixture" resolver "$temporary/resolver" resolver_unavailable
printf '%s\n' 'PASS nine local DNS configuration cases; no addresses, paths or DNS queries emitted'

link_root=$temporary/PRIVATE_SECRET-link-root
command_dir=$temporary/PRIVATE_SECRET-commands
mkdir "$command_dir"
"$TM_CORE" with-lock "$link_root" create -- "$(command -v bash)" -c \
    'printf "#!/bin/sh\nexit 0\n" > "$1/bin/launcher"; chmod 700 "$1/bin/launcher"' fixture "$link_root"
"$temporary/fixture" links-check "$link_root" SKIP no_managed_commands
[[ ! -e $link_root/links.json ]]
"$TM_CORE" with-lock "$link_root" existing -- "$TM_CORE" links "$link_root" install "$command_dir/claude" "$link_root/bin/launcher" >/dev/null
journal_digest=$("$TM_CORE" sha256 "$link_root/links.json")
"$temporary/fixture" links-check "$link_root" PASS managed_commands_owned
[[ $(readlink "$command_dir/claude") == "$link_root/bin/launcher" && $("$TM_CORE" sha256 "$link_root/links.json") == "$journal_digest" ]]
mv "$command_dir/claude" "$temporary/saved-owned-link"
ln -s ../npm/PRIVATE_SECRET-new-claude "$command_dir/claude"
"$temporary/fixture" links-check "$link_root" FAIL managed_command_changed_or_missing
[[ $(readlink "$command_dir/claude") == ../npm/PRIVATE_SECRET-new-claude && $("$TM_CORE" sha256 "$link_root/links.json") == "$journal_digest" ]]
mv "$command_dir/claude" "$temporary/saved-foreign-link"
"$temporary/fixture" links-check "$link_root" FAIL managed_command_changed_or_missing
[[ ! -e $command_dir/claude && ! -L $command_dir/claude && $("$TM_CORE" sha256 "$link_root/links.json") == "$journal_digest" ]]
printf '{"PRIVATE_SECRET":' >"$link_root/links.json"
journal_digest=$("$TM_CORE" sha256 "$link_root/links.json")
"$temporary/fixture" links-check "$link_root" FAIL command_ownership_invalid
[[ $("$TM_CORE" sha256 "$link_root/links.json") == "$journal_digest" && ! -e $command_dir/claude ]]
printf '%s\n' 'PASS command-link ownership, npm replacement and missing-command detection, empty-index SKIP, malformed journal rejection and redaction; fixtures preserved'

# Even when version/help succeed, full initialization can fail. Exercise the
# real bounded C gate with a fake vendor process; no account or network access.
mkdir -p "$temporary/startup-prefix/bin"
for scenario in pass fail signal flood timeout; do
    printf %s "$scenario" > "$temporary/startup-prefix/scenario"
    mkdir "$temporary/startup-$scenario"
    status=FAIL detail=probe_failed
    case $scenario in
        pass) status=PASS detail=isolated_initialization_passed ;;
        flood) detail=probe_output_limit ;;
        timeout) detail=probe_timeout ;;
    esac
    env ANTHROPIC_API_KEY=PRIVATE_SECRET CLAUDE_CODE_OAUTH_TOKEN=PRIVATE_SECRET \
        NODE_OPTIONS=PRIVATE_SECRET BUN_OPTIONS=PRIVATE_SECRET \
        BASH_ENV=PRIVATE_SECRET ENV=PRIVATE_SECRET PROOT_TMP_DIR=PRIVATE_SECRET \
        CLAUDE_CONFIG_DIR=PRIVATE_SECRET CLAUDE_CODE_SIMPLE=1 TM_PRIVATE_SECRET=PRIVATE_SECRET \
        "$temporary/fixture" startup "$temporary/PRIVATE_SECRET-root" "$temporary/startup-prefix" \
        2.1.270-0123456789abcdef01234567 "$temporary/startup-$scenario" "$status" "$detail" \
        > "$temporary/startup-result-$scenario.json"
    if grep -q PRIVATE_SECRET "$temporary/startup-result-$scenario.json"; then exit 1; fi
done
printf '%s\n' 'PASS isolated startup: hostile environment stripped, private config/cwd, version/help alone insufficient, init exit/signal/flood/timeout captured without secrets'
