#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
umask 077
repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tm-publication-test.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
fixture=$scratch/source
mkdir -p "$fixture/scripts" "$fixture/docs/releases" "$scratch/bin" "$scratch/trace" "$scratch/tmp"
cp "$repo/scripts/publish_release.sh" "$fixture/scripts/publish_release.sh"
cp "$repo/docs/releases/0.1.0.md" "$fixture/docs/releases/0.1.0.md"
printf '0.1.0\n' > "$fixture/VERSION"
export TM_PUBLICATION_TRACE=$scratch/trace TM_PUBLICATION_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$fixture/scripts/build_release.sh" <<'SH'
set -euo pipefail
[[ $1 == --output && $3 == --release && $# == 3 ]] || exit 89
[[ ${TM_PUBLICATION_CASE:-} != build_failure ]] || exit 90
mkdir -p -- "$2"
printf 'built\n' > "$TM_PUBLICATION_TRACE/built"
printf 'source-only fixture\n' > "$2/termux-muscle-0.1.0.tar.gz"
printf '# source installer\n' > "$2/install.sh"
printf '{}\n' > "$2/compatibility.json"
printf 'Generated strict metadata fixture\n' > "$2/RELEASE_NOTES.md"
(cd -- "$2" && sha256sum termux-muscle-0.1.0.tar.gz install.sh compatibility.json RELEASE_NOTES.md > SHA256SUMS)
if [[ ${TM_PUBLICATION_CASE:-} == corrupt_assets ]]; then printf corrupt >> "$2/install.sh"; fi
SH
printf '#!%s\n' "$(command -v bash)" > "$scratch/bin/git"
cat >> "$scratch/bin/git" <<'SH'
set -euo pipefail
other=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
case $1 in
    rev-parse)
        if [[ ${TM_PUBLICATION_CASE:-} == wrong_local_tag && $2 != HEAD ]]; then printf '%s\n' "$other";
        else printf '%s\n' "$TM_PUBLICATION_SHA"; fi ;;
    status)
        if [[ ${TM_PUBLICATION_CASE:-} == dirty || ( ${TM_PUBLICATION_CASE:-} == changed_during_build && -e $TM_PUBLICATION_TRACE/built ) ]]; then printf ' M VERSION\n'; fi ;;
    ls-remote)
        printf 'read\n' >> "$TM_PUBLICATION_TRACE/remote"
        sha=$TM_PUBLICATION_SHA
        if [[ ${TM_PUBLICATION_CASE:-} == wrong_remote || ( ${TM_PUBLICATION_CASE:-} == moved_remote && $(wc -l < "$TM_PUBLICATION_TRACE/remote") == 2 ) ]]; then sha=$other; fi
        if [[ ${TM_PUBLICATION_CASE:-} == lightweight ]]; then printf '%s\trefs/tags/v0.1.0\n' "$sha";
        else printf '%s\trefs/tags/v0.1.0\n%s\trefs/tags/v0.1.0^{}\n' "$other" "$sha"; fi ;;
    *) printf 'Unexpected fake git request\n' >&2; exit 91 ;;
esac
SH
printf '#!%s\n' "$(command -v bash)" > "$scratch/bin/gh"
cat >> "$scratch/bin/gh" <<'SH'
set -euo pipefail
other=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
if [[ $1 == api ]]; then
    [[ ${TM_PUBLICATION_CASE:-} != api_failure ]] || exit 92
    endpoint=''
    for argument; do [[ $argument != repos/* ]] || endpoint=$argument; done
    [[ $endpoint == repos/octocore-autonomous-systems/termux-muscle/actions/runs/123/attempts/1* ]] || exit 93
    if [[ $endpoint == */jobs\?* ]]; then
        [[ ${TM_PUBLICATION_CASE:-} != missing_both ]] || exit 0
        for compiler in gcc clang; do
            [[ ${TM_PUBLICATION_CASE:-} != missing_$compiler ]] || continue
            status=completed conclusion=success sha=$TM_PUBLICATION_SHA
            [[ ${TM_PUBLICATION_CASE:-} != failed_$compiler ]] || conclusion=failure
            [[ ${TM_PUBLICATION_CASE:-} != skipped_$compiler ]] || conclusion=skipped
            [[ ${TM_PUBLICATION_CASE:-} != pending_$compiler ]] || { status=in_progress; conclusion=null; }
            [[ ${TM_PUBLICATION_CASE:-} != wrong_job_sha ]] || sha=$other
            printf 'Linux / %s\t%s\t%s\t%s\n' "$compiler" "$status" "$conclusion" "$sha"
        done
        if [[ ${TM_PUBLICATION_CASE:-} == duplicate_gcc ]]; then printf 'Linux / gcc\tcompleted\tsuccess\t%s\n' "$TM_PUBLICATION_SHA"; fi
    else
        sha=$TM_PUBLICATION_SHA event=push path=.github/workflows/ci.yml attempt=1
        [[ ${TM_PUBLICATION_CASE:-} != wrong_run_sha ]] || sha=$other
        [[ ${TM_PUBLICATION_CASE:-} != wrong_run_event ]] || event=pull_request
        [[ ${TM_PUBLICATION_CASE:-} != wrong_workflow ]] || path=.github/workflows/other.yml
        [[ ${TM_PUBLICATION_CASE:-} != wrong_attempt ]] || attempt=2
        printf '%s\t%s\t%s\t%s\n' "$sha" "$event" "$path" "$attempt"
    fi
elif [[ $1 == release && $2 == create ]]; then
    printf '%s\0' "$@" > "$TM_PUBLICATION_TRACE/create.args"
    [[ ${TM_PUBLICATION_CASE:-} != existing_release ]] || exit 94
    while (($#)); do
        if [[ $1 == --notes-file ]]; then cp -- "$2" "$TM_PUBLICATION_TRACE/public-notes.md"; shift 2; else shift; fi
    done
    printf 'mock publication only\n'
else
    printf 'Unexpected fake gh request\n' >&2; exit 95
fi
SH
chmod 700 "$scratch/bin/git" "$scratch/bin/gh"
count=0
pass() { printf 'PASS publication gate: %s\n' "$1"; count=$((count + 1)); }
fail() { cat "$scratch/error" >&2; printf 'FAIL publication gate: %s\n' "$1" >&2; exit 1; }
invoke() {
    env PATH="$scratch/bin:$PATH" RUNNER_TEMP="$scratch/tmp" \
        GITHUB_ACTIONS=true GITHUB_EVENT_NAME=push GITHUB_REF_TYPE=tag \
        GITHUB_REPOSITORY=octocore-autonomous-systems/termux-muscle GITHUB_SERVER_URL=https://github.com \
        GITHUB_REF_NAME=v0.1.0 GITHUB_REF=refs/tags/v0.1.0 GITHUB_SHA="$TM_PUBLICATION_SHA" \
        GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 TM_CHECKS_RESULT=success "$@" \
        bash "$fixture/scripts/publish_release.sh" > "$scratch/output" 2> "$scratch/error"
}
reset_trace() { rm -f "$scratch/trace/"*; }
rejects() {
    local label=$1; shift
    reset_trace
    if invoke "$@"; then fail "accepted $label"; fi
    [[ ! -e $scratch/trace/create.args ]] || fail "publication reached for $label"
    case $label in
        moved_remote|changed_during_build|corrupt_assets) ;;
        *) [[ ! -e $scratch/trace/built ]] || fail "build reached for $label" ;;
    esac
    pass "$label is rejected before publication"
}

for state in failure cancelled skipped pending ''; do rejects "matrix $state" "TM_CHECKS_RESULT=$state"; done
for event in pull_request workflow_dispatch; do rejects "$event context" "GITHUB_EVENT_NAME=$event"; done
rejects 'foreign repository' GITHUB_REPOSITORY=another/repository
rejects 'branch ref' GITHUB_REF_TYPE=branch GITHUB_REF=refs/heads/main
rejects 'tag and version mismatch' GITHUB_REF_NAME=v9.0.0 GITHUB_REF=refs/tags/v9.0.0
rejects 'wrong checkout commit' GITHUB_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
for scenario in wrong_local_tag dirty api_failure wrong_run_sha wrong_run_event wrong_workflow wrong_attempt missing_both \
    missing_gcc missing_clang failed_gcc failed_clang skipped_gcc skipped_clang pending_gcc pending_clang wrong_job_sha duplicate_gcc \
    wrong_remote moved_remote changed_during_build build_failure corrupt_assets; do
    rejects "$scenario" "TM_PUBLICATION_CASE=$scenario"
done

reset_trace
invoke || fail 'valid matrix and annotated tag were rejected'
mapfile -d '' -t args < "$scratch/trace/create.args"
[[ ${args[0]} == release && ${args[1]} == create && ${args[2]} == v0.1.0 ]] || fail 'wrong release operation'
[[ " ${args[*]} " == *' --verify-tag '* && " ${args[*]} " == *" --target $TM_PUBLICATION_SHA "* &&
   " ${args[*]} " != *' --clobber '* ]] || fail 'missing immutable tag binding'
[[ $(wc -l < "$scratch/trace/remote") == 2 ]] || fail 'tag not checked before and after build'
grep -Fq 'Fable 5.1 answered a direct launcher check' "$scratch/trace/public-notes.md" || fail 'Fable limitation missing'
grep -Fq 'upstream fallback/refusal' "$scratch/trace/public-notes.md" || fail 'Fable automated failure missing'
grep -Fq 'Default cross-session messaging was disabled' "$scratch/trace/public-notes.md" || fail 'messaging limitation missing'
grep -Fq 'actual MCP tool invocation are untested' "$scratch/trace/public-notes.md" || fail 'untested workflow limitation missing'
grep -Fq 'Generated strict metadata fixture' "$scratch/trace/public-notes.md" || fail 'strict generated metadata missing'
shopt -s nullglob dotglob
temporary=("$scratch/tmp/"*)
[[ ${#temporary[@]} == 0 ]] || fail 'publication scratch not cleaned'
pass 'exact successful compiler jobs and annotated tag reach only immutable mocked publication with qualified notes'
reset_trace
invoke TM_PUBLICATION_CASE=lightweight || fail 'matching lightweight tag was rejected'
pass 'matching lightweight tag retains exact commit checks'
reset_trace
if invoke TM_PUBLICATION_CASE=existing_release; then fail 'existing release failure was ignored'; fi
[[ -e $scratch/trace/create.args ]] || fail 'existing-release fixture did not run'
pass 'an existing release fails without any update or clobber fallback'

# Configuration checks cover the security boundary that cannot be executed by
# local Bash: GitHub must wait for the whole matrix before granting publication.
awk '/^  publish:/{copy=1}copy' "$repo/.github/workflows/ci.yml" > "$scratch/publisher.yml"
grep -Eq '^    needs: checks$' "$scratch/publisher.yml" || fail 'publisher lacks whole-matrix dependency'
grep -Fq "success() && needs.checks.result == 'success'" "$scratch/publisher.yml" || fail 'publisher lacks explicit success condition'
grep -Fq "github.event_name == 'push' && github.ref_type == 'tag'" "$scratch/publisher.yml" || fail 'publisher lacks tag-push restriction'
grep -Fq 'run: bash scripts/publish_release.sh' "$scratch/publisher.yml" || fail 'workflow bypasses tested publication guard'
[[ $(grep -c 'contents: write' "$repo/.github/workflows/ci.yml") == 1 ]] || fail 'write permission is not publisher-scoped'
grep -Fq 'compiler: [gcc, clang]' "$repo/.github/workflows/ci.yml" || fail 'required compiler matrix changed'
grep -Eq 'run: make -j2 CFLAGS=.*-Werror' "$repo/.github/workflows/ci.yml" || fail 'production compiler warnings are not enforced'
if grep -Eq 'continue-on-error:[[:space:]]*true' "$repo/.github/workflows/ci.yml"; then fail 'CI is allowed to hide failures'; fi
pass 'workflow waits for both compilers and confines write permission to guarded tag publication'
printf '%s publication gate regression groups passed (mocked GitHub; no git/gh dependency or publication)\n' "$count"
