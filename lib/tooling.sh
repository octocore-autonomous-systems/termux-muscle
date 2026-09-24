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

tm_self_update() (
    set -euo pipefail
    local version='' force=false repository=octocore-autonomous-systems/termux-muscle work expected base
    while (($#)); do
        case $1 in
            --version) (($# > 1)) || tm_error usage '--version needs X.Y.Z.'; version=$2; shift 2 ;;
            -f|--force) force=true; shift ;;
            *) tm_error usage "Unknown self-update option: $1" ;;
        esac
    done
    "$TM_CORE" version-check "$TM_PROJECT_VERSION"
    if [[ -n $version ]]; then
        "$TM_CORE" version-check "$version"
        if [[ $force == false ]] && ! tm_project_version_newer "$version" "$TM_PROJECT_VERSION"; then
            printf 'Termux Muscle %s is installed; %s is not newer. No update performed. Use --force to reinstall a compatible version.\n' "$TM_PROJECT_VERSION" "$version"
            return 0
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
    work=$(mktemp -d "${TMPDIR:-$TM_PREFIX/tmp}/termux-muscle-self-update.XXXXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    tm_fetch_project() {
        curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
            --connect-timeout 15 --max-time 180 --retry 2 --retry-max-time 240 \
            --max-filesize "$3" --output "$2" -- "$1"
    }
    if [[ -z $version ]]; then
        tm_fetch_project "https://api.github.com/repos/$repository/releases/latest" "$work/latest.json" 1048576 ||
            tm_error download_failed 'Cannot resolve the latest project release; current tooling was preserved.'
        version=$("$TM_CORE" json-get "$work/latest.json" tag_name)
        [[ $version == v* ]] || tm_error invalid_version 'Latest project release has no version tag.'
        version=${version#v}
        "$TM_CORE" version-check "$version"
        if [[ $force == false ]] && ! tm_project_version_newer "$version" "$TM_PROJECT_VERSION"; then
            printf 'Termux Muscle %s is installed; %s is not newer. No update performed. Use --force to reinstall a compatible version.\n' "$TM_PROJECT_VERSION" "$version"
            return 0
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
    "$TM_PREFIX/bin/bash" "$work/install.sh" --version "$version" --root "$TM_ROOT" --prefix "$TM_PREFIX" --no-install
)
