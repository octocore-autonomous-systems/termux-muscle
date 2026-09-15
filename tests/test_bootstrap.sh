#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -euo pipefail
project=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/muscle-bootstrap-test.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
bash_path=$(command -v bash)
sh_path=$(command -v sh)
mkdir -p "$work/bin" "$work/remote" "$work/tmp space" "$work/com.termux/files/usr/etc/tls" "$work/com.termux/files/usr/bin"
ln -s "$bash_path" "$work/com.termux/files/usr/bin/bash"
printf 'test cert\n' > "$work/com.termux/files/usr/etc/tls/cert.pem"
export MOCK_WORK="$work"
export MOCK_CMP
MOCK_CMP=$(command -v cmp)
mock_bin="$work/bin"
for tool in bash grep awk mktemp rm sha256sum cmp cat mkdir cp chmod gzip tar sleep timeout; do
    ln -s "$(command -v "$tool")" "$mock_bin/$tool"
done
printf '#!%s\n' "$bash_path" > "$work/mock"
cat >> "$work/mock" <<'MOCK'
set -eu
case "${0##*/}" in
    uname) if [[ "$1" == -m ]]; then printf '%s\n' "${MOCK_ARCH:-aarch64}"; else printf '%s\n' "${MOCK_OS:-Linux}"; fi;;
    getprop) printf '%s\n' "${MOCK_SDK-36}";;
    pkg-config)
        if [[ "${MOCK_MISSING_LIBS:-0}" == 1 && ! -f "$MOCK_WORK/pkg.log" ]]; then exit 1; fi;;
    curl)
        output=; url=${!#}; printf '%s\n' "$url" >> "$MOCK_WORK/curl.log"
        while (($#)); do if [[ "$1" == --output ]]; then output=$2; shift 2; else shift; fi; done
        [[ "${MOCK_DOWNLOAD_FAIL:-0}" == 0 ]] || exit 22
        if [[ "${MOCK_WAIT:-0}" == 1 ]]; then touch_marker="$MOCK_WORK/curl.running"; printf 'running\n' > "$touch_marker"; sleep 30; fi
        cp -- "$MOCK_WORK/remote/${url##*/}" "$output";;
    pkg)
        printf '%s\n' "$*" > "$MOCK_WORK/pkg.log"
        [[ "${MOCK_PKG_FAIL:-0}" == 0 ]] || exit 1
        if [[ ${MOCK_MISSING_CMP:-0} == 1 ]]; then cp "$MOCK_CMP" "$MOCK_WORK/bin/cmp"; fi
        if [[ ${MOCK_MISSING_MAN:-0} == 1 ]]; then cp "$MOCK_WORK/mock" "$MOCK_WORK/bin/man"; fi;;
    make)
        source=$2; target=${!#}; printf '%s\n' "$target" >> "$MOCK_WORK/make.log"
        [[ "${MOCK_MAKE_FAIL:-}" != "$target" ]] || exit 47
        mkdir -p "$source/build"
        printf '#!/bin/sh\nexit 0\n' > "$source/build/tm-core"
        chmod +x "$source/build/tm-core";;
    proot|rg|cc|man) :;;
    *) exit 99;;
esac
MOCK
chmod +x "$work/mock"
for tool in uname getprop pkg-config curl pkg make proot rg cc man; do ln -s "$work/mock" "$mock_bin/$tool"; done
fixture="$work/fixture/termux-muscle-0.1.0"
mkdir -p "$fixture/bin" "$fixture/src"
mkdir -p "$fixture/.githooks"
printf 'BasedOnStyle: LLVM\n' > "$fixture/.clang-format"
printf '#!/bin/sh\nexit 99\n' > "$fixture/.githooks/pre-commit"
printf '0.1.0\n' > "$fixture/VERSION"
printf 'all:\n\t@true\ncheck:\n\t@true\n' > "$fixture/Makefile"
printf '/* fixture */\n' > "$fixture/src/main.c"
cat > "$fixture/bin/termux-muscle" <<'CLI'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$MOCK_WORK/cli.args"
exit "${MOCK_CLI_STATUS:-0}"
CLI
chmod +x "$fixture/bin/termux-muscle"
asset=termux-muscle-0.1.0.tar.gz
archive() {
    tar --format=ustar -C "$work/fixture" -czf "$work/remote/$asset" termux-muscle-0.1.0
    (cd "$work/remote" && sha256sum "$asset" > SHA256SUMS)
}
archive
reset_logs() { rm -f "$work/cli.args" "$work/make.log" "$work/curl.log" "$work/pkg.log"; }
run_install() {
    set +e
    env PATH="$mock_bin" PREFIX="$work/com.termux/files/usr" TMPDIR="$work/tmp space" PROOT_TMP_DIR= \
        "$sh_path" "$project/install.sh" --version 0.1.0 "$@" > "$work/output" 2> "$work/error"
    status=$?
    set -e
}
fail() { cat "$work/error" >&2; printf 'FAIL bootstrap: %s\n' "$*" >&2; exit 1; }
clean() { local paths=("$work/tmp space"/*); [[ ! -e "${paths[0]}" ]] || fail 'download scratch was not cleaned'; }
count=0
passed() { ((count += 1)); reset_logs; }

root_arg="$work/root ' \$(unexecuted)"
run_install --root "$root_arg" --prefix "$work/com.termux/files/usr" --no-install --no-link
[[ $status == 0 ]] || fail 'valid source install failed'
mapfile -d '' -t arguments < "$work/cli.args"
[[ ${arguments[0]} == bootstrap && ${arguments[1]} == --source-dir && ${arguments[3]} == --build-dir ]] || fail 'wrong bootstrap interface'
[[ ${arguments[5]} == --root && ${arguments[6]} == "$root_arg" && ${arguments[9]} == --no-install && ${arguments[10]} == --no-link ]] || fail 'literal arguments not preserved'
[[ $(cat "$work/make.log") == $'all\ncheck' && ! -e "$work/pkg.log" ]] || fail 'build/check order or prerequisite handling incorrect'
clean; passed

run_install
[[ $status == 0 ]] || fail 'default installation failed'
mapfile -d '' -t arguments < "$work/cli.args"
[[ ${#arguments[@]} == 5 ]] || fail 'default installation unexpectedly opted out of linking'
clean; passed

rm "$mock_bin/man"
export MOCK_MISSING_MAN=1
run_install
[[ $status == 0 ]] || fail 'missing man viewer was not provisioned'
grep -q mandoc "$work/pkg.log" || fail 'missing man did not request the real Termux mandoc package'
unset MOCK_MISSING_MAN
clean; passed

printf 'unexpected hook\n' > "$fixture/.githooks/post-install"
archive; run_install
[[ $status != 0 && ! -e "$work/make.log" ]] || fail 'unexpected hook archive path accepted'
rm "$fixture/.githooks/post-install"; clean; passed; archive

rm "$mock_bin/cmp"
export MOCK_MISSING_CMP=1
run_install
[[ $status == 0 ]] || fail 'missing cmp was not provisioned'
grep -q diffutils "$work/pkg.log" || fail 'missing cmp did not request diffutils'
unset MOCK_MISSING_CMP
clean; passed

printf '%064d  %s\n' 0 "$asset" > "$work/remote/SHA256SUMS"
run_install
[[ $status != 0 && ! -e "$work/make.log" && ! -e "$work/cli.args" ]] || fail 'bad digest reached build/execution'
grep -q 'checksum verification failed' "$work/error" || fail 'missing integrity diagnostic'
clean; passed; archive

cat "$work/remote/SHA256SUMS" >> "$work/remote/duplicate"
cat "$work/remote/SHA256SUMS" "$work/remote/duplicate" > "$work/remote/SHA256SUMS.new"
mv "$work/remote/SHA256SUMS.new" "$work/remote/SHA256SUMS"
run_install
[[ $status != 0 && ! -e "$work/make.log" ]] || fail 'duplicate checksum accepted'
clean; passed; archive

export MOCK_DOWNLOAD_FAIL=1
run_install
[[ $status != 0 && ! -e "$work/make.log" ]] || fail 'download failure built source'
unset MOCK_DOWNLOAD_FAIL
clean; run_install
[[ $status == 0 ]] || fail 'retry after download failure failed'
clean; passed

for architecture in x86_64 armv7l; do
    export MOCK_ARCH=$architecture
    run_install
    [[ $status != 0 && ! -e "$work/curl.log" && ! -e "$work/pkg.log" ]] || fail 'unsupported ABI reached mutations'
done
unset MOCK_ARCH; passed

export MOCK_MISSING_LIBS=1
run_install
[[ $status == 0 ]] || fail 'missing C libraries were not provisioned'
grep -q 'json-c libarchive openssl' "$work/pkg.log" || fail 'wrong C prerequisites'
passed
export MOCK_PKG_FAIL=1
run_install
[[ $status != 0 && ! -e "$work/curl.log" ]] || fail 'pkg failure reached network'
unset MOCK_PKG_FAIL MOCK_MISSING_LIBS; passed

for target in all check; do
    export MOCK_MAKE_FAIL=$target
    run_install
    [[ $status != 0 && ! -e "$work/cli.args" ]] || fail "$target failure reached publication"
    clean; passed
done
unset MOCK_MAKE_FAIL

ln -s /etc/passwd "$fixture/src/escape"
archive; run_install
[[ $status != 0 && ! -e "$work/make.log" ]] || fail 'archive symlink accepted'
rm "$fixture/src/escape"; clean; passed; archive

# Android may prohibit hardlink(2). Construct a genuine ustar hardlink header
# without requiring a hardlink-capable filesystem.
tar --format=ustar -C "$work/fixture" -cf "$work/hardlink.tar" termux-muscle-0.1.0/src/main.c
head -c 512 "$work/hardlink.tar" > "$work/header"
printf '00000000000\0' | dd of="$work/header" bs=1 seek=124 conv=notrunc status=none
printf '1' | dd of="$work/header" bs=1 seek=156 conv=notrunc status=none
printf 'termux-muscle-0.1.0/src/target.c\0' | dd of="$work/header" bs=1 seek=157 conv=notrunc status=none
printf '        ' | dd of="$work/header" bs=1 seek=148 conv=notrunc status=none
checksum=$(od -An -tu1 "$work/header" | awk '{for(i=1;i<=NF;i++)n+=$i} END{print n}')
printf '%06o\0 ' "$checksum" | dd of="$work/header" bs=1 seek=148 conv=notrunc status=none
cat "$work/header" > "$work/hardlink.tar"
dd if=/dev/zero bs=512 count=2 status=none >> "$work/hardlink.tar"
gzip -n -c "$work/hardlink.tar" > "$work/remote/$asset"
(cd "$work/remote" && sha256sum "$asset" > SHA256SUMS)
run_install
[[ $status != 0 && ! -e "$work/make.log" ]] || fail 'archive hardlink accepted'
grep -q 'links, special entries' "$work/error" || fail 'hardlink fixture was not checked as a link'
clean; passed; archive

tar --format=ustar --transform='s|termux-muscle-0.1.0/src/main.c|termux-muscle-0.1.0/../escape|' -C "$work/fixture" -czf "$work/remote/$asset" termux-muscle-0.1.0
(cd "$work/remote" && sha256sum "$asset" > SHA256SUMS)
run_install
[[ $status != 0 && ! -e "$work/make.log" ]] || fail 'archive traversal accepted'
clean; passed; archive

printf 'bad\n' > "$fixture/src/line"$'\n'"break.c"
archive; run_install
[[ $status != 0 && ! -e "$work/make.log" ]] || fail 'control-character archive name accepted'
rm "$fixture/src/line"$'\n'"break.c"; clean; passed; archive

export MOCK_CLI_STATUS=47
run_install
[[ $status == 47 ]] || fail 'CLI status was not preserved'
unset MOCK_CLI_STATUS; clean; passed

export MOCK_WAIT=1
set +e
env PATH="$mock_bin" PREFIX="$work/com.termux/files/usr" TMPDIR="$work/tmp space" PROOT_TMP_DIR= \
    timeout --signal=TERM --kill-after=2 2 "$sh_path" "$project/install.sh" --version 0.1.0 > "$work/output" 2> "$work/error"
status=$?
set -e
unset MOCK_WAIT
[[ $status != 0 && ! -e "$work/cli.args" ]] || fail 'interrupted download reached publication'
clean; run_install
[[ $status == 0 ]] || fail 'retry after interruption failed'
clean; passed
printf 'PASS: %s bootstrap regressions (shell only)\n' "$count"
