# Changes

## Unreleased

- Reserve `self-update` exit 0 for a completed management update or forced reinstall. Report an equal version with status 2, an older target with status 3, and update failures with status 1; preserve distinct stderr categories and the force override.

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
