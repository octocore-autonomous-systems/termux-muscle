# Changes

## 0.9.0

- Carry the Claude Code pin history. `compatibility.json` gains `claude.pinned_since`, the project release that first pinned the current version, and `pin_history`, one entry per earlier pin naming its exact version, the first and last project releases that pinned it, its acceptance date and the maintainer report of the last of those releases. The 0.8.0 tree records 2.1.270 (0.1.0 to 0.3.2) and 2.1.283 (0.4.0 to 0.7.0).
- `versions --available` labels a formerly pinned release `formerly pinned (first to last)` instead of `unverified`, always lists it alongside the pinned, active and retained releases, and `--json` adds a `formerly_pinned` field per release plus the manifest's `pin_history`. Versions that were never accepted stay `unverified`, and installing anything other than the pin still needs `--allow-unverified`.
- The release gate validates every history entry against its report (version, project release, maintainer provenance, all required lifecycle checks PASS, dates) and refuses a manifest that leaves any `docs/releases/X.Y.Z.md` older than `pinned_since` uncovered, so moving the pin without appending the outgoing version fails closed. Release notes gain a pin history table.

The Claude Code pin stays at **2.1.284** and musl at **1.2.6-r2**, with unchanged digests.

[Galaxy S26 Ultra evidence from 2026-09-29 UTC](compatibility/galaxy-s26-ultra-0.9.0-20260929.md) covers `make check` (all 15 test programs passed in a native Termux shell, including the pin history regressions) and maintainer acceptance from a clean checkout of the tested commit, including one bounded authenticated Opus 5.5 shell-tool workflow, with the live installation unchanged.

## 0.8.0

- Move the default pin from Claude Code **2.1.283** to **2.1.284**, the current upstream release, recording its official npm tarball URL, the registry SHA-512 integrity value and the SHA-256 of the extracted vendor executable. Both digests were confirmed against registry.npmjs.org and by a real acquisition run on a Galaxy S26 Ultra, and the executable digest was reproduced by extracting the cached archive again. The payload is unmodified; musl stays at **1.2.6-r2** with unchanged digests.
- Document **Sonnet 5.5** (`claude-sonnet-5-5`), which Anthropic's model configuration reference documents as requiring Claude Code **2.1.284 or later**. The 2.1.283 pin was below that minimum, so a default installation could not select the model. Refresh the documentation review date to 2026-09-29.
- Verify **Opus 5.5** on the new pin with an exact authenticated Bash-tool workflow. Sonnet 5.5 and Fable 5.1 are documented, not verified.

[Galaxy S26 Ultra evidence from 2026-09-29 UTC](compatibility/galaxy-s26-ultra-0.8.0-20260929.md) covers `make check` (all 15 test programs passed in a native Termux shell) and maintainer acceptance from a clean checkout of the tested commit, including one bounded authenticated Opus 5.5 shell-tool workflow, with the live installation unchanged.

## 0.7.0

- Regroup `termux-muscle --help` by what each command acts on: **Claude Code** (install, run, update, rollback, repair, versions, cleanup, link), **Termux Muscle** itself (self-update, uninstall, help) and **Troubleshooting** (doctor, test, migration), which checks the device, the manager and Claude Code together. The overview adds default paths for `--root` and `--prefix` and a short list of common tasks. Command names and options are unchanged.
- Move details from the old overview's closing paragraph to the command they belong to: self-update exit statuses and progress in `self-update --help`, version selection in `install --help` and `update --help`.
- Add `termux-muscle help COMMAND`, which prints the same text as `COMMAND --help`. Bash completion completes the command name.
- `--version` adds a second line naming the active Claude Code release, such as `Claude Code 2.1.283 (active)`. The first line is unchanged, and a fresh or damaged installation prints only that line.
- Add `versions --available`, which lists Claude Code releases published for the ARM64 musl package, newest first with release dates, labelled pinned or unverified, active or retained, and with upstream tags such as `latest`. It shows the ten newest plus every pinned, active or retained release; `--all` lists all and `--json` prints a `termux-muscle.available.v1` object. It reads one registry document and never downloads archives or changes state. Installing a version other than the pin still needs `--allow-unverified`.

The Claude Code pin stays at **2.1.283** and musl at **1.2.6-r2**, with unchanged digests.

[Galaxy S26 Ultra evidence from 2026-09-27 UTC](compatibility/galaxy-s26-ultra-0.7.0-20260927.md) covers `make check` (all 15 test programs passed) and maintainer acceptance from a clean checkout of the tested commit, including one bounded authenticated Opus 5.5 shell-tool workflow.

## 0.6.0

- Show signs of life during a quiet `self-update` on a terminal. The build shows a spinner with elapsed seconds. During tests, a live status after the dots shows the running program, its position such as `3/15`, and its elapsed seconds, so a slow program is distinguishable from a stall. Each status is erased when its step ends, and wraps follow the terminal width.
- Dots still mean one passed test program. Logs, CI and `--json` transcripts, where the progress output is not a terminal, receive exactly the 0.5.1 dots and totals. Set `TM_SELF_UPDATE_PROGRESS_LIVE=0` to turn the live status off.
- The live status stops at the end of each step, on failure and on HUP, INT and TERM, and also stops by itself if its installer or runner disappears. `tests/test_run.sh` and `tests/test_bootstrap.sh` cover each case.
- The display is drawn by the downloaded installer and test runner, so a 0.5.1 manager shows it on its update to 0.6.0.

The Claude Code pin stays at **2.1.283** and musl at **1.2.6-r2**, with unchanged digests.

[Galaxy S26 Ultra evidence from 2026-09-27 UTC](compatibility/galaxy-s26-ultra-0.6.0-20260927.md) covers `make check` under a simulated quiet self-update, with the live test status observed on a real terminal (all 15 test programs passed, the outer event file untouched), and maintainer acceptance from a clean checkout of the tested commit, including one bounded authenticated Opus 5.5 shell-tool workflow. The build spinner in a published self-update is a post-publication check.

## 0.5.1

- Fix `self-update` and `self-update --json` from 0.5.0, which stopped during tests with `valid source install failed`. The self-update's stage-event and progress variables reached the installer's test programs, and the bootstrap test's nested installer tried to write the caller's event file. The test runner now keeps that state to itself and reports progress alone; a new runner test covers it. `self-update --verbose` was not affected.
- The fix is in the downloaded installer's test runner, so a 0.5.0 manager can update to 0.5.1 with the ordinary quiet `self-update`.

The Claude Code pin stays at **2.1.283** and musl at **1.2.6-r2**, with unchanged digests.

[Galaxy S26 Ultra evidence from 2026-09-27 UTC](compatibility/galaxy-s26-ultra-0.5.1-20260927.md) covers `make check` under a simulated quiet self-update (all 15 test programs passed, the outer event file untouched) and maintainer acceptance from a clean checkout of the tested commit, including one bounded authenticated Opus 5.5 shell-tool workflow. The published quiet self-update is a post-publication check.

## 0.5.0

- Make ordinary `self-update` output concise. It names release verification, local build, tests and installation as each stage starts, prints one dot per passed top-level C or shell test program (wrapping after 60) and ends with passed, skipped and failed program totals. Compiler commands and individual PASS lines go to a private full log, which is kept at the printed path when a stage fails.
- Add `self-update -V/--verbose` to stream the full installer, build and test transcript, and `self-update --json`, which emits one `termux-muscle.self-update.v1` object with the result, exit code, error code and the complete transcript as base64, split into stages when the installer marks them. Exit statuses stay 0/1/2/3.
- Define the command line once in an argparse schema (`scripts/cli_schema.py`, a maintainer tool) that generates `lib/cli_schema.sh`, the source of help text and of the new Bash completion. Install and uninstall manage the completion file.
- **The first `self-update` from 0.4.0 to 0.5.0 still shows the full output.** Quiet mode is requested by the running manager and honored by the downloaded installer, and the 0.4.0 manager does not request it. Later self-updates run by a 0.5.0 or newer manager are concise.
- Clarify the model-check cost in `scripts/maintainer_acceptance.sh`: with a subscription login such as Pro or Max over OAuth the request counts against plan usage and is not billed; with an API key it is billed, capped at $0.50. The report's `total_cost_usd` is Claude Code's estimate at API prices.
- Track upstream Claude Code's ARM64 musl `latest` release every six hours in GitHub Actions, opening one compatibility-testing issue per newer observed version. Preserve closed decisions and maintainer edits; leave compatibility pins and user installations unchanged. Add offline maintainer-tool regressions and manual read-only checks. Its issue checklist runs `scripts/maintainer_acceptance.sh` for device acceptance.

The Claude Code pin stays at **2.1.283** and musl at **1.2.6-r2**, with unchanged digests.

[Galaxy S26 Ultra evidence from 2026-09-27 UTC](compatibility/galaxy-s26-ultra-0.5.0-20260927.md), produced by `scripts/maintainer_acceptance.sh` from a clean checkout of the tested commit, covers private source installation, isolated startup, offline update and rollback, removal with the live installation unchanged, and one bounded authenticated Opus 5.5 shell-tool workflow. Public installer delivery and the quiet self-update output are post-publication checks.

## 0.4.0

- Move the default pin from Claude Code **2.1.270** to **2.1.283**, the current upstream release, recording its official npm tarball URL, the registry SHA-512 SRI integrity value and the SHA-256 of the extracted vendor executable. The payload itself is unmodified; only its identity and digests are recorded here.
- Document **Opus 5.5** (`claude-opus-5-5`, minimum client **2.1.280**) and **Fable 5** (`claude-fable-5`, minimum client 2.1.219) in the compatibility manifest. Opus 5.5 is the reason for the pin move: the 2.1.270 pin is below its minimum client version, so a default installation could not select it. The release gate enforces that every documented model's minimum client version is at or below the pinned version.
- Report a missing `verified_on` in the strict release gate as an absent device-acceptance date rather than as a malformed metadata field. The release is rejected either way; only the reason is now legible.
- Add `scripts/maintainer_acceptance.sh`, which runs the complete maintainer lifecycle (bootstrap, isolated startup, offline update, optional authenticated Bash-tool and exact-model check, offline rollback, uninstall) in a disposable root. It proves the live installation unchanged, writes a device report and previews the release gate. It refuses to run inside a managed Claude Code session and explains why.
- Verify **Opus 5.5** with an exact authenticated Bash-tool workflow on the Galaxy S26 Ultra. The 0.3.2 and earlier Sonnet 5 results, and the 0.1.0 Opus and mixed Fable observations, remain dated evidence for their own releases and are not relabeled.

Musl stays at **1.2.6-r2** with unchanged digests, and the acquisition, startup-acceptance, update, rollback and removal behavior is unchanged.

[Galaxy S26 Ultra evidence from 2026-09-27 UTC](compatibility/galaxy-s26-ultra-0.4.0-20260927.md), produced by the new acceptance script from a clean checkout of the tested commit, covers private source installation, isolated startup, offline update and rollback, removal with the live installation unchanged, and one bounded authenticated Opus 5.5 shell-tool workflow. Acceptance must run from a fresh native Termux shell: the runtime's nested-namespace guard refuses to start a candidate payload from inside a managed Claude Code session. Public installer delivery remains a separate post-publication check.

## 0.3.2

- Reserve `self-update` exit 0 for a completed management update or forced reinstall. Report an equal version with status 2, an older target with status 3, and update failures with status 1; preserve distinct stderr categories and the force override.

Fresh [Galaxy S26 Ultra evidence from 2026-09-24 UTC](compatibility/galaxy-s26-ultra-0.3.2-20260924.md) covers private source installation, offline update/rollback, clean removal, the new status contract and one bounded authenticated Sonnet 5 shell-tool workflow. Public installer delivery remains a separate post-publication check.

## 0.3.1

- Run installer tests against the freshly built 0.3.1 helper even when an older installed manager exports its own helper path into the installer process. This fixes `self-update` from 0.2.0, which stopped safely during the 0.3.0 migration test before changing the manager.
- Preserve all published 0.3.0 assets and history; publish this correction as a separate release.

Fresh [Galaxy S26 Ultra evidence from 2026-09-24 UTC](compatibility/galaxy-s26-ultra-0.3.1-20260924.md) covers private source installation after a retained transient startup-probe failure, offline update/rollback, clean removal and one bounded authenticated Sonnet 5 shell-tool workflow. Public installer delivery remains a separate post-publication check.

## 0.3.0

- Add read-only `migration` advisories for settings loader overrides, legacy plugin/worktree paths, and executable PATH shadowing. Keep private values out of output and leave all user files unchanged.
- Require isolated version, help and non-conversational `--init-only` checks before runtime activation, update or rollback. Doctor uses the same startup checks. Strip inherited account/loader settings, use fresh HOME/config/cwd, disable user customizations, and reject system managed-policy presence rather than executing policy hooks.
- Bound startup time and captured output; retain only sanitized acceptance codes. A failed initialization preserves the active runtime and command links. These checks do not establish authenticated tools, networking, performance or background survival.
- Make `self-update` announce and skip equal or older management versions. `-f` and `--force` permit an intentional compatible reinstall or downgrade; integrity and ownership checks still apply.

This version retains Claude Code **2.1.270** and musl **1.2.6-r2**. [Fresh Galaxy S26 Ultra evidence from 2026-09-24 UTC](compatibility/galaxy-s26-ultra-0.3.0-20260924.md) verifies private source installation, isolated startup, offline update and rollback, removal, and one bounded authenticated Sonnet 5 Bash-tool workflow. It does not reverify ordinary command takeover, indexed manual discovery, public HTTPS delivery, interactive use, background operation or MCP tool calls. The 0.2.0 and 0.1.0 reports remain dated historical evidence.

## 0.2.0

Normal installation now sets up the executable `claude` command after validating and activating the runtime, including the Termux prefix, home-bin entry and a different first executable PATH match. Replaced commands are backed up and restored on uninstall only while their managed replacements remain unchanged and owned.

- Add `--no-link` to preserve Claude command entries; `--no-install` installs only the manager and manual without downloading or redirecting Claude.
- Make the management command available in both `$PREFIX/bin` and `~/.local/bin`, preserving foreign manager commands and reporting the full owned path on conflict.
- Install one regular, owned `termux-muscle(1)` manual with Termux `mandoc`, targeted index updates and ownership-aware refresh/removal. Preserve foreign manuals and installed Termux dependencies.
- Reject management self-update requests below 0.2.0 before invoking an older installer. Directly running an old installer over a newer root remains unsupported; Claude runtime rollback is a separate operation.
- Document the normal `claude auth login` / `claude` workflow and retain direct manager execution for diagnosis or explicit roots.
- Rebuild version-dependent C objects and unit binaries when `VERSION` changes, preventing a mixed-version helper after an incremental build.
- Add the Clang Format 21 contributor hook and CI check, separate from installer prerequisites, and the selected retrofuturistic project illustration with artwork attribution.

This version retains Claude Code **2.1.270** and musl **1.2.6-r2**. Fresh [Galaxy S26 Ultra evidence from 2026-09-15 UTC](compatibility/galaxy-s26-ultra-0.2.0-20260915.md) verifies isolated native source bootstrap, normal command takeover, namespace shell/shebang/ripgrep, indexed manual installation/refresh/removal, runtime update/rollback, failed-update preservation, repair and complete removal. A separate authenticated **Sonnet 5** fixture passed actual Bash-tool, native shell, portable shebang, ripgrep and nested-launcher checks with exact model identity. The tests preserved live-host command entries. Sonnet 5 is the only newly verified model in the 0.2.0 manifest; older Opus and mixed Fable observations remain attributed to **0.1.0 on 2026-09-14**. The companion report keeps native source acceptance separate from public release delivery.

## 0.1.0

Initial Termux Muscle release, targeting Claude Code 2.1.270 and musl 1.2.6-r2 on Android ARM64 with native Termux.

- Install from a checksummed source archive with curl; build the Bash/C manager locally with Clang and make.
- Run the original Anthropic musl executable inside a small PRoot environment using Termux's shell, resolver and certificates.
- Validate candidates before activation; retain a previous release, support offline repair and rollback, and protect running sessions during cleanup.
- Preserve existing launchers, journal explicit replacements, and restore eligible entries on uninstall.
- Build and validate management-tool updates separately from runtime updates.
- Collect local platform and model evidence without uploading it; provide a volunteer issue form and capability matrix.
- Include C unit tests and Bash regression tests for damaged downloads, unsafe inputs, interrupted transactions, locks, leases, command ownership and evidence handling.

The initial compatibility manifest documents Fable 5.1, Opus 5 and Sonnet 5. Exact authenticated results, Samsung Galaxy S26 Ultra / Android 16 / Termux 0.118.3 acceptance, and remaining limitations are recorded in the release's compatibility report and notes. A successful build on another device does not establish workflow compatibility there.

Sonnet 5 and Opus 5 passed exact authenticated checks. Fable 5.1 returned a direct response but automated probes encountered vendor fallback/refusal. Default cross-session messaging was disabled by a vendor UID-mapping check; background/screen-off behavior and actual MCP tool calls remain untested. See the [maintainer report](compatibility/galaxy-s26-ultra-20260914.md) for evidence and limits.
