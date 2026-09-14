#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
if [[ ${1:-} == --candidate ]]; then
    core=$2 root=$3 version=$4
    id=$("$core" state "$root" candidate "$version")
    release=$root/releases/$id
    mkdir -- "$release/lib"
    printf 'binary version %s\n' "$version" > "$release/claude"
    printf 'loader\n' > "$release/lib/ld-musl-aarch64.so.1"
    binary=$("$core" sha256 "$release/claude")
    loader=$("$core" sha256 "$release/lib/ld-musl-aarch64.so.1")
    printf '{"schema":1,"backend":"unmodified-musl-proot","version":"%s","claude":{"binary_sha256":"%s"},"musl":{"loader_sha256":"%s"}}\n' "$version" "$binary" "$loader" > "$release/payload.json"
    printf '{"status":"PASS","version":"%s"}\n' "$version" > "$release/test-acceptance.json"
    "$core" state "$root" validate "$id" "$release/test-acceptance.json"
    [[ ${5:-} != activate ]] || "$core" state "$root" activate "$id"
    printf '%s\n' "$id"
    exit
fi
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
core=$(realpath -- "${TM_CORE:-$repo/build/tm-core}")
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tm-state-test.XXXXXXXX")
holder=
cleanup_test() { [[ ! $holder ]] || kill "$holder" 2>/dev/null || :; chmod -R u+rwX "$scratch" 2>/dev/null || :; rm -rf -- "$scratch"; }
trap cleanup_test EXIT
root=$scratch/install
count=0
pass() { printf 'PASS state: %s\n' "$1"; count=$((count + 1)); }
fail() { printf 'FAIL state: %s\n' "$1" >&2; exit 1; }
rejects() {
    local expected=$1; shift
    if "$@" > "$scratch/out" 2> "$scratch/error"; then fail "accepted $expected"; fi
    grep -Fq ": $expected:" "$scratch/error" || { cat "$scratch/error" >&2; fail "wrong failure for $expected"; }
}
locked() { "$core" with-lock "$root" existing -- "$core" state "$root" "$@"; }
new_release() { "$core" with-lock "$root" existing -- bash "$repo/tests/test_state.sh" --candidate "$core" "$root" "$1" "${2:-}"; }

"$core" with-lock "$root" create -- "$core" state "$root" show > "$scratch/initial.json"
[[ $("$core" json-get "$scratch/initial.json" current) == null ]] || fail 'initial current'
[[ $(stat -c %a "$root/installation.json") == 600 ]] || fail 'identity permissions'
rejects lock_required "$core" state "$root" candidate 1.0.0
pass 'private initialization and explicit mutation lock boundary'

mkdir "$scratch/foreign"
printf 'do not truncate\n' > "$scratch/foreign/.lock"
cp "$scratch/foreign/.lock" "$scratch/foreign-before"
rejects invalid_json "$core" with-lock "$scratch/foreign" create -- true
cmp "$scratch/foreign/.lock" "$scratch/foreign-before" || fail 'foreign lock changed'
printf 'valuable\n' > "$scratch/foreign/data"
rejects foreign_root "$core" with-lock "$scratch/foreign" create -- true
[[ $(cat "$scratch/foreign/data") == valuable ]] || fail 'foreign files changed'
pass 'foreign installation and lock bytes are preserved before mutation'

"$core" with-lock "$root" existing -- bash -c 'printf ready > "$1"; exec sleep 30' _ "$scratch/ready" &
holder=$!
for ((i=0; i<100; i++)); do [[ -f $scratch/ready ]] && break; sleep .01; done
[[ -f $scratch/ready ]] || fail 'lock holder did not start'
rejects busy "$core" with-lock "$root" existing -- true
kill -KILL "$holder"; wait "$holder" 2>/dev/null || :; holder=
"$core" with-lock "$root" existing -- true
pass 'concurrent mutation is rejected and SIGKILL releases the kernel lock'

a=$(new_release 1.0.0 activate)
b=$(new_release 1.0.1 activate)
[[ $("$core" state "$root" current) == "$b" ]] || fail 'new current'
[[ $("$core" json-get "$root/state.json" previous) == "$a" ]] || fail 'previous retained'
locked rollback
[[ $("$core" state "$root" current) == "$a" ]] || fail 'offline rollback'
locked rollback
[[ $("$core" state "$root" current) == "$b" ]] || fail 'rollback toggle'
pass 'atomic promotion and offline rollback retain both validated releases'

c=$(new_release 1.0.2)
cp "$root/state.json" "$scratch/state-before"
printf corrupt >> "$root/releases/$c/claude"
rejects integrity_failed "$core" with-lock "$root" existing -- "$core" state "$root" activate "$c"
cmp "$root/state.json" "$scratch/state-before" || fail 'failed promotion changed state'
printf corrupt >> "$root/releases/$a/lib/ld-musl-aarch64.so.1"
rejects integrity_failed "$core" with-lock "$root" existing -- "$core" state "$root" rollback
cmp "$root/state.json" "$scratch/state-before" || fail 'failed rollback changed state'
pass 'corrupt update or rollback preserves the complete active state record'

locked cleanup 2 --dry-run > "$scratch/dry.json"
[[ -d $root/releases/$c ]] || fail 'dry run deleted candidate'
locked cleanup 2 > "$scratch/deleted.json"
[[ ! -e $root/releases/$c && -d $root/releases/$a && -d $root/releases/$b ]] || fail 'retention boundary'
rejects invalid_retention "$core" with-lock "$root" existing -- "$core" state "$root" cleanup 1
pass 'bounded cleanup removes only inactive owned candidates and honors dry run'

d=$(new_release 1.0.3)
original=$root/releases/$d
tombstone=$root/releases/.deleting-$d
dev=$(stat -c %d "$original"); inode=$(stat -c %i "$original")
identity=$("$core" json-get "$root/installation.json" id)
generation=$("$core" json-get "$root/state.json" generation)
printf '{"schema":1,"installation_id":"%s","generation":%s,"current":"%s","previous":"%s","history":["%s","%s"],"deletions":[{"id":"%s","device":%s,"inode":%s}]}\n' "$identity" "$generation" "$b" "$a" "$b" "$a" "$d" "$dev" "$inode" > "$root/state.json"
mv -- "$original" "$tombstone"
rm -- "$tombstone/.owned.json" "$tombstone/.lease" "$tombstone/payload.json"
locked cleanup > "$scratch/recovered.json"
[[ ! -e $tombstone ]] || fail 'partial deletion not recovered'
[[ $("$core" json-get "$root/state.json" deletions) == '[]' ]] || fail 'deletion journal not cleared'
pass 'inode journal recovers a partially deleted release after ownership files are gone'

e=$(new_release 1.0.4)
original=$root/releases/$e
tombstone=$root/releases/.deleting-$e
dev=$(stat -c %d "$original"); inode=$(stat -c %i "$original")
printf '{"schema":1,"installation_id":"%s","generation":%s,"current":"%s","previous":"%s","history":["%s","%s"],"deletions":[{"id":"%s","device":%s,"inode":%s}]}\n' "$identity" "$generation" "$b" "$a" "$b" "$a" "$e" "$dev" "$inode" > "$root/state.json"
mv "$original" "$scratch/retained-original"
mkdir "$tombstone"; printf valuable > "$tombstone/foreign"
rejects cleanup_conflict "$core" with-lock "$root" existing -- "$core" state "$root" cleanup
[[ $(cat "$tombstone/foreign") == valuable ]] || fail 'replacement inode was deleted'
pass 'recovery preserves a foreign replacement at the journaled deletion path'

restart=$scratch/restart
mkdir "$restart"
printf '{"schema":1,"owner":"termux-muscle","installation_id":"11111111-2222-4333-a444-555555555555","phase":"initializing"}\n' > "$restart/.lock"
printf '{partial' > "$restart/.installation.json-0123456789abcdef01234567.tmp"
"$core" with-lock "$restart" create -- true
[[ $("$core" json-get "$restart/installation.json" id) == 11111111-2222-4333-a444-555555555555 ]] || fail 'initialization identity changed'
[[ ! -e $restart/.installation.json-0123456789abcdef01234567.tmp ]] || fail 'initial draft not recovered'
pass 'interrupted identity publication recovers the same journaled installation'

linkroot=$scratch/linkroot
ln -s "$restart" "$linkroot"
rejects unsafe_root "$core" with-lock "$linkroot/" create -- true
cp "$restart/state.json" "$scratch/valid-state"
printf '{"schema":1,"installation_id":"11111111-2222-4333-a444-555555555555","generation":0,"current":"../../escape","previous":null,"history":[]}\n' > "$restart/state.json"
rejects invalid_state "$core" state "$restart" show
pass 'symlink roots and traversal identifiers cannot become managed releases'
printf '%s state regression groups passed\n' "$count"
