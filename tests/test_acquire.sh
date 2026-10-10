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
    https://registry.npmjs.org/@anthropic-ai%2fclaude-code-linux-arm64-musl/2.1.295) input=$TM_TEST_SOURCE/registry.json ;;
    https://downloads.claude.ai/claude-code-releases/latest|https://downloads.claude.ai/claude-code-releases/stable) input=$TM_TEST_SOURCE/channel ;;
    https://downloads.claude.ai/claude-code-releases/2.1.295/manifest.json) input=$TM_TEST_SOURCE/manifest.json ;;
    https://downloads.claude.ai/claude-code-releases/2.1.295/manifest.json.sig) input=$TM_TEST_SOURCE/manifest.json.sig ;;
    https://registry.npmjs.org/@anthropic-ai/claude-code-linux-arm64-musl/-/claude-code-linux-arm64-musl-*.tgz) input=$TM_TEST_SOURCE/npm.tgz ;;
    https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/musl-1.2.6-r2.apk) input=$TM_TEST_SOURCE/musl.apk ;;
    *) exit 42 ;;
esac
cp -- "$input" "$output"
[[ ${TM_TEST_CORRUPT:-false} != true ]] || printf corrupt >> "$output"
[[ -z ${TM_TEST_CORRUPT_URL:-} || $url != *"$TM_TEST_CORRUPT_URL" ]] || printf corrupt >> "$output"
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

# Signed releases. The fixture is Anthropic's real manifest and signature for
# 2.1.295, checked against the release key built into the helper.
fixture signed
signed=$test_work/signed
record=$test_root/tests/fixtures/release-2.1.295.json
signed_digest=$("$TM_CORE" json-get "$record" linux_arm64_musl_sha256)
"$TM_CORE" json-get "$record" manifest_base64 | base64 -d > "$signed/manifest.json"
"$TM_CORE" json-get "$record" signature_base64 | base64 -d > "$signed/manifest.json.sig"
"$TM_CORE" json-get "$record" foreign_signature_base64 | base64 -d > "$signed/foreign.sig"
[[ $("$TM_CORE" sha256 "$signed/manifest.json") == "$("$TM_CORE" json-get "$record" manifest_sha256)" ]]
"$TM_CORE" acquire-plan "$signed/compatibility.json" 2.1.295 signed "$signed/registry.json" \
    "$signed/manifest.json" "$signed/manifest.json.sig" > "$signed/plan.json"
[[ $("$TM_CORE" json-get "$signed/plan.json" compatibility_status) == signed ]]
[[ $("$TM_CORE" json-get "$signed/plan.json" verified) == true ]]
[[ $("$TM_CORE" json-get "$signed/plan.json" claude.binary_sha256) == "$signed_digest" ]]
[[ $("$TM_CORE" json-get "$signed/plan.json" claude.signed_manifest_sha256) == "$("$TM_CORE" json-get "$record" manifest_sha256)" ]]
[[ $("$TM_CORE" json-get "$signed/plan.json" claude.signing_key) == 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE ]]
[[ ! -e "$signed/manifest.json.sig.key" ]] || fail 'staged release key was left behind'
pass "Anthropic's signature admits an exact version and supplies the executable digest"

sed 's/2\.1\.295/2.1.296/' "$signed/manifest.json" > "$signed/tampered.json"
must_fail signature_invalid "$TM_CORE" acquire-plan "$signed/compatibility.json" 2.1.295 signed "$signed/registry.json" "$signed/tampered.json" "$signed/manifest.json.sig"
must_fail signature_invalid "$TM_CORE" acquire-plan "$signed/compatibility.json" 2.1.295 signed "$signed/registry.json" "$signed/manifest.json" "$signed/foreign.sig"
head -c 400 "$signed/manifest.json.sig" > "$signed/truncated.sig"
must_fail signature_invalid "$TM_CORE" acquire-plan "$signed/compatibility.json" 2.1.295 signed "$signed/registry.json" "$signed/manifest.json" "$signed/truncated.sig"
: > "$signed/empty.sig"
must_fail signature_invalid "$TM_CORE" acquire-plan "$signed/compatibility.json" 2.1.295 signed "$signed/registry.json" "$signed/manifest.json" "$signed/empty.sig"
[[ ! -e "$signed/foreign.sig.key" && ! -e "$signed/truncated.sig.key" && ! -e "$signed/empty.sig.key" ]] || fail 'staged release key was left behind after a rejection'
pass 'tampered manifest, another signer, and damaged or empty signatures are rejected'

# The release key also signs inline documents. One of those is not a detached
# signature for anything, whatever the installed gpgv would make of it.
"$TM_CORE" json-get "$record" inline_signed_base64 | base64 -d > "$signed/inline-signed"
grep -q -- '-----BEGIN PGP SIGNED MESSAGE-----' "$signed/inline-signed"
must_fail 'not a detached signature' "$TM_CORE" acquire-plan "$signed/compatibility.json" 2.1.295 signed "$signed/registry.json" "$signed/manifest.json" "$signed/inline-signed"
sed 's/BEGIN PGP SIGNED MESSAGE/BEGIN PGP SIGNATURE/' "$signed/inline-signed" > "$signed/relabelled-inline"
must_fail signature_invalid "$TM_CORE" acquire-plan "$signed/compatibility.json" 2.1.295 signed "$signed/registry.json" "$signed/manifest.json" "$signed/relabelled-inline"
printf '%s\n' '-----BEGIN PGP SIGNATURE-----' 'no blank line or packets' > "$signed/hollow.sig"
must_fail 'not a detached signature' "$TM_CORE" acquire-plan "$signed/compatibility.json" 2.1.295 signed "$signed/registry.json" "$signed/manifest.json" "$signed/hollow.sig"
pass 'a document signed inline by the release key is not a detached manifest signature'

# The verdict is read from gpgv's machine status, strictly. A stand-in gpgv
# replays each report an untrustworthy or older verifier could produce.
mkdir -- "$test_work/gpgv-bin" "$test_work/no-gpgv"
printf '#!%s\nprintf "%%s\\n" "$TM_TEST_GPGV_STATUS"\nexit "${TM_TEST_GPGV_EXIT:-0}"\n' "$(command -v bash)" > "$test_work/gpgv-bin/gpgv"
chmod 700 "$test_work/gpgv-bin/gpgv"
signer=31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE
goodsig="[GNUPG:] GOODSIG BAA929FF1A7ECACE Anthropic Claude Code Release Signing <security@anthropic.com>"
validsig="[GNUPG:] VALIDSIG $signer 2026-10-08 1791479448 0 4 0 1 10 00 $signer"
replay() {
    TM_TEST_GPGV_STATUS=$1 TM_TEST_GPGV_EXIT=${2:-0} PATH="$test_work/gpgv-bin:$PATH" "$TM_CORE" acquire-plan \
        "$signed/compatibility.json" 2.1.295 signed "$signed/registry.json" "$signed/manifest.json" "$signed/manifest.json.sig"
}
replay "$goodsig"$'\n'"$validsig" > "$signed/replayed-plan.json"
cmp -- "$signed/plan.json" "$signed/replayed-plan.json"
must_fail signature_invalid replay "$goodsig"$'\n'"$validsig" 1
must_fail signature_invalid replay "$goodsig"
must_fail signature_invalid replay "$validsig"
must_fail signature_invalid replay ''
must_fail signature_invalid replay "$goodsig"$'\n'"${validsig/ 00 / 01 }"
must_fail signature_invalid replay "$goodsig"$'\n'"${validsig% *} 0000000000000000000000000000000000000000"
must_fail signature_invalid replay "$goodsig"$'\n'"[GNUPG:] VALIDSIG $signer"
must_fail signature_invalid replay "$goodsig"$'\n'"$validsig"$'\n'"$goodsig"$'\n'"$validsig"
for refusal in 'BADSIG BAA929FF1A7ECACE x' 'ERRSIG BAA929FF1A7ECACE 1 10 00 1791479448 9' 'EXPSIG BAA929FF1A7ECACE x' \
    'EXPKEYSIG BAA929FF1A7ECACE x' 'REVKEYSIG BAA929FF1A7ECACE x' 'NO_PUBKEY BAA929FF1A7ECACE'; do
    must_fail signature_invalid replay "$goodsig"$'\n'"$validsig"$'\n'"[GNUPG:] $refusal"
done
must_fail prerequisites env PATH="$test_work/no-gpgv" "$TM_CORE" acquire-plan "$signed/compatibility.json" 2.1.295 signed "$signed/registry.json" "$signed/manifest.json" "$signed/manifest.json.sig"
pass 'only one good signature of the binary manifest by the built-in key is accepted; gpgv is required'

# A genuine signature for a different version does not admit this one, a
# channel name is not a version, and the signature is never optional.
sed 's/"version":"2\.1\.295"/"version":"2.1.294"/' "$signed/registry.json" > "$signed/registry-294.json"
must_fail invalid_metadata "$TM_CORE" acquire-plan "$signed/compatibility.json" 2.1.294 signed "$signed/registry-294.json" "$signed/manifest.json" "$signed/manifest.json.sig"
must_fail invalid_version "$TM_CORE" acquire-plan "$signed/compatibility.json" latest signed
must_fail invalid_arguments "$TM_CORE" acquire-plan "$signed/compatibility.json" 2.1.295 signed "$signed/registry.json"
must_fail unverified_version "$TM_CORE" acquire-plan "$signed/compatibility.json" 2.1.295 pinned
pass 'a signature covers one exact version and cannot be skipped by the signed policy'

# The registry archive here does not hold the executable Anthropic signed.
mkdir -- "$signed/release"
must_fail integrity_failed "$TM_CORE" acquire-extract "$signed/plan.json" "$signed/npm.tgz" "$signed/musl.apk" "$signed/release"
[[ ! -e "$signed/release/payload.json" ]]
pass 'an executable that differs from the signed SHA-256 is rejected'

# Receipt round trip for a signed release, using the fixture executable's own digest.
fixture_digest=$("$TM_CORE" sha256 "$signed/original-claude")
sed "s/$signed_digest/$fixture_digest/" "$signed/plan.json" > "$signed/matching-plan.json"
mkdir -- "$signed/accepted" "$signed/rebuilt"
"$TM_CORE" acquire-extract "$signed/matching-plan.json" "$signed/npm.tgz" "$signed/musl.apk" "$signed/accepted" > "$signed/receipt.json"
[[ $("$TM_CORE" json-get "$signed/accepted/payload.json" compatibility_status) == signed ]]
[[ $("$TM_CORE" json-get "$signed/accepted/payload.json" verified) == true ]]
[[ $("$TM_CORE" json-get "$signed/accepted/payload.json" claude.signing_key) == 31DDDE24DDFAB679F42D7BD2BAA929FF1A7ECACE ]]
"$TM_CORE" acquire-plan "$signed/accepted/payload.json" pinned pinned > "$signed/repair-plan.json"
"$TM_CORE" acquire-extract "$signed/repair-plan.json" "$signed/npm.tgz" "$signed/musl.apk" "$signed/rebuilt" > /dev/null
cmp -- "$signed/accepted/payload.json" "$signed/rebuilt/payload.json"
sed 's/"compatibility_status":"signed"/"compatibility_status":"pinned"/' "$signed/accepted/payload.json" > "$signed/relabelled.json"
must_fail invalid_metadata "$TM_CORE" acquire-plan "$signed/relabelled.json" pinned pinned
grep -v signed_manifest_sha256 "$signed/accepted/payload.json" > "$signed/stripped.json"
must_fail invalid_metadata "$TM_CORE" acquire-plan "$signed/stripped.json" pinned pinned
pass 'signed receipt keeps its provenance, repairs offline and cannot be relabelled'

# The shell layer: channel pointer, signed manifest and signature downloads.
export TM_TEST_SOURCE="$signed"
printf '2.1.295' > "$signed/channel"
: > "$TM_TEST_CURL_LOG"
[[ $(tm_channel_version latest) == 2.1.295 && $(tm_channel_version stable) == 2.1.295 ]]
must_fail invalid_channel tm_channel_version nightly
printf '%s\n' '<html>not a version</html>' > "$signed/channel"
must_fail invalid_channel tm_channel_version latest
: > "$signed/channel"
must_fail invalid_channel tm_channel_version latest
: > "$TM_TEST_CURL_LOG"
tm_acquire_plan "$signed/compatibility.json" 2.1.295 signed false "$signed/shell-plan.json"
cmp -- "$signed/plan.json" "$signed/shell-plan.json"
mapfile -t requests < "$TM_TEST_CURL_LOG"
[[ ${#requests[@]} == 3 && ${requests[1]} == */2.1.295/manifest.json && ${requests[2]} == */2.1.295/manifest.json.sig ]]
must_fail offline_unavailable tm_acquire_plan "$signed/compatibility.json" 2.1.295 signed true "$signed/offline-plan.json"
# Bytes appended to the downloaded manifest are not the bytes Anthropic signed.
export TM_TEST_CORRUPT_URL=/manifest.json
must_fail signature_invalid tm_acquire_plan "$signed/compatibility.json" 2.1.295 signed false "$signed/corrupt-plan.json"
unset TM_TEST_CORRUPT_URL
[[ ! -e "$signed/offline-plan.json" && ! -e "$signed/corrupt-plan.json" ]]
: > "$TM_TEST_CURL_LOG"
tm_acquire_plan "$signed/compatibility.json" pinned signed false "$signed/pin-plan.json"
[[ ! -s $TM_TEST_CURL_LOG && $("$TM_CORE" json-get "$signed/pin-plan.json" compatibility_status) == pinned ]]
pass 'channel lookup and signed plans download only the registry record, manifest and signature'

# Cache cleanup: the pin and every retained release keep their source archives;
# archives that nothing retained refers to are removed.
store=$test_work/prune-root
"$TM_CORE" with-lock "$store" create -- true
retain() {
    "$TM_CORE" with-lock "$store" existing -- bash -c '
        set -euo pipefail
        core=$1 root=$2 version=$3 integrity=$4 archive=$5
        id=$("$core" state "$root" candidate "$version")
        release=$root/releases/$id
        mkdir -- "$release/lib"
        printf "binary %s\n" "$version" > "$release/claude"
        printf "loader\n" > "$release/lib/ld-musl-aarch64.so.1"
        printf "{\"schema\":1,\"backend\":\"unmodified-musl-proot\",\"version\":\"%s\",\"claude\":{\"binary_sha256\":\"%s\"%s},\"musl\":{\"loader_sha256\":\"%s\"%s}}\n" \
            "$version" "$("$core" sha256 "$release/claude")" "${integrity:+,\"integrity\":\"$integrity\"}" \
            "$("$core" sha256 "$release/lib/ld-musl-aarch64.so.1")" "${archive:+,\"sha256\":\"$archive\"}" > "$release/payload.json"
        printf "{\"status\":\"PASS\",\"version\":\"%s\"}\n" "$version" > "$release/test-acceptance.json"
        "$core" state "$root" validate "$id" "$release/test-acceptance.json"
        "$core" state "$root" activate "$id"
    ' _ "$TM_CORE" "$store" "$@"
}
prune() { "$TM_CORE" with-lock "$store" existing -- "$TM_CORE" acquire-prune "$store" "$valid/compatibility.json" "$@"; }
apk_digest=$("$TM_CORE" json-get "$valid/compatibility.json" musl.sha256)
retain 2.1.271 "$("$TM_CORE" json-get "$test_work/next-plan.json" claude.integrity)" "$apk_digest"
retain 2.1.295 "$("$TM_CORE" json-get "$signed/plan.json" claude.integrity)" "$apk_digest"
kept=("$("$TM_CORE" acquire-field "$valid/plan.json" claude-cache)" "$("$TM_CORE" acquire-field "$test_work/next-plan.json" claude-cache)"
      "$("$TM_CORE" acquire-field "$signed/plan.json" claude-cache)" "$("$TM_CORE" acquire-field "$valid/plan.json" musl-cache)")
[[ ${#kept[@]} == 4 && ${kept[0]} != "${kept[1]}" && ${kept[1]} != "${kept[2]}" ]]
zeros=0000000000000000000000000000000000000000000000000000000000000000
stale=("sha512-$zeros$zeros.archive" "sha256-$zeros.archive")
for name in "${kept[@]}" "${stale[@]}" notes.txt; do printf 'archive %s\n' "$name" > "$store/cache/$name"; done
printf preserve > "$test_work/prune-foreign"
ln -s "$test_work/prune-foreign" "$store/cache/sha256-${zeros/0/1}.archive"
mkdir -- "$store/cache/.acquire.leftover"
must_fail lock_required "$TM_CORE" acquire-prune "$store" "$valid/compatibility.json"
prune --dry-run > "$test_work/prune-dry.json"
[[ $("$TM_CORE" json-get "$test_work/prune-dry.json" count) == 2 && $("$TM_CORE" json-get "$test_work/prune-dry.json" complete) == true ]]
for name in "${stale[@]}"; do [[ -f $store/cache/$name ]] || fail 'dry run removed an archive'; done
prune > "$test_work/prune.json"
[[ $("$TM_CORE" json-get "$test_work/prune.json" count) == 2 && $("$TM_CORE" json-get "$test_work/prune.json" bytes) -gt 0 ]]
for name in "${stale[@]}"; do [[ ! -e $store/cache/$name ]] || fail 'unused archive was kept'; done
for name in "${kept[@]}" notes.txt; do [[ -f $store/cache/$name ]] || fail "cache cleanup removed $name"; done
[[ -L $store/cache/sha256-${zeros/0/1}.archive && $(<"$test_work/prune-foreign") == preserve && -d $store/cache/.acquire.leftover ]]
prune > "$test_work/prune-again.json"
[[ $("$TM_CORE" json-get "$test_work/prune-again.json" count) == 0 ]]
# A retained release whose receipt names no sources makes every archive worth keeping.
retain 2.1.296 '' ''
printf 'archive\n' > "$store/cache/${stale[1]}"
prune > "$test_work/prune-unknown.json"
[[ $("$TM_CORE" json-get "$test_work/prune-unknown.json" complete) == false && $("$TM_CORE" json-get "$test_work/prune-unknown.json" count) == 0 ]]
[[ -f $store/cache/${stale[1]} ]]
pass 'cache cleanup keeps pin and retained sources, removes the rest, and spares links, foreign files and unknown receipts'

# versions --available: one registry document labelled against the pin and the
# installation. Numeric ordering, limits, local releases and hostile tags.
listing=$test_work/listing
mkdir -- "$listing"
printf '%s\n' '{"schema":1,"claude":{"version":"2.1.10","pinned_since":"0.3.0","package":"@anthropic-ai/claude-code-linux-arm64-musl"},"pin_history":[{"version":"2.1.9","project_versions":{"first":"0.1.0","last":"0.2.0"},"verified_on":"2026-01-09","report":"compatibility/fixture.json"}]}' > "$listing/compatibility.json"
cat > "$listing/registry.json" <<'JSON'
{"name":"@anthropic-ai/claude-code-linux-arm64-musl",
 "dist-tags":{"latest":"2.1.11","stable":"2.1.9","Bad\u001b[31m":"2.1.11","next":"9.9.9"},
 "versions":{"2.1.8":{},"2.1.9":{},"2.1.10":{},"2.1.11":{"deprecated":"broken"},"2.1.12-beta.1":{},"0.0.0":{}},
 "time":{"2.1.8":"2026-01-08T00:00:00.000Z","2.1.9":"2026-01-09T00:00:00.000Z","2.1.10":"2026-01-10T00:00:00.000Z","2.1.11":"not a date"}}
JSON
fresh=$listing/fresh-root
"$TM_CORE" acquire-available "$listing/compatibility.json" "$listing/registry.json" "$fresh" all text > "$listing/all.txt"
[[ ! -e $fresh ]] || fail 'listing created an installation root'
diff -u - "$listing/all.txt" <<'TEXT' || fail 'available listing text changed'
Claude Code releases for Termux (linux-arm64-musl), newest first:

VERSION    RELEASED    STATUS
2.1.11     -           unverified, deprecated, latest
2.1.10     2026-01-10  pinned
2.1.9      2026-01-09  formerly pinned (0.1.0 to 0.2.0), stable
2.1.8      2026-01-08  unverified
0.0.0      -           unverified

The pinned release passed acceptance with this Termux Muscle version; a formerly
pinned release passed with the Termux Muscle releases shown. Every other version
is unverified by this project and is installed only when Anthropic's release
signature verifies:
  termux-muscle update                          newest release (latest channel)
  termux-muscle update --claude-version X.Y.Z   one exact release
TEXT
"$TM_CORE" acquire-available "$listing/compatibility.json" "$listing/registry.json" "$fresh" 1 text > "$listing/one.txt"
grep -Fq '2.1.11 ' "$listing/one.txt" && grep -Fq '2.1.10 ' "$listing/one.txt" || fail 'limit hid the pinned release'
grep -Fq '2.1.9      2026-01-09  formerly pinned (0.1.0 to 0.2.0), stable' "$listing/one.txt" || fail 'limit hid the formerly pinned release'
! grep -Fq '2.1.8 ' "$listing/one.txt" || fail 'limit ignored'
grep -Fq 'Showing 3 of 5 releases; add --all' "$listing/one.txt" || fail 'limit summary missing'
root=$listing/root
"$TM_CORE" with-lock "$root" create -- true
old=$("$TM_CORE" with-lock "$root" existing -- bash "$test_root/tests/test_state.sh" --candidate "$TM_CORE" "$root" 2.1.8 activate)
"$TM_CORE" with-lock "$root" existing -- bash "$test_root/tests/test_state.sh" --candidate "$TM_CORE" "$root" 2.1.7 activate > /dev/null
"$TM_CORE" acquire-available "$listing/compatibility.json" "$listing/registry.json" "$root" 2 json > "$listing/local.json"
[[ -n $old && $("$TM_CORE" json-get "$listing/local.json" schema) == termux-muscle.available.v1 ]] || fail 'listing schema'
[[ $("$TM_CORE" json-get "$listing/local.json" active) == 2.1.7 ]] || fail 'active version'
[[ $("$TM_CORE" json-get "$listing/local.json" complete) == false ]] || fail 'partial listing reported complete'
[[ $("$TM_CORE" json-get "$listing/local.json" releases) == '[{"version":"2.1.11","released":null,"pinned":false,"formerly_pinned":null,"active":false,"retained":false,"tags":["latest"],"deprecated":true,"in_registry":true},{"version":"2.1.10","released":"2026-01-10","pinned":true,"formerly_pinned":null,"active":false,"retained":false,"tags":[],"deprecated":false,"in_registry":true},{"version":"2.1.9","released":"2026-01-09","pinned":false,"formerly_pinned":{"version":"2.1.9","project_versions":{"first":"0.1.0","last":"0.2.0"},"verified_on":"2026-01-09","report":"compatibility/fixture.json"},"active":false,"retained":false,"tags":["stable"],"deprecated":false,"in_registry":true},{"version":"2.1.8","released":"2026-01-08","pinned":false,"formerly_pinned":null,"active":false,"retained":true,"tags":[],"deprecated":false,"in_registry":true},{"version":"2.1.7","released":null,"pinned":false,"formerly_pinned":null,"active":true,"retained":false,"tags":[],"deprecated":false,"in_registry":false}]' ]] ||
    { cat -- "$listing/local.json" >&2; fail 'local releases were not labelled'; }
[[ $("$TM_CORE" json-get "$listing/local.json" pin_history) == '[{"version":"2.1.9","project_versions":{"first":"0.1.0","last":"0.2.0"},"verified_on":"2026-01-09","report":"compatibility/fixture.json"}]' ]] || fail 'pin history missing from the JSON listing'
# A manifest without pin_history (older project releases) still lists.
printf '%s\n' '{"schema":1,"claude":{"version":"2.1.10","package":"@anthropic-ai/claude-code-linux-arm64-musl"}}' > "$listing/legacy.json"
"$TM_CORE" acquire-available "$listing/legacy.json" "$listing/registry.json" "$fresh" all text | grep -Fq '2.1.9      2026-01-09  unverified, stable' || fail 'legacy manifest listing changed'
# A history entry naming the current pin never demotes the pin label.
printf '%s\n' '{"schema":1,"claude":{"version":"2.1.10","package":"@anthropic-ai/claude-code-linux-arm64-musl"},"pin_history":[{"version":"2.1.10","project_versions":{"first":"0.1.0","last":"0.2.0"}}]}' > "$listing/conflict.json"
"$TM_CORE" acquire-available "$listing/conflict.json" "$listing/registry.json" "$fresh" all text | grep -Fq '2.1.10     2026-01-10  pinned' || fail 'conflicting history demoted the pin'

printf '%s\n' '{"name":"@evil/claude-code-linux-arm64-musl","versions":{}}' > "$listing/other.json"
must_fail invalid_metadata "$TM_CORE" acquire-available "$listing/compatibility.json" "$listing/other.json" "$fresh" all text
must_fail invalid_arguments "$TM_CORE" acquire-available "$listing/compatibility.json" "$listing/registry.json" "$fresh" 0 text
must_fail invalid_arguments "$TM_CORE" acquire-available "$listing/compatibility.json" "$listing/registry.json" "$fresh" all yaml
pass 'available versions: numeric order, pin/formerly-pinned/active/retained labels, limits and safe tags'
printf 'Acquisition regression groups passed: %s\n' "$test_count"
