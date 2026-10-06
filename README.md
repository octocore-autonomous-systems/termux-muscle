# Termux Muscle

**Install, run, update and recover Claude Code on Android with Termux.**

![Termux Muscle: a friendly robot and Tux work together inside a phone, with C, Bash and GNU Make equipment.](docs/images/termux-muscle-hero.png)

[Artwork license and credits](docs/images/README.md). The Android robot is reproduced or modified from work created and shared by Google and used according to terms described in the [Creative Commons 3.0 Attribution License](https://creativecommons.org/licenses/by/3.0/).

An independent community project from [Octocore Autonomous Systems](https://github.com/octocore-autonomous-systems) (OAS). **Not affiliated with, endorsed by, sponsored by, or authorized by Anthropic.** Claude and Claude Code are Anthropic products; your use of them remains subject to Anthropic's terms and account access.

> **0.15.0 pins Claude Code 2.1.291** on Android **ARM64 / aarch64** and preserves 2.1.289 as formerly pinned by 0.14.0. Private source installation, startup, update, rollback, removal and an authenticated **Opus 5.5** tool workflow passed on **Samsung Galaxy S26 Ultra, Android 17, Termux 0.118.3 (GitHub)**. See the scoped [0.15.0 report](compatibility/galaxy-s26-ultra-0.15.0-20261006.md); other configurations need volunteer evidence.

[Install](#install) · [Commands](#everyday-use) · [Device matrix](#device-compatibility) · [Troubleshooting](docs/troubleshooting.md) · [Contribute](CONTRIBUTING.md)

## Why this exists

A Claude Code update can leave Termux with a launcher and no usable binary. Termux Muscle manages that installation boundary and the work that follows:

- Downloads Anthropic's official ARM64 musl package and verifies its bytes before use.
- Supplies a small PRoot environment with the musl loader, Termux shell, live DNS and certificates.
- Checks a candidate before making it current; keeps a previous release for rollback.
- Separates runtime updates, account authentication and management-tool updates.
- Sets up the normal `claude` command after runtime validation, backing up replaced commands for eligible restoration.
- Preserves your Claude credentials, settings and projects.

This is a **Claude Code lifecycle manager**, not a general agent runtime. It does not provide model access or make Android an officially supported Anthropic platform. [Architecture and limits →](docs/architecture.md)

## Install

Run this in a **native Termux shell on an ARM64 Android device**:

```sh
curl -fsSL https://github.com/octocore-autonomous-systems/termux-muscle/releases/download/v0.15.0/install.sh | sh
```

The installer adds missing Termux prerequisites with `pkg`, verifies the release's source archive, builds the C helper locally and runs its offline tests before installation. Bash manages the lifecycle; the helper uses json-c, libarchive and OpenSSL. Build and test tools are Clang, make, pkg-config and diffutils; tar and gzip unpack the source. Runtime tools are Bash, PRoot, coreutils, ripgrep, curl and CA certificates. Termux's `mandoc` package provides the manual viewer. The installed project requires no Python, npm or Ubuntu installation. Contributors can regenerate the checked-in CLI help and completion files from the standard-library `argparse` definition with `python3 scripts/cli_schema.py`; add `--check` to verify they are current.

Local compilation requires downloading a C toolchain when one is not already installed. It builds our helper against your Termux environment; Anthropic's proprietary Claude Code executable is downloaded separately and remains unmodified.

After the runtime passes validation, the installer sets up `claude` in the Termux prefix, `~/.local/bin`, and at the first existing executable `claude` found elsewhere on PATH. Replaced regular files and symlinks are backed up. Start Claude Code and use its normal authentication flow:

```sh
claude auth login
claude
```

The manager is made available in `$PREFIX/bin` and `~/.local/bin` without changing shell startup files. The installer also installs one manual page:

```sh
termux-muscle --version
man termux-muscle
```

Bash completion is linked into `${XDG_DATA_HOME:-$HOME/.local/share}/bash-completion/completions/termux-muscle`. A Bash session that loads `bash-completion` discovers commands and options from this script. You can also source the file directly. The installer preserves an unrelated existing completion file; uninstall removes only its managed symlink. Completion does not access the network, launch the runtime, or look up account data, and it stops at `run` so Claude Code owns its following arguments.

An unrelated existing command named `termux-muscle` or an unrelated manual is preserved; the installer prints the full owned path when needed. Shell aliases, functions and cached command locations can override executable PATH lookup; open a fresh shell if the old command persists. See [command recovery](docs/troubleshooting.md#command-selection-and-recovery).

For a custom setup, pass `--no-link` to install the runtime while preserving Claude command entries. Pass `--no-install` to install only the management tool and manual, without downloading or redirecting Claude. To inspect the bootstrap or supply these options, download the same `install.sh` URL to a file, read it, then run `sh install.sh --no-link` or `sh install.sh --no-install`.

## Existing installations and development preflight

Run `termux-muscle migration` from the affected project before moving an existing setup. It reports old loader settings, legacy plugin/worktree
path hints, and executable shadowing without changing configuration or reading transcripts.
See the [migration guide](docs/migration.md).

Candidate checks require isolated non-conversational initialization as well
as version/help. They do not use your Claude account, hooks, plugins or MCP configuration;
normal launches still do. See [startup acceptance](docs/testing.md#isolated-startup-acceptance).

## Everyday use

| Task | Command |
| --- | --- |
| Start Claude Code | `claude` |
| Authenticate through Claude Code | `claude auth login` |
| Run Claude with its own arguments | `claude --model claude-opus-5` |
| Read the installed manual | `man termux-muscle` |
| Inspect installed and retained releases | `termux-muscle versions` |
| See which Claude Code versions can be installed | `termux-muscle versions --available` |
| Check installation health | `termux-muscle doctor` |
| Install the version tested for this project release | `termux-muscle update` |
| Restore the previous local release | `termux-muscle rollback` |
| Rebuild from verified cached downloads | `termux-muscle repair --offline` |
| Update this management tool | `termux-muscle self-update` (`--force` to reinstall a compatible version) |
| Write a device report for review | `termux-muscle test --output report.json` |
| Remove this installation and restore eligible commands/manual | `termux-muscle uninstall` |

Default updates stay with the project's compatibility pin. An explicitly requested upstream version is experimental until tested on your device; see `update --help`. Installation and ordinary health checks make no paid model requests. Uninstall restores replaced commands only while their installed entries remain unchanged and owned; it preserves later foreign changes and keeps the recovery evidence. Claude account data, settings, sessions, projects and installed Termux packages remain intact.

`rollback` restores a previous **Claude Code runtime**. Management-tool self-update is separate: an equal version reports `already_current` and exits 2; an older target reports `target_older` and exits 3. Exit 0 means an update or forced reinstall completed; other update failures exit 1. `-f` or `--force` deliberately reinstalls a compatible version after the normal integrity checks. In-place updates below 0.2.0 remain incompatible even with `--force`, because those managers cannot read the manual ownership records. Do not run an old installer over a newer installation. An intentional downgrade below 0.2.0 requires uninstalling with the current manager first.

`self-update --json` emits one `termux-muscle.self-update.v1` object on stdout for installation, already-current, older-target, and handled failures. It includes `current_version`, `target_version` (null until resolved), `forced`, `result`, `exit_code`, `error_code`, `message`, and `transcript`. The transcript's `combined_output_base64` is the complete combined installer/build/test output as bytes; decode it to investigate details. `transcript.complete` is false if the 32 MiB capture limit is reached, and the command then exits 1 with `capture_failed`. Exit statuses remain 0/1/2/3.

Use `-V` or `--verbose` to stream the full installer, build, and test transcript. With `--json`, either verbose flag has no effect: JSON contains the complete captured transcript. The `transcript.stages` array separates verification, build, test, and installation output for installers that emit stage boundaries; older published installers appear as one `installer` stage. Each stage has base64 `output_base64` bytes.

Ordinary self-update output shows release verification, local build, tests and installation as they start. During tests, one dot means one top level C or shell test program has passed, and the stage ends with passed, skipped and failed program totals. On a terminal, a spinner with elapsed seconds runs during the build, and after the dots a live status shows the running program, its position such as `3/15`, and its elapsed seconds; each is erased when its step ends. Logs and `--json` transcripts receive only the dots, which wrap after 60, and the totals. Set `TM_SELF_UPDATE_PROGRESS_LIVE=0` to turn the live status off. Compiler commands and individual PASS lines stay in a private full log. On failure, the command names the stage and retains that log at the printed path.

## Upstream release tracking

The repository's scheduled tracker checks Anthropic's ARM64 musl package every
six hours and opens a deduplicated compatibility-testing issue when it observes
a version newer than the project pin. Discovery does not approve compatibility
or update installations. Maintainers still test and publish a verified pin;
users then run `termux-muscle self-update` followed by `termux-muscle update`.
See [release tracking](docs/release-tracking.md) for activation, manual checks,
failure visibility and scheduling limits.

## Device compatibility

A configuration is **device + Android/API + Termux build**, with ABI, kernel, page size and dependency versions in its report. Android version affects available system interfaces; hardware and vendor firmware can change the kernel and process behavior. Neither dimension alone proves compatibility.

The capability matrix grows only when someone supplies a report. **PASS** means that named check passed; **FAIL** means it failed; **SKIP** means untested. A maintainer report is distinguished from a community report.

| Tested configuration | Install | Start | Shell namespace | Claude tools | Manual | Update | Rollback | Removal | Evidence |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | :---: | :---: | --- |
| **0.15.0, 2026-10-06 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 17 / API 37 · Termux 0.118.3 (GitHub) | PASS¹⁷ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.15.0-20261006.md) · [JSON](compatibility/galaxy-s26-ultra-0.15.0-20261006.json) |
| **0.14.0, 2026-10-04 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 17 / API 37 · Termux 0.118.3 (GitHub) | PASS¹⁶ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.14.0-20261004.md) · [JSON](compatibility/galaxy-s26-ultra-0.14.0-20261004.json) |
| **0.13.0, 2026-10-02 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 17 / API 37 · Termux 0.118.3 (GitHub) | PASS¹⁵ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.13.0-20261002.md) · [JSON](compatibility/galaxy-s26-ultra-0.13.0-20261002.json) |
| **0.12.0, 2026-10-02 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 17 / API 37 · Termux 0.118.3 (GitHub) | PASS¹⁴ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.12.0-20261002.md) · [JSON](compatibility/galaxy-s26-ultra-0.12.0-20261002.json) |
| **0.11.0, 2026-09-30 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS¹³ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.11.0-20260930.md) · [JSON](compatibility/galaxy-s26-ultra-0.11.0-20260930.json) |
| **0.10.0, 2026-09-29 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS¹² | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.10.0-20260929.md) · [JSON](compatibility/galaxy-s26-ultra-0.10.0-20260929.json) |
| **0.9.0, 2026-09-29 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS¹¹ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.9.0-20260929.md) · [JSON](compatibility/galaxy-s26-ultra-0.9.0-20260929.json) |
| **0.8.0, 2026-09-29 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS¹⁰ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.8.0-20260929.md) · [JSON](compatibility/galaxy-s26-ultra-0.8.0-20260929.json) |
| **0.7.0, 2026-09-27 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS⁹ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.7.0-20260927.md) · [JSON](compatibility/galaxy-s26-ultra-0.7.0-20260927.json) |
| **0.6.0, 2026-09-27 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS⁸ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.6.0-20260927.md) · [JSON](compatibility/galaxy-s26-ultra-0.6.0-20260927.json) |
| **0.5.1, 2026-09-27 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS⁷ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.5.1-20260927.md) · [JSON](compatibility/galaxy-s26-ultra-0.5.1-20260927.json) |
| **0.5.0, 2026-09-27 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS⁶ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.5.0-20260927.md) · [JSON](compatibility/galaxy-s26-ultra-0.5.0-20260927.json) |
| **0.4.0, 2026-09-27 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS⁵ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.4.0-20260927.md) · [JSON](compatibility/galaxy-s26-ultra-0.4.0-20260927.json) |
| **0.3.2, 2026-09-24 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS⁴ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.3.2-20260924.md) · [JSON](compatibility/galaxy-s26-ultra-0.3.2-20260924.json) |
| **0.3.1, 2026-09-24 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS³ | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.3.1-20260924.md) · [JSON](compatibility/galaxy-s26-ultra-0.3.1-20260924.json) |
| **0.3.0, 2026-09-24 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS² | PASS | PASS | PASS | — | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.3.0-20260924.md) · [JSON](compatibility/galaxy-s26-ultra-0.3.0-20260924.json) |
| **0.2.0, 2026-09-15 UTC** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS¹ | PASS | PASS | PASS | PASS | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-0.2.0-20260915.md) · [JSON](compatibility/galaxy-s26-ultra-0.2.0-20260915.json) |
| **0.1.0, 2026-09-14** · Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS | PASS | PASS | PASS | — | PASS | PASS | PASS | [Historical report](compatibility/galaxy-s26-ultra-20260914.md) · [JSON](compatibility/galaxy-s26-ultra-20260914.json) |

¹⁷ Version 0.15.0 moves the pin to Claude Code 2.1.291 and retains 2.1.289 in pin history. All 15 test programs passed in a native Termux shell; optional host probes and the unavailable cross-UID executable fixture were skipped as detailed in the report. Acceptance ran from a clean checkout and verified Opus 5.5 on the new pin, with the live installation unchanged. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.

¹⁶ Version 0.14.0 moves the pin to Claude Code 2.1.289 and retains 2.1.288 in pin history. All 15 test programs passed in a native Termux shell; optional host probes and the unavailable cross-UID executable fixture were skipped as detailed in the report. Acceptance ran from a clean checkout and verified Opus 5.5 on the new pin, with the live installation unchanged. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.

¹⁵ Version 0.13.0 moves the pin to Claude Code 2.1.288 and retains 2.1.287 in pin history. All 15 test programs passed in a native Termux shell; optional host probes and the unavailable cross-UID executable fixture were skipped as detailed in the report. Acceptance ran from a clean checkout and verified Opus 5.5 on the new pin, with the live installation unchanged. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.

¹⁴ Version 0.12.0 moves the pin to Claude Code 2.1.287 and retains 2.1.286 in pin history. It is the first acceptance on Android 17 / API 37. All 15 test programs passed in a native Termux shell; optional host probes and the unavailable cross-UID executable fixture were skipped as detailed in the report. Acceptance ran from a clean checkout and verified Opus 5.5 on the new pin, with the live installation unchanged. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.

¹³ Version 0.11.0 moves the pin to Claude Code 2.1.286 and retains 2.1.285 in pin history. All 15 test programs passed in a native Termux shell; optional host probes and the unavailable cross-UID executable fixture were skipped as detailed in the report. Acceptance ran from a clean checkout and verified Opus 5.5 on the new pin, with the live installation unchanged. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.

¹² Version 0.10.0 moves the pin to Claude Code 2.1.285 and retains 2.1.284 in pin history. All 15 test programs passed in a native Termux shell; optional host probes and the unavailable cross-UID executable fixture were skipped as detailed in the report. Acceptance ran from a clean checkout and verified Opus 5.5 on the new pin, with the live installation unchanged. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.

¹¹ Version 0.9.0 keeps the 2.1.284 pin and carries the Claude Code pin history in `compatibility.json`, with a release-gate guard for moved pins and formerly pinned labels in `versions --available`. Its `make check` passed in a native Termux shell, and acceptance ran `scripts/maintainer_acceptance.sh` from a clean checkout of the tested commit and verified Opus 5.5 again. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.

¹⁰ Version 0.8.0 moves the pin to Claude Code 2.1.284 and documents Sonnet 5.5. Its `make check` passed in a native Termux shell, and acceptance ran `scripts/maintainer_acceptance.sh` from a clean checkout of the tested commit and verified Opus 5.5 on the new pin. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.

⁹ Version 0.7.0 groups the command help, adds `help COMMAND`, an active Claude Code line in `--version` and `versions --available`. Its `make check` passed in a native Termux shell, and acceptance ran `scripts/maintainer_acceptance.sh` from a clean checkout of the tested commit and verified Opus 5.5 again. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.

⁸ Version 0.6.0 adds live self-update progress on a terminal. Its `make check` ran under a simulated quiet self-update with the live test status on a real terminal, and acceptance ran `scripts/maintainer_acceptance.sh` from a clean checkout of the tested commit and verified Opus 5.5 again. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.

⁷ Version 0.5.1 fixes quiet and JSON `self-update` from 0.5.0, which failed during tests. Its `make check` also ran under a simulated quiet self-update, and acceptance ran `scripts/maintainer_acceptance.sh` from a clean checkout of the tested commit and verified Opus 5.5 again. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.

⁶ Version 0.5.0 keeps the 2.1.283 pin and adds quiet self-update, `--verbose`, `--json` and Bash completion. Its acceptance ran `scripts/maintainer_acceptance.sh` from a clean checkout of the tested commit, with a private root and `--no-link`, and verified Opus 5.5 again with an exact authenticated Bash-tool fixture. Command takeover, indexed manual discovery and public HTTPS delivery were not retested; the quiet self-update output is checked after publication.

⁵ Version 0.4.0 moves the pin to Claude Code 2.1.283. Its acceptance ran `scripts/maintainer_acceptance.sh` from a clean checkout of the tested commit, with a private root and `--no-link`, and verified Opus 5.5 with an exact authenticated Bash-tool fixture. Command takeover, indexed manual discovery and public HTTPS delivery were not retested.

⁴ Version 0.3.2 verifies the distinct self-update exit statuses in addition to private source lifecycle acceptance. Public installer delivery is checked after publication.

³ Version 0.3.1 corrects the installer test helper selection when self-updating from an older manager. The 0.3.0 self-update from 0.2.0 stopped before installation because its migration test selected the old helper. The published 0.3.0 files are preserved.

² The fresh **0.3.0** source installation used a private root and `--no-link`. It passed a separate authenticated Sonnet 5 shell-tool fixture. Command takeover, indexed manual discovery and public HTTPS delivery were not retested for 0.3.0.

¹ The fresh **0.2.0** installation result covers the real native source bootstrap with private command/manual destinations and verified original vendor archives. It does not claim public HTTPS delivery. Its local namespace probe passed; a separate authenticated Sonnet 5 fixture also passed actual Bash tool execution, native shell, portable shebang, ripgrep and nested launcher checks. The indexed manual installed, refreshed and was removed correctly; 0.1.0 did not ship this manual. Reports include exact Claude Code, loader, compiler, C libraries, PRoot, Bash, ripgrep and package versions, including `mandoc` for 0.2.0. See [testing](docs/testing.md) for each check's scope. Background/screen-off behavior and actual MCP tool calls remain untested; the older report records the vendor's default cross-session messaging UID-mapping failure.

**Have a different phone, tablet, Android release or Termux version? Please help test.** We especially need other manufacturers, Android/kernel releases, 4 KiB and 16 KiB page-size devices, and different Termux distributions/builds.

```sh
termux-muscle test --output report.json
```

Review the local JSON, then [open a Device compatibility issue](https://github.com/octocore-autonomous-systems/termux-muscle/issues/new?template=device-compatibility.yml) and attach or paste it. Nothing is uploaded automatically. The report uses an allowlist of platform details and check results; do not add tokens, complete environment dumps or private session logs. No account is needed for the default checks. An explicit `--model MODEL_ID` test uses your authenticated account and may incur usage.

## Claude Code and models

Project versions and Claude Code versions are separate. **0.15.0** moves the pin to **Claude Code 2.1.291**; **0.14.0** moved it to **2.1.289**; **0.13.0** moved it to **2.1.288**; **0.12.0** moved it to **2.1.287**; **0.11.0** moved it to **2.1.286**; **0.10.0** moved it to **2.1.285**; **0.8.0** moved it to **2.1.284** and **0.9.0** kept it; **0.4.0** moved it to 2.1.283 and **0.5.0** through **0.7.0** kept it; 0.1.0 through 0.3.2 all pinned 2.1.270; every release keeps musl **1.2.6-r2**. [compatibility.json](compatibility.json) is the machine-readable record; each published release includes matching notes and checksums. Its `pin_history` names every earlier pin with the project releases that accepted it and the report that did so, and `claude.pinned_since` names the release that first pinned the current version, so `termux-muscle versions --available` shows a formerly pinned version as such rather than as unverified. A newer pin does not add a model or an account entitlement: it only makes a client version available that upstream documents as the minimum for a given model.

| Documented model | Model ID | Minimum Claude Code |
| --- | --- | --- |
| Fable 5.1 | `claude-fable-5-1` | 2.1.257 |
| Fable 5 | `claude-fable-5` | 2.1.219 |
| Opus 5.5 | `claude-opus-5-5` | 2.1.280 |
| Opus 5 | `claude-opus-5` | 2.1.219 |
| Sonnet 5.5 | `claude-sonnet-5-5` | 2.1.284 |
| Sonnet 5 | `claude-sonnet-5` | 2.1.197 |

Model documentation was checked **2026-09-29** against [Anthropic's model configuration documentation](https://code.claude.com/docs/en/model-config). **Sonnet 5.5 requires client 2.1.284 or later, which is why 0.8.0 moves the pin; it is documented, not verified. Opus 5.5 passed exact authenticated tool acceptance with 0.15.0 on the 2.1.291 pin on 2026-10-06 UTC, with 0.14.0 on the 2.1.289 pin on 2026-10-04 UTC, with 0.13.0 on the 2.1.288 pin and 0.12.0 on the 2.1.287 pin on 2026-10-02 UTC, with 0.11.0 on the 2.1.286 pin on 2026-09-30 UTC, and with 0.10.0 on the 2.1.285 pin and 0.9.0 and 0.8.0 on the 2.1.284 pin on 2026-09-29 UTC.** **Opus 5.5 requires client 2.1.280 or later, which is why 0.4.0 moved the pin. Opus 5.5 passed exact authenticated tool acceptance with 0.7.0, 0.6.0, 0.5.1, 0.5.0 and 0.4.0 on 2026-09-27 UTC.** **Sonnet 5 passed exact authenticated tool acceptance with 0.3.2, 0.3.1 and 0.3.0 on 2026-09-24 UTC, and with 0.2.0 on 2026-09-15 UTC.** The dated **0.1.0** report separately retains Opus 5/Sonnet 5 PASS results and a direct Fable 5.1 response with automated upstream fallback/refusal; those observations remain visible in the [historical report](compatibility/galaxy-s26-ultra-20260914.md#model-observations). Opus and Fable were not newly verified for 0.3.2. Availability depends on your account, provider and organization policy; no Opus 5.1 identifier was established by the evidence.

## Help build something dependable

Bug reports, device evidence and small fixes are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains branch names, tests and pull requests. The [engineering record](docs/engineering.md) connects the defects we encountered with design decisions and acceptance evidence.

Our source is [MPL-2.0](LICENSE). Claude Code and separately downloaded dependencies retain their own licenses and terms. We learned from several existing Termux projects and the musl approach documented by Khronos31; see [CREDITS.md](CREDITS.md).
