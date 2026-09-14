#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Developer-only: deliberately excluded from the installer's tests/test_*.sh glob.
set -euo pipefail
umask 077
source_repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
checker=$source_repo/scripts/check_format.sh
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tm-format-tests.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
count=0
pass() { printf 'PASS format tooling: %s\n' "$1"; count=$((count + 1)); }
fail() { printf 'FAIL format tooling: %s\n' "$1" >&2; exit 1; }
mock=$scratch/clang-format
printf '#!%s\n' "$(command -v bash)" > "$mock"
cat >> "$mock" <<'MOCK'
set -euo pipefail
if [[ ${1:-} == --version ]]; then printf 'clang-format version %s.1.8\n' "${MOCK_FORMAT_MAJOR:-21}"; exit; fi
[[ $# == 4 && $1 == --dry-run && $2 == --Werror && $3 == --style=file && $4 == --assume-filename=* ]] || exit 77
file=${4#*=}
directory=${file%/*}
while [[ ! -f $directory/.clang-format && ! -f $directory/_clang-format && $directory != / ]]; do directory=${directory%/*}; [[ $directory ]] || directory=/; done
if [[ -f $directory/.clang-format ]]; then style=$(cat "$directory/.clang-format"); else style=$(cat "$directory/_clang-format"); fi
content=$(cat)
printf '%s\0%s\0%s\0' "$file" "$style" "$content" >> "$MOCK_FORMAT_TRACE"
[[ $style == LOOSE || $content != *BAD* ]]
MOCK
chmod 700 "$mock"
export CLANG_FORMAT=$mock MOCK_FORMAT_TRACE=$scratch/trace
new_case() {
    local name=$1
    work=$scratch/"$name repository"
    mkdir -p -- "$work/scripts" "$work/.githooks" "$work/src"
    cp -- "$checker" "$work/scripts/check_format.sh"
    cp -- "$source_repo/.githooks/pre-commit" "$work/.githooks/pre-commit"
    cd -- "$work"
    git init -q
    git config user.email fixture@example.invalid
    git config user.name 'Format fixture'
    git config commit.gpgsign false
    printf 'STRICT\n' > .clang-format
    printf 'GOOD baseline\n' > src/main.c
    printf 'Documentation\n' > README.md
    git add .
    git -c core.hooksPath=/dev/null commit -qm baseline
    : > "$MOCK_FORMAT_TRACE"
}
check() { bash "$checker" "$@"; }
rejects() {
    local message=$1; shift
    if "$@" > "$scratch/stdout" 2> "$scratch/stderr"; then fail "unexpected acceptance: $message"; fi
    grep -Fq -- "$message" "$scratch/stderr" || { cat "$scratch/stderr" >&2; fail "wrong rejection: $message"; }
}
new_case documentation
printf 'Changed docs\n' >> README.md; git add README.md
CLANG_FORMAT=$scratch/missing check --staged
[[ ! -s $MOCK_FORMAT_TRACE ]] || fail 'documentation ran formatter'
pass 'documentation-only staging needs no formatter'

# Even a legacy invalid style cannot turn a documentation-only commit into a C check.
printf 'STRICT\n' > "$scratch/documentation-style"
rm .clang-format; ln -s "$scratch/documentation-style" .clang-format
git add .clang-format
git -c core.hooksPath=/dev/null commit -qm legacy-style
printf 'Another docs edit\n' >> README.md; git add README.md
CLANG_FORMAT=$scratch/missing check --staged
[[ ! -s $MOCK_FORMAT_TRACE ]] || fail 'legacy style triggered a documentation check'
pass 'unchanged legacy style does not block unrelated documentation staging'

new_case partial_bad
printf 'BAD staged\n' > src/main.c; git add src/main.c
printf 'GOOD working\n' > src/main.c
cp src/main.c "$scratch/working-before"
git ls-files --stage > "$scratch/index-before"
rejects 'incorrect staged formatting' check --staged
cmp src/main.c "$scratch/working-before"
git ls-files --stage > "$scratch/index-after"; cmp "$scratch/index-before" "$scratch/index-after"
pass 'bad staged blob is rejected despite good worktree; source and index are untouched'

new_case partial_good
printf 'GOOD staged\n' > src/main.c; git add src/main.c
printf 'BAD unstaged\n' > src/main.c
check --staged > /dev/null
rejects 'incorrect all formatting' check --all
pass 'staged check ignores bad unstaged bytes; all check reads the worktree'

new_case staged_style
printf 'BAD staged\n' > src/main.c; git add src/main.c
printf 'LOOSE\n' > .clang-format
rejects 'incorrect staged formatting' check --staged
check --all > /dev/null
pass 'staged style is used independently of unstaged style changes'

new_case style_only
printf 'LOOSE\n' > .clang-format
printf 'BAD baseline allowed by original style\n' > src/main.c
git add .; git -c core.hooksPath=/dev/null commit -qm loose
printf 'STRICT\n' > .clang-format; git add .clang-format
rejects 'incorrect staged formatting' check --staged
pass 'a style-only change checks unchanged indexed C files'

new_case renamed_root_style
git mv .clang-format old-style.txt
rejects 'tracked regular root .clang-format is required' check --staged
pass 'renaming the root style away triggers all-source validation'

new_case renamed_nested_style
mkdir src/nested
printf 'LOOSE\n' > src/nested/.clang-format
printf 'BAD accepted by original nested style\n' > src/nested/item.h
git add .; git -c core.hooksPath=/dev/null commit -qm nested-style
git mv src/nested/.clang-format src/nested/old-style.txt
rejects 'incorrect staged formatting' check --staged
pass 'renaming a nested style away checks unchanged C against its new inherited style'

new_case nested_style
mkdir src/nested
printf 'LOOSE\n' > src/nested/.clang-format
printf 'BAD accepted by nearest style\n' > src/nested/item.h
git add .
check --staged > /dev/null
printf 'STRICT\n' > src/nested/.clang-format; git add src/nested/.clang-format
rejects 'incorrect staged formatting' check --staged
pass 'nested staged configuration follows normal formatter lookup'

new_case symlink_style
printf 'STRICT\n' > "$scratch/external-style"
rm .clang-format; ln -s "$scratch/external-style" .clang-format; git add .clang-format
rejects 'formatting configuration must be a regular file' check --staged
pass 'staged symbolic-link configuration is rejected'

new_case symlink_working_style
printf 'GOOD change\n' > src/main.c; git add src/main.c
rm .clang-format; ln -s "$scratch/external-style" .clang-format
check --staged > /dev/null
rejects 'must be a regular working-tree file' check --all
pass 'working-tree style symlink is rejected without affecting staged style'

new_case names
# shellcheck disable=SC2016 # The filename must retain literal shell syntax.
odd='src/spaces and $(touch SENTINEL).c'
line=$'src/newline\ndirectory/item name.h'
mkdir -p -- "${line%/*}"
printf 'GOOD space and literal shell syntax\n' > "$odd"
printf 'GOOD newline path\n' > "$line"
git add -- "$odd" "$line"
check --staged > /dev/null
[[ ! -e SENTINEL ]] || fail 'filename was executed'
printf 'BAD staged name\n' > "$odd"; git add -- "$odd"
rejects 'incorrect staged formatting' check --staged
pass 'spaces, newlines and literal shell syntax in tracked filenames are preserved'

new_case renamed_deleted
printf 'GOOD change\n' > src/main.c; git add src/main.c
git mv src/main.c 'src/renamed file.h'
check --staged > /dev/null
git reset --hard -q HEAD
git rm -q src/main.c
CLANG_FORMAT=$scratch/missing check --staged
pass 'renamed C headers are checked; deleted sources are skipped'

new_case missing_formatter
printf 'GOOD change\n' > src/main.c; git add src/main.c
rejects 'clang-format 21 is required' env CLANG_FORMAT="$scratch/missing" bash "$checker" --staged
rejects 'clang-format 21 is required; found:' env MOCK_FORMAT_MAJOR=20 bash "$checker" --staged
pass 'missing and wrong-major formatters have actionable diagnostics'

new_case missing_style
git rm -q .clang-format
rejects 'tracked regular root .clang-format is required' check --staged
pass 'deleting the root style fails rather than silently using a fallback'

new_case symlink_source
printf 'GOOD external\n' > "$scratch/external.c"
ln -s "$scratch/external.c" src/link.c; git add src/link.c
rejects 'C source must be a regular file' check --staged
pass 'symbolic-link C input is rejected'

new_case untracked
printf 'BAD untracked\n' > src/untracked.c
check --all > /dev/null
pass 'all mode covers tracked files without adding untracked source'

new_case hook
# Execute the actual hook through Git; only this disposable repo is configured.
git config core.hooksPath .githooks
printf 'BAD staged\n' > src/main.c; git add src/main.c
rejects 'incorrect staged formatting' git commit -qm rejected
[[ $(git rev-list --count HEAD) == 1 ]] || fail 'hook allowed a rejected commit'
printf 'GOOD staged\n' > src/main.c; git add src/main.c
git commit -qm accepted > /dev/null
[[ $(git rev-list --count HEAD) == 2 ]] || fail 'hook prevented good commit'
printf 'Docs only\n' >> README.md; git add README.md
CLANG_FORMAT=$scratch/missing git commit -qm documentation > /dev/null
[[ $(git rev-list --count HEAD) == 3 ]] || fail 'documentation hook unexpectedly needed formatter'
pass 'real Git pre-commit blocks bad C, permits good C and skips documentation'
printf 'PASS: %s developer formatting regression groups\n' "$count"
