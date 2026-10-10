# SPDX-License-Identifier: MPL-2.0
# Source this file from Bash. TM_CORE is the absolute path to our built helper.
# Each operation uses a subshell so its strict mode and cleanup trap are local.

tm_acquire_download() (
    set -euo pipefail
    [[ $# == 3 ]] || { printf '%s\n' 'termux-muscle: invalid_arguments: download needs URL, output and limit.' >&2; exit 1; }
    local tm_url=$1 tm_output=$2 tm_limit=$3 tm_http
    # -q must be curl's first option: an unrelated .curlrc must not enable
    # redirects, disable verification, or select another output file.
    tm_http=$(curl -q --fail --silent --show-error --proto '=https' \
        --connect-timeout 15 --max-time 180 --max-filesize "$tm_limit" \
        --output "$tm_output" --write-out '%{http_code}' -- "$tm_url") || {
        printf '%s\n' 'termux-muscle: download_failed: Official source download failed; existing runtime was preserved.' >&2
        exit 1
    }
    [[ $tm_http == 200 ]] || {
        printf '%s\n' 'termux-muscle: download_failed: Official source did not return HTTP 200; redirects are not followed.' >&2
        exit 1
    }
)

tm_acquire_plan() (
    set -euo pipefail
    [[ $# == 5 ]] || { printf '%s\n' 'termux-muscle: invalid_arguments: plan needs manifest, selector, policy, offline and output.' >&2; exit 1; }
    local tm_manifest=$1 tm_selector=$2 tm_policy=$3 tm_offline=$4 tm_output=$5
    local tm_plan_work tm_status tm_url
    : "${TM_CORE:?Set TM_CORE to the built native helper.}"
    [[ $TM_CORE == /* && -x $TM_CORE ]] || { printf '%s\n' 'termux-muscle: helper_missing: TM_CORE must be an absolute executable path.' >&2; exit 1; }
    case $tm_offline in true|false|0|1) ;; *) printf '%s\n' 'termux-muscle: invalid_arguments: offline must be true or false.' >&2; exit 1 ;; esac
    [[ ! -e $tm_output && ! -L $tm_output ]] || { printf '%s\n' 'termux-muscle: unsafe_path: Plan output must be a new file.' >&2; exit 1; }
    tm_plan_work=$(mktemp -d "${TMPDIR:-/tmp}/termux-muscle-plan.XXXXXXXX") || exit 1
    trap 'rm -rf -- "$tm_plan_work"' EXIT
    "$TM_CORE" acquire-plan "$tm_manifest" "$tm_selector" "$tm_policy" > "$tm_plan_work/plan.json" || exit 1
    tm_status=$("$TM_CORE" acquire-field "$tm_plan_work/plan.json" status) || exit 1
    if [[ $tm_status == metadata_required ]]; then
        if [[ $tm_offline == true || $tm_offline == 1 ]]; then
            printf '%s\n' 'termux-muscle: offline_unavailable: Resolving another release requires the official registry; offline repair needs its saved receipt.' >&2
            exit 1
        fi
        tm_url=$("$TM_CORE" acquire-field "$tm_plan_work/plan.json" metadata-url) || exit 1
        tm_acquire_download "$tm_url" "$tm_plan_work/metadata.json" 1048576 || exit 1
        if [[ $tm_policy == signed ]]; then
            # Anthropic's signed manifest names the executable's SHA-256. The
            # helper verifies the signature before it reads that digest.
            tm_url=$("$TM_CORE" acquire-field "$tm_plan_work/plan.json" manifest-url) || exit 1
            tm_acquire_download "$tm_url" "$tm_plan_work/manifest.json" 1048576 || exit 1
            tm_url=$("$TM_CORE" acquire-field "$tm_plan_work/plan.json" signature-url) || exit 1
            tm_acquire_download "$tm_url" "$tm_plan_work/manifest.json.sig" 65536 || exit 1
            "$TM_CORE" acquire-plan "$tm_manifest" "$tm_selector" "$tm_policy" "$tm_plan_work/metadata.json" \
                "$tm_plan_work/manifest.json" "$tm_plan_work/manifest.json.sig" > "$tm_plan_work/resolved.json" || exit 1
        else
            "$TM_CORE" acquire-plan "$tm_manifest" "$tm_selector" "$tm_policy" "$tm_plan_work/metadata.json" > "$tm_plan_work/resolved.json" || exit 1
        fi
        mv -fT -- "$tm_plan_work/resolved.json" "$tm_plan_work/plan.json" || exit 1
    fi
    [[ $("$TM_CORE" acquire-field "$tm_plan_work/plan.json" status) == ready ]] || exit 1
    # noclobber rejects an output file created between the check and this write.
    (umask 077; set -o noclobber; cat -- "$tm_plan_work/plan.json" > "$tm_output")
)

# Print the exact version a release channel names. The channel file is a bare
# version string; it selects a version and authenticates nothing.
tm_channel_version() (
    set -euo pipefail
    [[ $# == 1 ]] || { printf '%s\n' 'termux-muscle: invalid_arguments: channel lookup needs one channel.' >&2; exit 1; }
    local tm_url tm_channel_work tm_version=''
    tm_url=$("$TM_CORE" acquire-channel "$1") || exit 1
    tm_channel_work=$(mktemp -d "${TMPDIR:-/tmp}/termux-muscle-channel.XXXXXXXX") || exit 1
    trap 'rm -rf -- "$tm_channel_work"' EXIT
    tm_acquire_download "$tm_url" "$tm_channel_work/version" 64 || exit 1
    IFS= read -r tm_version < "$tm_channel_work/version" || [[ -n $tm_version ]] || :
    "$TM_CORE" version-check "$tm_version" 2>/dev/null || {
        printf '%s\n' 'termux-muscle: invalid_channel: The release channel did not name an exact X.Y.Z version.' >&2
        exit 1
    }
    printf '%s\n' "$tm_version"
)

tm_acquire() (
    set -euo pipefail
    [[ $# == 6 ]] || { printf '%s\n' 'termux-muscle: invalid_arguments: acquisition needs release, cache, manifest, selector, policy and offline.' >&2; exit 1; }
    local tm_release=$1 tm_cache=$2 tm_manifest=$3 tm_selector=$4 tm_policy=$5 tm_offline=$6
    local tm_work tm_kind tm_key tm_url tm_limit tm_archive tm_temporary
    local tm_npm='' tm_musl=''
    [[ -d $tm_release && ! -L $tm_release ]] || { printf '%s\n' 'termux-muscle: unsafe_path: Use a prepared private candidate directory.' >&2; exit 1; }
    [[ ! -L $tm_cache ]] || { printf '%s\n' 'termux-muscle: unsafe_path: The cache must not be a symbolic link.' >&2; exit 1; }
    mkdir -p -- "$tm_cache" || exit 1
    tm_work=$(mktemp -d "$tm_cache/.acquire.XXXXXXXX") || exit 1
    trap 'rm -rf -- "$tm_work"' EXIT
    tm_acquire_plan "$tm_manifest" "$tm_selector" "$tm_policy" "$tm_offline" "$tm_work/plan.json" || exit 1
    for tm_kind in claude musl; do
        tm_key=$("$TM_CORE" acquire-field "$tm_work/plan.json" "$tm_kind-cache") || exit 1
        tm_url=$("$TM_CORE" acquire-field "$tm_work/plan.json" "$tm_kind-url") || exit 1
        tm_limit=$("$TM_CORE" acquire-field "$tm_work/plan.json" "$tm_kind-max") || exit 1
        tm_archive=$tm_cache/$tm_key
        [[ ! -L $tm_archive && ( ! -e $tm_archive || -f $tm_archive ) ]] || {
            printf '%s\n' 'termux-muscle: unsafe_path: A source cache entry is not an ordinary file.' >&2; exit 1
        }
        if [[ ! -f $tm_archive ]] || ! "$TM_CORE" acquire-verify "$tm_work/plan.json" "$tm_kind" "$tm_archive" 2>/dev/null; then
            if [[ $tm_offline == true || $tm_offline == 1 ]]; then
                printf '%s\n' 'termux-muscle: offline_unavailable: A verified source archive is missing or damaged; reconnect to repair the cache.' >&2
                exit 1
            fi
            tm_temporary=$tm_work/$tm_kind.download
            tm_acquire_download "$tm_url" "$tm_temporary" "$tm_limit" || exit 1
            "$TM_CORE" acquire-verify "$tm_work/plan.json" "$tm_kind" "$tm_temporary" || exit 1
            mv -fT -- "$tm_temporary" "$tm_archive" || exit 1
        fi
        if [[ $tm_kind == claude ]]; then tm_npm=$tm_archive; else tm_musl=$tm_archive; fi
    done
    "$TM_CORE" acquire-extract "$tm_work/plan.json" "$tm_npm" "$tm_musl" "$tm_release"
)

# Read-only listing for versions --available: one registry document, parsed and
# labelled by the helper. Nothing is cached, verified for install or activated.
tm_available_versions() (
    set -euo pipefail
    [[ $# == 2 ]] || { printf '%s\n' 'termux-muscle: invalid_arguments: listing needs all and json flags.' >&2; exit 1; }
    local tm_all=$1 tm_json=$2 tm_work tm_http tm_limit=10 tm_format=text
    [[ $tm_all == false ]] || tm_limit=all
    [[ $tm_json == false ]] || tm_format=json
    tm_work=$(mktemp -d "${TMPDIR:-/tmp}/termux-muscle-available.XXXXXXXX") || exit 1
    trap 'rm -rf -- "$tm_work"' EXIT
    # -q must be curl's first option: an unrelated .curlrc must not enable
    # redirects, disable verification, or select another output file.
    tm_http=$(curl -q --fail --silent --show-error --proto '=https' \
        --connect-timeout 15 --max-time 60 --max-filesize 16777216 \
        --output "$tm_work/metadata.json" --write-out '%{http_code}' -- \
        'https://registry.npmjs.org/@anthropic-ai%2fclaude-code-linux-arm64-musl') || {
        printf '%s\n' 'termux-muscle: registry_unavailable: Cannot read the official npm registry; check the network and retry.' >&2
        exit 1
    }
    [[ $tm_http == 200 ]] || {
        printf '%s\n' 'termux-muscle: registry_unavailable: The official npm registry did not return HTTP 200; redirects are not followed.' >&2
        exit 1
    }
    "$TM_CORE" acquire-available "$TM_SOURCE/compatibility.json" "$tm_work/metadata.json" \
        "$TM_ROOT" "$tm_limit" "$tm_format"
)
