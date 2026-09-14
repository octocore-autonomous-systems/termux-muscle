#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Real C verifier tests with explicitly synthetic reports; no account or network.
set -euo pipefail
repo=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/muscle-release-gate.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
cat > "$work/driver.c" <<'C'
#include "tm.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
int tm_links_main(int argc, char **argv) {(void)argc;(void)argv;return 0;}
int tm_acquire_main(int argc, char **argv) {(void)argc;(void)argv;return 0;}
int tm_tooling_main(int argc, char **argv) {(void)argc;(void)argv;return 0;}
#ifndef OMIT_REPORT
int tm_report_main(int argc, char **argv) {(void)argc;(void)argv;return 0;}
#endif
int main(int argc, char **argv) {
    if (argc >= 4 && !strncmp(argv[1],"fixture-",8)) {
        json_object *object=tm_json_read(argv[2]), *parent=object, *value=NULL;
        char *key=tm_strdup(argv[3]), *save=NULL, *part=strtok_r(key,".",&save);
        while(part) {
            char *next=strtok_r(NULL,".",&save);
            if(!next)break;
            if(json_object_is_type(parent,json_type_array)) parent=json_object_array_get_idx(parent,(size_t)atoi(part));
            else if(!json_object_object_get_ex(parent,part,&parent))return 65;
            part=next;
        }
        if(!strcmp(argv[1],"fixture-get")) {
            if(!json_object_object_get_ex(parent,part,&value))return 65;
            puts(json_object_get_string(value));
        } else if(!strcmp(argv[1],"fixture-delete")) {
            json_object_object_del(parent,part);tm_json_write(argv[2],object);
        } else if(!strcmp(argv[1],"fixture-duplicate")) {
            if(!json_object_object_get_ex(parent,part,&value))return 65;
            json_object_array_add(value,json_object_get(json_object_array_get_idx(value,0)));
            tm_json_write(argv[2],object);
        } else if(argc==5 && !strcmp(argv[1],"fixture-set")) {
            value=json_tokener_parse(argv[4]);
            if(!value && strcmp(argv[4],"null"))return 65;
            if(json_object_is_type(parent,json_type_array))json_object_array_put_idx(parent,(size_t)atoi(part),value);
            else json_object_object_add(parent,part,value);
            tm_json_write(argv[2],object);
        } else return 65;
        json_object_put(object);free(key);return 0;
    }
    return tm_release_main(argc-1,argv+1);
}
C
version=$(cat "$repo/VERSION")
read -r -a cflags <<< "$(pkg-config --cflags json-c libarchive libcrypto)"
read -r -a libs <<< "$(pkg-config --libs json-c libarchive libcrypto)"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I"$repo/src" "-DTM_VERSION=\"$version\"" "${cflags[@]}" \
    "$work/driver.c" "$repo/src/release.c" "$repo/src/common.c" "${libs[@]}" -o "$work/verifier"
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -DOMIT_REPORT -I"$repo/src" "-DTM_VERSION=\"$version\"" "${cflags[@]}" \
    "$work/driver.c" "$repo/src/release.c" "$repo/src/common.c" "${libs[@]}" -o "$work/incomplete"
source="$work/source"
mkdir -p "$source/compatibility" "$source/src" "$source/bin" "$source/tests" "$source/lib"
for file in LICENSE CREDITS.md README.md CONTRIBUTING.md Makefile; do printf 'fixture source\n' > "$source/$file"; done
for file in main state runtime release tooling; do printf '/* fixture source */\n' > "$source/src/$file.c"; done
for file in tooling acquire diagnostics; do printf '# fixture hook\n' > "$source/lib/$file.sh"; done
printf '# fixture CLI\n' > "$source/bin/termux-muscle"
printf '# fixture tests\n' > "$source/tests/run.sh"
printf '%s\n' "$version" > "$source/VERSION"
printf '#!/bin/sh\nVERSION="%s"\n' "$version" > "$source/install.sh"
printf '# Changes\n\n## %s\n\nFixture release.\n' "$version" > "$source/CHANGELOG.md"
cp "$repo/compatibility.json" "$source/compatibility.json"
manifest="$source/compatibility.json"
report="$source/compatibility/device.json"
date=$("$work/verifier" fixture-get "$manifest" models.checked_documentation_on)
claude=$("$work/verifier" fixture-get "$manifest" claude.version)
musl=$("$work/verifier" fixture-get "$manifest" musl.version)
set_json() { "$work/verifier" fixture-set "$1" "$2" "$3"; }
set_json "$manifest" verified_on "\"$date\""
set_json "$manifest" reports '["compatibility/device.json"]'
set_json "$manifest" models.verified '[]'
cat > "$report" <<JSON
{
  "schema":1,"generated_at":"${date}T12:00:00Z","project":{"name":"Termux Muscle","version":"$version"},
  "claude_code":{"version":"$claude","musl_version":"$musl"},"provenance":"maintainer",
  "environment":{"manufacturer":"Fixture","model":"Synthetic device","android_version":"16","android_api":36,"abi":"aarch64","kernel":"fixture-6.1","page_size":4096,"termux_version":"0.118.3","termux_source":"GitHub",
    "packages":{"bash":"fixture-1","coreutils":"fixture-1","curl":"fixture-1","ca-certificates":"fixture-1","proot":"fixture-1","ripgrep":"fixture-1","clang":"fixture-1","make":"fixture-1","pkg-config":"fixture-1","json-c":"fixture-1","libarchive":"fixture-1","openssl":"fixture-1"}},
  "checks":[{"id":"install","status":"PASS"},{"id":"startup_version","status":"PASS"},{"id":"startup_help","status":"PASS"},{"id":"shell_tools","status":"PASS"},{"id":"update","status":"PASS"},{"id":"rollback","status":"PASS"},{"id":"uninstall","status":"PASS"}],
  "models":[]
}
JSON
cp "$manifest" "$work/baseline-manifest.json"
cp "$report" "$work/baseline-report.json"
count=0
fail() { cat "$work/error" >&2; printf 'FAIL release gate: %s\n' "$*" >&2; exit 1; }
check() {
    set +e
    "$work/verifier" release-check "$source" > "$work/output" 2> "$work/error"
    status=$?
    set -e
}
reset() { cp "$work/baseline-manifest.json" "$manifest"; cp "$work/baseline-report.json" "$report"; }
reject() { check; [[ $status != 0 ]] || fail "$1"; ((count+=1)); reset; }
check; [[ $status == 0 ]] || fail 'valid synthetic evidence rejected'; ((count+=1))

for id in 0 1 2 3 4 5 6; do
    set_json "$report" "checks.$id.status" '"SKIP"'; reject "required skipped check $id accepted"
done
set_json "$report" checks '[]'; reject 'missing lifecycle evidence accepted'
set_json "$report" checks.0.status '"MAYBE"'; reject 'unknown check status accepted'
"$work/verifier" fixture-duplicate "$report" checks; reject 'duplicate check IDs accepted'
set_json "$report" provenance '"community"'; reject 'community report promoted to maintainer'
set_json "$report" provenance '"unknown"'; reject 'unknown provenance accepted'
set_json "$report" project.version '"999.0.0"'; reject 'stale project evidence accepted'
set_json "$report" claude_code.version '"2.1.112"'; reject 'stale Claude evidence accepted'
set_json "$report" claude_code.musl_version '"1.0.0-r0"'; reject 'stale loader evidence accepted'
set_json "$report" generated_at '"2026-02-30T12:00:00Z"'; reject 'impossible report date accepted'
set_json "$report" generated_at '"2099-01-01T12:00:00Z"'; reject 'future report accepted'
set_json "$manifest" verified_on 'null'; reject 'undated release accepted'
"$work/verifier" fixture-delete "$report" environment.termux_version; reject 'missing Termux version accepted'
set_json "$report" environment.packages.clang '"unknown"'; reject 'unknown compiler version accepted'
"$work/verifier" fixture-delete "$report" environment.packages.libarchive; reject 'missing runtime library version accepted'
set_json "$report" environment.page_size '1234'; reject 'invalid page size accepted'
set_json "$report" environment.abi '"x86_64"'; reject 'unsupported device ABI accepted'
set_json "$manifest" reports '["compatibility/device.json","compatibility/device.json"]'; reject 'duplicate report references accepted'
set_json "$manifest" reports '["../external.json"]'; reject 'report traversal accepted'
cp "$report" "$work/external.json"
rm "$report"; ln -s "$work/external.json" "$report"
check; [[ $status != 0 ]] || fail 'symlink report accepted'; rm "$report"; reset; ((count+=1))
set_json "$manifest" claude.package '"@someone/claude-code"'; reject 'unofficial package accepted'
set_json "$manifest" claude.integrity '"sha512-invalid"'; reject 'malformed package integrity accepted'
set_json "$manifest" musl.url '"https://attacker.example/musl.apk"'; reject 'unofficial loader accepted'
set_json "$manifest" models.source '"https://code.claude.com.attacker.example/docs"'; reject 'lookalike model source accepted'
"$work/verifier" fixture-duplicate "$manifest" models.documented; reject 'duplicate documented models accepted'
set_json "$manifest" models.documented '[]'; reject 'absent documented models accepted'
set_json "$manifest" models.documented.0.minimum_claude_version '"999.0.0"'; reject 'model requiring a newer client accepted'
set_json "$manifest" models.verified '["claude-fable-5-1"]'; reject 'model claim without evidence accepted'
set_json "$manifest" models.verified '["claude-fable-5-1"]'
set_json "$report" models '[{"requested":"claude-fable-5-1","observed":["claude-opus-5"],"status":"PASS"}]'
reject 'model fallback accepted as requested-model success'
set_json "$manifest" models.verified '["claude-fable-5-1"]'
set_json "$report" models '[{"requested":"claude-fable-5-1","observed":["claude-fable-5-1"],"status":"PASS"}]'
check; [[ $status == 0 ]] || fail 'exact observed-model evidence rejected'; ((count+=1))
set_json "$manifest" models.verified '[{"requested":"claude-fable-5-1","status":"SKIP"}]'
reject 'conflicting failed/skipped verified-model status accepted'
set_json "$manifest" models.verified '["claude-fable-5-1"]'
set_json "$report" models '[{"requested":"claude-fable-5-1","observed":["claude-fable-5-1"],"status":"PASS"}]'
"$work/verifier" fixture-duplicate "$report" models; reject 'duplicate model results accepted'

set +e
"$work/incomplete" release-check "$source" > "$work/output" 2> "$work/error"
status=$?
set -e
[[ $status != 0 ]] || fail 'missing mandatory module passed release gate'
grep -q 'commands are missing' "$work/error" || fail 'missing-module failure had wrong cause'
((count+=1))

set_json "$manifest" verified_on 'null'
set_json "$manifest" reports '[]'
"$work/verifier" release-notes "$source" > "$work/notes" 2> "$work/error" || fail 'draft notes failed'
grep -q 'No device acceptance is asserted' "$work/notes" || fail 'draft notes claimed acceptance'
grep -q 'No authenticated model checks' "$work/notes" || fail 'draft notes claimed model verification'
# shellcheck disable=SC2016 # Deliberately hostile literal input must not execute.
set_json "$manifest" models.documented.0.name '"Fable | <script> $(touch NEVER)"'
"$work/verifier" release-notes "$source" > "$work/notes" 2> "$work/error" || fail 'escaped note generation failed'
grep -Fq '&lt;script&gt;' "$work/notes" || fail 'HTML was not escaped'
grep -Fq '\|' "$work/notes" || fail 'table syntax was not escaped'
[[ ! -e "$source/NEVER" ]] || fail 'metadata was executed'
((count+=1))
printf 'PASS: %s C release-evidence regressions\n' "$count"
