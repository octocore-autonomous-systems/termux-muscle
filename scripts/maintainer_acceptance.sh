#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Maintainer device acceptance for one Termux Muscle version.
#
# Runs the complete lifecycle in a disposable data root and writes a device
# report that the strict release gate can evaluate:
#
#   install (source bootstrap, --no-link) -> isolated startup checks
#   -> offline update -> optional authenticated shell-tool check
#   -> offline rollback -> uninstall
#
# The live installation is never used. Its commands, manual, completion and
# state are fingerprinted before and after; any difference fails the run.
#
# Run from a fresh native Termux shell, NOT from inside Claude Code: a managed
# Claude session runs inside PRoot, and the runtime deliberately refuses to
# start a second managed release from there (runtime_nested_conflict).
#
# Usage: scripts/maintainer_acceptance.sh [--model MODEL_ID] [--output FILE]
#                                         [--keep-work] [--preflight]
#
#   --model ID   Also run the authenticated shell-tool check with this exact
#                model. This makes one real model request as your Claude
#                login. A subscription login (Pro or Max over OAuth) counts
#                it against plan usage and is not billed; an API key is
#                billed, capped by --max-budget-usd 0.50. The report's
#                total_cost_usd is Claude Code's estimate at API prices, not a
#                charge. Without --model, shell_tools stays SKIP and the report
#                cannot pass the release gate.
#   --output F   Report path (default: compatibility/reports/acceptance-
#                VERSION-UTCSTAMP.json). Must not exist.
#   --keep-work  Keep the disposable work directory even on success.
#   --preflight  Check prerequisites, print the plan, and stop.
#   --allow-dirty  Accept uncommitted or untracked source files. The report
#                records this, and such evidence does not describe any commit.
#
# Exit: 0 all required checks PASS and live installation unchanged;
#       1 at least one required check is not PASS; 2 usage or preflight
#       refusal; 3 the live installation changed (investigate immediately).
set -euo pipefail
shopt -s inherit_errexit
umask 077

SRC=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TM=$SRC/bin/termux-muscle
CORE=$SRC/build/tm-core
PREFIX=${PREFIX:-/data/data/com.termux/files/usr}
REAL_HOME=$HOME
LIVE_DATA=${XDG_DATA_HOME:-$HOME/.local/share}
LIVE_ROOT=$LIVE_DATA/termux-muscle
REQUIRED=(install startup_version startup_help shell_tools update rollback uninstall)
BUDGET_USD=0.50

die() { printf 'acceptance: %s\n' "$*" >&2; exit 2; }
say() { printf '\n== %s\n' "$*" >&2; }

model='' output='' keep_work=false preflight_only=false allow_dirty=false
while (($#)); do
    case $1 in
        --allow-dirty) allow_dirty=true; shift ;;
        --model) (($# > 1)) || die '--model needs an exact model ID.'; model=$2; shift 2 ;;
        --output) (($# > 1)) || die '--output needs a file.'; output=$2; shift 2 ;;
        --keep-work) keep_work=true; shift ;;
        --preflight) preflight_only=true; shift ;;
        -h|--help) sed -n '3,35p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "unknown option: $1 (see --help)" ;;
    esac
done
[[ -z $model || $model =~ ^claude-[a-z0-9.-]+$ ]] || die "model ID looks invalid: $model"

# ---------------------------------------------------------------- preflight
# This is the check that stops a run from inside Claude Code, with the reason.
if [[ -e /.termux-muscle-namespace.json ]]; then
    die "this shell is inside a termux-muscle-managed Claude Code session (PRoot namespace).
The runtime refuses to start a different managed release from here, so the
candidate startup checks cannot run. Open a fresh Termux session (not started
from claude) and rerun this script there."
fi
tracer=$(sed -n 's/^TracerPid:[[:space:]]*//p' /proc/self/status)
[[ $tracer == 0 ]] || die "this process is being traced (TracerPid $tracer), e.g. by PRoot or a debugger. Run from a fresh native Termux shell."
[[ $(uname -m) == aarch64 ]] || die 'Android ARM64 (aarch64) is required.'
for tool in jq make sha256sum timeout git; do
    command -v "$tool" >/dev/null || die "missing command: $tool (pkg install $tool)"
done
[[ -x $TM ]] || die "not a termux-muscle checkout: $SRC"

version=$(<"$SRC/VERSION")
pin=$(jq -r '.claude.version' "$SRC/compatibility.json")
musl=$(jq -r '.musl.version' "$SRC/compatibility.json")
[[ $(jq -r '.project_version' "$SRC/compatibility.json") == "$version" ]] ||
    die 'VERSION and compatibility.json project_version disagree.'
# Evidence must describe a commit. `make stage` copies whole bin/, lib/ and
# docs/ trees into the tested installation, so untracked files count too.
# Reports written by this script are the only exemption.
commit=$(git -C "$SRC" rev-parse HEAD)
changes=$(git -C "$SRC" status --porcelain --untracked-files=all -- . ':!compatibility/reports' | wc -l)
dirty=false
((changes == 0)) || dirty=true
if [[ $dirty == true && $allow_dirty == false ]]; then
    die "the source tree has $changes uncommitted or untracked file(s), so the result would not
describe commit ${commit:0:7}. Run from a clean checkout of the branch being released, e.g.
  git -C '$SRC' worktree add ../termux-muscle-acceptance ${commit:0:7}
or pass --allow-dirty for an exploratory run whose report records the tree as dirty."
fi
stamp=$(date -u +%Y%m%dT%H%M%SZ)
[[ -n $output ]] || output=$SRC/compatibility/reports/acceptance-$version-$stamp.json
[[ ! -e $output && ! -L $output ]] || die "report already exists: $output"

cat >&2 <<PLAN
Termux Muscle $version acceptance
  source      $SRC (${commit:0:7}$($dirty && printf ', %s uncommitted or untracked file(s)' "$changes"))
  pinned      Claude Code $pin, musl $musl
  live root   $LIVE_ROOT (fingerprinted, never modified)
  model check ${model:-none; shell_tools will be SKIP}${model:+ (one real request: plan usage on a subscription, billed up to \$$BUDGET_USD on an API key)}
  report      $output
PLAN
$preflight_only && { printf '%s\n' 'Preflight passed; nothing was changed.' >&2; exit 0; }

# ------------------------------------------------------------- live guard
fingerprint() {
    local path
    for path in "$PREFIX/bin/claude" "$PREFIX/bin/termux-muscle" \
        "$REAL_HOME/.local/bin/claude" "$REAL_HOME/.local/bin/termux-muscle" \
        "$PREFIX/share/man/man1/termux-muscle.1" \
        "$LIVE_DATA/bash-completion/completions/termux-muscle" \
        "$LIVE_ROOT/state.json" "$LIVE_ROOT/links.json" "$LIVE_ROOT/installation.json" \
        "$LIVE_ROOT/tooling.json" "$LIVE_ROOT/tools/current"; do
        if [[ -L $path ]]; then printf 'link %s -> %s\n' "$path" "$(readlink -- "$path")"
        elif [[ -f $path ]]; then printf 'file %s %s\n' "$path" "$(sha256sum < "$path" | cut -d' ' -f1)"
        elif [[ -e $path ]]; then printf 'other %s\n' "$path"
        else printf 'absent %s\n' "$path"; fi
    done
}

say 'Building helper'
make -C "$SRC" >/dev/null
[[ $("$CORE" --version) == "Termux Muscle $version" ]] || die 'built helper version does not match VERSION.'

mkdir -p -- "$REAL_HOME/.cache"
work=$(mktemp -d "$REAL_HOME/.cache/tm-acceptance.XXXXXXXX")
root=$work/home/.local/share/termux-muscle
log=$work/acceptance.log
mkdir -p -- "$work/home/.local/share" "$work/fixture"
fingerprint > "$work/live-before.txt"

declare -A result detail
record() { result[$1]=$2; detail[$1]=$3; printf '  %-16s %-4s %s\n' "$1" "$2" "$3" >&2; }

# Lifecycle commands see a disposable HOME and data root, so every link,
# manual or completion they create belongs to the disposable installation.
lifecycle() {
    printf '\n$ termux-muscle %s\n' "$*" >> "$log"
    HOME=$work/home XDG_DATA_HOME=$work/home/.local/share \
        "$TM" --root "$root" --prefix "$PREFIX" "$@" >> "$log" 2>&1
}
state_field() { jq -r --arg k "$1" '.[$k] // empty' "$root/state.json" 2>/dev/null || :; }

cleanup() {
    local status=$?
    if [[ -d $root ]]; then lifecycle uninstall || :; fi
    if [[ $status == 0 && $keep_work == false ]]; then
        rm -rf -- "$work"
    else
        printf '\nWork directory kept for review: %s\n' "$work" >&2
    fi
}
trap cleanup EXIT

# ----------------------------------------------------------------- install
say 'install: source bootstrap into a disposable root (--no-link)'
installed=''
if lifecycle bootstrap --source-dir "$SRC" --build-dir "$SRC/build" --no-link; then
    installed=$(state_field current)
    receipt=$root/releases/$installed/payload.json
    if [[ -n $installed && $(jq -r .version "$receipt") == "$pin" &&
          $(jq -r .compatibility_status "$receipt") == pinned ]]; then
        record install PASS private_source_bootstrap_no_link
    else
        record install FAIL activated_release_not_the_pin
    fi
else
    record install FAIL bootstrap_failed
fi

# ---------------------------------------------- isolated startup + report
say 'startup: isolated version, help and init checks via termux-muscle test'
diagnostics=$work/diagnostics.json
if [[ -n $installed ]]; then
    lifecycle test --output "$diagnostics" || :
fi
if [[ -s $diagnostics ]]; then
    for id in startup_version startup_help startup_init runtime_integrity namespace_shell; do
        status=$(jq -r --arg id "$id" '.checks[] | select(.id == $id) | .status' "$diagnostics")
        code=$(jq -r --arg id "$id" '.checks[] | select(.id == $id) | .detail_code // ""' "$diagnostics")
        record "$id" "${status:-SKIP}" "${code:-not_reported}"
    done
else
    for id in startup_version startup_help startup_init; do record "$id" SKIP runtime_unavailable; done
fi

# ------------------------------------------------------------------ update
say 'update: offline candidate from the verified cache'
updated=''
if [[ -n $installed ]] && lifecycle update --offline; then
    updated=$(state_field current)
    if [[ -n $updated && $updated != "$installed" && $(state_field previous) == "$installed" ]]; then
        record update PASS offline_candidate_activated
    else
        record update FAIL state_not_advanced
    fi
elif [[ -n $installed ]]; then
    record update FAIL update_failed
else
    record update SKIP prerequisite_failed
fi

# ----------------------------------------------- authenticated shell tools
workflow='null'
models='[]'
if [[ -z $model ]]; then
    record shell_tools SKIP no_model_requested
elif [[ -z $updated ]]; then
    record shell_tools SKIP prerequisite_failed
else
    say "shell_tools: one real Bash tool call with $model (API-key spend cap \$$BUDGET_USD)"
    nonce=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    fixture=$work/fixture/tm-fixture
    printf '%s\n' "$nonce" > "$work/fixture/needle.txt"
    # The portable shebang exercises the namespace's /usr/bin/env mapping and
    # rg exercises native tools. Any failure stops before the marker is printed.
    cat > "$fixture" <<FIXTURE
#!/usr/bin/env sh
set -eu
dir=\$(dirname -- "\$0")
rg --fixed-strings --quiet -- '$nonce' "\$dir/needle.txt"
printf '%s\n' '$nonce' > "\$dir/attestation"
printf 'TM_FIXTURE_OK %s\n' '$nonce'
FIXTURE
    chmod 700 "$fixture"
    stream=$work/stream.jsonl
    started=$(date +%s%3N)
    tool_exit=0
    # Real HOME supplies the user's normal credentials; the flags keep user
    # settings, hooks, MCP servers, skills and session files out of the run.
    (cd "$work/fixture" && timeout --kill-after=10 300 \
        "$TM" --root "$root" --prefix "$PREFIX" run \
        -p "Use the Bash tool exactly once to run this command unchanged: $fixture
Then reply with only the line it printed." \
        --model "$model" --output-format stream-json --verbose \
        --tools Bash --allowedTools Bash --permission-mode dontAsk \
        --max-budget-usd "$BUDGET_USD" \
        --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
        --setting-sources '' --settings '{"disableAllHooks":true}' \
        --no-session-persistence --disable-slash-commands --safe-mode --no-chrome \
        > "$stream" 2>> "$log") || tool_exit=$?
    elapsed=$(( $(date +%s%3N) - started ))
    events() { jq -cR 'fromjson? // empty' "$stream"; }
    # Same source as src/report.c: the model that actually produced each reply.
    observed=$(events | jq -sc '[.[] | select(.type == "assistant") | .message.model
        | select(. != null)] | unique')
    uses=$(events | jq -sc --arg f "$fixture" '[.[] | select(.type == "assistant") | .message.content[]?
        | select(.type == "tool_use" and .name == "Bash" and ((.input.command // "") | contains($f))) | .id]')
    matched=$(events | jq -sc --argjson ids "$uses" --arg marker "TM_FIXTURE_OK $nonce" '[.[]
        | select(.type == "user") | .message.content[]? | select(.type == "tool_result")
        | select(.tool_use_id as $u | $ids | index($u))
        | select((.is_error // false) | not)
        | (if (.content | type) == "string" then .content else ([.content[]? | .text? // empty] | join("")) end)
        | select(contains($marker))] | length')
    final=$(events | jq -sc '[.[] | select(.type == "result")] | last // {}')
    attested=false
    [[ -f $work/fixture/attestation && $(<"$work/fixture/attestation") == "$nonce" ]] && attested=true
    final_ok=$(jq -r '(.subtype == "success") and ((.is_error // false) | not)' <<< "$final")
    exact=$(jq -r --arg m "$model" '. == [$m]' <<< "$observed")

    if [[ $tool_exit == 0 && $matched -ge 1 && $attested == true && $final_ok == true ]]; then
        record shell_tools PASS authenticated_fixture_observed
        record native_shell PASS authenticated_fixture_observed
        record portable_shebang PASS authenticated_fixture_observed
        record ripgrep PASS authenticated_fixture_observed
    elif [[ $tool_exit == 124 || $tool_exit == 137 ]]; then
        record shell_tools FAIL timeout
    elif [[ $(jq length <<< "$uses") == 0 ]]; then
        record shell_tools FAIL no_fixture_tool_use
    elif [[ $attested != true ]]; then
        record shell_tools FAIL fixture_not_attested
    else
        record shell_tools FAIL tool_result_or_final_failed
    fi
    if [[ $exact == true ]]; then model_status=PASS model_code=exact_model_verified
    elif [[ $observed == '[]' ]]; then model_status=FAIL model_code=model_not_observed
    else model_status=FAIL model_code=observed_model_differs; fi
    printf '  %-16s %-4s %s (observed %s)\n' "model" "$model_status" "$model_code" "$observed" >&2
    models=$(jq -nc --arg r "$model" --arg s "$model_status" --arg c "$model_code" --argjson o "$observed" \
        '[{requested: $r, status: $s, detail_code: $c, observed: $o}]')
    workflow=$(jq -nc --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson uses "$uses" \
        --argjson matched "$matched" --argjson final "$final" --argjson attested "$attested" \
        --argjson exit "$tool_exit" --argjson ms "$elapsed" --argjson bytes "$(wc -c < "$stream")" \
        --argjson budget "$BUDGET_USD" '{
            generated_at: $at, model_requests: true, live_host_links_changed: false,
            exact_fixture_tool_uses: ($uses | length), matching_successful_tool_results: $matched,
            final_success: (($final.subtype == "success") and (($final.is_error // false) | not)),
            fixture_attestation_matches: $attested, total_cost_usd: ($final.total_cost_usd // null),
            capture: {exit_code: $exit, timeout: ($exit == 124 or $exit == 137), elapsed_ms: $ms, bytes: $bytes},
            maximum_budget_usd: $budget}')
fi

# ---------------------------------------------------------------- rollback
say 'rollback: restore the previous release offline'
if [[ -n $updated ]] && lifecycle rollback; then
    if [[ $(state_field current) == "$installed" ]]; then
        record rollback PASS previous_candidate_restored_offline
    else
        record rollback FAIL previous_not_restored
    fi
elif [[ -n $updated ]]; then
    record rollback FAIL rollback_failed
else
    record rollback SKIP prerequisite_failed
fi

# --------------------------------------------------------------- uninstall
say 'uninstall: remove the disposable installation'
if [[ -n $installed ]] && lifecycle uninstall; then
    leftovers=()
    for path in "$root" "$work/home/.local/bin/termux-muscle" \
        "$work/home/.local/share/bash-completion/completions/termux-muscle"; do
        [[ ! -e $path && ! -L $path ]] || leftovers+=("${path#"$work"/}")
    done
    if ((${#leftovers[@]} == 0)); then
        record uninstall PASS private_owned_root_removed
    else
        record uninstall FAIL owned_files_left
        printf '    left behind: %s\n' "${leftovers[*]}" >&2
    fi
elif [[ -n $installed ]]; then
    record uninstall FAIL uninstall_failed
else
    record uninstall SKIP prerequisite_failed
fi

# -------------------------------------------------------------- live check
fingerprint > "$work/live-after.txt"
live_unchanged=true
if ! diff -u "$work/live-before.txt" "$work/live-after.txt" >> "$log"; then
    live_unchanged=false
fi

# ------------------------------------------------------------------ report
say 'Writing report'
[[ -s $diagnostics ]] || die "no diagnostics report was produced; see $log"
overrides=$(for id in "${!result[@]}"; do
    jq -nc --arg id "$id" --arg s "${result[$id]}" --arg c "${detail[$id]}" \
        '{id: $id, status: $s, detail_code: $c}'
done | jq -sc .)
mkdir -p -- "$(dirname -- "$output")"
jq --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson over "$overrides" --argjson models "$models" \
    --argjson workflow "$workflow" --argjson live "$live_unchanged" --arg notes "$(basename -- "${output%.json}").md" \
    --arg commit "$commit" --argjson dirty "$dirty" '
    # Observed results replace the diagnostic placeholders by ID; checks the
    # diagnostic report does not know about are appended in ID order.
    ([.checks[].id]) as $ids
    | ($over | map({key: .id, value: .}) | from_entries) as $o
    | .checks = ([.checks[] | $o[.id] // .]
                 + ($over | map(select(.id as $i | $ids | index($i) | not)) | sort_by(.id)))
    | .generated_at = $at
    | .provenance = "maintainer"
    | .source = {commit: $commit, uncommitted_changes: $dirty}
    | .models = $models
    | .evidence_notes = $notes
    | .lifecycle_acceptance = {scope: "isolated_native_source_bootstrap_no_link",
        model_requests: false, live_host_links_changed: ($live | not),
        public_release_delivery: "not_exercised"}
    | if $workflow == null then . else .authenticated_workflow = $workflow end' \
    "$diagnostics" > "$output.tmp"
mv -- "$output.tmp" "$output"

# -------------------------------------------------------------- gate preview
# Evaluate the report with the real release gate in a scratch copy, without
# registering it in the checkout's compatibility.json.
preview=$work/gate-preview
mkdir -p -- "$preview"
git -C "$SRC" ls-files -z | (cd "$SRC" && xargs -0 cp --parents -t "$preview" 2>/dev/null) || :
mkdir -p -- "$preview/compatibility"
cp -- "$output" "$preview/compatibility/acceptance.json"
jq --arg d "$(date -u +%Y-%m-%d)" '.verified_on = $d | .reports = ["compatibility/acceptance.json"]' \
    "$SRC/compatibility.json" > "$preview/compatibility.json"
gate=$("$CORE" release-check "$preview" 2>&1) && gate_ok=true || gate_ok=false

# ----------------------------------------------------------------- summary
missing=()
for id in "${REQUIRED[@]}"; do [[ ${result[$id]:-} == PASS ]] || missing+=("$id"); done
printf '\nRequired checks:\n' >&2
for id in "${REQUIRED[@]}"; do printf '  %-16s %s\n' "$id" "${result[$id]:-SKIP}" >&2; done
printf 'Live installation unchanged: %s\n' "$live_unchanged" >&2
printf 'Release-gate preview: %s\n' "$gate" >&2
printf 'Report: %s\nLog: %s\n' "$output" "$log" >&2

if [[ $live_unchanged != true ]]; then
    printf '\nThe live installation CHANGED during acceptance. Review the diff in %s.\n' "$log" >&2
    exit 3
fi
if ((${#missing[@]})); then
    printf '\nNot releasable: %s not PASS.\n' "${missing[*]}" >&2
    exit 1
fi
cat >&2 <<NEXT

All required checks passed. To register this evidence (a reviewed step):
  1. Rename the report to the device-and-date convention, e.g.
     compatibility/galaxy-s26-ultra-$version-$(date -u +%Y%m%d).json, and write its .md notes.
  2. In compatibility.json set "verified_on" to $(date -u +%Y-%m-%d) and add the report to "reports".
  3. If the model check passed and you want to claim it, add the model to models.verified.
  4. Run: build/tm-core release-check .
NEXT
$gate_ok || exit 1
