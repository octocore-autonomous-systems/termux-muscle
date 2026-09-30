#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Independent OAS community project; not affiliated with Anthropic.
set -eu
# Archive validation must not inherit options from unrelated shell customizations.
unset TAR_OPTIONS GZIP
REPOSITORY="octocore-autonomous-systems/termux-muscle"
VERSION="0.11.0"

fail() { printf '%s\n' "termux-muscle: $*" >&2; exit 1; }
usage() {
    cat <<'USAGE'
Usage: sh install.sh [--version X.Y.Z] [--root DIR] [--prefix DIR]
                     [--no-install] [--no-link]
Download verified source, build and test it locally, then install Claude Code.
Normal installation sets up claude on PATH and saves replaced command entries.
--no-install installs the management tool and manual without downloading or linking Claude.
--no-link installs Claude but leaves Claude command entries unchanged.
--link is accepted for compatibility; linking is already the default.
--prefix is the Termux package root, normally the existing $PREFIX.
Requires native Termux on Android aarch64. Missing prerequisites use Termux pkg.
USAGE
}
version=$VERSION
install_root=
install_prefix=
no_install=0
link_claude=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --version|--root|--prefix)
            [ "$#" -ge 2 ] && [ -n "$2" ] || fail "$1 requires a value"
            case "$1" in --version) version=$2;; --root) install_root=$2;; --prefix) install_prefix=$2;; esac
            shift 2;;
        --no-install) no_install=1; shift;;
        --link) link_claude=1; shift;;
        --no-link) link_claude=0; shift;;
        --help|-h) usage; exit 0;;
        *) fail "unknown argument: $1 (use --help)";;
    esac
done
printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$' || fail "expected a semantic release version, such as $VERSION"
[ "$(uname -s)" = Linux ] || fail "requires native Android Termux"
case "$(uname -m)" in aarch64|arm64) ;; *) fail "this release supports Android aarch64 only";; esac
termux_prefix=${PREFIX:-}
case "$termux_prefix" in */com.termux/files/usr) ;; *) fail "run inside native Termux; PREFIX is not a Termux package prefix";; esac
command -v getprop >/dev/null 2>&1 || fail "run in native Termux, outside a proot distribution"
[ -n "$(getprop ro.build.version.sdk)" ] || fail "cannot identify Android"
[ -z "${PROOT_TMP_DIR:-}" ] || fail "run the installer outside a proot distribution"
command -v pkg >/dev/null 2>&1 || fail "Termux pkg is unavailable"
missing=
for pair in bash:bash proot:proot sha256sum:coreutils cmp:diffutils rg:ripgrep curl:curl make:make cc:clang pkg-config:pkg-config tar:tar gzip:gzip man:mandoc; do
    program=${pair%%:*}; package=${pair#*:}
    command -v "$program" >/dev/null 2>&1 || missing="$missing $package"
done
if command -v pkg-config >/dev/null 2>&1; then
    for pair in json-c:json-c libarchive:libarchive libcrypto:openssl; do
        module=${pair%%:*}; package=${pair#*:}
        pkg-config --exists "$module" || missing="$missing $package"
    done
else
    missing="$missing json-c libarchive openssl"
fi
[ -f "$termux_prefix/etc/tls/cert.pem" ] || missing="$missing ca-certificates"
if [ -n "$missing" ]; then
    printf '%s\n' "Installing Termux build/runtime prerequisites:$missing" >&2
    # Only the literal package identifiers above are expanded here.
    # shellcheck disable=SC2086
    pkg install -y $missing || fail "prerequisite installation failed; resolve the pkg error and rerun"
fi
for program in bash proot sha256sum cmp rg curl make cc pkg-config tar gzip man; do
    command -v "$program" >/dev/null 2>&1 || fail "required program is missing: $program"
done
pkg-config --exists json-c libarchive libcrypto || fail "required C libraries or headers are missing"
[ -f "$termux_prefix/etc/tls/cert.pem" ] || fail "Termux CA bundle is missing"
[ -x "$termux_prefix/bin/bash" ] || fail "Termux Bash is missing from its package prefix"
tar --version | grep -q 'GNU tar' || fail "GNU tar is required for restricted source extraction"

# On a terminal, a quiet self-update also shows a spinner and elapsed seconds
# while the build runs. TM_SELF_UPDATE_PROGRESS_LIVE=0 turns this off and 1
# forces it; logs and JSON transcripts never receive it.
live_progress=0
if [ "${TM_SELF_UPDATE_PROGRESS_MODE:-}" = concise ]; then
    case "${TM_SELF_UPDATE_PROGRESS_LIVE:-}" in
        1) live_progress=1 ;;
        0) ;;
        *) if [ -t 3 ]; then live_progress=1; fi ;;
    esac
fi
spinner=
spinner_line=
start_spinner() {
    spinner_line=$1
    if [ "$live_progress" -ne 1 ]; then printf '%s\n' "$1" >&3; return 0; fi
    printf '%s' "$1" >&3
    installer=$$
    started=$(date +%s) || started=
    (
        trap - 0 INT TERM HUP
        set -- '|' '/' '-' '\'
        # Stop by itself if the installer disappears without cleaning up.
        while kill -0 "$installer" 2>/dev/null; do
            elapsed=
            if [ -n "$started" ] && now=$(date +%s); then elapsed=" $((now - started))s"; fi
            printf '\r%s %s%s\033[K' "$spinner_line" "$1" "$elapsed" >&3 || exit 0
            frame=$1; shift; set -- "$@" "$frame"
            sleep 0.5 2>/dev/null || sleep 1 || exit 0
        done
    ) &
    spinner=$!
}
stop_spinner() {
    [ -n "$spinner" ] || return 0
    kill "$spinner" 2>/dev/null || :
    wait "$spinner" 2>/dev/null || :
    spinner=
    printf '\r%s\033[K\n' "$spinner_line" >&3
}
umask 077
scratch=$(mktemp -d "${TMPDIR:-${termux_prefix}/tmp}/termux-muscle-install.XXXXXXXX") || fail "cannot create a private download directory"
cleanup() { stop_spinner; rm -rf -- "$scratch"; }
trap cleanup 0
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
asset="termux-muscle-$version.tar.gz"
base="https://github.com/$REPOSITORY/releases/download/v$version"
fetch() {
    curl -q --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --connect-timeout 15 --max-time 180 --retry 2 --retry-max-time 240 \
        --max-filesize "$3" --output "$2" "$1" || fail "download failed; the managed installation was not changed"
}
record_update_stage() {
    stop_spinner
    [ -n "${TM_SELF_UPDATE_EVENTS:-}" ] || return 0
    [ -n "${TM_SELF_UPDATE_TRANSCRIPT_FILE:-}" ] || fail "missing self-update transcript path"
    bytes=$(wc -c < "$TM_SELF_UPDATE_TRANSCRIPT_FILE") || fail "cannot measure self-update transcript"
    printf '%s %s\n' "$1" "$bytes" >> "$TM_SELF_UPDATE_EVENTS" || fail "cannot record self-update stage"
    if [ "${TM_SELF_UPDATE_PROGRESS_MODE:-}" = concise ]; then
        case "$1" in
            verification) printf 'Verifying source archive...\n' >&3 ;;
            build) start_spinner 'Building Termux Muscle locally...' ;;
            test) printf 'Running test programs: ' >&3 ;;
            installation) printf 'Installing verified manager...\n' >&3 ;;
        esac
    fi
}
record_update_stage verification
fetch "$base/SHA256SUMS" "$scratch/SHA256SUMS" 65536
fetch "$base/$asset" "$scratch/$asset" 16777216
expected=$(awk -v name="$asset" '$2 == name {count++; value=$1} END {if(count != 1) exit 1; print value}' "$scratch/SHA256SUMS") || fail "checksum manifest has no unique source entry"
[ "${#expected}" -eq 64 ] || fail "malformed SHA-256 digest"
case "$expected" in *[!0-9a-fA-F]*) fail "malformed SHA-256 digest";; esac
printf '%s  %s\n' "$expected" "$asset" > "$scratch/source.sha256"
(cd "$scratch" && sha256sum -c source.sha256 >/dev/null) || fail "checksum verification failed; source was not built"

# The project source and this installer share the same publisher trust boundary.
# Accept only the predictable source archive produced by our release script.
# Escape-style listings make newline/control names visibly rejectable.
LC_ALL=C timeout --kill-after=5 60 tar --list --gzip --file "$scratch/$asset" --absolute-names --quoting-style=escape > "$scratch/names" || fail "cannot list source archive"
LC_ALL=C timeout --kill-after=5 60 tar --list --verbose --gzip --file "$scratch/$asset" --absolute-names --quoting-style=escape > "$scratch/types" || fail "cannot inspect source archive"
awk -v prefix="termux-muscle-$version/" '
    BEGIN {count=0}
    {
        count++
        if ($0 !~ /^[A-Za-z0-9._+\/-]+$/ || index($0,prefix)!=1 || $0 ~ /(^|\/)\.\.?($|\/)/ || $0 ~ /\/\//) exit 1
        relative=substr($0,length(prefix)+1)
        if(relative!="" && relative!~/^(src|lib|bin|scripts|tests|docs|\.github|compatibility)\// && relative!~/^(Makefile|VERSION|LICENSE|CREDITS\.md|README\.md|CONTRIBUTING\.md|CHANGELOG\.md|compatibility\.json|install\.sh|\.gitignore|\.clang-format|\.githooks\/|\.githooks\/pre-commit)$/) exit 1
        if(seen[$0]++) exit 1
    }
    END {if(count==0 || count>4096) exit 1}
' "$scratch/names" || fail "source archive contains unsafe or unexpected paths"
awk '
    substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1}
    {if($3 !~ /^[0-9]+$/) exit 1; total+=$3}
    END {if(total>67108864) exit 1}
' "$scratch/types" || fail "source archive contains links, special entries or excessive size"
mkdir "$scratch/source"
timeout --kill-after=5 60 tar --extract --gzip --file "$scratch/$asset" --directory "$scratch/source" \
    --no-same-owner --no-same-permissions --keep-old-files \
    || fail "source extraction failed"
source_dir="$scratch/source/termux-muscle-$version"
[ -f "$source_dir/VERSION" ] && [ "$(cat "$source_dir/VERSION")" = "$version" ] || fail "source VERSION does not match the requested release"
[ -f "$source_dir/Makefile" ] && [ -f "$source_dir/bin/termux-muscle" ] || fail "source archive lacks its build or CLI entry"
record_update_stage build
printf '%s\n' "Building and testing Termux Muscle $version locally..." >&2
timeout --kill-after=5 600 make -C "$source_dir" all || fail "local compilation failed; the managed installation was not changed"
record_update_stage test
timeout --kill-after=5 600 make -C "$source_dir" check || fail "local tests failed; the managed installation was not changed"
[ -x "$source_dir/build/tm-core" ] || fail "local build did not produce its C helper"
set -- "$source_dir/bin/termux-muscle" bootstrap --source-dir "$source_dir" --build-dir "$source_dir/build"
[ -z "$install_root" ] || set -- "$@" --root "$install_root"
[ -z "$install_prefix" ] || set -- "$@" --prefix "$install_prefix"
[ "$no_install" -eq 0 ] || set -- "$@" --no-install
[ "$link_claude" -eq 1 ] || set -- "$@" --no-link
record_update_stage installation
"$termux_prefix/bin/bash" "$@"
