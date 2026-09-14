# SPDX-License-Identifier: MPL-2.0
# Bash lifecycle hooks; C owns identities, publication journals and leases.

tm_bootstrap() (
    set -euo pipefail
    local source_dir='' build_dir='' no_install=false link_claude=false
    while (($#)); do
        case $1 in
            --source-dir|--build-dir)
                (($# > 1)) || tm_error usage "$1 needs a directory."
                if [[ $1 == --source-dir ]]; then source_dir=$2; else build_dir=$2; fi
                shift 2 ;;
            --no-install) no_install=true; shift ;;
            --link) link_claude=true; shift ;;
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
    manager_path=$HOME/.local/bin/termux-muscle
    mkdir -p -- "$HOME/.local/bin"
    # Expected foreign commands are preserved; errors in existing ownership
    # metadata are still fatal when the links helper attempts a managed repair.
    if [[ ( -e $manager_path || -L $manager_path ) &&
          ( ! -L $manager_path || $(readlink -- "$manager_path") != "$TM_ROOT/bin/termux-muscle" ) ]]; then
        printf 'Existing command preserved: %s\nUse the owned command: %s\n' "$manager_path" "$TM_ROOT/bin/termux-muscle" >&2
    else
        "$TM_CORE" links "$TM_ROOT" install "$manager_path" "$TM_ROOT/bin/termux-muscle" >/dev/null
    fi
    if [[ $link_claude == true ]]; then
        "$TM_CORE" links "$TM_ROOT" install "$TM_PREFIX/bin/claude" "$TM_ROOT/bin/claude" >/dev/null
    fi
    if [[ $no_install == false ]]; then tm_install_release install; fi
    "$TM_CORE" tooling "$TM_ROOT" cleanup
    printf 'Termux Muscle %s installed from locally built source (%s).\n' "$TM_PROJECT_VERSION" "$id"
    printf 'Command: %s\n' "$TM_ROOT/bin/termux-muscle"
    case :$PATH: in *:"$HOME/.local/bin":*) ;; *) printf 'Add %s to PATH to use termux-muscle by name.\n' "$HOME/.local/bin" ;; esac
)

tm_uninstall() {
    (($# == 0)) || tm_error usage 'uninstall takes no arguments.'
    "$TM_CORE" tooling "$TM_ROOT" uninstall
}

tm_self_update() (
    set -euo pipefail
    local version='' repository=octocore-autonomous-systems/termux-muscle work expected base
    while (($#)); do
        case $1 in
            --version) (($# > 1)) || tm_error usage '--version needs X.Y.Z.'; version=$2; shift 2 ;;
            *) tm_error usage "Unknown self-update option: $1" ;;
        esac
    done
    [[ -z $version ]] || "$TM_CORE" version-check "$version"
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
    fi
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
