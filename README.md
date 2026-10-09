# Termux Muscle

**Install, run, update and recover Claude Code on Android with Termux.**

![Termux Muscle: a friendly robot and Tux work together inside a phone, with C, Bash and GNU Make equipment.](docs/images/termux-muscle-hero.png)

[Artwork license and credits](docs/images/README.md). The Android robot is reproduced or modified from work created and shared by Google and used according to terms described in the [Creative Commons 3.0 Attribution License](https://creativecommons.org/licenses/by/3.0/).

An independent community project from [Octocore Autonomous Systems](https://github.com/octocore-autonomous-systems) (OAS). **Not affiliated with, endorsed by, sponsored by, or authorized by Anthropic.** Claude and Claude Code are Anthropic products; your use of them remains subject to Anthropic's terms and account access.

> **0.20.0 pins Claude Code 2.1.296** on Android **ARM64 / aarch64** and preserves 2.1.295 as formerly pinned by 0.19.0. Private source installation, startup, update, rollback, removal and an authenticated **Opus 5.5** tool workflow passed on **Samsung Galaxy S26 Ultra, Android 17, Termux 0.118.3 (GitHub)**. See the scoped [0.20.0 report](compatibility/galaxy-s26-ultra-0.20.0-20261009.md); other configurations need volunteer evidence.

[Install](#install) · [Commands](#everyday-use) · [Device matrix](docs/device-compatibility.md) · [Troubleshooting](docs/troubleshooting.md) · [Contribute](CONTRIBUTING.md)

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
curl -fsSL https://github.com/octocore-autonomous-systems/termux-muscle/releases/download/v0.20.0/install.sh | sh
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

See the [device compatibility matrix](docs/device-compatibility.md) for tested device, Android/API and Termux configurations, per-check results, evidence reports and limitations. **PASS** means the named check passed; **FAIL** means it failed; **SKIP** means untested.

Have a different phone, tablet, Android release or Termux build? The [compatibility guide](docs/device-compatibility.md) explains how to submit a local report.

## Claude Code and models

Termux Muscle and Claude Code have independent version numbers. Each Termux Muscle release selects a Claude Code client version.

| Termux Muscle version | Pinned Claude Code version |
| --- | --- |
| [0.1.0](docs/releases/0.1.0.md) | 2.1.270 |
| [0.2.0](docs/releases/0.2.0.md) | 2.1.270 |
| [0.3.0](docs/releases/0.3.0.md) | 2.1.270 |
| [0.3.1](docs/releases/0.3.1.md) | 2.1.270 |
| [0.3.2](docs/releases/0.3.2.md) | 2.1.270 |
| [0.4.0](docs/releases/0.4.0.md) | 2.1.283 |
| [0.5.0](docs/releases/0.5.0.md) | 2.1.283 |
| [0.5.1](docs/releases/0.5.1.md) | 2.1.283 |
| [0.6.0](docs/releases/0.6.0.md) | 2.1.283 |
| [0.7.0](docs/releases/0.7.0.md) | 2.1.283 |
| [0.8.0](docs/releases/0.8.0.md) | 2.1.284 |
| [0.9.0](docs/releases/0.9.0.md) | 2.1.284 |
| [0.10.0](docs/releases/0.10.0.md) | 2.1.285 |
| [0.11.0](docs/releases/0.11.0.md) | 2.1.286 |
| [0.12.0](docs/releases/0.12.0.md) | 2.1.287 |
| [0.13.0](docs/releases/0.13.0.md) | 2.1.288 |
| [0.14.0](docs/releases/0.14.0.md) | 2.1.289 |
| [0.15.0](docs/releases/0.15.0.md) | 2.1.291 |
| [0.16.0](docs/releases/0.16.0.md) | 2.1.292 |
| [0.17.0](docs/releases/0.17.0.md) | 2.1.293 |
| [0.18.0](docs/releases/0.18.0.md) | 2.1.294 |
| [0.19.0](docs/releases/0.19.0.md) | 2.1.295 |
| [0.20.0](docs/releases/0.20.0.md) | 2.1.296 |

The [compatibility manifest](compatibility.json) records the current pin and pin history; `termux-muscle versions --available` identifies formerly pinned clients. The musl loader remains **1.2.6-r2**.

Model minimums describe client requirements. The Termux Muscle minimum is derived from the earliest release whose pin meets that requirement; it does not establish the model's introduction date or device verification. **—** means no listed release meets the requirement.

| Model | Model ID | Claude Code min. version | Termux Muscle min. version |
| --- | --- | --- | --- |
| Sonnet 5 | `claude-sonnet-5` | 2.1.197 | [0.1.0](docs/releases/0.1.0.md) |
| Fable 5 | `claude-fable-5` | 2.1.219 | [0.1.0](docs/releases/0.1.0.md) |
| Opus 5 | `claude-opus-5` | 2.1.219 | [0.1.0](docs/releases/0.1.0.md) |
| Fable 5.1 | `claude-fable-5-1` | 2.1.257 | [0.1.0](docs/releases/0.1.0.md) |
| Opus 5.5 | `claude-opus-5-5` | 2.1.280 | [0.4.0](docs/releases/0.4.0.md) |
| Sonnet 5.5 | `claude-sonnet-5-5` | 2.1.284 | [0.8.0](docs/releases/0.8.0.md) |

Model requirements were documented on **2026-09-29** against [Anthropic's model configuration documentation](https://code.claude.com/docs/en/model-config). Availability depends on your account, provider and organization policy; a newer client does not grant model access.

**Opus 5.5** passed authenticated tool acceptance with Termux Muscle **0.20.0** and Claude Code **2.1.296** on **2026-10-09** ([scoped report](compatibility/galaxy-s26-ultra-0.20.0-20261009.md)). Other listed models are not verified by that report.

Earlier measurements, including mixed Fable observations, retain their dated scope in the [device compatibility reports](docs/device-compatibility.md).

## Help build something dependable

Bug reports, device evidence and small fixes are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains branch names, tests and pull requests. The [engineering record](docs/engineering.md) connects the defects we encountered with design decisions and acceptance evidence.

Our source is [MPL-2.0](LICENSE). Claude Code and separately downloaded dependencies retain their own licenses and terms. We learned from several existing Termux projects and the musl approach documented by Khronos31; see [CREDITS.md](CREDITS.md).
