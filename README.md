# Termux Muscle

**Install, run, update and recover Claude Code on Android with Termux.**

An independent community project from [Octocore Autonomous Systems](https://github.com/octocore-autonomous-systems) (OAS). **Not affiliated with, endorsed by, sponsored by, or authorized by Anthropic.** Claude and Claude Code are Anthropic products; your use of them remains subject to Anthropic's terms and account access.

> **0.1.0 pins Claude Code 2.1.270** on Android **ARM64 / aarch64**. Tested on **Samsung Galaxy S26 Ultra, Android 16, Termux 0.118.3 (GitHub)**. Other configurations need volunteer evidence.

[Install](#install) · [Commands](#everyday-use) · [Device matrix](#device-compatibility) · [Troubleshooting](docs/troubleshooting.md) · [Contribute](CONTRIBUTING.md)

## Why this exists

A Claude Code update can leave Termux with a launcher and no usable binary. Termux Muscle manages that installation boundary and the work that follows:

- Downloads Anthropic's official ARM64 musl package and verifies its bytes before use.
- Supplies a small PRoot environment with the musl loader, Termux shell, live DNS and certificates.
- Checks a candidate before making it current; keeps a previous release for rollback.
- Separates runtime updates, account authentication and management-tool updates.
- Preserves your Claude credentials, settings, projects and existing command until you explicitly link it.

This is a **Claude Code lifecycle manager**, not a general agent runtime. It does not provide model access or make Android an officially supported Anthropic platform. [Architecture and limits →](docs/architecture.md)

## Install

Run this in a **native Termux shell on an ARM64 Android device**:

```sh
curl -fsSL https://github.com/octocore-autonomous-systems/termux-muscle/releases/download/v0.1.0/install.sh | sh
```

The installer adds missing Termux prerequisites with `pkg`, verifies the release's source archive, builds the C helper locally and runs its offline tests before installation. Bash manages the lifecycle; the helper uses json-c, libarchive and OpenSSL. Build and test tools are Clang, make, pkg-config and diffutils; tar and gzip unpack the source. Runtime tools are Bash, PRoot, coreutils, ripgrep, curl and CA certificates. The project requires no Python, npm or Ubuntu installation.

Local compilation requires downloading a C toolchain when one is not already installed. It builds our helper against your Termux environment; Anthropic's proprietary Claude Code executable is downloaded separately and remains unmodified.

The manager command is installed in `~/.local/bin`. Add that directory to this shell's path, then start Claude Code and use its normal authentication flow:

```sh
export PATH="$HOME/.local/bin:$PATH"
termux-muscle run -- auth login
termux-muscle run
```

To use the familiar `claude` command, explicitly opt into linking it:

```sh
termux-muscle link
claude
```

An existing foreign `claude` command is preserved unless you request replacement. Read `termux-muscle link --help` for that case. To inspect the bootstrap before running it, download the same `install.sh` URL to a file, read it, then run `sh install.sh`.

## Everyday use

| Task | Command |
| --- | --- |
| Run Claude with its own arguments | `termux-muscle run -- --model claude-fable-5-1` |
| Inspect installed and retained releases | `termux-muscle versions` |
| Check installation health | `termux-muscle doctor` |
| Install the version tested for this project release | `termux-muscle update` |
| Restore the previous local release | `termux-muscle rollback` |
| Rebuild from verified cached downloads | `termux-muscle repair --offline` |
| Update this management tool | `termux-muscle self-update` |
| Write a device report for review | `termux-muscle test --output report.json` |
| Remove this installation and its managed links | `termux-muscle uninstall` |

Default updates stay with the project's tested compatibility manifest. An explicitly requested upstream version is experimental until tested on your device; see `update --help`. Installation and ordinary health checks make no paid model requests. Uninstall preserves Claude account data, settings, sessions and your projects.

## Device compatibility

A configuration is **device + Android/API + Termux build**, with ABI, kernel, page size and dependency versions in its report. Android version affects available system interfaces; hardware and vendor firmware can change the kernel and process behavior. Neither dimension alone proves compatibility.

The capability matrix grows only when someone supplies a report. **PASS** means that named check passed; **FAIL** means it failed; **SKIP** means untested. A maintainer report is distinguished from a community report.

| Tested configuration | Install | Start | Shell/tools | Update | Rollback | Removal | Evidence |
| --- | :---: | :---: | :---: | :---: | :---: | :---: | --- |
| Samsung Galaxy S26 Ultra · SM-S948U · Android 16 / API 36 · Termux 0.118.3 (GitHub) | PASS | PASS | PASS | PASS | PASS | PASS | [Maintainer report](compatibility/galaxy-s26-ultra-20260914.md) · [JSON](compatibility/galaxy-s26-ultra-20260914.json) |

This row records tests of Termux Muscle's Bash/C implementation and original vendor runtime. Reports include exact Claude Code, loader, compiler, C libraries, PRoot, Bash, ripgrep and relevant package versions. See [testing](docs/testing.md) for what each check means. Background/screen-off behavior and actual MCP tool calls remain untested; the default cross-session messaging socket was disabled by the vendor's UID-mapping check on this host.

**Have a different phone, tablet, Android release or Termux version? Please help test.** We especially need other manufacturers, Android/kernel releases, 4 KiB and 16 KiB page-size devices, and different Termux distributions/builds.

```sh
termux-muscle test --output report.json
```

Review the local JSON, then [open a Device compatibility issue](https://github.com/octocore-autonomous-systems/termux-muscle/issues/new?template=device-compatibility.yml) and attach or paste it. Nothing is uploaded automatically. The report uses an allowlist of platform details and check results; do not add tokens, complete environment dumps or private session logs. No account is needed for the default checks. An explicit `--model MODEL_ID` test uses your authenticated account and may incur usage.

## Claude Code and models

Project versions and Claude Code versions are separate. The **0.1.0** manifest pins **Claude Code 2.1.270**, with musl **1.2.6-r2**. [compatibility.json](compatibility.json) is the machine-readable record; each release includes matching notes and checksums.

| Documented model | Model ID | Minimum Claude Code |
| --- | --- | --- |
| Fable 5.1 | `claude-fable-5-1` | 2.1.257 |
| Opus 5 | `claude-opus-5` | 2.1.219 |
| Sonnet 5 | `claude-sonnet-5` | 2.1.197 |

Model documentation checked **2026-09-14** against [Anthropic's model configuration documentation](https://code.claude.com/docs/en/model-config). **Sonnet 5 and Opus 5 passed exact authenticated checks.** Fable 5.1 answered a direct launcher check, while automated probes triggered upstream fallback/refusal; those failures remain visible in the [report](compatibility/galaxy-s26-ultra-20260914.md#model-observations). Availability depends on your account, provider and organization policy.

## Help build something dependable

Bug reports, device evidence and small fixes are welcome. [CONTRIBUTING.md](CONTRIBUTING.md) explains branch names, tests and pull requests. The [engineering record](docs/engineering.md) describes how we use ELO to connect decisions, defects and acceptance evidence. ELO is optional for contributors and is not an installation or runtime dependency.

Our source is [MPL-2.0](LICENSE). Claude Code and separately downloaded dependencies retain their own licenses and terms. We learned from several existing Termux projects and the musl approach documented by Khronos31; see [CREDITS.md](CREDITS.md).
