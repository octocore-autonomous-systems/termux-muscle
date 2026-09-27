# SPDX-License-Identifier: MPL-2.0
# shellcheck shell=bash
# Bash lifecycle hooks; C owns identities, publication journals and leases.

tm_manual_index() {
    local operation=$1 manual=$TM_PREFIX/share/man/man1/termux-muscle.1
    command -v makewhatis >/dev/null || return 0
    if ! timeout --kill-after=5 30 makewhatis "$operation" "$TM_PREFIX/share/man" man1/termux-muscle.1; then
        printf 'Manual index update failed for %s. Rerun setup to refresh it; the page can be read directly with man %s.\n' "$manual" "$manual" >&2
        return 1
    fi
}

tm_completion_path() {
    printf '%s/bash-completion/completions/termux-muscle\n' "${XDG_DATA_HOME:-$HOME/.local/share}"
}

tm_completion_install() {
    local target=$TM_ROOT/tools/current/docs/completions/termux-muscle.sh
    local path
    path=$(tm_completion_path)
    [[ -f $target && ! -L $target ]] || tm_error completion_missing 'Published manager lacks its Bash completion script.'
    mkdir -p -- "${path%/*}"
    if [[ -e $path || -L $path ]]; then
        if [[ -L $path && $(readlink -- "$path") == "$target" ]]; then return 0; fi
        printf 'Existing Bash completion preserved: %s\nSource the managed script directly: %s\n' "$path" "$target" >&2
        return 0
    fi
    ln -s -- "$target" "$path"
    printf 'Bash completion installed: %s\n' "$path"
}

tm_completion_remove() {
    local path target
    path=$(tm_completion_path)
    target=$TM_ROOT/tools/current/docs/completions/termux-muscle.sh
    if [[ -L $path && $(readlink -- "$path") == "$target" ]]; then
        rm -- "$path"
    fi
}

tm_bootstrap() (
    set -euo pipefail
    local source_dir='' build_dir='' no_install=false link_claude=true
    while (($#)); do
        case $1 in
            --source-dir|--build-dir)
                (($# > 1)) || tm_error usage "$1 needs a directory."
                if [[ $1 == --source-dir ]]; then source_dir=$2; else build_dir=$2; fi
                shift 2 ;;
            --no-install) no_install=true; shift ;;
            --link) link_claude=true; shift ;;
            --no-link) link_claude=false; shift ;;
            *) tm_error usage "Unknown bootstrap option: $1" ;;
        esac
    done
    [[ -n $source_dir && -n $build_dir ]] || tm_error usage 'bootstrap requires --source-dir and --build-dir.'
    source_dir=$(realpath -e -- "$source_dir")
    build_dir=$(realpath -e -- "$build_dir")
    [[ $source_dir == "$TM_SOURCE" && $build_dir == "$source_dir/build" && -x $build_dir/tm-core ]] ||
        tm_error source_mismatch 'Bootstrap must run the freshly built source checkout and its build directory.'
    [[ $("$build_dir/tm-core" --version) == "Termux Muscle $TM_PROJECT_VERSION" ]] ||
        tm_error source_mismatch 'The source version and locally built helper disagree.'
    local work id manager_path
    # Keep the new stage outside the installation: interrupted uninstall recovery
    # may remove the old root cache before this stage is published.
    work=$(mktemp -d "${TMPDIR:-$TM_PREFIX/tmp}/termux-muscle-stage.XXXXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    timeout --kill-after=5 120 make -C "$source_dir" stage "DESTDIR=$work/stage" >&2
    id=$("$TM_CORE" tooling "$TM_ROOT" publish "$work/stage" "$TM_PROJECT_VERSION" "$TM_PREFIX")
    mkdir -p -- "$HOME/.local/bin"
    # Expected foreign commands are preserved; errors in existing ownership
    # metadata are still fatal when the links helper attempts a managed repair.
    for manager_path in "$TM_PREFIX/bin/termux-muscle" "$HOME/.local/bin/termux-muscle"; do
        if [[ ${manager_path%/*} -ef $TM_ROOT/bin ]]; then continue; fi
        if [[ ( -e $manager_path || -L $manager_path ) &&
              ( ! -L $manager_path || $(readlink -- "$manager_path") != "$TM_ROOT/bin/termux-muscle" ) ]]; then
            printf 'Existing command preserved: %s\nUse the owned command: %s\n' "$manager_path" "$TM_ROOT/bin/termux-muscle" >&2
        else
            "$TM_CORE" links "$TM_ROOT" install "$manager_path" "$TM_ROOT/bin/termux-muscle" >/dev/null
        fi
    done
    local manual_path=$TM_PREFIX/share/man/man1/termux-muscle.1
    local manual_target=$TM_ROOT/tools/current/docs/man/termux-muscle.1
    mkdir -p -- "$TM_PREFIX/share/man/man1"
    local manual_result
    manual_result=$("$TM_CORE" links "$TM_ROOT" install-manual "$manual_path" "$manual_target")
    if [[ $manual_result == foreign_preserved ]]; then
        printf 'Existing manual preserved: %s\nRead the installed manual with: man %s\n' "$manual_path" "$manual_target" >&2
    else
        tm_manual_index -d || :
        printf 'Manual installed: %s (man termux-muscle)\n' "$manual_path"
    fi
    tm_completion_install
    if [[ $no_install == false ]]; then
        tm_install_release install --no-link
        if [[ $link_claude == true ]]; then tm_default_claude_links; fi
    fi
    "$TM_CORE" tooling "$TM_ROOT" cleanup
    printf 'Termux Muscle %s installed from locally built source (%s).\n' "$TM_PROJECT_VERSION" "$id"
    printf 'Command: %s\n' "$TM_ROOT/bin/termux-muscle"
    if [[ ! $(type -P termux-muscle || :) -ef $TM_ROOT/bin/termux-muscle ]]; then
        printf 'PATH does not select the managed termux-muscle command; use %s.\n' "$TM_ROOT/bin/termux-muscle" >&2
    fi
)

tm_uninstall() {
    (($# == 0)) || tm_error usage 'uninstall takes no arguments.'
    local manual=$TM_PREFIX/share/man/man1/termux-muscle.1 indexed=false status result=0
    if [[ -f $manual && ! -L $manual ]]; then
        status=$("$TM_CORE" links "$TM_ROOT" manual-status "$manual") || return
        if [[ $status == owned ]]; then
            # mandoc needs the page to exist when removing its index entry.
            # If C refuses removal or restores an original, rebuild that entry.
            indexed=true
            tm_manual_index -u || :
        fi
    fi
    "$TM_CORE" tooling "$TM_ROOT" uninstall || result=$?
    if ((result == 0)); then tm_completion_remove; fi
    if [[ $indexed == true && ( -e $manual || -L $manual ) ]]; then
        tm_manual_index -d || :
    fi
    return "$result"
}

tm_project_version_newer() {
    # Versions have already passed tm-core's strict X.Y.Z validation. Compare
    # digit strings by length first so large components cannot overflow Bash.
    local LC_ALL=C part
    local -a candidate installed
    IFS=. read -r -a candidate <<< "$1"
    IFS=. read -r -a installed <<< "$2"
    for part in 0 1 2; do
        if (( ${#candidate[part]} > ${#installed[part]} )); then return 0; fi
        if (( ${#candidate[part]} < ${#installed[part]} )); then return 1; fi
        if [[ ${candidate[part]} > ${installed[part]} ]]; then return 0; fi
        if [[ ${candidate[part]} < ${installed[part]} ]]; then return 1; fi
    done
    return 1
}

tm_self_update_version_gate() {
    local candidate=$1 installed=$2
    if tm_project_version_newer "$candidate" "$installed"; then return 0; fi
    if tm_project_version_newer "$installed" "$candidate"; then
        printf 'termux-muscle: target_older: %s is installed; %s is older. No update performed. Use --force for a compatible downgrade.\n' "$installed" "$candidate" >&2
        return 3
    fi
    printf 'termux-muscle: already_current: Termux Muscle %s is already installed. No update performed. Use --force to reinstall.\n' "$installed" >&2
    return 2
}

tm_self_update_impl() (
    set -euo pipefail
    local version='' force=false repository=octocore-autonomous-systems/termux-muscle work expected base
    while (($#)); do
        case $1 in
            --version) (($# > 1)) || tm_error usage '--version needs X.Y.Z.'; version=$2; shift 2 ;;
            -f|--force) force=true; shift ;;
            *) tm_error usage "Unknown self-update option: $1" ;;
        esac
    done
    "$TM_CORE" version-check "$TM_PROJECT_VERSION" || tm_error invalid_version 'Installed manager version is invalid.'
    if [[ -n $version ]]; then
        "$TM_CORE" version-check "$version" || tm_error invalid_version 'Requested manager version is invalid.'
        [[ -z ${TM_SELF_UPDATE_TARGET_FILE:-} ]] || printf '%s\n' "$version" > "$TM_SELF_UPDATE_TARGET_FILE"
        if [[ $force == false ]]; then
            tm_self_update_version_gate "$version" "$TM_PROJECT_VERSION" || return $?
        fi
    fi
    # v0.1.x cannot read regular manual-file ownership records. Reject before
    # running its installer, which could otherwise publish old tooling first.
    tm_check_tooling_compatibility() {
        if [[ $1 =~ ^0\.(0|1)\. ]]; then
            tm_error incompatible_tooling 'In-place downgrade below 0.2.0 is unsupported. The current installation was preserved; use the current manager to uninstall before intentionally installing an older manager.'
        fi
    }
    [[ -z $version ]] || tm_check_tooling_compatibility "$version"
    work=$(mktemp -d "${TMPDIR:-$TM_PREFIX/tmp}/termux-muscle-self-update.XXXXXXXX") ||
        tm_error temporary_failed 'Cannot create a private self-update download directory.'
    trap 'rm -rf -- "$work"' EXIT
    tm_fetch_project() {
        curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 15 --max-time 180 --retry 2 --retry-max-time 240 \
            --max-filesize "$3" --output "$2" -- "$1"
    }
    if [[ -z $version ]]; then
        tm_fetch_project "https://api.github.com/repos/$repository/releases/latest" "$work/latest.json" 1048576 ||
            tm_error download_failed 'Cannot resolve the latest project release; current tooling was preserved.'
        version=$("$TM_CORE" json-get "$work/latest.json" tag_name) ||
            tm_error invalid_version 'Latest release metadata has no valid version tag.'
        [[ $version == v* ]] || tm_error invalid_version 'Latest project release has no version tag.'
        version=${version#v}
        "$TM_CORE" version-check "$version" || tm_error invalid_version 'Latest release version is invalid.'
        [[ -z ${TM_SELF_UPDATE_TARGET_FILE:-} ]] || printf '%s\n' "$version" > "$TM_SELF_UPDATE_TARGET_FILE"
        if [[ $force == false ]]; then
            tm_self_update_version_gate "$version" "$TM_PROJECT_VERSION" || return $?
        fi
    fi
    tm_check_tooling_compatibility "$version"
    base=https://github.com/$repository/releases/download/v$version
    tm_fetch_project "$base/SHA256SUMS" "$work/SHA256SUMS" 65536 || tm_error download_failed 'Cannot download project checksums.'
    tm_fetch_project "$base/install.sh" "$work/install.sh" 262144 || tm_error download_failed 'Cannot download the versioned source installer.'
    expected=$(awk '$2 == "install.sh" {count++; value=$1} END {if(count != 1) exit 1; print value}' "$work/SHA256SUMS") ||
        tm_error checksum_failed 'The manifest has no unique installer checksum.'
    [[ $expected =~ ^[[:xdigit:]]{64}$ ]] || tm_error checksum_failed 'The manifest installer checksum is malformed.'
    printf '%s  install.sh\n' "$expected" > "$work/installer.sha256"
    (cd -- "$work" && sha256sum -c installer.sha256 >/dev/null) ||
        tm_error checksum_failed 'Installer checksum does not match; no downloaded code was executed.'
    # No mutation lock is held during network requests, compilation or tests.
    # The verified installer takes it only when the new source is ready.
    if [[ -n ${TM_SELF_UPDATE_EVENTS:-} ]]; then
        printf 'installer %s\n' "$(wc -c < "$TM_SELF_UPDATE_TRANSCRIPT_FILE")" >> "$TM_SELF_UPDATE_EVENTS"
    fi
    "$TM_PREFIX/bin/bash" "$work/install.sh" --version "$version" --root "$TM_ROOT" --prefix "$TM_PREFIX" --no-install ||
        tm_error update_failed 'The verified installer did not complete; inspect its output. The manager update was not confirmed.'
)

tm_self_update() (
    set -euo pipefail
    local json=false verbose=false force=false arg work status=0 target=- result=failed error_code=- message=- line complete=true
    local -a args=()
    for arg in "$@"; do
        case $arg in
            --json) json=true ;;
            -V|--verbose) verbose=true ;;
            -f|--force) force=true; args+=("$arg") ;;
            *) args+=("$arg") ;;
        esac
    done
    if [[ $json == false && $verbose == true ]]; then
        unset TM_SELF_UPDATE_EVENTS TM_SELF_UPDATE_TRANSCRIPT_FILE TM_SELF_UPDATE_PROGRESS_MODE TM_SELF_UPDATE_TARGET_FILE
        tm_self_update_impl "${args[@]}"
        return
    fi
    if [[ $json == false ]]; then printf 'Checking manager release...\n' >&2; fi
    work=$(mktemp -d "${TMPDIR:-$TM_PREFIX/tmp}/termux-muscle-result.XXXXXXXX") || {
        if [[ $json == true ]]; then
            "$TM_CORE" self-update-json "$TM_PROJECT_VERSION" - "$force" failed 1 temporary_failed \
                'Cannot create a private self-update result directory.' /dev/null true -
        else
            printf 'termux-muscle: temporary_failed: Cannot create a private self-update result directory.\n' >&2
        fi
        return 1
    }
    chmod 700 "$work"
    : > "$work/transcript"
    : > "$work/events"
    TM_SELF_UPDATE_TARGET_FILE=$work/target
    tm_self_update_capture() (
        # Bound raw compiler/test output before management publication.
        ulimit -f 65536
        export TM_SELF_UPDATE_EVENTS="$work/events" TM_SELF_UPDATE_TRANSCRIPT_FILE="$work/transcript"
        if [[ $json == false ]]; then
            export TM_SELF_UPDATE_PROGRESS_MODE=concise
        else
            unset TM_SELF_UPDATE_PROGRESS_MODE
        fi
        tm_self_update_impl "${args[@]}"
    )
    if [[ $json == true ]]; then
        if tm_self_update_capture > "$work/transcript" 2>&1 3>/dev/null; then status=0; else status=$?; fi
    elif tm_self_update_capture 3>&2 > "$work/transcript" 2>&1; then
        status=0
    else
        status=$?
    fi
    [[ ! -f $work/target ]] || target=$(< "$work/target")
    case $status in
        0) result=installed ;;
        2) result=already_current; error_code=already_current ;;
        3) result=target_older; error_code=target_older ;;
        *) status=1; result=failed ;;
    esac
    while IFS= read -r line; do
        if [[ $line =~ ^termux-muscle:\ ([a-z_]+):\ (.*)$ ]]; then
            if [[ $error_code == - ]]; then error_code=${BASH_REMATCH[1]}; fi
            message=${BASH_REMATCH[2]}
            break
        fi
    done < "$work/transcript"
    if [[ $status == 1 && $error_code == - ]]; then
        error_code=update_failed
        message='The verified installer did not complete; inspect the transcript.'
    fi
    if (( $(stat -c %s -- "$work/transcript") >= 33554432 )); then
        status=1 result=failed error_code=capture_failed complete=false
        message='The 32 MiB transcript limit was reached; update completion is unconfirmed.'
    fi
    if [[ $status == 0 ]]; then message=-; fi
    if [[ $json == true ]]; then
        if ! "$TM_CORE" self-update-json "$TM_PROJECT_VERSION" "$target" "$force" "$result" \
            "$status" "$error_code" "$message" "$work/transcript" "$complete" "$work/events"; then
            # The primary serializer writes only after reading all inputs, so
            # a malformed stage record can still yield one failure object.
            if "$TM_CORE" self-update-json "$TM_PROJECT_VERSION" "$target" "$force" failed 1 \
                capture_failed "Cannot encode the full transcript; private log retained at $work/transcript." \
                /dev/null false -; then
                return 1
            fi
            printf 'termux-muscle: capture_failed: JSON result could not be produced; private log retained at %s.\n' "$work/transcript" >&2
            return 1
        fi
        rm -rf -- "$work"
        return "$status"
    fi
    if [[ $status == 0 ]]; then
        printf 'Installed Termux Muscle %s.\n' "$target" >&2
        rm -rf -- "$work"
    elif [[ $status == 2 || $status == 3 ]]; then
        printf 'termux-muscle: %s: %s\n' "$error_code" "$message" >&2
        rm -rf -- "$work"
    else
        local stage='release verification'
        if [[ -s $work/events ]]; then
            stage=$(tail -n 1 "$work/events")
            stage=${stage%% *}
        fi
        printf 'termux-muscle: %s: during %s: %s\nFull log: %s\n' \
            "$error_code" "$stage" "$message" "$work/transcript" >&2
    fi
    return "$status"
)
