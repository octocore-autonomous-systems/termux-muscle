#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
umask 077
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
core=$(realpath -- "${TM_CORE:-$repo/build/tm-core}")
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tm-links-test.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

# A tiny test-only JSON editor synthesizes interrupted disk states. Production
# metadata is never sourced/evaluated and the mandatory suite needs no Python.
cat > "$scratch/fixture.c" <<'C'
#define _GNU_SOURCE 1
#include <json-c/json.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
static json_object *field(json_object *j, const char *key) {
    json_object *value = NULL;
    if (!json_object_object_get_ex(j, key, &value)) exit(80);
    return value;
}
int main(int argc, char **argv) {
    if (argc != 4) return 64;
    char index_path[4096], pending_path[4096];
    snprintf(index_path, sizeof index_path, "%s/links.json", argv[2]);
    snprintf(pending_path, sizeof pending_path, "%s/links-pending.json", argv[2]);
    if (!strcmp(argv[1], "stage")) {
        json_object *operation = json_object_from_file(pending_path);
        char staged[4096], *parent = strdup(argv[3]);
        char *slash = strrchr(parent, '/'); if (!slash) return 81; *slash = 0;
        const char *name = ".tm-link-0123456789abcdef01234567.tmp";
        snprintf(staged, sizeof staged, "%s/%s", parent, name);
        FILE *file = fopen(staged, "w"); if (!file) return 82;
        fputs("partial original command", file); fclose(file);
        struct stat info; if (lstat(staged, &info)) return 83;
        json_object_object_add(operation, "temporary", json_object_new_string(name));
        json_object_object_add(operation, "temporary_device", json_object_new_int64(info.st_dev));
        json_object_object_add(operation, "temporary_inode", json_object_new_int64(info.st_ino));
        int result = json_object_to_file_ext(pending_path, operation, JSON_C_TO_STRING_PRETTY);
        json_object_put(operation); free(parent); return result ? 84 : 0;
    }
    json_object *index = json_object_from_file(index_path);
    if (!index) return 85;
    json_object *entries = field(index, "entries"), *entry = field(entries, argv[3]);
    if (!strcmp(argv[1], "backup")) {
        puts(json_object_get_string(field(entry, "backup"))); json_object_put(index); return 0;
    }
    if (!strcmp(argv[1], "bad-backup")) {
        json_object_object_add(entry, "backup", json_object_new_string("../../unrelated.bin"));
        int result = json_object_to_file_ext(index_path, index, JSON_C_TO_STRING_PRETTY);
        json_object_put(index); return result ? 86 : 0;
    }
    int restore = !strcmp(argv[1], "pending-restore");
    if (!restore && strcmp(argv[1], "pending-install")) return 87;
    json_object *operation = json_object_new_object(), *link = json_object_new_object();
    json_object_object_add(link, "kind", json_object_new_string("symlink"));
    json_object_object_add(link, "target", json_object_get(field(entry, "target")));
    json_object_object_add(operation, "schema", json_object_new_int(1));
    json_object_object_add(operation, "installation_id", json_object_get(field(index, "installation_id")));
    json_object_object_add(operation, "action", json_object_new_string(restore ? "restore" : "install"));
    json_object_object_add(operation, "entry", json_object_get(entry));
    json_object_object_add(operation, "before", json_object_get(restore ? link : field(entry, "original")));
    json_object_object_add(operation, "after", json_object_get(restore ? field(entry, "original") : link));
    if (json_object_to_file_ext(pending_path, operation, JSON_C_TO_STRING_PRETTY)) return 88;
    if (!restore) json_object_object_del(entries, argv[3]);
    int result = json_object_to_file_ext(index_path, index, JSON_C_TO_STRING_PRETTY);
    json_object_put(operation); json_object_put(link); json_object_put(index);
    return result ? 89 : 0;
}
C
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror $(pkg-config --cflags json-c) \
    "$scratch/fixture.c" $(pkg-config --libs json-c) -o "$scratch/fixture"

count=0
pass() { printf 'PASS links: %s\n' "$1"; count=$((count + 1)); }
fail() { printf 'FAIL links: %s\n' "$1" >&2; exit 1; }
new_case() {
    root="$scratch/$1 installation"
    commands="$scratch/$1 commands"
    mkdir -p -- "$commands"
    "$core" with-lock "$root" create -- bash -c 'printf "#!/bin/sh\nexit 0\n" > "$1/bin/launcher"; chmod 700 "$1/bin/launcher"' fixture "$root"
    target="$root/bin/launcher"
    command_path="$commands/claude"
}
links() { "$core" with-lock "$root" existing -- "$core" links "$root" "$@"; }
rejects() {
    local code=$1; shift
    if "$@" > "$scratch/rejected.out" 2> "$scratch/rejected.err"; then fail "expected rejection: $code"; fi
    grep -Fq -- ": $code:" "$scratch/rejected.err" || { cat "$scratch/rejected.err" >&2; fail "wrong category: $code"; }
}
original_file() { printf 'original launcher\n' > "$command_path"; chmod 751 "$command_path"; }
published_file() { original_file; links install "$command_path" "$target" --replace >/dev/null; }
restore_fixture_bytes() {
    rm -- "$command_path"
    printf 'original launcher\n' > "$command_path"; chmod 751 "$command_path"
}

new_case regular
original_file
rejects link_conflict links install "$command_path" "$target"
[[ ! -L $command_path && $(cat "$command_path") == 'original launcher' ]] || fail 'foreign file changed'
[[ $(links install "$command_path" "$target" --replace) == installed ]] || fail 'replace result'
backup=$("$scratch/fixture" backup "$root" "$command_path")
[[ $(stat -c %a "$root/backups/$backup") == 600 ]] || fail 'private backup permissions'
[[ $(links restore "$command_path") == restored ]] || fail 'restore result'
[[ ! -L $command_path && $(cat "$command_path") == 'original launcher' && $(stat -c %a "$command_path") == 751 ]] || fail 'original bytes or mode lost'
[[ ! -e $root/backups/$backup && ! -e $root/links-pending.json ]] || fail 'completed restoration retained its redundant backup'
pass 'foreign file opt-in replacement restores bytes/mode and retires its private backup'

for literal in ../absent /an/absent/absolute/target; do
    new_case "symlink-$count"
    ln -s -- "$literal" "$command_path"
    links install "$command_path" "$target" --replace >/dev/null
    links restore "$command_path" >/dev/null
    [[ $(readlink "$command_path") == "$literal" ]] || fail 'literal symlink target changed'
    pass 'relative or dangling symlink restores its exact literal target'
done

new_case missing
links install "$command_path" "$target" >/dev/null
links restore "$command_path" >/dev/null
[[ ! -e $command_path && ! -L $command_path ]] || fail 'new owned link not removed'
pass 'uninstall removes only a newly owned command entry'

new_case npm
published_file
backup=$("$scratch/fixture" backup "$root" "$command_path")
rm -- "$command_path"; ln -s -- ../npm/new-claude "$command_path"
[[ $(links restore "$command_path") == foreign_change_preserved ]] || fail 'npm drift result'
[[ $(readlink "$command_path") == ../npm/new-claude ]] || fail 'npm replacement overwritten'
[[ $(cat "$root/backups/$backup") == 'original launcher' ]] || fail 'npm drift lost original backup'
"$core" links "$root" status > "$scratch/status"
grep -Eq '"owned"[[:space:]]*:[[:space:]]*false' "$scratch/status" || fail 'drift status'
pass 'later npm launcher replacement is preserved and reported'

new_case repeated
published_file
backup=$("$scratch/fixture" backup "$root" "$command_path")
[[ $(links install "$command_path" "$target") == unchanged ]] || fail 'idempotent install'
rm -- "$command_path"
links install "$command_path" "$target" >/dev/null
[[ $("$scratch/fixture" backup "$root" "$command_path") == "$backup" ]] || fail 'repair lost original backup'
links restore "$command_path" >/dev/null
[[ $(cat "$command_path") == 'original launcher' ]] || fail 'repair lost original bytes'
pass 'repeat install and missing-link repair preserve the restoration record'

new_case hostile
command_path="$commands/claude '\$(false) * line"$'\n''break'
published_file
links restore "$command_path" >/dev/null
[[ $(cat "$command_path") == 'original launcher' ]] || fail 'hostile filename restoration'
pass 'quotes, shell metacharacters and newlines in paths remain literal'

new_case special
mkdir -- "$command_path"; printf keep > "$command_path/work"
rejects link_conflict links install "$command_path" "$target" --replace
[[ $(cat "$command_path/work") == keep ]] || fail 'directory overwritten'
rejects invalid_link_target links install "$target" "$target" --replace
outside="$scratch/outside launcher"; printf '#!/bin/sh\n' > "$outside"; chmod 700 "$outside"
rejects invalid_link_target links install "$commands/other" "$outside"
pass 'directories, self-links and targets outside root/bin are rejected'

new_case corrupt
published_file
backup=$("$scratch/fixture" backup "$root" "$command_path")
printf corruption > "$root/backups/$backup"
rejects backup_invalid links restore "$command_path"
[[ $(readlink "$command_path") == "$target" ]] || fail 'corrupt backup replaced the active link'
pass 'corrupted backup cannot replace the owned launcher'

new_case traversal
published_file
"$scratch/fixture" bad-backup "$root" "$command_path"
rejects invalid_state links restore "$command_path"
[[ $(readlink "$command_path") == "$target" ]] || fail 'unsafe backup record changed command'
pass 'backup metadata cannot escape private backup storage'

new_case backupsymlink
published_file
backup=$("$scratch/fixture" backup "$root" "$command_path")
mv -- "$root/backups/$backup" "$scratch/saved backup"
ln -s -- "$scratch/saved backup" "$root/backups/$backup"
rejects unsafe_path links restore "$command_path"
[[ $(readlink "$command_path") == "$target" ]] || fail 'symlink backup changed command'
pass 'backup symlinks are rejected without replacing the launcher'

new_case beforepublish
published_file
backup=$("$scratch/fixture" backup "$root" "$command_path")
"$scratch/fixture" pending-install "$root" "$command_path"
restore_fixture_bytes
[[ $(links recover) == not_applied ]] || fail 'before-publication recovery'
[[ ! -e $root/links-pending.json && $(cat "$command_path") == 'original launcher' ]] || fail 'before-publication recovery mutated original'
[[ ! -e $root/backups/$backup ]] || fail 'abandoned installation retained an unnecessary backup'
pass 'interruption before publication preserves the original and retires its unneeded backup'

new_case afterpublish
published_file
"$scratch/fixture" pending-install "$root" "$command_path"
[[ $(links recover) == committed ]] || fail 'after-publication recovery'
links restore "$command_path" >/dev/null
[[ $(cat "$command_path") == 'original launcher' ]] || fail 'recovered index lost restoration'
pass 'interruption after publication completes ownership bookkeeping'

new_case driftrecovery
published_file
"$scratch/fixture" pending-install "$root" "$command_path"
rm -- "$command_path"; printf 'newer independent edit' > "$command_path"
[[ $(links recover) == foreign_change_preserved ]] || fail 'interrupted drift recovery'
[[ $(cat "$command_path") == 'newer independent edit' ]] || fail 'drift recovery overwrote command'
shopt -s nullglob; archives=("$root"/backups/link-conflict-*.json); shopt -u nullglob
[[ ${#archives[@]} -eq 1 ]] || fail 'missing conflict evidence'
pass 'interrupted independent edits are preserved with conflict evidence'

new_case staging
published_file
"$scratch/fixture" pending-install "$root" "$command_path"
restore_fixture_bytes
"$scratch/fixture" stage "$root" "$command_path"
[[ $(links recover) == not_applied ]] || fail 'partial staging recovery'
[[ ! -e "$commands/.tm-link-0123456789abcdef01234567.tmp" ]] || fail 'owned partial staging was not removed'
pass 'journaled partial staging is removed by recorded inode identity'

new_case stagingreplacement
published_file
"$scratch/fixture" pending-install "$root" "$command_path"
restore_fixture_bytes
"$scratch/fixture" stage "$root" "$command_path"
staged="$commands/.tm-link-0123456789abcdef01234567.tmp"
mv -- "$staged" "$scratch/retained staging inode"
printf 'foreign staging replacement' > "$staged"
[[ $(links recover) == foreign_change_preserved ]] || fail 'staging replacement result'
[[ $(cat "$staged") == 'foreign staging replacement' ]] || fail 'replacement staging inode deleted'
pass 'a replacement staging inode is preserved rather than cleaned'

new_case afterrestore
published_file
backup=$("$scratch/fixture" backup "$root" "$command_path")
"$scratch/fixture" pending-restore "$root" "$command_path"
restore_fixture_bytes
[[ $(links recover) == committed ]] || fail 'restore-after-publication recovery'
[[ $(links restore "$command_path") == not_owned ]] || fail 'restored entry still owned'
[[ ! -e $root/backups/$backup ]] || fail 'restoration replay retained a completed backup'
pass 'interrupted restoration removes only completed ownership records'

new_case afterbackupretired
published_file
backup=$("$scratch/fixture" backup "$root" "$command_path")
"$scratch/fixture" pending-restore "$root" "$command_path"
restore_fixture_bytes
rm -- "$root/backups/$backup"
[[ $(links recover) == committed ]] || fail 'replay after backup unlink'
[[ ! -e $root/links-pending.json && $(cat "$command_path") == 'original launcher' ]] || fail 'backup retirement replay changed restored original'
pass 'restoration recovery tolerates a crash after completed backup retirement'

new_case changedretiredbackup
published_file
backup=$("$scratch/fixture" backup "$root" "$command_path")
"$scratch/fixture" pending-restore "$root" "$command_path"
restore_fixture_bytes
printf 'independent backup edit' > "$root/backups/$backup"
[[ $(links recover) == foreign_change_preserved ]] || fail 'changed retirement backup was not reported'
[[ $(cat "$root/backups/$backup") == 'independent backup edit' && $(cat "$command_path") == 'original launcher' ]] || fail 'changed backup or restored command lost'
shopt -s nullglob; archives=("$root"/backups/link-conflict-*.json); shopt -u nullglob
[[ ${#archives[@]} == 1 ]] || fail 'changed retirement backup lacks recovery evidence'
pass 'a changed backup after restoration is preserved with conflict evidence'

new_case conflictbackup
published_file
backup=$("$scratch/fixture" backup "$root" "$command_path")
"$scratch/fixture" pending-install "$root" "$command_path"
"$scratch/fixture" stage "$root" "$command_path"
staged="$commands/.tm-link-0123456789abcdef01234567.tmp"
mv -- "$staged" "$scratch/conflict staging inode"
printf 'foreign staging replacement' > "$staged"
[[ $(links recover) == foreign_change_preserved ]] || fail 'conflict fixture did not archive evidence'
links restore "$command_path" >/dev/null
[[ $(cat "$command_path") == 'original launcher' && $(cat "$root/backups/$backup") == 'original launcher' ]] || fail 'completed restore removed archived recovery backup'
shopt -s nullglob; archives=("$root"/backups/link-conflict-*.json); shopt -u nullglob
[[ ${#archives[@]} == 1 && $(cat "$staged") == 'foreign staging replacement' ]] || fail 'conflict evidence was discarded'
pass 'successful later restoration retains backups needed by archived conflicts'

new_case unrelatedbackup
published_file
backup=$("$scratch/fixture" backup "$root" "$command_path")
printf 'independent file' > "$root/backups/user-note.txt"
links restore "$command_path" >/dev/null
[[ ! -e $root/backups/$backup && $(cat "$root/backups/user-note.txt") == 'independent file' ]] || fail 'retirement swept unrelated backup storage'
pass 'backup retirement targets only the completed operation and preserves unrelated files'

new_case restoreall
original_file
links install "$command_path" "$target" --replace >/dev/null
links install "$commands/second" "$target" >/dev/null
links restore-all > "$scratch/restored-all"
[[ $(cat "$command_path") == 'original launcher' && ! -L $commands/second ]] || fail 'restore-all behavior'
pass 'restore-all restores originals and removes newly created aliases'

printf 'PASS: %s launcher ownership behavior groups\n' "$count"
