#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
umask 077
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
core=$(realpath -- "${TM_CORE:-$repo/build/tm-core}")
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tm-tooling-test.XXXXXXXX")
holder=''
cleanup() { [[ ! $holder ]] || kill "$holder" 2>/dev/null || :; rm -rf -- "$scratch"; }
trap cleanup EXIT
count=0
pass() { printf 'PASS tooling: %s\n' "$1"; count=$((count + 1)); }
fail() { printf 'FAIL tooling: %s\n' "$1" >&2; exit 1; }
rejects() {
    local expected=$1; shift
    if "$@" > "$scratch/out" 2> "$scratch/error"; then fail "accepted $expected"; fi
    grep -Fq ": $expected:" "$scratch/error" || { cat "$scratch/error" >&2; fail "wrong failure for $expected"; }
}
prefix=$scratch/prefix
mkdir -p -- "$prefix/bin" "$prefix/tmp" "$scratch/stage/bin" "$scratch/stage/libexec"
mkdir -p -- "$scratch/stage/docs/man"
printf '.TH TERMUX-MUSCLE 1\n.SH NAME\ntermux-muscle \\- fixture manual\n' > "$scratch/stage/docs/man/termux-muscle.1"
ln -s -- "$(command -v bash)" "$prefix/bin/bash"
stage=$scratch/stage
cp -- "$core" "$stage/libexec/tm-core"
printf '0.1.0\n' > "$stage/VERSION"
printf '{}\n' > "$stage/compatibility.json"
printf 'fixture notice\n' > "$stage/LICENSE"
printf 'fixture credits\n' > "$stage/CREDITS.md"
cat > "$stage/bin/termux-muscle" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[[ $1 == --root && $3 == --prefix ]]
root=$2; shift 4
case ${1:-} in
    hold) printf ready > "$2"; exec sleep 30 ;;
    remove) exec "$TM_TEST_CORE" with-lock "$root" existing -- "$TM_TEST_CORE" tooling "$root" uninstall ;;
    *) printf '%s\0' "$@" ;;
esac
SH
chmod 700 "$stage/bin/termux-muscle"
export TM_TEST_CORE=$core
new_case() {
    root="$scratch/$1 installation '\$(false)"
    "$core" with-lock "$root" create -- true
}
tooling() { "$core" with-lock "$root" existing -- "$core" tooling "$root" "$@"; }
publish() { tooling publish "$stage" 0.1.0 "$prefix"; }
wait_holder() {
    for ((i=0; i<150; i++)); do [[ -f $scratch/ready ]] && return; sleep .01; done
    fail 'lease holder did not start'
}
stop_holder() { kill "$holder"; wait "$holder" 2>/dev/null || :; holder=''; rm -f -- "$scratch/ready"; }

new_case initial
rejects lock_required "$core" tooling "$root" publish "$stage" 0.1.0 "$prefix"
a=$(publish)
[[ $(readlink -- "$root/tools/current") == "$a" ]] || fail 'current pointer'
[[ -f $root/bin/.tm-dispatch && ! -L $root/bin/.tm-dispatch ]] || fail 'stable dispatcher not regular'
[[ $(head -1 "$root/bin/termux-muscle") == "#!$(realpath -- "$(command -v bash)")" ]] || fail 'absolute Termux Bash shebang'
# shellcheck disable=SC2016 # Deliberately literal shell syntax tests argv safety.
args=('one two' '' '$() *' $'line\nbreak' --root '/unchanged/claude/argument')
"$root/bin/termux-muscle" "${args[@]}" > "$scratch/actual"
printf '%s\0' "${args[@]}" > "$scratch/expected"
cmp "$scratch/actual" "$scratch/expected" || fail 'manager argv forwarding'
"$root/bin/claude" "${args[@]}" > "$scratch/actual"
printf '%s\0' run -- "${args[@]}" > "$scratch/expected"
cmp "$scratch/actual" "$scratch/expected" || fail 'Claude argv forwarding'
pass 'owned stable native launchers lease tooling and preserve every argument'

"$core" tooling "$root" run "$a" -- hold "$scratch/ready" & holder=$!
wait_holder
b=$(publish); c=$(publish)
tooling cleanup
[[ -d $root/tools/$a && -d $root/tools/$b && -d $root/tools/$c ]] || fail 'live old tools removed'
rejects busy tooling uninstall
[[ -x $root/bin/termux-muscle ]] || fail 'busy uninstall changed launchers'
stop_holder
tooling cleanup
[[ ! -e $root/tools/$a && -d $root/tools/$b && -d $root/tools/$c ]] || fail 'current/previous retention'
pass 'cleanup retains current, previous and live older tools; live uninstall is refused'

printf changed >> "$root/tools/$c/bin/termux-muscle"
rejects tooling_integrity "$root/bin/termux-muscle" --help
cp -- "$stage/bin/termux-muscle" "$root/tools/$c/bin/termux-muscle"
chmod 700 "$root/tools/$c/bin/termux-muscle"
printf foreign > "$root/bin/claude"
rejects tooling_conflict publish
[[ $(cat "$root/bin/claude") == foreign ]] || fail 'foreign stable launcher overwritten'
[[ -f $root/tooling-pending.json ]] || fail 'publication failure not journaled'
pass 'changed source and foreign stable launchers fail before execution or overwrite'

# Repair the saved known launcher, then rerun cleanup to recover publication.
"$core" tooling "$root" show > "$scratch/tool-state.json"
rm -- "$root/bin/claude"
tooling cleanup
[[ ! -e $root/tooling-pending.json && -x $root/bin/claude ]] || fail 'pending publication not recovered'
pass 'publication journal resumes an interrupted stable-wrapper/pointer transition'

ln -s -- "$scratch" "$stage/foreign"
rejects tooling_stage publish
rm -- "$stage/foreign"
tooling cleanup
shopt -s nullglob
drafts=("$root/tools"/.creating-*)
[[ ${#drafts[@]} == 0 ]] || fail 'owned interrupted copy not removed'
pass 'staging refuses symbolic links and recovers owned incomplete copies'

"$root/bin/termux-muscle" remove > "$scratch/removed.json"
[[ $("$core" json-get "$scratch/removed.json" status) == removed && ! -e $root ]] || fail 'own tooling lease uninstall'
pass 'the invoking manager can upgrade its own lease and fully uninstall'

new_case backup
publish >/dev/null
outside=$scratch/foreign-command
printf original > "$outside"; chmod 751 "$outside"
"$core" with-lock "$root" existing -- "$core" links "$root" install "$outside" "$root/bin/claude" --replace >/dev/null
rm -- "$outside"; printf replacement > "$outside"
mkdir -p -- "$scratch/home/.claude"
printf auth-sentinel > "$scratch/home/.claude/settings.json"
HOME=$scratch/home tooling uninstall > "$scratch/removed.json"
[[ $("$core" json-get "$scratch/removed.json" status) == removed_with_recovery ]] || fail 'missing backup retention status'
[[ $(cat "$outside") == replacement && -f $root/UNINSTALL-RECOVERY.txt && -f $root/installation.json ]] || fail 'changed link or recovery lost'
backups=("$root/backups"/*.bin)
[[ ${#backups[@]} == 1 && $(cat "${backups[0]}") == original ]] || fail 'original backup removed'
[[ $(cat "$scratch/home/.claude/settings.json") == auth-sentinel ]] || fail 'vendor settings changed'
pass 'uninstall preserves foreign replacement commands, original backup evidence and vendor settings'

new_case external
publish >/dev/null
outside=$scratch/restored-command
printf original > "$outside"; chmod 751 "$outside"
"$core" with-lock "$root" existing -- "$core" links "$root" install "$outside" "$root/bin/claude" --replace >/dev/null
tooling uninstall > "$scratch/removed.json"
[[ ! -e $root && $(cat "$outside") == original && $(stat -c %a "$outside") == 751 ]] || fail 'unchanged owned link restoration'
pass 'clean removal restores original command bytes and permissions'

new_case runtime
publish >/dev/null
runtime=$("$core" with-lock "$root" existing -- "$core" state "$root" candidate 1.0.0)
cat > "$scratch/lease-holder.c" <<'C'
#include <fcntl.h>
#include <stdio.h>
#include <sys/file.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc != 3) return 64;
    int lease = open(argv[1], O_RDWR);
    if (lease < 0 || flock(lease, LOCK_SH)) return 65;
    FILE *ready = fopen(argv[2], "w");
    if (!ready || fputs("ready", ready) < 0 || fclose(ready)) return 66;
    for (;;) pause();
}
C
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror "$scratch/lease-holder.c" -o "$scratch/lease-holder"
"$scratch/lease-holder" "$root/releases/$runtime/.lease" "$scratch/ready" & holder=$!
wait_holder
rejects busy tooling uninstall
[[ -d $root/releases/$runtime && -x $root/bin/claude ]] || fail 'busy runtime removal mutated files'
stop_holder
tooling uninstall >/dev/null
[[ ! -e $root ]] || fail 'runtime candidate not removed'
pass 'runtime execution leases block removal before command restoration or deletion'

new_case recovery
a=$(publish)
cp "$root/tooling.json" "$scratch/before-state.json"
b=$(publish)
identity=$("$core" json-get "$root/installation.json" id)
before=$("$core" json-get "$scratch/before-state.json" stable)
after=$(cat "$root/tooling.json")
printf '{"schema":1,"installation_id":"%s","id":"%s","old":"%s","before":%s,"state":%s}\n' \
    "$identity" "$b" "$a" "$before" "$after" > "$root/tooling-pending.json"
rm "$root/tools/current"; ln -s "$a" "$root/tools/current"
tooling cleanup
[[ $(readlink "$root/tools/current") == "$b" && ! -e $root/tooling-pending.json ]] || fail 'pointer recovery before commit'
printf '{"schema":1,"installation_id":"%s","id":"%s","old":"%s","before":%s,"state":%s}\n' \
    "$identity" "$b" "$a" "$before" "$after" > "$root/tooling-pending.json"
tooling cleanup
[[ $(readlink "$root/tools/current") == "$b" && ! -e $root/tooling-pending.json ]] || fail 'pointer recovery after commit'
pass 'publication journal recovers on either side of the atomic current-pointer commit'

c=$(publish)
dev=$(stat -c %d "$root/tools/$a"); inode=$(stat -c %i "$root/tools/$a")
tomb=.tool-delete-0123456789abcdef01234567
printf '{"schema":1,"installation_id":"%s","area":"tools","name":"%s","tomb":"%s","device":%s,"inode":%s}\n' \
    "$identity" "$a" "$tomb" "$dev" "$inode" > "$root/tooling-delete.json"
mv "$root/tools/$a" "$root/tools/$tomb"
rm "$root/tools/$tomb/.owned.json" "$root/tools/$tomb/.lease"
tooling cleanup
[[ ! -e $root/tools/$tomb && ! -e $root/tooling-delete.json ]] || fail 'partially deleted tool recovery'
pass 'inode-checked journal finishes interrupted deletion after tool metadata is gone'

dev=$(stat -c %d "$root/tools/$b"); inode=$(stat -c %i "$root/tools/$b")
printf '{"schema":1,"installation_id":"%s","area":"tools","name":"%s","tomb":"%s","device":%s,"inode":%s}\n' \
    "$identity" "$b" "$tomb" "$dev" "$inode" > "$root/tooling-delete.json"
mv "$root/tools/$b" "$scratch/retained-original"
mkdir "$root/tools/$tomb"; printf valuable > "$root/tools/$tomb/foreign"
rejects tooling_conflict tooling cleanup
[[ $(cat "$root/tools/$tomb/foreign") == valuable ]] || fail 'foreign deletion-path inode removed'
rm "$root/tooling-delete.json"
rm -r "$root/tools/$tomb"
mv "$scratch/retained-original" "$root/tools/$b"
pass 'a replacement directory at an interrupted deletion path is preserved'

printf '{"schema":1,"installation_id":"%s","current":"%s"}\n' "$identity" "$c" > "$root/tooling-uninstall.json"
rm -r "$root/tools/$c"
d=$(publish)
[[ $(readlink "$root/tools/current") == "$d" && ! -e $root/tooling-uninstall.json &&
   $("$core" json-get "$root/installation.json" id) == "$identity" ]] || fail 'source bootstrap removal recovery'
tooling uninstall >/dev/null
[[ ! -e $root ]] || fail 'post-recovery uninstall'
pass 'source publication finishes interrupted uninstall before rebuilding the same owned root'

new_case foreign-content
publish >/dev/null
mkdir "$root/user-folder"; printf valuable > "$root/user-folder/file"
tooling uninstall > "$scratch/removed.json"
[[ $(cat "$root/user-folder/file") == valuable && -f $root/UNINSTALL-RECOVERY.txt ]] || fail 'foreign root content deleted'
pass 'unrecognized installation-root content remains with explicit recovery evidence'

new_case tampering
a=$(publish)
mv "$root/tools/$a/libexec" "$scratch/real-libexec"
ln -s "$scratch/real-libexec" "$root/tools/$a/libexec"
rejects unsafe_path "$root/bin/termux-muscle" --help
rm "$root/tools/$a/libexec"
mv "$scratch/real-libexec" "$root/tools/$a/libexec"
cp "$root/tools/$a/.owned.json" "$scratch/owned-before.json"
sed -E 's/"schema"[[:space:]]*:[[:space:]]*1/"schema":2/' "$scratch/owned-before.json" > "$root/tools/$a/.owned.json"
rejects tooling_identity "$root/bin/termux-muscle" --help
cp "$scratch/owned-before.json" "$root/tools/$a/.owned.json"
chmod 600 "$root/bin/claude"
rejects tooling_conflict publish
[[ $(stat -c %a "$root/bin/claude") == 600 ]] || fail 'foreign stable mode changed'
chmod 700 "$root/bin/claude"
tooling cleanup
pass 'installed directory symlinks, future ownership schemas and foreign launcher modes are rejected'

identity=$("$core" json-get "$root/installation.json" id)
mkdir "$root/unrelated"
printf valuable > "$root/unrelated/file"
dev=$(stat -c %d "$root/unrelated"); inode=$(stat -c %i "$root/unrelated")
printf '{"schema":1,"installation_id":"%s","area":".","name":"unrelated","tomb":"%s","device":%s,"inode":%s}\n' \
    "$identity" "$tomb" "$dev" "$inode" > "$root/tooling-delete.json"
rejects tooling_journal tooling cleanup
[[ $(cat "$root/unrelated/file") == valuable ]] || fail 'out-of-scope journal deleted unrelated files'
rm "$root/tooling-delete.json"
tooling uninstall >/dev/null
pass 'deletion recovery rejects even matching inode records outside owned payload scopes'

# Exercise the shell hooks with real C ownership and mocked network/build tools.
mkdir -p "$scratch/mocks" "$scratch/source/build" "$scratch/hook-home/.local/bin" "$scratch/remote"
cp "$core" "$scratch/source/build/tm-core"
bootstrap_version=$(cat "$repo/VERSION")
printf '%s\n' "$bootstrap_version" > "$scratch/source/VERSION"
cp -R "$stage" "$scratch/bootstrap-stage"
printf '%s\n' "$bootstrap_version" > "$scratch/bootstrap-stage/VERSION"
printf '#!%s\n' "$(command -v bash)" > "$scratch/mocks/make"
cat >> "$scratch/mocks/make" <<'SH'
set -euo pipefail
for arg; do
    case $arg in DESTDIR=*) destination=${arg#DESTDIR=} ;; esac
done
mkdir -p -- "$destination"
cp -R -- "$TM_TEST_STAGE/." "$destination/"
SH
printf '#!%s\n' "$(command -v bash)" > "$scratch/mocks/curl"
cat >> "$scratch/mocks/curl" <<'SH'
set -euo pipefail
[[ $1 == -q ]] || exit 82
printf 'called\n' >> "$TM_TEST_REMOTE/calls"
while (($#)); do
    case $1 in --output) output=$2; shift 2 ;; *) url=$1; shift ;; esac
done
case $url in
    */releases/latest) printf '{"tag_name":"v%s"}\n' "${TM_TEST_LATEST_VERSION:-0.2.0}" > "$output" ;;
    */SHA256SUMS) cp "$TM_TEST_REMOTE/SHA256SUMS" "$output" ;;
    */install.sh) cp "$TM_TEST_REMOTE/install.sh" "$output" ;;
    *) exit 83 ;;
esac
SH
printf '#!%s\n' "$(command -v bash)" > "$scratch/mocks/makewhatis"
cat >> "$scratch/mocks/makewhatis" <<'SH'
set -euo pipefail
[[ $# == 3 && ( $1 == -d || $1 == -u ) && $2 == "$TM_PREFIX/share/man" &&
   $3 == man1/termux-muscle.1 && -f $2/$3 && ! -L $2/$3 ]] || exit 84
printf '%s\n' "$1" >> "$TM_TEST_REMOTE/index-calls"
[[ ${TM_TEST_INDEX_FAIL:-0} != 1 ]]
SH
chmod 700 "$scratch/mocks/"*
cat > "$scratch/hook.sh" <<'SH'
set -euo pipefail
tm_error() { printf 'termux-muscle: %s: %s\n' "$1" "$2" >&2; exit 1; }
tm_install_release() {
    [[ ${TM_TEST_RUNTIME_FAIL:-0} != 1 ]] || return 47
    printf 'runtime-installed\n' >> "$TM_TEST_REMOTE/runtime"
}
source "$TM_TEST_COMMANDS"
source "$TM_TEST_LIB"
[[ -z ${TM_TEST_STALE_CLAUDE:-} ]] || hash -p "$TM_TEST_STALE_CLAUDE" claude
operation=$1; shift
"tm_$operation" "$@"
SH
export TM_TEST_LIB=$repo/lib/tooling.sh TM_TEST_STAGE=$scratch/bootstrap-stage TM_TEST_REMOTE=$scratch/remote
export TM_TEST_COMMANDS=$repo/lib/commands.sh
export TM_SOURCE=$scratch/source TM_CORE=$core TM_PROJECT_VERSION=$bootstrap_version TM_PREFIX=$prefix
new_case shell-bootstrap
export TM_ROOT=$root
hook_home=$scratch/hook-home
shadow=$scratch/shadow-bin
mkdir -p "$shadow"
printf '#!%s\nprintf legacy-shadow\n' "$(command -v bash)" > "$shadow/claude"
chmod 751 "$shadow/claude"
printf legacy-home > "$hook_home/.local/bin/claude"
chmod 700 "$hook_home/.local/bin/claude"
ln -s "$shadow/claude" "$prefix/bin/claude"
hook_path=$shadow:$prefix/bin:$scratch/mocks:$PATH
[[ $(PATH="$hook_path" type -P claude) == "$shadow/claude" ]] || fail 'bootstrap fixture would discover a live host command'
printf original-manager > "$hook_home/.local/bin/termux-muscle"
# Model the real prefix fallback even when native Termux exports TMPDIR.
HOME=$hook_home PATH=$hook_path env -u TMPDIR "$core" with-lock "$root" existing -- bash "$scratch/hook.sh" \
    bootstrap --source-dir "$TM_SOURCE" --build-dir "$TM_SOURCE/build" --no-install > "$scratch/hook-output"
[[ $(cat "$hook_home/.local/bin/termux-muscle") == original-manager && ! -e $scratch/remote/runtime ]] || fail 'foreign manager/default no-install'
[[ $(readlink "$prefix/bin/claude") == "$shadow/claude" && $(cat "$hook_home/.local/bin/claude") == legacy-home ]] || fail 'tool-only bootstrap changed Claude commands'
manual=$prefix/share/man/man1/termux-muscle.1
[[ -f $manual && ! -L $manual && $(stat -c %a "$manual") == 644 ]] || fail 'manual was not installed as a readable regular page'
cmp "$manual" "$TM_TEST_STAGE/docs/man/termux-muscle.1" || fail 'manual content mismatch'
[[ $(cat "$scratch/remote/index-calls") == -d && $(readlink "$prefix/bin/termux-muscle") == "$root/bin/termux-muscle" ]] || fail 'manual indexing or prefix manager command missing'
rm "$hook_home/.local/bin/termux-muscle"
HOME=$hook_home PATH=$hook_path env -u TMPDIR "$core" with-lock "$root" existing -- bash "$scratch/hook.sh" \
    bootstrap --source-dir "$TM_SOURCE" --build-dir "$TM_SOURCE/build" --no-link > "$scratch/hook-output"
[[ $(readlink "$prefix/bin/claude") == "$shadow/claude" && $(cat "$hook_home/.local/bin/claude") == legacy-home && -s $scratch/remote/runtime ]] || fail 'no-link did not preserve Claude commands'
pass 'tool-only and no-link bootstrap preserve Claude commands while installing the manual'

rejects_fixture_bootstrap() {
    if HOME=$hook_home PATH=$hook_path env -u TMPDIR "$core" with-lock "$root" existing -- bash "$scratch/hook.sh" \
        bootstrap --source-dir "$TM_SOURCE" --build-dir "$TM_SOURCE/build" > "$scratch/hook-output" 2> "$scratch/error"; then
        fail 'expected bootstrap failure succeeded'
    fi
}
export TM_TEST_RUNTIME_FAIL=1
rejects_fixture_bootstrap
unset TM_TEST_RUNTIME_FAIL
[[ $(readlink "$prefix/bin/claude") == "$shadow/claude" && $(cat "$hook_home/.local/bin/claude") == legacy-home ]] || fail 'failed runtime changed Claude commands'
pass 'runtime installation failure leaves default Claude entries unchanged'

printf '#!%s\nprintf stale-unrelated\n' "$(command -v bash)" > "$scratch/stale-claude"
chmod 700 "$scratch/stale-claude"
export TM_TEST_STALE_CLAUDE=$scratch/stale-claude
mv "$hook_home/.local/bin/claude" "$scratch/home-original"
mkdir "$hook_home/.local/bin/claude"
rejects_fixture_bootstrap
[[ -d $hook_home/.local/bin/claude && $(readlink "$shadow/claude") == "$root/bin/claude" && $(readlink "$prefix/bin/claude") == "$root/bin/claude" ]] || fail 'later link failure did not preserve the conflicting entry and earlier journals'
grep -q 'command setup is incomplete' "$scratch/error" || fail 'partial command setup failure lacked recovery guidance'
rmdir "$hook_home/.local/bin/claude"
mv "$scratch/home-original" "$hook_home/.local/bin/claude"
HOME=$hook_home PATH=$hook_path env -u TMPDIR "$core" with-lock "$root" existing -- bash "$scratch/hook.sh" \
    bootstrap --source-dir "$TM_SOURCE" --build-dir "$TM_SOURCE/build" > "$scratch/hook-output"
[[ $(readlink "$hook_home/.local/bin/termux-muscle") == "$root/bin/termux-muscle" &&
   $(readlink "$prefix/bin/claude") == "$root/bin/claude" && $(readlink "$shadow/claude") == "$root/bin/claude" &&
   $(readlink "$hook_home/.local/bin/claude") == "$root/bin/claude" && -s $scratch/remote/runtime ]] || fail 'shell bootstrap ownership/install/default links'
grep -q 'Command ownership record:' "$scratch/hook-output" || fail 'default takeover record not explained'
pass 'default bootstrap owns the PATH winner and standard entries; partial failure can be retried without losing original backups'
[[ ! -L $scratch/stale-claude && $("$scratch/stale-claude") == stale-unrelated ]] || fail 'stale hash replaced unrelated command'
unset TM_TEST_STALE_CLAUDE
pass 'default takeover clears a stale child-shell command hash before selecting the executable PATH winner'
prefix_scratch=("$prefix/tmp/"*)
[[ ${#prefix_scratch[@]} == 0 ]] || fail 'bootstrap fallback temporary directory not cleaned'

printf '.SH UPDATED\nNew manual revision.\n' >> "$TM_TEST_STAGE/docs/man/termux-muscle.1"
HOME=$hook_home PATH=$hook_path "$core" with-lock "$root" existing -- bash "$scratch/hook.sh" bootstrap \
    --source-dir "$TM_SOURCE" --build-dir "$TM_SOURCE/build" --no-install > "$scratch/hook-output"
cmp "$manual" "$TM_TEST_STAGE/docs/man/termux-muscle.1" || fail 'owned manual did not refresh'
pass 'tool-only upgrade refreshes the owned regular manual and its index'

cp "$manual" "$scratch/owned-manual"
printf 'foreign manual replacement\n' > "$manual"
before_index=$(wc -l < "$scratch/remote/index-calls")
HOME=$hook_home PATH=$hook_path "$core" with-lock "$root" existing -- bash "$scratch/hook.sh" bootstrap \
    --source-dir "$TM_SOURCE" --build-dir "$TM_SOURCE/build" --no-install > "$scratch/hook-output" 2> "$scratch/error"
[[ $(cat "$manual") == 'foreign manual replacement' && $(wc -l < "$scratch/remote/index-calls") == "$before_index" ]] || fail 'foreign manual or index changed'
grep -q 'Existing manual preserved' "$scratch/error" || fail 'foreign manual preservation not explained'
cp "$scratch/owned-manual" "$manual"
pass 'upgrade preserves a later foreign manual and its index with direct-page guidance'

TM_TEST_INDEX_FAIL=1 HOME=$hook_home PATH=$hook_path "$core" with-lock "$root" existing -- bash "$scratch/hook.sh" bootstrap \
    --source-dir "$TM_SOURCE" --build-dir "$TM_SOURCE/build" --no-install > "$scratch/hook-output" 2> "$scratch/error"
grep -q 'Manual index update failed' "$scratch/error" || fail 'index failure not explained'
[[ -f $manual ]] || fail 'index failure lost the readable page'
pass 'index failure leaves the installed page usable and explains how to refresh it'

current_tool=$(readlink "$root/tools/current")
"$core" tooling "$root" run "$current_tool" -- hold "$scratch/ready" & holder=$!
wait_holder
rejects busy env HOME="$hook_home" PATH="$hook_path" "$core" with-lock "$root" existing -- bash "$scratch/hook.sh" uninstall
[[ $(tail -2 "$scratch/remote/index-calls") == $'-u\n-d' && -f $manual ]] || fail 'refused uninstall did not restore manual index'
stop_holder
pass 'busy uninstall restores the manual index and leaves the installation intact'

cat > "$scratch/remote/install.sh" <<'SH'
printf '%s\0' "$@" > "$TM_TEST_REMOTE/executed"
SH
(cd "$scratch/remote" && sha256sum install.sh > SHA256SUMS)
cp "$root/state.json" "$scratch/runtime-before-self-update.json"
PATH=$scratch/mocks:$PATH bash "$scratch/hook.sh" project_version_newer 0.10.0 0.9.999 || fail 'numeric component length comparison'
PATH=$scratch/mocks:$PATH bash "$scratch/hook.sh" project_version_newer 999999999999999999999.0.0 999999999999999999998.99.99 || fail 'large component comparison'
if PATH=$scratch/mocks:$PATH bash "$scratch/hook.sh" project_version_newer 0.2.0 0.2.0; then fail 'equal version compared as newer'; fi
if PATH=$scratch/mocks:$PATH bash "$scratch/hook.sh" project_version_newer 0.2.9 0.3.0; then fail 'older minor version compared as newer'; fi
: > "$scratch/remote/calls"
before_calls=$(wc -l < "$scratch/remote/calls")
PATH=$scratch/mocks:$PATH env -u TMPDIR bash "$scratch/hook.sh" self_update > "$scratch/hook-output"
grep -q '0.2.0 is not newer. No update performed.' "$scratch/hook-output" || fail 'latest equal version lacked no-op notice'
[[ ! -e $scratch/remote/executed && $(wc -l < "$scratch/remote/calls") == $((before_calls + 1)) ]] || fail 'latest equal version fetched installer or executed it'
prefix_scratch=("$prefix/tmp/"*)
[[ ${#prefix_scratch[@]} == 0 ]] || fail 'equal-version fallback temporary directory not cleaned'
before_calls=$(wc -l < "$scratch/remote/calls")
PATH=$scratch/mocks:$PATH bash "$scratch/hook.sh" self_update --version 0.2.0 > "$scratch/hook-output"
grep -q 'No update performed.' "$scratch/hook-output" || fail 'explicit equal version lacked no-op notice'
[[ ! -e $scratch/remote/executed && $(wc -l < "$scratch/remote/calls") == "$before_calls" ]] || fail 'explicit equal version reached network'
TM_PROJECT_VERSION=0.2.1 PATH=$scratch/mocks:$PATH bash "$scratch/hook.sh" self_update --version 0.2.0 > "$scratch/hook-output"
grep -q '0.2.0 is not newer. No update performed.' "$scratch/hook-output" || fail 'older version lacked no-op notice'
[[ $(wc -l < "$scratch/remote/calls") == "$before_calls" ]] || fail 'explicit older version reached network'
pass 'equal and older manager versions skip installation with a notice before installer download'

PATH=$scratch/mocks:$PATH TM_TEST_LATEST_VERSION=0.2.1 env -u TMPDIR bash "$scratch/hook.sh" self_update > "$scratch/hook-output"
printf '%s\0' --version 0.2.1 --root "$root" --prefix "$prefix" --no-install > "$scratch/expected"
cmp "$scratch/remote/executed" "$scratch/expected" || fail 'self-update immutable source forwarding'
cmp "$root/state.json" "$scratch/runtime-before-self-update.json" || fail 'self-update changed runtime state'
prefix_scratch=("$prefix/tmp/"*)
[[ ${#prefix_scratch[@]} == 0 ]] || fail 'self-update fallback temporary directory not cleaned'
rm "$scratch/remote/executed"
PATH=$scratch/mocks:$PATH bash "$scratch/hook.sh" self_update --force --version 0.2.0 > "$scratch/hook-output"
printf '%s\0' --version 0.2.0 --root "$root" --prefix "$prefix" --no-install > "$scratch/expected"
cmp "$scratch/remote/executed" "$scratch/expected" || fail '--force did not reinstall equal version'
rm "$scratch/remote/executed"
TM_PROJECT_VERSION=0.2.1 PATH=$scratch/mocks:$PATH bash "$scratch/hook.sh" self_update -f --version 0.2.0 > "$scratch/hook-output"
cmp "$scratch/remote/executed" "$scratch/expected" || fail '-f did not permit compatible older version'
rm "$scratch/remote/executed"
printf corrupt >> "$scratch/remote/install.sh"
rejects checksum_failed env PATH="$scratch/mocks:$PATH" bash "$scratch/hook.sh" self_update --version 0.2.1
[[ ! -e $scratch/remote/executed ]] || fail 'unverified self-update code executed'
pass 'newer and forced compatible self-update verify installer checksums, clean scratch and preserve runtime'

before_calls=$(wc -l < "$scratch/remote/calls")
rejects invalid_version env PATH="$scratch/mocks:$PATH" bash "$scratch/hook.sh" self_update --version '../../escape'
rejects incompatible_tooling env PATH="$scratch/mocks:$PATH" bash "$scratch/hook.sh" self_update --force --version 0.1.0
[[ $(wc -l < "$scratch/remote/calls") == "$before_calls" ]] || fail 'invalid update version reached network'
HOME=$hook_home PATH=$hook_path "$core" with-lock "$root" existing -- bash "$scratch/hook.sh" uninstall >/dev/null
[[ $(tail -1 "$scratch/remote/index-calls") == -u ]] || fail 'uninstall did not remove the owned manual index while page existed'
[[ ! -e $root && ! -e $hook_home/.local/bin/termux-muscle && ! -e $prefix/bin/termux-muscle && ! -e $manual &&
   $(readlink "$prefix/bin/claude") == "$shadow/claude" && $(cat "$hook_home/.local/bin/claude") == legacy-home &&
   $(stat -c %a "$shadow/claude") == 751 && $("$shadow/claude") == legacy-shadow ]] || fail 'default commands were not restored or the manual was not removed'
pass 'invalid self-update selectors are rejected before network; shell-created entries uninstall cleanly'

shared_shell=''
for candidate in "$(command -v bash)" /usr/bin/bash /bin/bash; do
    if [[ -r $candidate && -x $candidate && $(stat -Lc %u "$candidate") != "$(id -u)" ]]; then
        shared_shell=$candidate; break
    fi
done
if [[ -n $shared_shell ]]; then
    new_case system-dependency
    mkdir -p "$scratch/system-prefix/bin"
    ln -s "$shared_shell" "$scratch/system-prefix/bin/bash"
    tooling publish "$stage" 0.1.0 "$scratch/system-prefix" >/dev/null
    tooling uninstall >/dev/null
    [[ ! -e $root && -x $shared_shell ]] || fail 'shared dependency was rejected or modified'
    pass 'a readable executable package shell may belong to another UID without becoming owned data'
else
    printf 'SKIP tooling: no readable executable Bash owned by another UID is available\n'
fi

printf '%s tooling regression groups passed\n' "$count"
