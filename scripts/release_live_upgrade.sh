#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Maintainer release helper: move the live device onto published release P (NATIVE shell).
#
#   bash scripts/release_live_upgrade.sh P X OUT_DIR
#
# self-update to P, confirm a second self-update reports already_current (exit 2), re-register X
# as the project pin when it still carries its pre-pin "unverified" label (rollback + offline
# update), then record versions and doctor. Safe to re-run. Writes self-update.log,
# self-update-after-publication.log, live-versions-before-repin.txt, live-repin.log,
# live-versions.txt, live-device.json and live-available.json into OUT_DIR.
set -euo pipefail
P=$1; X=$2; OUT=$3
grep -q '^TracerPid:[[:space:]]*0$' /proc/self/status || { echo "run this in a native, untraced Termux shell" >&2; exit 1; }
mkdir -p "$OUT"

rc=0; termux-muscle self-update > "$OUT/self-update.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 2 ] || { echo "self-update failed (exit $rc)" >&2; exit 1; }
rc=0; termux-muscle self-update > "$OUT/self-update-after-publication.log" 2>&1 || rc=$?
[ "$rc" = 2 ] && grep -q already_current "$OUT/self-update-after-publication.log" || { echo "second self-update did not report already_current (exit $rc)" >&2; exit 1; }

termux-muscle versions > "$OUT/live-versions-before-repin.txt"
if grep -Eq "^Current +$X +unverified" "$OUT/live-versions-before-repin.txt"; then
  { termux-muscle rollback && termux-muscle update --offline; } > "$OUT/live-repin.log" 2>&1
else
  echo "Claude Code $X was not labelled unverified; re-pin skipped" > "$OUT/live-repin.log"
fi
{ termux-muscle --version; termux-muscle versions; claude --version; } > "$OUT/live-versions.txt" 2>&1
grep -qx "Termux Muscle $P" "$OUT/live-versions.txt" && grep -Eq "^Current +$X +pinned" "$OUT/live-versions.txt" \
  && grep -qx "$X (Claude Code)" "$OUT/live-versions.txt" || { cat "$OUT/live-versions.txt" >&2; echo "device is not on $P with $X pinned" >&2; exit 1; }
termux-muscle doctor > "$OUT/live-device.json" 2>&1
pass=$(grep -c '"status":"PASS"' "$OUT/live-device.json" || true); fail=$(grep -c '"status":"FAIL"' "$OUT/live-device.json" || true)
[ "$pass" = 7 ] && [ "$fail" = 0 ] || { echo "doctor: $pass PASS, $fail FAIL (want 7 and 0)" >&2; exit 1; }
termux-muscle versions --available --json > "$OUT/live-available.json"
cat "$OUT/live-versions.txt"
echo "LIVE UPGRADE PASS: Termux Muscle $P, Claude Code $X pinned, doctor 7 PASS"
