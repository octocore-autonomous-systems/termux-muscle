#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Maintainer release helper: verify the published release P from a NATIVE shell.
#
#   bash scripts/release_public_verify.sh P LOCAL_SHA256SUMS OUT_DIR
#
# Downloads the five public assets, checks them against SHA256SUMS and against the local
# build's SHA256SUMS, then runs the real public installer in a disposable root with HOME and
# XDG_DATA_HOME redirected, and proves the live installation was not touched. Writes
# asset-verification.txt, public-install.log and live-fingerprint-{before,after}-public-install.txt
# into OUT_DIR. Exits non-zero on the first failure.
set -euo pipefail
P=$1; LOCAL=$2; OUT=$3
grep -q '^TracerPid:[[:space:]]*0$' /proc/self/status || { echo "run this in a native, untraced Termux shell" >&2; exit 1; }
URL=https://github.com/octocore-autonomous-systems/termux-muscle/releases/download/v$P
REAL_HOME=$HOME
W=$REAL_HOME/.cache/tm-public-$P
rm -rf "$W"; mkdir -p "$W/assets" "$W/home" "$OUT"

fingerprint() {
  cd "$REAL_HOME"
  for l in .local/bin/termux-muscle .local/bin/claude; do printf '%s -> %s\n' "$l" "$(readlink "$l")"; done
  sha256sum .local/share/termux-muscle/bin/* .local/share/termux-muscle/installation.json \
    .local/share/termux-muscle/links.json .local/share/termux-muscle/state.json \
    .local/share/termux-muscle/tooling.json "$PREFIX/share/man/man1/termux-muscle.1" \
    .local/share/bash-completion/completions/termux-muscle
}

cd "$W/assets"
for f in SHA256SUMS termux-muscle-$P.tar.gz install.sh compatibility.json RELEASE_NOTES.md; do curl -fsSL -o "$f" "$URL/$f"; done
{ sha256sum RELEASE_NOTES.md SHA256SUMS compatibility.json install.sh termux-muscle-$P.tar.gz
  sha256sum -c SHA256SUMS
  cmp SHA256SUMS "$LOCAL" && echo "SHA256SUMS identical to local build"; } > "$OUT/asset-verification.txt" 2>&1

fingerprint > "$OUT/live-fingerprint-before-public-install.txt"
( export HOME=$W/home XDG_DATA_HOME=$W/home/.local/share
  set -x
  curl -fsSL "$URL/install.sh" | sh -s -- --root "$W/root" --no-link
  "$W/root/bin/termux-muscle" --root "$W/root" --version
  "$W/root/bin/termux-muscle" --root "$W/root" versions
  "$W/root/bin/termux-muscle" --root "$W/root" doctor
  "$W/root/bin/termux-muscle" --root "$W/root" uninstall
  test ! -e "$W/root"
) > "$OUT/public-install.log" 2>&1
fingerprint > "$OUT/live-fingerprint-after-public-install.txt"
cmp "$OUT/live-fingerprint-before-public-install.txt" "$OUT/live-fingerprint-after-public-install.txt"
rm -rf "$W"
echo "PUBLIC VERIFICATION PASS: v$P assets match the local build; public installer passed; live installation unchanged"
