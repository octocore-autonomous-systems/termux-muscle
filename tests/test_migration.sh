#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
core="${TM_CORE:-$repo/build/tm-core}"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tm-migration-test.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
root="$scratch/install"
prefix="$scratch/prefix"
project="$scratch/private-project-marker/nested"
config="$scratch/private-config-marker"
mkdir -p "$root/bin" "$prefix/bin" "$project" "$config/plugins" "$scratch/home"
printf '#!/bin/sh\nexit 91\n' > "$root/bin/claude"
chmod 700 "$root/bin/claude"
ln -s "$root/bin/claude" "$prefix/bin/claude"
export HOME="$scratch/home" CLAUDE_CONFIG_DIR="$config"
unset LD_PRELOAD LD_LIBRARY_PATH

check() {
    (cd "$project" && PATH="$prefix/bin" "$core" migration "$root" "$prefix") > "$scratch/report"
    if grep -Eq 'private-(config|project|secret)-marker|must-not-run|/home/private-marker' "$scratch/report"; then
        printf 'FAIL migration: private input appeared in report\n' >&2
        exit 1
    fi
}
has() { grep -Fq "\"$1\"" "$scratch/report" || {
    cat "$scratch/report"
    exit 1
}; }
absent() { if grep -Fq "\"$1\"" "$scratch/report"; then
    cat "$scratch/report"
    exit 1
fi; }

# No active runtime, network tools or executable vendor client is required.
check
has managed_executable_selected
has private_session_history_not_scanned
has parent_shell_state_not_visible
[[ ! -e "$root/state.json" ]]
printf 'PASS migration: diagnostics work independently of an installed runtime\n'

cat > "$config/settings.json" << 'JSON'
{"env":{"LD_PRELOAD":"private-secret-marker.so"},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"touch must-not-run"}]}]}}
JSON
mkdir -p "$scratch/private-project-marker/.claude"
printf '%s\n' '{"env":{"LD_LIBRARY_PATH":"private-secret-marker"}}' > "$scratch/private-project-marker/.claude/settings.local.json"
printf '%s\n' '{"plugins":{"private-secret-marker":[{"installPath":"/home/private-marker/plugin"}]}}' > "$config/plugins/installed_plugins.json"
printf '%s\n' '{"private-secret-marker":{"installLocation":"/home/private-marker/marketplace"}}' > "$config/plugins/known_marketplaces.json"
mkdir -p "$scratch/private-project-marker/.git/worktrees/private-secret-marker"
printf '%s\n' /home/private-marker/worktree/.git > "$scratch/private-project-marker/.git/worktrees/private-secret-marker/gitdir"
cp -R "$config" "$scratch/config-before"
cp -R "$scratch/private-project-marker" "$scratch/project-before"
check
has settings_loader_override_found
has plugin_home_paths_require_review
has worktree_home_paths_require_review
diff -r "$config" "$scratch/config-before"
diff -r "$scratch/private-project-marker" "$scratch/project-before"
[[ ! -e "$project/must-not-run" ]]
printf 'PASS migration: ancestor settings, plugin and worktree hints without disclosure or mutation\n'

# Malformed JSON, oversized input, special files and symlinks are not clean bills of health.
printf '%s\n' '{"env":' > "$config/settings.json"
check
has settings_unreadable
printf '%s\n' '{"env":{"LD_PRELOAD":42}}' > "$config/settings.json"
check
has settings_unreadable
truncate -s 1048577 "$config/settings.json"
check
has settings_unreadable
rm "$config/settings.json"
mkfifo "$config/settings.json"
check
has settings_unreadable
rm "$config/settings.json"
printf '%s\n' '{}' > "$scratch/linked-settings"
ln -s "$scratch/linked-settings" "$config/settings.json"
check
has settings_unreadable
rm "$config/settings.json"
printf '%s\n' '{}' > "$config/settings.json"
mv "$config/plugins" "$scratch/linked-plugins"
ln -s "$scratch/linked-plugins" "$config/plugins"
check
has plugin_metadata_unreadable
printf 'PASS migration: unreadable and linked configuration is explicitly advisory\n'

# Selected override wins over HOME. Empty values are not conflicting overrides.
mkdir -p "$HOME/.claude" "$scratch/clean-project" "$scratch/clean-config"
printf '%s\n' '{"env":{"LD_PRELOAD":"private-secret-marker"}}' > "$HOME/.claude/settings.json"
printf '%s\n' '{"env":{"LD_PRELOAD":"","LD_LIBRARY_PATH":""}}' > "$scratch/clean-config/settings.json"
project="$scratch/clean-project"
config="$scratch/clean-config"
export CLAUDE_CONFIG_DIR="$config"
check
absent settings_loader_override_found
unset CLAUDE_CONFIG_DIR
check
has settings_loader_override_found
export CLAUDE_CONFIG_DIR="$config"
printf 'PASS migration: configuration selection and empty overrides\n'

# A different executable can shadow the owned command; do not execute it.
mkdir -p "$scratch/shadow"
printf '#!/bin/sh\ntouch must-not-run\n' > "$scratch/shadow/claude"
chmod 700 "$scratch/shadow/claude"
(cd "$project" && PATH="$scratch/shadow:$prefix/bin" "$core" migration "$root" "$prefix") > "$scratch/report"
has unmanaged_executable_selected
[[ ! -e "$project/must-not-run" ]]
printf 'gitdir: /home/private-marker/missing/.git/worktrees/test\n' > "$project/.git"
check
has worktree_home_paths_require_review
printf 'PASS migration: shadowing and linked-worktree migration hints\n'

# Private transcript contents are never scanned, including a FIFO that would hang a reader.
mkdir -p "$config/projects/private-secret-marker"
mkfifo "$config/projects/private-secret-marker/private-transcript.jsonl"
check
has private_session_history_not_scanned
printf 'PASS migration: historical transcripts are outside the scan\n'

# Android application directories can be searchable but not listable. Inspect
# known files through those ancestors without requesting directory read access.
mkdir -p "$scratch/traverse-only/config"
printf '%s\n' '{"env":{"LD_PRELOAD":"private-secret-marker"}}' > "$scratch/traverse-only/config/settings.json"
chmod 111 "$scratch/traverse-only"
CLAUDE_CONFIG_DIR="$scratch/traverse-only/config" "$core" migration "$root" "$prefix" > "$scratch/report"
chmod 700 "$scratch/traverse-only"
has settings_loader_override_found
has selected_settings_inspected
printf 'PASS migration: searchable non-listable ancestors remain inspectable without following links\n'
