#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Developer-only check. Never rewrites source files or the Git index.
set -euo pipefail
export LC_ALL=C GIT_OPTIONAL_LOCKS=0
umask 077
fail() { printf 'format: %s\n' "$*" >&2; exit 1; }
[[ $# == 1 && ( $1 == --all || $1 == --staged ) ]] || fail 'usage: bash scripts/check_format.sh --all|--staged'
mode=$1
repo=$(git rev-parse --show-toplevel) || fail 'run this check inside a Git working tree'
cd -- "$repo"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tm-format.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
mkdir -- "$scratch/tree"
# Capture object IDs once, then read those exact blobs even with partial staging.
git ls-files --stage -z > "$scratch/index"
declare -A changed=()
config_changed=0
is_style() { [[ ${1##*/} == .clang-format || ${1##*/} == _clang-format ]]; }
if [[ $mode == --staged ]]; then
    git diff --cached --no-renames --name-only --diff-filter=ACDMRTUXB -z > "$scratch/changed"
    while IFS= read -r -d '' path; do
        changed["$path"]=1
        if is_style "$path"; then config_changed=1; fi
    done < "$scratch/changed"
fi
sources=()
styles=()
source_oids=()
style_oids=()
style_error=
while IFS= read -r -d '' entry; do
    header=${entry%%$'\t'*}
    path=${entry#*$'\t'}
    read -r file_mode oid stage <<< "$header"
    if is_style "$path"; then
        if [[ $stage != 0 ]]; then
            style_error="resolve the staged formatting configuration conflict: $path"
        elif [[ $file_mode != 100644 && $file_mode != 100755 ]]; then
            style_error="formatting configuration must be a regular file: $path"
        fi
        styles+=("$path"); style_oids+=("$oid")
    elif [[ $path == *.c || $path == *.h ]]; then
        if [[ $mode == --all || $config_changed == 1 || ${changed["$path"]+present} ]]; then
            [[ $stage == 0 ]] || fail "resolve the staged C source conflict: $path"
            [[ $file_mode == 100644 || $file_mode == 100755 ]] || fail "C source must be a regular file: $path"
            sources+=("$path"); source_oids+=("$oid")
        fi
    fi
done < "$scratch/index"
# Documentation-only commits need neither a formatter nor a style installation.
[[ ${#sources[@]} != 0 ]] || exit 0
[[ ! $style_error ]] || fail "$style_error"
if [[ -n ${CLANG_FORMAT:-} ]]; then
    formatter=$CLANG_FORMAT
elif command -v clang-format-21 >/dev/null 2>&1; then
    formatter=clang-format-21
else
    formatter=clang-format
fi
command -v "$formatter" >/dev/null 2>&1 || fail 'clang-format 21 is required for C changes; install it or set CLANG_FORMAT to its executable'
version=$("$formatter" --version) || fail 'cannot query clang-format version'
[[ $version =~ version[[:space:]]+([0-9]+)(\.|[[:space:]]|$) && ${BASH_REMATCH[1]} == 21 ]] || fail "clang-format 21 is required; found: $version"
copy_source() {
    local path=$1 oid=$2 directory=.
    if [[ $path == */* ]]; then directory=${path%/*}; fi
    mkdir -p -- "$scratch/tree/$directory"
    if [[ $mode == --staged ]]; then
        git cat-file blob "$oid" > "$scratch/tree/$path"
    else
        [[ -f $path && ! -L $path ]] || fail "tracked source/configuration must be a regular working-tree file: $path"
        cat -- "$path" > "$scratch/tree/$path"
    fi
}
for ((i=0; i<${#styles[@]}; i++)); do copy_source "${styles[i]}" "${style_oids[i]}"; done
[[ -f $scratch/tree/.clang-format ]] || fail 'a tracked regular root .clang-format is required'
for ((i=0; i<${#sources[@]}; i++)); do copy_source "${sources[i]}" "${source_oids[i]}"; done
failed=0
for path in "${sources[@]}"; do
    if ! "$formatter" --dry-run --Werror --style=file --assume-filename="$scratch/tree/$path" < "$scratch/tree/$path" > /dev/null; then
        printf 'format: incorrect %s formatting: %q\n' "${mode#--}" "$path" >&2
        failed=1
    fi
done
if [[ $failed == 1 ]]; then
    printf 'format: format the intended files with clang-format 21, review the changes, then stage them explicitly.\n' >&2
    exit 1
fi
printf 'format: checked %s %s C/header file(s) with clang-format 21.\n' "${#sources[@]}" "${mode#--}"
