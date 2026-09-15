# SPDX-License-Identifier: MPL-2.0
# shellcheck shell=bash
# Normal installation owns the familiar command after the runtime passes checks.
# The C links helper records backups and publishes/restores each entry atomically.
tm_default_claude_links() {
    local selected path result before
    local -a paths=()
    local -A seen=()
    hash -r
    selected=$(type -P claude || :)
    [[ -z $selected ]] || paths+=("$selected")
    paths+=("$TM_PREFIX/bin/claude" "$HOME/.local/bin/claude")
    mkdir -p -- "$HOME/.local/bin"
    for path in "${paths[@]}"; do
        [[ $path == /* ]] || path=$PWD/$path
        [[ ! ${seen["$path"]+present} ]] || continue
        seen["$path"]=1
        # A PATH containing the owned bin directory already selects the target;
        # never try to replace that launcher with a link to itself.
        if [[ ${path##*/} == claude && ${path%/*} -ef $TM_ROOT/bin ]]; then continue; fi
        before=missing
        [[ ! -e $path && ! -L $path ]] || before=existing
        if ! result=$("$TM_CORE" links "$TM_ROOT" install "$path" "$TM_ROOT/bin/claude" --replace); then
            printf 'Claude runtime is active, but command setup is incomplete at: %s\n' "$path" >&2
            printf 'Earlier entries may already be managed. Resolve the reported conflict and rerun install, or use termux-muscle uninstall to restore eligible entries.\n' >&2
            return 1
        fi
        if [[ $result == unchanged ]]; then
            printf 'Already managed: %s\n' "$path"
        elif [[ $before == existing ]]; then
            printf 'Replaced with managed Claude: %s\nPrevious entry saved for restoration.\n' "$path"
        else
            printf 'Installed managed Claude: %s\n' "$path"
        fi
    done
    hash -r
    selected=$(type -P claude || :)
    printf 'Command ownership record: %s/links.json\n' "$TM_ROOT"
    printf 'Original file backups: %s/backups\n' "$TM_ROOT"
    if [[ -z $selected || ! $selected -ef $TM_ROOT/bin/claude ]]; then
        tm_error command_path "Claude is installed, but PATH does not select it. Add $TM_PREFIX/bin or $HOME/.local/bin to PATH."
    fi
    printf 'Ready: claude on executable PATH selects the managed runtime. Uninstall restores unchanged owned command entries.\n'
    printf 'Shell aliases/functions can override PATH; shell startup files were not changed.\n'
}
