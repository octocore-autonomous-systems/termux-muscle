#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Maintainer release helper: validate Claude Code X on the live device from a NATIVE shell.
#
#   bash scripts/release_validate.sh X OUT_DIR
#
# Installs X through the unverified-version path (skipped when X is already active), runs doctor
# and one authenticated Opus 5.5 test, then proves the cached npm archive and the extracted
# executable match the registry and the install receipt. Writes update-X.log, doctor-X.txt,
# live-test.log, live-test-X.json, npm-dist-X.json and integrity-X.txt into OUT_DIR, and ends by
# printing the INTEGRITY and BINARY_SHA256 values that scripts/release_prepare.py takes. Exits non-zero on the
# first failure: if it does, stop and report; do no release work.
set -euo pipefail
X=$1; OUT=$2; MODEL=${3:-claude-opus-5-5}
grep -q '^TracerPid:[[:space:]]*0$' /proc/self/status || { echo "run this in a native, untraced Termux shell" >&2; exit 1; }
mkdir -p "$OUT"
TM=$HOME/.local/share/termux-muscle

if termux-muscle --version | grep -qx "Claude Code $X (active)"; then
  echo "Claude Code $X was already active; update skipped" > "$OUT/update-$X.log"
else
  termux-muscle update --claude-version "$X" --allow-unverified > "$OUT/update-$X.log" 2>&1
fi
termux-muscle doctor > "$OUT/doctor-$X.txt" 2>&1
pass=$(grep -c '"status":"PASS"' "$OUT/doctor-$X.txt" || true); fail=$(grep -c '"status":"FAIL"' "$OUT/doctor-$X.txt" || true)
[ "$pass" = 7 ] && [ "$fail" = 0 ] || { echo "doctor: $pass PASS, $fail FAIL (want 7 and 0)" >&2; exit 1; }

T=$PREFIX/tmp/tm-live-test-$X.$$.json   # termux-muscle test refuses an existing output file
termux-muscle test --model "$MODEL" --output "$T" > "$OUT/live-test.log" 2>&1
mv "$T" "$OUT/live-test-$X.json"
python3 - "$OUT/live-test-$X.json" "$X" "$MODEL" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["claude_code"]["version"] == sys.argv[2], "test ran on another Claude Code version"
assert not [c for c in d["checks"] if c["status"] == "FAIL"], "a live check failed"
m = d["models"]
assert len(m) == 1 and m[0]["requested"] == sys.argv[3] and m[0]["detail_code"] == "exact_model_verified", m
PY

npm view "@anthropic-ai/claude-code-linux-arm64-musl@$X" dist --json > "$OUT/npm-dist-$X.json"
INTEGRITY=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["integrity"])' "$OUT/npm-dist-$X.json")
HEX=$(printf '%s' "${INTEGRITY#sha512-}" | base64 -d | xxd -p | tr -d '\n')
ARCHIVE=$TM/cache/sha512-$HEX.archive
[ "$(sha512sum "$ARCHIVE" | cut -d' ' -f1)" = "$HEX" ] || { echo "cached archive does not match the npm integrity" >&2; exit 1; }
S=$(mktemp -d "$PREFIX/tmp/tm-validate.XXXXXX"); trap 'rm -rf "$S"' EXIT
tar -xzf "$ARCHIVE" -C "$S" package/claude
BIN=$(sha256sum "$S/package/claude" | cut -d' ' -f1)
RECEIPT=$(grep -l "\"binary_sha256\":\"$BIN\"" "$TM"/releases/"$X"-*/payload.json | head -1)
[ -n "$RECEIPT" ] || { echo "no install receipt for $X records binary_sha256 $BIN" >&2; exit 1; }
{ echo "npm integrity: $INTEGRITY"; echo "npm integrity hex: $HEX"; echo "cached archive: $ARCHIVE (sha512 matches)"
  echo "package/claude sha256: $BIN"; echo "receipt: $RECEIPT (nested binary_sha256 matches)"; } > "$OUT/integrity-$X.txt"
echo "VALIDATION PASS: Claude Code $X, doctor 7 PASS, $MODEL exact, archive and executable match"
echo "INTEGRITY=$INTEGRITY"
echo "BINARY_SHA256=$BIN"
