#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
unset TAR_OPTIONS GZIP
source_root=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output=dist
release=0
fail() { printf 'release: %s\n' "$*" >&2; exit 1; }
while (($#)); do
    case "$1" in
        --output|--root)
            (($# >= 2)) && [[ -n "$2" ]] || fail "$1 requires a value"
            if [[ "$1" == --output ]]; then output=$2; else source_root=$2; fi
            shift 2;;
        --release) release=1; shift;;
        --help) printf '%s\n' 'Usage: scripts/build_release.sh [--root SOURCE] [--output DIR] [--release]'; exit 0;;
        *) fail "unknown argument: $1";;
    esac
done
source_root=$(CDPATH='' cd -- "$source_root" && pwd)
[[ -f "$source_root/VERSION" && ! -L "$source_root/VERSION" ]] || fail 'VERSION must be a regular file'
version=$(cat "$source_root/VERSION")
[[ "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$ ]] || fail 'VERSION must be a semantic version'
[[ $(awk -F'"' '/^VERSION="[^"]+"$/ {print $2}' "$source_root/install.sh") == "$version" ]] || fail 'installer VERSION does not match VERSION'
for file in Makefile LICENSE CREDITS.md compatibility.json bin/termux-muscle docs/man/termux-muscle.1; do
    [[ -s "$source_root/$file" && ! -L "$source_root/$file" ]] || fail "missing regular source: $file"
done
make -C "$source_root" all >&2
helper="$source_root/build/tm-core"
[[ -x "$helper" && ! -L "$helper" ]] || fail 'make did not produce build/tm-core'
if ((release)); then "$helper" release-check "$source_root"; fi
[[ ! -L "$output" ]] || fail 'output directory cannot be a symlink'
mkdir -p -- "$output"
output=$(CDPATH='' cd -- "$output" && pwd)
umask 077
scratch=$(mktemp -d "${TMPDIR:-/tmp}/termux-muscle-release.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
prefix="termux-muscle-$version"
stage="$scratch/$prefix"
mkdir "$stage"
shopt -s nullglob dotglob globstar
cd -- "$source_root"
files=(Makefile VERSION LICENSE CREDITS.md README.md CONTRIBUTING.md CHANGELOG.md compatibility.json install.sh .gitignore .clang-format)
for directory in src lib bin scripts tests docs .github .githooks compatibility; do
    [[ ! -L "$directory" ]] || fail "source directory is a symlink: $directory"
    [[ ! -d "$directory" ]] || files+=("$directory" "$directory"/**)
done
for file in "${files[@]}"; do
    [[ "$file" =~ ^[A-Za-z0-9._/-]+$ && "$file" != /* && "$file" != *'/../'* && ! -L "$file" ]] || fail "unsafe source name or symlink: $file"
done
printf '%s\n' "${files[@]}" | LC_ALL=C sort -u > "$scratch/files"
while IFS= read -r file; do
    [[ -e "$file" || -L "$file" ]] || continue
    [[ "$file" =~ ^[A-Za-z0-9._/-]+$ && "$file" != /* && "$file" != *'/../'* && ! -L "$file" ]] || fail "unsafe source name or symlink: $file"
    # Git does not preserve empty directories. Create only parents of source files,
    # so a working tree and a fresh checkout produce the same archive contents.
    if [[ -d "$file" ]]; then continue; fi
    [[ -f "$file" ]] || fail "source contains a special file: $file"
    case "$file" in
        .githooks/pre-commit) ;;
        .githooks/*) fail "unexpected contributor hook: $file";;
    esac
    case "$file" in
        scripts/track_upstream.py|tests/dev/test_track_upstream.py) ;; # Maintainer-only source; never run by bootstrap.
        *.c|*.h|*.sh|*.md|*.yml|*.yaml|*.json|Makefile|VERSION|LICENSE|.gitignore|.clang-format|.githooks/pre-commit|docs/man/termux-muscle.1|docs/images/termux-muscle-hero.png|bin/termux-muscle) ;;
        *) fail "unexpected source file type (vendor/build artifacts are excluded): $file";;
    esac
    mkdir -p -- "$stage/$(dirname -- "$file")"
    cp -- "$file" "$stage/$file"
    case "$file" in *.sh|.githooks/pre-commit|bin/termux-muscle) chmod 755 "$stage/$file";; *) chmod 644 "$stage/$file";; esac
done < "$scratch/files"
asset="$prefix.tar.gz"
for name in "$asset" install.sh compatibility.json RELEASE_NOTES.md SHA256SUMS; do
    [[ ! -L "$output/$name" ]] || fail "refusing symlink output: $name"
done
# Ustar has no volatile extended headers. Fixed metadata plus gzip -n is reproducible.
LC_ALL=C tar --sort=name --format=ustar --mtime=@0 --owner=0 --group=0 --numeric-owner \
    --mode=u=rwX,go=rX -C "$scratch" -cf "$scratch/source.tar" "$prefix"
gzip -n -9 -c "$scratch/source.tar" > "$scratch/$asset"
[[ $(wc -c < "$scratch/source.tar") -le 67108864 && $(wc -c < "$scratch/$asset") -le 16777216 ]] || fail 'source archive exceeds bootstrap size limits'
cp -- "$source_root/install.sh" "$scratch/install.sh"
cp -- "$source_root/compatibility.json" "$scratch/compatibility.json"
{
    if ((!release)); then printf '%s\n\n' '> Development build: device acceptance is not asserted; do not publish as verified.'; fi
    "$helper" release-notes "$source_root"
} > "$scratch/RELEASE_NOTES.md"
(cd -- "$scratch" && sha256sum "$asset" install.sh compatibility.json RELEASE_NOTES.md > SHA256SUMS)
for name in "$asset" install.sh compatibility.json RELEASE_NOTES.md SHA256SUMS; do
    cp -- "$scratch/$name" "$output/$name"
    chmod 644 "$output/$name"
done
chmod 755 "$output/install.sh"
printf 'Built %s (%s)\n' "$output/$asset" "$([[ $release == 1 ]] && printf 'release gate passed' || printf 'development')"
