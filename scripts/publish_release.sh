#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Publication entry for the tag job, after both compiler matrix jobs succeed.
set -euo pipefail
umask 077
repository=octocore-autonomous-systems/termux-muscle
source_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd -- "$source_root"
fail() { printf 'release-publication: %s\n' "$*" >&2; exit 1; }
(($# == 0)) || fail 'This workflow entry takes no arguments.'
[[ ${GITHUB_ACTIONS:-} == true && ${GITHUB_EVENT_NAME:-} == push &&
   ${GITHUB_REF_TYPE:-} == tag && ${GITHUB_REPOSITORY:-} == "$repository" &&
   ${GITHUB_SERVER_URL:-} == https://github.com ]] || fail 'Publication requires the GitHub tag-push workflow for this repository.'
[[ ${TM_CHECKS_RESULT:-} == success ]] || fail 'The complete compiler matrix must succeed before publication.'
version=$(cat VERSION)
[[ $version =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || fail 'VERSION must name a stable X.Y.Z release.'
tag=v$version
[[ ${GITHUB_REF_NAME:-} == "$tag" && ${GITHUB_REF:-} == "refs/tags/$tag" ]] || fail 'The pushed tag does not match VERSION.'
commit=${GITHUB_SHA:-}
[[ $commit =~ ^[0-9a-f]{40}$ && ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ &&
   ${GITHUB_RUN_ATTEMPT:-} =~ ^[1-9][0-9]*$ ]] || fail 'Workflow commit, run or attempt identity is invalid.'
[[ $(git rev-parse HEAD) == "$commit" && $(git rev-parse "$GITHUB_REF^{commit}") == "$commit" ]] ||
    fail 'The checked-out commit and exact tag must match the workflow commit.'
[[ -z $(git status --porcelain --untracked-files=all) ]] || fail 'Publish only an unchanged tagged checkout.'
human_notes=$source_root/docs/releases/$version.md
[[ -s $human_notes && ! -L $human_notes ]] || fail 'This release needs reviewed versioned notes, including its known limitations.'

work=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/termux-muscle-publish.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
attempt_api=repos/$repository/actions/runs/$GITHUB_RUN_ID/attempts/$GITHUB_RUN_ATTEMPT
gh api --hostname github.com "$attempt_api" \
    --jq '[.head_sha,.event,.path,.run_attempt]|@tsv' > "$work/run.tsv" || fail 'Cannot verify the current workflow attempt.'
expected=$(printf '%s\tpush\t.github/workflows/ci.yml\t%s' "$commit" "$GITHUB_RUN_ATTEMPT")
[[ $(cat "$work/run.tsv") == "$expected" ]] || fail 'CI evidence belongs to another commit, event, workflow or attempt.'
gh api --hostname github.com --paginate "$attempt_api/jobs?per_page=100" \
    --jq '.jobs[]|select(.name=="Linux / gcc" or .name=="Linux / clang")|[.name,.status,.conclusion,.head_sha]|@tsv' \
    > "$work/jobs.tsv" || fail 'Cannot verify both compiler jobs.'
gcc_count=0 clang_count=0
while IFS=$'\t' read -r name status conclusion head extra; do
    [[ -n $name && $status == completed && $conclusion == success && $head == "$commit" && -z $extra ]] ||
        fail 'A required compiler job is incomplete, unsuccessful or belongs to another commit.'
    case $name in
        'Linux / gcc') gcc_count=$((gcc_count + 1)) ;;
        'Linux / clang') clang_count=$((clang_count + 1)) ;;
        *) fail 'Unexpected compiler job evidence.' ;;
    esac
done < "$work/jobs.tsv"
[[ $gcc_count == 1 && $clang_count == 1 ]] || fail 'Exactly one successful GCC job and one successful Clang job are required in this attempt.'

check_remote_tag() {
    local selected
    selected=$(git ls-remote --exit-code "https://github.com/$repository.git" "refs/tags/$tag" "refs/tags/$tag^{}" |
        awk -v tag="refs/tags/$tag" '
            $2 == tag {plain_count++; plain=$1; next}
            $2 == tag "^{}" {peeled_count++; peeled=$1; next}
            {bad=1}
            END {if(bad || plain_count!=1 || peeled_count>1)exit 1; print peeled_count ? peeled : plain}
        ') || fail 'Cannot verify the current public tag target.'
    [[ $selected == "$commit" ]] || fail 'The public tag moved or does not name the tested commit.'
}
check_remote_tag
# This rechecks local evidence at the exact tagged checkout. The preceding
# matrix already compiled/tested both compilers and checked reproducibility.
bash scripts/build_release.sh --output "$work/assets" --release
(cd -- "$work/assets" && sha256sum -c SHA256SUMS) || fail 'Release asset checksums failed.'
{
    cat -- "$human_notes"
    printf '\n---\n\n'
    cat -- "$work/assets/RELEASE_NOTES.md"
} > "$work/public-notes.md"
[[ $(git rev-parse HEAD) == "$commit" && -z $(git status --porcelain --untracked-files=all) ]] ||
    fail 'The tagged checkout changed while release assets were built.'
check_remote_tag
# create refuses an existing release; never edit/upload with --clobber. The
# tag was already pushed by a maintainer and must still exist at publication.
gh release create "$tag" \
    "$work/assets/termux-muscle-$version.tar.gz" "$work/assets/install.sh" \
    "$work/assets/compatibility.json" "$work/assets/RELEASE_NOTES.md" "$work/assets/SHA256SUMS" \
    --repo "$repository" --verify-tag --target "$commit" --title "Termux Muscle $version" \
    --notes-file "$work/public-notes.md"
