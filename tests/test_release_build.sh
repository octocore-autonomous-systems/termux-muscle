#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Packaging boundary tests; structured evidence validation belongs to tm-core tests.
set -euo pipefail
project=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/muscle-release-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
source="$work/source"
mkdir -p "$source/src" "$source/bin" "$source/lib" "$source/tests" "$source/scripts" "$source/docs"
mkdir -p "$source/.githooks"
printf 'BasedOnStyle: LLVM\n' > "$source/.clang-format"
printf '#!/bin/sh\nexit 0\n' > "$source/.githooks/pre-commit"
cp "$project/install.sh" "$source/install.sh"
cp "$project/compatibility.json" "$source/compatibility.json"
printf '0.1.0\n' > "$source/VERSION"
printf 'fixture license\n' > "$source/LICENSE"
printf 'fixture credits\n' > "$source/CREDITS.md"
printf 'fixture documentation\n' > "$source/README.md"
printf '/* fixture source */\n' > "$source/src/example.c"
printf '#!/usr/bin/env bash\nexit 0\n' > "$source/bin/termux-muscle"
printf '# shell fixture\n' > "$source/lib/fixture.sh"
printf '#!%s\n' "$(command -v bash)" > "$source/tests/mock-core.sh"
cat >> "$source/tests/mock-core.sh" <<'CORE'
case "$1" in
    release-check) [[ -f "$2/compatibility/approved.json" ]] || { printf 'release evidence missing\n' >&2; exit 42; };;
    release-notes) printf '# Termux Muscle 0.1.0\n\nClaude Code: 2.1.270. Fixture release notes.\n';;
    *) exit 99;;
esac
CORE
cat > "$source/Makefile" <<'MAKE'
all:
	@mkdir -p build
	@cp tests/mock-core.sh build/tm-core
	@chmod +x build/tm-core
MAKE
count=0
fail() { cat "$work/error" >&2; printf 'FAIL release: %s\n' "$*" >&2; exit 1; }
run_build() {
    set +e
    bash "$project/scripts/build_release.sh" --root "$source" --output "$work/dist" "$@" > "$work/output" 2> "$work/error"
    status=$?
    set -e
}
passed() { ((count += 1)); }
run_build
[[ $status == 0 ]] || fail 'development build failed'
asset=termux-muscle-0.1.0.tar.gz
(cd "$work/dist" && sha256sum -c SHA256SUMS >/dev/null) || fail 'published hashes are invalid'
grep -q 'Development build' "$work/dist/RELEASE_NOTES.md" || fail 'development build claimed verification'
tar -tzf "$work/dist/$asset" > "$work/names"
grep -q 'src/example.c' "$work/names" || fail 'source omitted'
grep -q 'LICENSE' "$work/names" || fail 'license omitted'
grep -q '/.clang-format$' "$work/names" || fail 'formatter configuration omitted'
grep -q '/.githooks/pre-commit$' "$work/names" || fail 'contributor hook omitted'
tar -tvzf "$work/dist/$asset" > "$work/modes"
grep -Eq '^-rwxr-xr-x .*[/]\.githooks/pre-commit$' "$work/modes" || fail 'contributor hook is not executable'
if grep -Eq '/build/|\.pyz$|\.py$|tm-core$' "$work/names"; then fail 'archive included compiler output or Python'; fi
passed

printf '# unapproved hook\n' > "$source/.githooks/other.sh"
run_build
[[ $status != 0 ]] || fail 'unexpected contributor hook accepted'
grep -q 'unexpected contributor hook' "$work/error" || fail 'wrong unexpected hook diagnostic'
rm "$source/.githooks/other.sh"
passed

first=$(sha256sum "$work/dist/$asset")
touch -t 200101010101 "$source/src/example.c" "$source/lib/fixture.sh"
chmod 600 "$source/lib/fixture.sh"
run_build
[[ $status == 0 && $(sha256sum "$work/dist/$asset") == "$first" ]] || fail 'source archive is not deterministic'
passed

mkdir -p "$source/compatibility/reports/empty" "$source/docs/local-empty"
run_build
[[ $status == 0 && $(sha256sum "$work/dist/$asset") == "$first" ]] || fail 'untracked empty directories changed source archive'
passed

rm -rf "$work/dist"
run_build --release
[[ $status != 0 && ! -e "$work/dist" ]] || fail 'failed release gate created artifacts'
grep -q 'release evidence missing' "$work/error" || fail 'release gate was bypassed'
passed
mkdir -p "$source/compatibility"
printf '{"fixture":true}\n' > "$source/compatibility/approved.json"
run_build --release
[[ $status == 0 ]] || fail 'accepted release gate failed'
if grep -q 'Development build' "$work/dist/RELEASE_NOTES.md"; then fail 'accepted release incorrectly marked development'; fi
passed

printf '0.2.0\n' > "$source/VERSION"
run_build
[[ $status != 0 ]] || fail 'installer/source version mismatch accepted'
grep -q 'VERSION does not match' "$work/error" || fail 'wrong mismatch diagnostic'
printf '0.1.0\n' > "$source/VERSION"
passed

for file in LICENSE CREDITS.md; do
    mv "$source/$file" "$work/saved"
    run_build
    [[ $status != 0 ]] || fail "missing $file accepted"
    mv "$work/saved" "$source/$file"
done
passed

printf 'not a distributable vendor binary\n' > "$source/src/vendor.so"
run_build
[[ $status != 0 ]] || fail 'unexpected binary source accepted'
rm "$source/src/vendor.so"
passed

ln -s /etc/passwd "$source/src/secret.c"
run_build
[[ $status != 0 ]] || fail 'source symlink accepted'
rm "$source/src/secret.c"
printf 'bad filename\n' > "$source/src/line"$'\n'"break.c"
run_build
[[ $status != 0 ]] || fail 'control character source filename accepted'
rm "$source/src/line"$'\n'"break.c"
passed

printf 'outside sentinel\n' > "$work/sentinel"
rm "$work/dist/$asset"
ln -s "$work/sentinel" "$work/dist/$asset"
run_build
[[ $status != 0 && $(cat "$work/sentinel") == 'outside sentinel' ]] || fail 'output symlink overwrote unrelated data'
passed
make_source="$work/make source"
mkdir -p "$make_source/src" "$make_source/bin" "$make_source/lib" "$make_source/docs"
cp "$project/Makefile" "$make_source/Makefile"
for file in VERSION compatibility.json LICENSE CREDITS.md README.md; do cp "$source/$file" "$make_source/$file"; done
printf 'fixture contribution guide\n' > "$make_source/CONTRIBUTING.md"
printf '/* empty fixture header */\n' > "$make_source/src/tm.h"
printf 'int main(void) { return 0; }\n' > "$make_source/src/main.c"
cp "$source/bin/termux-muscle" "$make_source/bin/termux-muscle"
cp "$source/lib/fixture.sh" "$make_source/lib/fixture.sh"
destination="$work/stage ' literal \$(unexecuted)"
make -C "$make_source" stage "DESTDIR=$destination" > "$work/output" 2> "$work/error" || fail 'make staging failed with literal path'
[[ -x "$destination/libexec/tm-core" && -f "$destination/bin/termux-muscle" ]] || fail 'make expanded literal destination characters'
set +e
make -C "$make_source" stage "DESTDIR=$destination" > "$work/output" 2> "$work/error"
status=$?
set -e
[[ $status != 0 && -x "$destination/libexec/tm-core" ]] || fail 'make stage accepted a nonempty destination'
passed
printf 'PASS: %s source release regressions (shell only)\n' "$count"
