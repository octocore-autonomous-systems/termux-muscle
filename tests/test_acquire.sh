#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
test_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
export TM_CORE=${TM_CORE:-$test_root/build/tm-core}
test_work=$(mktemp -d "${TMPDIR:-/tmp}/termux-muscle-acquire-test.XXXXXXXX")
trap 'rm -rf -- "$test_work"' EXIT
read -r -a test_cflags <<< "$(pkg-config --cflags json-c libarchive libcrypto)"
read -r -a test_ldflags <<< "$(pkg-config --libs json-c libarchive libcrypto)"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"$test_root/src" "${test_cflags[@]}" \
    "$test_root/tests/acquire_fixture.c" "$test_root/src/common.c" "${test_ldflags[@]}" -o "$test_work/fixture"
# shellcheck source=../lib/acquire.sh
source "$test_root/lib/acquire.sh"
test_count=0

pass() { printf 'PASS acquire: %s\n' "$1"; test_count=$((test_count + 1)); }
fail() { printf 'FAIL acquire: %s\n' "$1" >&2; exit 1; }
must_fail() {
    local expected=$1; shift
    if "$@" > "$test_work/rejected.out" 2> "$test_work/rejected.err"; then fail "unexpected success: $expected"; fi
    [[ $(<"$test_work/rejected.err") == *"$expected"* ]] || {
        cat -- "$test_work/rejected.err" >&2; fail "wrong rejection category; expected $expected"
    }
}
fixture() {
    mkdir -- "$test_work/$1"
    "$test_work/fixture" "$test_work/$1" "$1"
}
fixture valid
valid=$test_work/valid
"$TM_CORE" acquire-plan "$valid/compatibility.json" pinned pinned > "$valid/plan.json"
[[ $("$TM_CORE" acquire-field "$valid/plan.json" status) == ready ]]
[[ $("$TM_CORE" acquire-field "$valid/plan.json" version) == 2.1.270 ]]
mkdir -- "$valid/release with 'quotes' and spaces"
"$TM_CORE" acquire-extract "$valid/plan.json" "$valid/npm.tgz" "$valid/musl.apk" "$valid/release with 'quotes' and spaces" > "$valid/result.json"
cmp -- "$valid/original-claude" "$valid/release with 'quotes' and spaces/claude"
cmp -- "$valid/original-loader" "$valid/release with 'quotes' and spaces/lib/ld-musl-aarch64.so.1"
[[ -s "$valid/release with 'quotes' and spaces/licenses/claude-LICENSE.md" ]]
[[ $("$TM_CORE" json-get "$valid/result.json" verified) == true ]]
pass 'unmodified vendor bytes, license, exact hashes and concatenated gzip/PAX APK'

for mode in rpath-first runpath-first; do
    fixture "$mode"
    "$TM_CORE" acquire-plan "$test_work/$mode/compatibility.json" pinned pinned > "$test_work/$mode/plan.json"
    mkdir -- "$test_work/$mode/release"
    "$TM_CORE" acquire-extract "$test_work/$mode/plan.json" "$test_work/$mode/npm.tgz" "$test_work/$mode/musl.apk" "$test_work/$mode/release" > "$test_work/$mode/result.json"
    cmp -- "$test_work/$mode/original-claude" "$test_work/$mode/release/claude"
    pass "empty $mode does not change supported dynamic dependencies"
done

must_fail candidate_not_empty "$TM_CORE" acquire-extract "$valid/plan.json" "$valid/npm.tgz" "$valid/musl.apk" "$valid/release with 'quotes' and spaces"
pass 'existing candidate preserved'
for mode in traversal duplicate symlink parent-link; do
    fixture "$mode"
    "$TM_CORE" acquire-plan "$test_work/$mode/compatibility.json" pinned pinned > "$test_work/$mode/plan.json"
    mkdir -- "$test_work/$mode/release"
    must_fail unsafe_archive "$TM_CORE" acquire-extract "$test_work/$mode/plan.json" "$test_work/$mode/npm.tgz" "$test_work/$mode/musl.apk" "$test_work/$mode/release"
    [[ ! -e "$test_work/$mode/release/payload.json" ]]
    pass "reject $mode archive"
done
[[ ! -e "$test_work/escape" ]]
for mode in wrong-arch wrong-interpreter wrong-dependency wrong-searchpath-first wrong-load-size wrong-load-range loader-no-load; do
    fixture "$mode"
    "$TM_CORE" acquire-plan "$test_work/$mode/compatibility.json" pinned pinned > "$test_work/$mode/plan.json"
    mkdir -- "$test_work/$mode/release"
    must_fail invalid_elf "$TM_CORE" acquire-extract "$test_work/$mode/plan.json" "$test_work/$mode/npm.tgz" "$test_work/$mode/musl.apk" "$test_work/$mode/release"
    pass "reject $mode despite matching archive and payload hashes"
done
for mode in wrong-binary-hash wrong-loader-hash; do
    fixture "$mode"
    "$TM_CORE" acquire-plan "$test_work/$mode/compatibility.json" pinned pinned > "$test_work/$mode/plan.json"
    mkdir -- "$test_work/$mode/release"
    must_fail integrity_failed "$TM_CORE" acquire-extract "$test_work/$mode/plan.json" "$test_work/$mode/npm.tgz" "$test_work/$mode/musl.apk" "$test_work/$mode/release"
    pass "reject $mode independently of archive integrity"
done
for mode in missing-loader manifest-mismatch manifest-nul truncated; do
    fixture "$mode"
    "$TM_CORE" acquire-plan "$test_work/$mode/compatibility.json" pinned pinned > "$test_work/$mode/plan.json"
    mkdir -- "$test_work/$mode/release"
    expected=invalid_archive; [[ $mode != manifest-* ]] || expected=invalid_metadata
    must_fail "$expected" "$TM_CORE" acquire-extract "$test_work/$mode/plan.json" "$test_work/$mode/npm.tgz" "$test_work/$mode/musl.apk" "$test_work/$mode/release"
    pass "reject $mode"
done
fixture expansion-bomb
"$TM_CORE" acquire-plan "$test_work/expansion-bomb/compatibility.json" pinned pinned > "$test_work/expansion-bomb/plan.json"
mkdir -- "$test_work/expansion-bomb/release"
must_fail archive_too_large "$TM_CORE" acquire-extract "$test_work/expansion-bomb/plan.json" "$test_work/expansion-bomb/npm.tgz" "$test_work/expansion-bomb/musl.apk" "$test_work/expansion-bomb/release"
pass 'decoded padding cannot bypass expansion limit'

fixture nonofficial
must_fail invalid_source "$TM_CORE" acquire-plan "$test_work/nonofficial/compatibility.json" pinned pinned
must_fail invalid_version "$TM_CORE" acquire-plan "$valid/compatibility.json" '../latest' allow-unverified
must_fail unverified_version "$TM_CORE" acquire-plan "$valid/compatibility.json" latest pinned
fixture metadata-other
must_fail invalid_source "$TM_CORE" acquire-plan "$test_work/metadata-other/compatibility.json" latest allow-unverified "$test_work/metadata-other/registry.json"
pass 'official exact source paths, explicit version policy and registry identity enforced'

mkdir -- "$test_work/mock-bin"
printf '#!%s\n' "$(command -v bash)" > "$test_work/mock-bin/curl"
cat >> "$test_work/mock-bin/curl" <<'MOCK'
set -euo pipefail
[[ $1 == -q ]] || exit 40
output='' url='' maximum='' protocol='' deadline=''
while (( $# )); do
    case $1 in
        --output) output=$2; shift 2 ;;
        --max-filesize) maximum=$2; shift 2 ;;
        --proto) protocol=$2; shift 2 ;;
        --max-time) deadline=$2; shift 2 ;;
        --connect-timeout|--write-out) shift 2 ;;
        --) url=$2; shift 2 ;;
        -L|--location|-k|--insecure) exit 41 ;;
        *) shift ;;
    esac
done
[[ $protocol == '=https' && $deadline == 180 && $maximum =~ ^[0-9]+$ ]]
printf '%s\n' "$url" >> "$TM_TEST_CURL_LOG"
case $url in
    https://registry.npmjs.org/@anthropic-ai%2fclaude-code-linux-arm64-musl/latest) input=$TM_TEST_SOURCE/registry.json ;;
    https://registry.npmjs.org/@anthropic-ai/claude-code-linux-arm64-musl/-/claude-code-linux-arm64-musl-*.tgz) input=$TM_TEST_SOURCE/npm.tgz ;;
    https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/musl-1.2.6-r2.apk) input=$TM_TEST_SOURCE/musl.apk ;;
    *) exit 42 ;;
esac
cp -- "$input" "$output"
[[ ${TM_TEST_CORRUPT:-false} != true ]] || printf corrupt >> "$output"
printf '%s' "${TM_TEST_HTTP:-200}"
MOCK
chmod 700 "$test_work/mock-bin/curl"
export PATH="$test_work/mock-bin:$PATH" TM_TEST_CURL_LOG="$test_work/curl.log" TM_TEST_SOURCE="$valid"
mkdir -- "$test_work/online" "$test_work/cache"
tm_acquire "$test_work/online" "$test_work/cache" "$valid/compatibility.json" pinned pinned false > "$test_work/online-result.json"
mapfile -t requests < "$TM_TEST_CURL_LOG"
[[ ${#requests[@]} == 2 ]]
pass 'Bash download limits, curlrc suppression, HTTPS-only and source verification'
mkdir -- "$test_work/offline"
: > "$TM_TEST_CURL_LOG"
tm_acquire "$test_work/offline" "$test_work/cache" "$valid/compatibility.json" pinned pinned true > "$test_work/offline-result.json"
[[ ! -s $TM_TEST_CURL_LOG ]]
cmp -- "$test_work/online/payload.json" "$test_work/offline/payload.json"
pass 'offline reconstruction reuses verified archives without HTTP or authentication'

cache_key=$("$TM_CORE" acquire-field "$valid/plan.json" claude-cache)
printf damaged > "$test_work/cache/$cache_key"
mkdir -- "$test_work/damaged-offline" "$test_work/repaired-cache"
must_fail offline_unavailable tm_acquire "$test_work/damaged-offline" "$test_work/cache" "$valid/compatibility.json" pinned pinned true
tm_acquire "$test_work/repaired-cache" "$test_work/cache" "$valid/compatibility.json" pinned pinned false > "$test_work/repaired-result.json"
mapfile -t requests < "$TM_TEST_CURL_LOG"
[[ ${#requests[@]} == 1 ]]
pass 'damaged cache rejected offline and repaired online'

mkdir -- "$test_work/symlink-cache" "$test_work/symlink-release"
printf preserve > "$test_work/foreign"
ln -s "$test_work/foreign" "$test_work/symlink-cache/$cache_key"
must_fail unsafe_path tm_acquire "$test_work/symlink-release" "$test_work/symlink-cache" "$valid/compatibility.json" pinned pinned false
[[ $(<"$test_work/foreign") == preserve ]]
pass 'cache symlink and foreign content preserved'

mkdir -- "$test_work/bad-download" "$test_work/bad-cache" "$test_work/redirect-release" "$test_work/redirect-cache"
export TM_TEST_CORRUPT=true
must_fail integrity_failed tm_acquire "$test_work/bad-download" "$test_work/bad-cache" "$valid/compatibility.json" pinned pinned false
unset TM_TEST_CORRUPT
[[ ! -e "$test_work/bad-download/payload.json" && ! -e "$test_work/bad-cache/$cache_key" ]]
export TM_TEST_HTTP=302
must_fail download_failed tm_acquire "$test_work/redirect-release" "$test_work/redirect-cache" "$valid/compatibility.json" pinned pinned false
unset TM_TEST_HTTP
pass 'bad downloads and redirects never publish a payload or cache archive'

fixture unverified
export TM_TEST_SOURCE="$test_work/unverified"
mkdir -- "$test_work/next" "$test_work/next-cache" "$test_work/next-repair"
tm_acquire_plan "$TM_TEST_SOURCE/compatibility.json" latest allow-unverified false "$test_work/next-plan.json"
[[ $("$TM_CORE" acquire-field "$test_work/next-plan.json" version) == 2.1.271 ]]
tm_acquire "$test_work/next" "$test_work/next-cache" "$test_work/next-plan.json" pinned allow-unverified false > "$test_work/next-result.json"
[[ $("$TM_CORE" json-get "$test_work/next-result.json" verified) == false ]]
must_fail unverified_version "$TM_CORE" acquire-plan "$test_work/next/payload.json" pinned pinned
: > "$TM_TEST_CURL_LOG"
tm_acquire "$test_work/next-repair" "$test_work/next-cache" "$test_work/next/payload.json" pinned allow-unverified true > "$test_work/next-repair-result.json"
[[ ! -s $TM_TEST_CURL_LOG ]]
cmp -- "$test_work/next/payload.json" "$test_work/next-repair/payload.json"
must_fail offline_unavailable tm_acquire_plan "$valid/compatibility.json" latest allow-unverified true "$test_work/no-offline-latest.json"
pass 'explicit unverified version resolution, truthful receipt and offline repair'
printf 'Acquisition regression groups passed: %s\n' "$test_count"
