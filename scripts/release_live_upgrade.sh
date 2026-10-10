#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Maintainer release helper: move the live device onto published release P.
#
#   bash scripts/release_live_upgrade.sh P OUT_DIR
#
# Updates the manager to P and confirms a second self-update reports already_current (exit 2).
# Then follows the release channel as an ordinary user would (`termux-muscle update`), and, when
# the active Claude Code release still uses a backend other than P's default, installs the same
# version again so the device runs the default. Records versions and doctor. Safe to re-run.
# Writes self-update.log, self-update-after-publication.log, live-update.log, live-backend.log,
# live-versions.txt, live-device.json and live-available.json into OUT_DIR.
#
# A running Claude Code session keeps the release it started with; this changes what the next
# session starts.
set -euo pipefail
P=$1; OUT=$2
# self-update builds and tests the new manager, and those tests cannot run in a traced process.
grep -q '^TracerPid:[[:space:]]*0$' /proc/self/status || { echo "run this in an untraced shell: native Termux, or a session on the native backend" >&2; exit 1; }
mkdir -p "$OUT"
TM=${XDG_DATA_HOME:-$HOME/.local/share}/termux-muscle

rc=0; termux-muscle self-update > "$OUT/self-update.log" 2>&1 || rc=$?
[ "$rc" = 0 ] || [ "$rc" = 2 ] || { echo "self-update failed (exit $rc)" >&2; exit 1; }
rc=0; termux-muscle self-update > "$OUT/self-update-after-publication.log" 2>&1 || rc=$?
[ "$rc" = 2 ] && grep -q already_current "$OUT/self-update-after-publication.log" || { echo "second self-update did not report already_current (exit $rc)" >&2; exit 1; }
[ "$(termux-muscle --version | head -n 1)" = "Termux Muscle $P" ] || { echo "the manager is not $P" >&2; exit 1; }

termux-muscle update > "$OUT/live-update.log" 2>&1
case $(sed -n 's/.*"backend": *"\([^"]*\)".*/\1/p' "$TM/tools/current/compatibility.json") in
    musl-native) default=native ;;
    unmodified-musl-proot) default=proot ;;
    *) echo "cannot read the default backend of the installed manager" >&2; exit 1 ;;
esac
current() { termux-muscle versions | awk '$1 == "Current" { print $2, $4 }'; }
read -r X backend <<< "$(current)"
if [ "$backend" != "$default" ]; then
    termux-muscle update --claude-version "$X" > "$OUT/live-backend.log" 2>&1
else
    echo "Claude Code $X already runs on the $default backend" > "$OUT/live-backend.log"
fi

{ termux-muscle --version; termux-muscle versions; claude --version; } > "$OUT/live-versions.txt" 2>&1
read -r X backend <<< "$(current)"
[ "$backend" = "$default" ] && grep -qx "$X (Claude Code)" "$OUT/live-versions.txt" ||
    { cat "$OUT/live-versions.txt" >&2; echo "device is not running Claude Code $X on the $default backend" >&2; exit 1; }
termux-muscle doctor > "$OUT/live-device.json" 2>&1
pass=$(grep -c '"status":"PASS"' "$OUT/live-device.json" || true); fail=$(grep -c '"status":"FAIL"' "$OUT/live-device.json" || true)
[ "$pass" = 7 ] && [ "$fail" = 0 ] || { echo "doctor: $pass PASS, $fail FAIL (want 7 and 0)" >&2; exit 1; }
termux-muscle versions --available --json > "$OUT/live-available.json"
cat "$OUT/live-versions.txt"
echo "LIVE UPGRADE PASS: Termux Muscle $P, Claude Code $X on the $default backend, doctor 7 PASS"
