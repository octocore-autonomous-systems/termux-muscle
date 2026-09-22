# Testing and device reports

There are three different kinds of evidence: deterministic regression tests, device checks and authenticated model/workflow tests. Keep them separate in issues, PRs and release notes.

The [0.2.0 Samsung Galaxy S26 Ultra report](../compatibility/galaxy-s26-ultra-0.2.0-20260915.md) contains fresh native command/manual and runtime lifecycle observations plus a separate authenticated Sonnet tool workflow. It distinguishes that actual Claude tool evidence from the local namespace probe, and source bootstrap from public installer delivery. The unchanged 2026-09-14 report identifies project 0.1.0 and retains that release's paid workflow/model observations.

## One-command volunteer report

After installation, run:

```sh
termux-muscle test --output report.json
```

This writes a local report using safe checks. It does not upload anything, change your credentials or intentionally uninstall your working installation. Review the JSON and attach it to a [Device compatibility issue](https://github.com/octocore-autonomous-systems/termux-muscle/issues/new?template=device-compatibility.yml). A failure is useful evidence too; include the error category and what you were trying to do.

We welcome other manufacturers, phones and tablets, Android versions, vendor kernels, page sizes and Termux versions/distributions. No account or coding experience is needed for the default checks. Do not change a missing result to PASS because a nearby check passed.

The report records only the allowed compatibility fields: manufacturer/model, Android version and API, ABI, kernel, page size, Termux version/source, project and Claude Code versions, relevant package versions, and check outcomes. It does not need your serial number, network addresses, private filesystem paths, environment, account configuration, prompts or session history. Review any extra material you attach yourself.

## What the matrix means

| Capability | Evidence required |
| --- | --- |
| Install | A fresh isolated installation completes. State whether it used source bootstrap, a packaged archive or the published HTTPS pipeline; these are distinct delivery checks. |
| Start | The selected executable reports the expected version and produces help successfully. |
| Shell namespace | A real runtime probe exercises mapped shell, portable shebang and native file tools. This alone is not Claude tool execution. |
| Claude tools (`shell_tools`) | Actual authenticated Claude tool events show the intended shell and file operations working. |
| Manual | The indexed regular page is discovered through `man termux-muscle`, refreshed and removed with the tested ownership behavior. |
| Update | A candidate passes checks and is activated without breaking the retained installation. |
| Rollback | A previous local release is restored and starts without a download. |
| Removal | Uninstall removes owned files and restores eligible links while preserving unrelated data. |

Every check has an ID and **PASS**, **FAIL** or **SKIP**. Reports distinguish maintainer and community provenance. The default volunteer command cannot prove all the installation lifecycle steps above; untouched steps remain SKIP. Maintainer acceptance performs these steps using an isolated root and deliberate failure fixtures.

A report for one exact configuration does not certify all versions of that phone, Android or Termux. When any of them changes, preserve the old report and add a new dated one.

For 0.2.0, installation evidence must also show that an ordinary `claude --version` selects the accepted runtime and that `man termux-muscle` discovers the installed page. A direct invocation of the owned runtime or a manual by full pathname does not prove normal command or manual discovery.

## Optional authenticated checks

Use a model you are entitled to access:

```sh
termux-muscle test --model claude-fable-5-1 --output report.json
```

This explicitly permits a model request and may incur usage on your account. The result must identify the requested and observed model. Documented model availability is distinct from a successful authenticated check. Never add OAuth tokens or API keys to a public report.

Interactive TUI, terminal resizing, hooks, nested invocations, MCP transports and custom workflows should be reported separately with exact steps. Describe hooks and servers with harmless fixtures rather than publishing production configuration. Record each integration's version, expected event and actual result; a passing fixture demonstrates only the integration exercised.

## Deterministic tests for contributors

From a checkout with a C11 compiler, make, pkg-config, json-c, libarchive and OpenSSL development files, plus Bash, coreutils, diffutils, tar and gzip (and `mandoc` for manual rendering/integration):

```sh
make
make check
bash scripts/build_release.sh --output dist
```

The C and Bash unit/regression suite uses temporary directories, fake downloads and subprocess fixtures. It needs no account and makes no network or model requests. Bootstrap tests execute the actual shell script with a mocked platform and package manager. Release tests inspect real generated source archives, checksums and release-gate behavior. No Python test runner or fixture generator is required.

GitHub Actions checks the C/Bash suite with GCC and Clang on Linux and compares repeated source builds. Release tags must also pass the device-evidence gate. Linux CI is a separate result from Android device acceptance.

Regression coverage includes checksum failures, invalid archives, interrupted downloads, hostile paths, launcher ownership, update interruption, mutation locks, leased releases, stale DNS, nested contexts, rollback and removal. Assertions should test the user-visible outcome and recovery, not repeat the implementation.

New command/manual regressions must cover the normal executable PATH winner, prefix/home entries, reruns and opt-outs; foreign manager/manual preservation; regular-manual content/mode ownership; interrupted replacement; targeted manual-index refresh/removal; and rejecting old-manager self-update before download/publication. None of these checks requires account or model usage.

## Maintainer device acceptance

Use dedicated disposable root, home and command/manual destinations. Normal 0.2.0 installation claims executable Claude entries, so a disposable data root alone does not isolate that behavior: the prefix, home-bin and executable PATH winner must all be controlled fixtures. Use `--no-link` for runtime-only checks that still share a real command prefix, and test automatic takeover separately with disposable commands. Record the exact installed package versions and source commit. Exercise the public bootstrap, `claude --version`, help, interactive session, shell/shebang and file tools, nested execution, optional package-manager/MCP fixtures, update failure, successful update, rollback, offline repair and uninstall.

Include sentinel files outside the owned root and a foreign launcher fixture so removal proves preservation, not just deletion. Check original vendor hashes. Exercise signal handling and interrupted maintenance using bounded fixtures. Review reports before committing them.

For automatic command setup, place an executable Claude fixture ahead of the prefix in PATH and preserve originals at all supported entries. Confirm takeover follows candidate validation, that failed validation leaves those commands intact, and that clean uninstall restores original bytes/modes or literal symlink targets. Change a managed entry afterward and confirm uninstall preserves the foreign replacement and recovery evidence. Test `--no-link` and management-only `--no-install` explicitly. A child process cannot clear its parent's shell hash, alias or function; document that boundary rather than recording universal shell takeover.

For the manual, use a disposable manual tree and index. Check regular-file installation, discovery through `man termux-muscle`, updated page content after self-update, targeted index behavior, preservation of a pre-existing foreign manual and preservation of a later replacement. Clean uninstall must remove the owned page and its index entry while preserving unrelated pages and installed dependencies. Record the actual `mandoc` package version in device evidence.

Management self-update must preserve the runtime state bytes. A 0.2.0 `self-update --version` request below 0.2.0 must fail before invoking the old installer. Do not confuse that tested guard with direct execution of an old installer, which is unsupported and can bypass it, or with the supported previous-runtime `rollback` command.

The release gate requires a matching maintainer report with PASS for `install`, `startup_version`, `startup_help`, `shell_tools`, `update`, `rollback` and `uninstall`, plus exact platform/software metadata. It rejects stale project/runtime versions and missing, skipped or failed required checks. Release assertions remain the maintainer's responsibility: a JSON label cannot replace the actual test run.

The manifest references only the matching 0.2.0 report; the retained 0.1.0 report cannot satisfy a new release's required checks. A namespace probe must not turn `shell_tools` into PASS: the recorded 0.2.0 PASS comes from the separate actual Sonnet-issued tool call and independently checked result. Prior Opus and mixed Fable observations remain dated historical evidence and are not relabeled as new model checks.

## Isolated startup acceptance

Unreleased source adds `startup_init` alongside `startup_version` and `startup_help`.
Install, update, repair and rollback require all three before activation; doctor/test use
these same checks. Historical 0.1.0/0.2.0 reports are not retroactively upgraded.

The helper runs the verified vendor payload with an allowlisted environment, private HOME,
CLAUDE_CONFIG_DIR/XDG directories and working directory. Resolver and certificate overrides
are retained, but credentials, shell injection, loader workarounds and provider overrides
are not. Initialization uses `--init-only`, safe mode, empty setting sources and MCP config,
disabled hooks and tools, and no prompt. The [upstream CLI reference](https://code.claude.com/docs/en/cli-reference)
defines init-only as exiting without a conversation. Unsupported flags fail closed rather
than silently weakening the check. Help does not list every supported flag.

Safe mode still honors managed hooks. Presence of `/etc/claude-code` (including inaccessible
or linked entries) therefore rejects automatic acceptance with `managed_policy_requires_review`.
The manager does not remove or bypass an organization's policy. This guard applies to
acceptance checks, not ordinary launches of an already installed runtime.

Each probe has a 30-second deadline and 64 KiB captured-output limit, with null stdin and
discarded stderr. Reports contain fixed result codes, never raw startup output. No paid model
request is made. This is configuration isolation, **not a network or filesystem sandbox**.
The payload can still use its release-owned runtime temporary directory. Candidate scratch
is removed by the lifecycle shell trap; interrupted doctor probes or forced SIGKILL may leave
private scratch under the selected prefix's temporary directory. Normal cleanup removes only
the freshly allocated probe tree.

A PASS demonstrates isolated non-conversational initialization on this configuration, not
normal user hooks/settings, full interactive operation, DNS reachability, authenticated tools,
MCP calls, background survival or another device. Use the separate `migration` advisory command
for existing configuration conflicts. Existing core state receipts remain readable; do not use
internal `state` commands to bypass the public candidate gate.

Regression fixtures cover successful version/help followed by failed init, signals, timeout,
output overflow, inherited secret/configuration stripping and current-state/command preservation.
Device acceptance must additionally execute the original pinned payload and verify that fixture
hooks and MCP commands in the caller's configuration were not invoked.
