#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail

# This private fixture operation runs under the helper's inherited mutation lock.
if [[ ${1:-} == --fixture ]]; then
    core=$2 root=$3 prefix=$4 binary=$5 loader=$6
    version=${7:-2.1.270}
    id=$("$core" state "$root" candidate "$version")
    release="$root/releases/$id"
    mkdir -p -- "$release/lib"
    cp -- "$binary" "$release/claude"
    cp -- "$loader" "$release/lib/ld-musl-aarch64.so.1"
    chmod 700 "$release/claude" "$release/lib/ld-musl-aarch64.so.1"
    binary_hash=$(sha256sum "$release/claude"); binary_hash=${binary_hash%% *}
    loader_hash=$(sha256sum "$release/lib/ld-musl-aarch64.so.1"); loader_hash=${loader_hash%% *}
    printf '{"schema":1,"backend":"unmodified-musl-proot","version":"%s","claude":{"binary_sha256":"%s"},"musl":{"loader_sha256":"%s"}}\n' \
        "$version" "$binary_hash" "$loader_hash" > "$release/payload.json"
    "$core" context "$root" "$prefix" "$id"
    printf '{"status":"PASS","version":"%s"}\n' "$version" > "$release/test-acceptance.json"
    "$core" state "$root" validate "$id" "$release/test-acceptance.json" >/dev/null
    "$core" state "$root" activate "$id" >/dev/null
    printf '%s\n' "$id"
    exit
fi

# A release prepared for the native backend. Launch checks use the digests of
# the installed files recorded under "native", not those of the originals.
if [[ ${1:-} == --fixture-native ]]; then
    core=$2 root=$3 prefix=$4 binary=$5 loader=$6 resolver=$7
    id=$("$core" state "$root" candidate 2.1.270)
    release="$root/releases/$id"
    mkdir -p -- "$release/lib"
    cp -- "$binary" "$release/claude"
    cp -- "$loader" "$release/lib/ld-musl-aarch64.so.1"
    cp -- "$resolver" "$release/lib/tm-resolver.so"
    chmod 700 "$release/claude" "$release/lib/ld-musl-aarch64.so.1" "$release/lib/tm-resolver.so"
    zeros=0000000000000000000000000000000000000000000000000000000000000000
    printf '{"schema":1,"backend":"musl-native","version":"2.1.270","claude":{"binary_sha256":"%s"},"musl":{"loader_sha256":"%s"},"native":{"binary_sha256":"%s","loader_sha256":"%s","resolver_sha256":"%s","interpreter":"%s"}}\n' \
        "$zeros" "$zeros" "$("$core" sha256 "$release/claude")" "$("$core" sha256 "$release/lib/ld-musl-aarch64.so.1")" \
        "$("$core" sha256 "$release/lib/tm-resolver.so")" "$release/lib/ld-musl-aarch64.so.1" > "$release/payload.json"
    "$core" context "$root" "$prefix" "$id"
    printf '{"status":"PASS","version":"2.1.270"}\n' > "$release/test-acceptance.json"
    "$core" state "$root" validate "$id" "$release/test-acceptance.json" >/dev/null
    "$core" state "$root" activate "$id" >/dev/null
    printf '%s\n' "$id"
    exit
fi

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
core=$(realpath -- "${TM_CORE:-$repo/build/tm-core}")
script="$repo/tests/test_runtime.sh"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tm-runtime-test.XXXXXXXX")
live_supervisor= live_group=
cleanup_fixture() {
    if [[ -n $live_supervisor ]]; then kill -KILL "$live_supervisor" 2>/dev/null || true; wait "$live_supervisor" 2>/dev/null || true; fi
    if [[ -n $live_group ]]; then kill -KILL -- "-$live_group" 2>/dev/null || true; fi
    rm -rf -- "$scratch"
}
trap cleanup_fixture EXIT
root="$scratch/installation with spaces"
prefix="$scratch/termux prefix"
mkdir -p -- "$prefix/bin" "$prefix/etc/tls"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror "$repo/tests/runtime_probe.c" -o "$scratch/probe"
cp -- "$scratch/probe" "$prefix/bin/proot"
ln -s -- "$(command -v bash)" "$prefix/bin/bash"
ln -s -- "$(command -v env)" "$prefix/bin/env"
for helper in mktemp chmod rm; do ln -s -- "$(command -v "$helper")" "$prefix/bin/$helper"; done
cp -- "$scratch/probe" "$prefix/bin/rg"
printf 'nameserver 192.0.2.1\n' > "$prefix/etc/resolv.conf"
printf 'fixture CA\n' > "$prefix/etc/tls/cert.pem"
printf 'fixture loader\n' > "$scratch/loader"
chmod 700 "$scratch/loader"
id=$("$core" with-lock "$root" create -- bash "$script" --fixture \
    "$core" "$root" "$prefix" "$scratch/probe" "$scratch/loader")
release="$root/releases/$id"
count=0
pass() { printf 'PASS runtime: %s\n' "$1"; count=$((count + 1)); }
fail() { printf 'FAIL runtime: %s\n' "$1" >&2; exit 1; }
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }
line() { printf '%s:%s\n' "$1" "$(hex "$2")"; }
contains() { grep -Fxq -- "$2" "$1" || fail "$3"; }
rejects() {
    local code=$1; shift
    if "$@" > "$scratch/rejected.out" 2> "$scratch/rejected.err"; then fail "expected rejection: $code"; fi
    grep -Fq -- ": $code:" "$scratch/rejected.err" || {
        cat "$scratch/rejected.err" >&2; fail "wrong rejection category: $code";
    }
}

[[ $(sha256sum "$scratch/probe" | cut -d ' ' -f 1) == $(sha256sum "$release/claude" | cut -d ' ' -f 1) ]] || fail 'vendor fixture modified'
[[ $(stat -c %a "$release/namespace.json") == 600 ]] || fail 'context permissions'
[[ $(stat -c %a "$release/runtime-tmp") == 700 ]] || fail 'temporary permissions'
pass 'context creation preserves source bytes and private permissions'

arguments=(auth login -- "spaces and 'quotes'" '*' '$(false)' '' $'line\nbreak' '{"key":"a b"}')
TM_CUSTOM_TEST='preserve-me' "$core" run "$root" "$prefix" current normal -- "${arguments[@]}" > "$scratch/normal"
grep '^arg:' "$scratch/normal" | tail -n "${#arguments[@]}" > "$scratch/actual-arguments"
for value in "${arguments[@]}"; do line arg "$value"; done > "$scratch/expected-arguments"
cmp "$scratch/actual-arguments" "$scratch/expected-arguments" || fail 'argument corruption'
contains "$scratch/normal" 'lease:inherited' 'shared lease must survive exec'
contains "$scratch/normal" "$(line TM_CUSTOM_TEST preserve-me)" 'caller environment lost'
pass 'native exec preserves exact arguments and inherited lease'

bindings=(
    "$release/lib/ld-musl-aarch64.so.1:/lib/ld-musl-aarch64.so.1!"
    "$release/lib/ld-musl-aarch64.so.1:/lib/libc.musl-aarch64.so.1!"
    "$prefix/etc/resolv.conf:/etc/resolv.conf!"
    "$(realpath "$prefix/bin/bash"):/bin/sh!"
    "$(realpath "$prefix/bin/env"):/usr/bin/env!"
    "$release/runtime-tmp:/tmp!"
    "$release/namespace.json:/.termux-muscle-namespace.json!"
)
for value in "${bindings[@]}"; do contains "$scratch/normal" "$(line arg "$value")" 'missing precise bind'; done
[[ $(grep -Fxc "$(line arg -b)" "$scratch/normal") == 7 ]] || fail 'unexpected broad/additional bindings'
if grep -Fxq "$(line arg --kill-on-exit)" "$scratch/normal"; then fail 'normal runtime must preserve background lifetime'; fi
pass 'exact loader, resolver, shell, env and temporary mappings'

"$core" run "$root" "$prefix" current probe -- --version > "$scratch/probe-output"
contains "$scratch/probe-output" "$(line arg --kill-on-exit)" 'probe child cleanup flag absent'
pass 'probe cleanup is separate from normal runtime behavior'

"$core" shell-probe "$root" "$prefix" current > "$scratch/shell-probe-command"
for value in "${bindings[@]}"; do contains "$scratch/shell-probe-command" "$(line arg "$value")" 'shell probe changed namespace binds'; done
contains "$scratch/shell-probe-command" "$(line arg --kill-on-exit)" 'shell probe child cleanup flag absent'
contains "$scratch/shell-probe-command" "$(line arg "$(realpath "$prefix/bin/bash")")" 'shell probe must use known Bash'
contains "$scratch/shell-probe-command" 'lease:inherited' 'shell probe lost release lease'
if grep -Fxq "$(line arg "$release/claude")" "$scratch/shell-probe-command"; then fail 'shell probe must not execute vendor binary'; fi
rejects usage "$core" shell-probe "$root" "$prefix" current unexpected
pass 'namespace-only shell probe shares exact verified binds and retained lease'

printf 'int tm_preload_fixture(void) { return 1; }\n' > "$scratch/preload.c"
"${CC:-cc}" -shared -fPIC "$scratch/preload.c" -o "$scratch/preload.so"
LD_PRELOAD="$scratch/preload.so" LD_LIBRARY_PATH="$scratch" "$core" run "$root" "$prefix" current normal -- > "$scratch/environment"
if grep -Eq '^(LD_PRELOAD|LD_LIBRARY_PATH):' "$scratch/environment"; then fail 'incompatible loader settings leaked'; fi
contains "$scratch/environment" "$(line DISABLE_AUTOUPDATER 1)" 'updater protection absent'
pass 'Bionic-compatible caller preload is cleared before payload launch'

printf 'nameserver 198.51.100.1\n' > "$prefix/etc/resolv.conf"
"$core" run "$root" "$prefix" current normal -- > "$scratch/resolver"
contains "$scratch/resolver" "$(line arg "$prefix/etc/resolv.conf:/etc/resolv.conf!")" 'resolver was snapshotted'
[[ ! -e "$release/resolv.conf" ]] || fail 'unexpected resolver snapshot'
printf 'nameserver 203.0.113.1\n' > "$scratch/custom resolver"
printf 'custom CA\n' > "$scratch/custom CA"
TM_RESOLV_CONF="$scratch/custom resolver" SSL_CERT_FILE="$scratch/custom CA" \
    "$core" run "$root" "$prefix" current normal -- > "$scratch/overrides"
contains "$scratch/overrides" "$(line arg "$scratch/custom resolver:/etc/resolv.conf!")" 'resolver override lost'
contains "$scratch/overrides" "$(line SSL_CERT_FILE "$scratch/custom CA")" 'CA override lost'
pass 'live resolver source and explicit resolver/CA choices are preserved'

status=0
TM_PROBE_EXIT=23 "$core" run "$root" "$prefix" current normal -- > /dev/null || status=$?
[[ $status == 23 ]] || fail 'exit status changed'
status=0
TM_PROBE_SIGNAL=2 "$core" run "$root" "$prefix" current normal -- > /dev/null || status=$?
[[ $status == 130 ]] || fail 'interrupt status changed'
pass 'native exec preserves exit code and interrupt semantics'

cp -- "$release/namespace.json" "$scratch/context saved"
rm -- "$release/namespace.json"
ln -s -- "$scratch/context saved" "$release/namespace.json"
rejects unsafe_path "$core" run "$root" "$prefix" current normal --
rm -- "$release/namespace.json"; cp -- "$scratch/context saved" "$release/namespace.json"
mv -- "$release/runtime-tmp" "$release/runtime-tmp saved"
ln -s -- "$scratch" "$release/runtime-tmp"
rejects unsafe_path "$core" run "$root" "$prefix" current normal --
rm -- "$release/runtime-tmp"; mv -- "$release/runtime-tmp saved" "$release/runtime-tmp"
pass 'context and temporary-directory symlinks cannot redirect managed paths'

printf 'corruption\n' >> "$release/claude"
rejects integrity_failed "$core" run "$root" "$prefix" current normal --
cp -- "$scratch/probe" "$release/claude"; chmod 700 "$release/claude"
pass 'altered native bytes are rejected before execution'

# ------------------------------------------------------------ native backend
resolver_object="$repo/build/tm-resolver.so"
[[ -f $resolver_object ]] || fail 'the native resolver object was not built'
native_root="$scratch/native installation"
# LD_PRELOAD cannot name a path with spaces, so this prefix has none.
native_prefix="$scratch/native-prefix"
mkdir -p -- "$native_prefix/bin" "$native_prefix/etc/tls" "$native_prefix/tmp"
ln -s -- "$(command -v bash)" "$native_prefix/bin/bash"
ln -s -- "$(command -v env)" "$native_prefix/bin/env"
for helper in mktemp chmod rm; do ln -s -- "$(command -v "$helper")" "$native_prefix/bin/$helper"; done
# The shell diagnostic really runs here, so it needs a real ripgrep.
real_rg=$(command -v rg || :)
if [[ -n $real_rg ]]; then ln -s -- "$real_rg" "$native_prefix/bin/rg"; else cp -- "$scratch/probe" "$native_prefix/bin/rg"; fi
printf 'nameserver 192.0.2.1\n' > "$native_prefix/etc/resolv.conf"
printf 'fixture CA\n' > "$native_prefix/etc/tls/cert.pem"
native_id=$("$core" with-lock "$native_root" create -- bash "$script" --fixture-native \
    "$core" "$native_root" "$native_prefix" "$scratch/probe" "$scratch/loader" "$resolver_object")
native_release="$native_root/releases/$native_id"
native() { "$core" run "$native_root" "$native_prefix" current normal -- --report "$@"; }

TM_CUSTOM_TEST='preserve-me' native "${arguments[@]}" > "$scratch/native-normal"
grep '^arg:' "$scratch/native-normal" > "$scratch/native-arguments"
cmp "$scratch/native-arguments" "$scratch/expected-arguments" || fail 'native argument corruption'
contains "$scratch/native-normal" "$(line self "$native_release/claude")" 'native release did not start its own executable'
if grep -Fxq "$(line arg -b)" "$scratch/native-normal"; then fail 'a native release was started through PRoot'; fi
contains "$scratch/native-normal" 'lease:inherited' 'native launch lost the release lease'
contains "$scratch/native-normal" "$(line TM_CUSTOM_TEST preserve-me)" 'native launch lost the caller environment'
contains "$scratch/native-normal" "$(line TM_PRELOAD "$native_release/lib/tm-resolver.so")" 'resolver object not named for the private loader'
contains "$scratch/native-normal" "$(line TM_RESOLV_CONF "$native_prefix/etc/resolv.conf")" 'resolver file not named'
contains "$scratch/native-normal" "$(line DISABLE_AUTOUPDATER 1)" 'updater protection absent'
contains "$scratch/native-normal" "$(line USE_BUILTIN_RIPGREP 0)" 'native ripgrep not selected'
contains "$scratch/native-normal" "$(line SSL_CERT_FILE "$native_prefix/etc/tls/cert.pem")" 'certificate bundle not selected'
[[ $("$core" run "$native_root" "$native_prefix" current probe -- --native-ok) == native-ok ]] || fail 'native probe launch'
pass 'native release starts its executable directly with exact arguments, lease and resolver settings'

# The private loader does not read LD_PRELOAD or LD_LIBRARY_PATH, so they stay
# in place for the Android programs Claude Code runs.
mkdir -- "$scratch/caller tmp"
LD_PRELOAD="$scratch/preload.so" LD_LIBRARY_PATH="$scratch" TM_LIBRARY_PATH=/redirected \
    TMPDIR="$scratch/caller tmp" native > "$scratch/native-environment"
contains "$scratch/native-environment" "$(line LD_PRELOAD "$scratch/preload.so")" 'native launch removed the caller preload'
contains "$scratch/native-environment" "$(line LD_LIBRARY_PATH "$scratch")" 'native launch removed the caller library path'
if grep -q '^TM_LIBRARY_PATH:' "$scratch/native-environment"; then fail 'a caller could redirect the private loader library path'; fi
contains "$scratch/native-environment" "$(line TMPDIR "$scratch/caller tmp")" 'native launch replaced the caller temporary directory'
contains "$scratch/native-environment" "$(line CLAUDE_CODE_TMPDIR "$scratch/caller tmp")" 'Claude Code scratch not pointed at a writable directory'
TMPDIR="$scratch/caller tmp" CLAUDE_CODE_TMPDIR="$scratch" native > "$scratch/native-environment"
contains "$scratch/native-environment" "$(line CLAUDE_CODE_TMPDIR "$scratch")" 'an explicit Claude Code scratch directory was replaced'
env -u TMPDIR -u CLAUDE_CODE_TMPDIR "$core" run "$native_root" "$native_prefix" current normal -- --report > "$scratch/native-environment"
contains "$scratch/native-environment" "$(line TMPDIR "$native_prefix/tmp")" 'no temporary directory was supplied'
contains "$scratch/native-environment" "$(line CLAUDE_CODE_TMPDIR "$native_prefix/tmp")" 'no Claude Code scratch directory was supplied'
# Started without a preload, as from a service, Claude Code's tools still get
# Termux's termux-exec when the prefix has it. A caller's own preload is kept.
env -u LD_PRELOAD "$core" run "$native_root" "$native_prefix" current normal -- --report > "$scratch/native-environment"
if grep -q '^LD_PRELOAD:' "$scratch/native-environment"; then fail 'a preload was invented for a prefix without termux-exec'; fi
mkdir -- "$native_prefix/lib"
cp -- "$scratch/preload.so" "$native_prefix/lib/libtermux-exec.so"
env -u LD_PRELOAD "$core" run "$native_root" "$native_prefix" current normal -- --report > "$scratch/native-environment"
contains "$scratch/native-environment" "$(line LD_PRELOAD "$native_prefix/lib/libtermux-exec.so")" 'termux-exec was not supplied to a launch without a preload'
cp -- "$scratch/preload.so" "$native_prefix/lib/libtermux-exec-ld-preload.so"
env -u LD_PRELOAD "$core" run "$native_root" "$native_prefix" current normal -- --report > "$scratch/native-environment"
contains "$scratch/native-environment" "$(line LD_PRELOAD "$native_prefix/lib/libtermux-exec-ld-preload.so")" 'the current termux-exec library name was not preferred'
LD_PRELOAD="$scratch/preload.so" native > "$scratch/native-environment"
contains "$scratch/native-environment" "$(line LD_PRELOAD "$scratch/preload.so")" 'a caller preload was replaced by the default'
[[ $("$core" state "$native_root" versions | tail -n 1) =~ ^Current\ +2\.1\.270\ +unknown\ +native$ ]] || fail 'versions did not show the native backend'
[[ $("$core" state "$root" versions | tail -n 1) =~ ^Current\ +2\.1\.270\ +unknown\ +proot$ ]] || fail 'versions did not show the PRoot backend'
printf 'nameserver 203.0.113.1\n' > "$scratch/native resolver"
TM_RESOLV_CONF="$scratch/native resolver" SSL_CERT_FILE="$scratch/custom CA" native > "$scratch/native-environment"
contains "$scratch/native-environment" "$(line TM_RESOLV_CONF "$scratch/native resolver")" 'native resolver override lost'
contains "$scratch/native-environment" "$(line SSL_CERT_FILE "$scratch/custom CA")" 'native CA override lost'
status=0; TM_PROBE_EXIT=23 native > /dev/null || status=$?
[[ $status == 23 ]] || fail 'native exit status changed'
status=0; TM_PROBE_SIGNAL=2 native > /dev/null || status=$?
[[ $status == 130 ]] || fail 'native interrupt status changed'
pass "native launch keeps the caller's linker variables, temporary directory, overrides and exit status"

if [[ -n $real_rg ]]; then
    printf 'printf startup-hook-ran > "%s"\n' "$scratch/native hook result" > "$scratch/native startup hook"
    [[ $(BASH_ENV="$scratch/native startup hook" ENV="$scratch/native startup hook" \
        "$core" shell-probe "$native_root" "$native_prefix" current) == namespace_shell:PASS ]] || fail 'native shell diagnostic'
    [[ ! -e "$scratch/native hook result" ]] || fail 'native shell diagnostic sourced a caller startup hook'
    (shopt -s nullglob; remnants=("$native_release/runtime-tmp"/.native-probe.*); ((${#remnants[@]} == 0))) || fail 'native shell diagnostic left scratch'
    pass 'native shell diagnostic runs Termux shell, a script and ripgrep without PRoot or startup hooks'
else
    printf 'SKIP runtime: native shell diagnostic needs ripgrep\n'
fi

for file in claude lib/ld-musl-aarch64.so.1 lib/tm-resolver.so; do
    cp -- "$native_release/$file" "$scratch/native saved"
    printf 'corruption\n' >> "$native_release/$file"
    rejects integrity_failed "$core" run "$native_root" "$native_prefix" current normal -- --report
    cp -- "$scratch/native saved" "$native_release/$file"; chmod 700 "$native_release/$file"
done
cp -- "$native_release/payload.json" "$scratch/native receipt"
sed 's/"musl-native"/"chroot"/' "$scratch/native receipt" > "$native_release/payload.json"
rejects invalid_backend "$core" run "$native_root" "$native_prefix" current normal -- --report
sed 's/,"native":{.*}}$/}/' "$scratch/native receipt" > "$native_release/payload.json"
if "$core" run "$native_root" "$native_prefix" current normal -- --report > /dev/null 2>&1; then fail 'a native receipt without installed digests was launched'; fi
cp -- "$scratch/native receipt" "$native_release/payload.json"
native > /dev/null
pass 'altered native files and receipts are rejected before execution'

# A running native session holds its release against cleanup, as PRoot's does.
"$core" with-lock "$native_root" existing -- bash "$script" --fixture-native \
    "$core" "$native_root" "$native_prefix" "$scratch/probe" "$scratch/loader" "$resolver_object" > /dev/null
"$core" with-lock "$native_root" existing -- bash "$script" --fixture-native \
    "$core" "$native_root" "$native_prefix" "$scratch/probe" "$scratch/loader" "$resolver_object" > /dev/null
"$scratch/probe" --supervise "$core" "$native_root" "$native_prefix" "$native_id" "$scratch/native ready" "$scratch/native child" &
live_supervisor=$!
for ((attempt=0; attempt<100; attempt++)); do
    [[ -s "$scratch/native ready" && -s "$scratch/native child" ]] && break
    sleep 0.05
done
[[ -s "$scratch/native ready" && -s "$scratch/native child" ]] || fail 'native lease subprocess did not initialize'
read -r live_group < "$scratch/native child"
kill -KILL "$live_supervisor"
wait "$live_supervisor" 2>/dev/null || true
live_supervisor=
"$core" with-lock "$native_root" existing -- "$core" state "$native_root" cleanup 2 > "$scratch/native lease busy"
[[ -d "$native_release" ]] || fail 'cleanup removed a native release that a session was running'
kill -KILL -- "-$live_group"
live_group=
for ((attempt=0; attempt<100; attempt++)); do
    "$core" with-lock "$native_root" existing -- "$core" state "$native_root" cleanup 2 > "$scratch/native lease released"
    [[ ! -d "$native_release" ]] && break
    sleep 0.05
done
[[ ! -d "$native_release" ]] || fail 'an ended native session kept blocking cleanup'
pass 'a running native session keeps its release through cleanup and frees it on exit'

# The resolver object, loaded into an initialized process as musl loads it.
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror "$repo/tests/resolver_fixture.c" -o "$scratch/resolver-fixture" -ldl
printf 'nameserver 192.0.2.53\n' > "$scratch/resolver file"
resolved() { TM_RESOLV_CONF=$1 "$scratch/resolver-fixture" "$resolver_object" "${2:-empty}"; }
[[ $(resolved "$scratch/resolver file") == "cloexec $scratch/resolver file" ]] || fail 'resolver file was not opened close-on-exec on descriptor 99'
[[ $(resolved "$scratch/resolver file" occupied) == "cloexec $scratch/resolver file" ]] || fail 'a descriptor already on 99 was kept'
[[ $(resolved "$scratch/absent resolver") == none ]] || fail 'a missing resolver file produced a descriptor'
[[ $(resolved "$scratch/absent resolver" occupied) == 'inherited /dev/null' ]] || fail 'a missing resolver file disturbed descriptor 99'
[[ $(cd -- "$scratch" && resolved 'resolver file') == none ]] || fail 'a relative resolver path was opened'
[[ $(env -u TM_RESOLV_CONF "$scratch/resolver-fixture" "$resolver_object" empty) == none ]] || fail 'a descriptor appeared with no resolver named'
# musl satisfies a dependency named libc itself; anything else would not load.
if command -v readelf > /dev/null; then
    if readelf -d "$resolver_object" | grep NEEDED | grep -qv 'Shared library: \[libc\.'; then fail 'the resolver object needs a library other than libc'; fi
fi
pass 'resolver object opens the named file on descriptor 99, close-on-exec, and nothing else'

if [[ ${TM_RUNTIME_HOST_PROBES:-0} == 1 ]]; then
    host_prefix=$(realpath -- "${TM_TEST_PREFIX:-${PREFIX:?PREFIX required for host probes}}")
    host_root="$scratch/host installation"
    first=$("$core" with-lock "$host_root" create -- bash "$script" --fixture \
        "$core" "$host_root" "$host_prefix" "$scratch/probe" "$scratch/loader")
    second=$("$core" with-lock "$host_root" existing -- bash "$script" --fixture \
        "$core" "$host_root" "$host_prefix" "$scratch/probe" "$scratch/loader")
    [[ $(timeout -k 3 20 "$core" run "$host_root" "$host_prefix" "$first" probe -- --shell) == shell-ok ]] || fail 'actual /bin/sh binding'
    printf '#!/usr/bin/env bash\nprintf portable-ok\n' > "$scratch/portable hook"
    chmod 700 "$scratch/portable hook"
    [[ $(timeout -k 3 20 "$core" run "$host_root" "$host_prefix" "$first" probe -- --portable "$scratch/portable hook") == portable-ok ]] || fail 'portable shebang'
    [[ $(timeout -k 3 20 "$core" run "$host_root" "$host_prefix" "$first" probe -- --nested "$core" "$host_root" "$host_prefix") == native-identity-ok ]] || fail 'nested release pin'
    rejects runtime_nested_conflict timeout -k 3 20 "$core" run "$host_root" "$host_prefix" "$first" probe -- \
        --nested-exact "$core" "$host_root" "$host_prefix" "$second"
    pass 'REAL PRoot shell, portable shebang, nested pin and candidate-conflict probes'

    printf 'printf startup-hook-ran > "%s"\n' "$scratch/startup hook result" > "$scratch/startup hook"
    [[ $(BASH_ENV="$scratch/startup hook" ENV="$scratch/startup hook" \
        timeout -k 3 20 "$core" shell-probe "$host_root" "$host_prefix" "$first") == namespace_shell:PASS ]] || fail 'namespace shell probe'
    [[ ! -e "$scratch/startup hook result" ]] || fail 'namespace diagnostic sourced a caller startup hook'
    [[ $(timeout -k 3 20 "$core" run "$host_root" "$host_prefix" "$first" probe -- \
        --nested-shell-probe "$core" "$host_root" "$host_prefix") == namespace_shell:PASS ]] || fail 'nested namespace shell probe'
    # A bad portable-command PATH must be reported as failure, and the scratch
    # must still be cleaned by the same fixture's EXIT trap.
    if PATH=/nonexistent "$(command -v timeout)" -k 3 20 "$core" shell-probe "$host_root" "$host_prefix" "$first" \
        > "$scratch/shell-probe-failed.out" 2> "$scratch/shell-probe-failed.err"; then fail 'portable lookup failure was hidden'; fi
    (shopt -s nullglob; remnants=("$host_root/releases/$first/runtime-tmp"/.namespace-probe.*); ((${#remnants[@]} == 0))) || fail 'shell probe left scratch after success or failure'
    pass 'REAL namespace shell probe checks sh/env/rg, nested pin and failure cleanup (no model request)'

    third=$("$core" with-lock "$host_root" existing -- bash "$script" --fixture \
        "$core" "$host_root" "$host_prefix" "$scratch/probe" "$scratch/loader")
    "$scratch/probe" --supervise "$core" "$host_root" "$host_prefix" "$first" "$scratch/lease ready" "$scratch/lease child" &
    live_supervisor=$!
    for ((attempt=0; attempt<100; attempt++)); do
        [[ -s "$scratch/lease ready" && -s "$scratch/lease child" ]] && break
        sleep 0.05
    done
    [[ -s "$scratch/lease ready" && -s "$scratch/lease child" ]] || fail 'lease subprocess did not initialize'
    read -r live_group < "$scratch/lease child"
    kill -KILL "$live_supervisor"
    wait "$live_supervisor" 2>/dev/null || true
    live_supervisor=
    "$core" with-lock "$host_root" existing -- "$core" state "$host_root" cleanup 2 > "$scratch/lease busy"
    [[ -d "$host_root/releases/$first" ]] || fail 'supervisor death released a still-running PRoot lease'
    kill -KILL -- "-$live_group"
    live_group=
    for ((attempt=0; attempt<100; attempt++)); do
        "$core" with-lock "$host_root" existing -- "$core" state "$host_root" cleanup 2 > "$scratch/lease released"
        [[ ! -d "$host_root/releases/$first" ]] && break
        sleep 0.05
    done
    [[ ! -d "$host_root/releases/$first" ]] || fail 'dead PRoot lease blocked later cleanup'
    pass 'REAL PRoot retains a live release after supervisor SIGKILL and releases it on exit'

    if [[ -n ${TM_TEST_VENDOR_BINARY:-} && -n ${TM_TEST_MUSL_LOADER:-} ]]; then
        vendor_id=$("$core" with-lock "$host_root" existing -- bash "$script" --fixture \
            "$core" "$host_root" "$host_prefix" "$TM_TEST_VENDOR_BINARY" "$TM_TEST_MUSL_LOADER" "${TM_TEST_VENDOR_VERSION:-2.1.270}")
        timeout -k 3 30 "$core" run "$host_root" "$host_prefix" "$vendor_id" probe -- --version > "$scratch/vendor-version"
        grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+ \(Claude Code\)$' "$scratch/vendor-version" || fail 'official native version'
        pass 'REAL unmodified vendor version probe (no authentication or model request)'
        dispatch_id=$("$core" with-lock "$host_root" existing -- bash "$script" --fixture \
            "$core" "$host_root" "$host_prefix" "$scratch/probe" "$TM_TEST_MUSL_LOADER")
        printf 'TM_NATIVE_EMBEDDED_GREP_OK\n' > "$scratch/grep fixture"
        result=$(timeout -k 3 30 "$core" run "$host_root" "$host_prefix" "$dispatch_id" probe -- \
            --exec-argv0 "$host_root/releases/$vendor_id/claude" ugrep -G TM_NATIVE_EMBEDDED_GREP_OK "$scratch/grep fixture")
        [[ $result == TM_NATIVE_EMBEDDED_GREP_OK ]] || fail 'vendor embedded-tool argv0 dispatch'
        pass 'REAL unmodified vendor embedded grep retains custom argv0 dispatch'
    else
        printf 'SKIP runtime: official vendor probe requires explicit verified binary and loader paths\n'
    fi
else
    printf 'SKIP runtime: real PRoot/vendor probes require TM_RUNTIME_HOST_PROBES=1\n'
fi
printf 'PASS: %s runtime behavior groups\n' "$count"
