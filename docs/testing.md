# Testing and device reports

There are three different kinds of evidence: deterministic regression tests, device checks and authenticated model/workflow tests. Keep them separate in issues, PRs and release notes.

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
| Install | The packaged installer completes in a fresh isolated installation. |
| Start | The selected executable reports the expected version and produces help successfully. |
| Shell/tools | Actual Claude tool events show the intended shell and file operations working. |
| Update | A candidate passes checks and is activated without breaking the retained installation. |
| Rollback | A previous local release is restored and starts without a download. |
| Removal | Uninstall removes owned files and restores eligible links while preserving unrelated data. |

Every check has an ID and **PASS**, **FAIL** or **SKIP**. Reports distinguish maintainer and community provenance. The default volunteer command cannot prove all the installation lifecycle steps above; untouched steps remain SKIP. Maintainer acceptance performs these steps using an isolated root and deliberate failure fixtures.

A report for one exact configuration does not certify all versions of that phone, Android or Termux. When any of them changes, preserve the old report and add a new dated one.

## Optional authenticated checks

Use a model you are entitled to access:

```sh
termux-muscle test --model claude-fable-5-1 --output report.json
```

This explicitly permits a model request and may incur usage on your account. The result must identify the requested and observed model. Documented model availability is distinct from a successful authenticated check. Never add OAuth tokens or API keys to a public report.

Interactive TUI, terminal resizing, hooks, nested invocations, MCP transports and custom workflows should be reported separately with exact steps. Describe hooks and servers with harmless fixtures rather than publishing production configuration. An optional ELO hook check can demonstrate a concrete local hook invocation; ELO is not needed for general compatibility testing.

## Deterministic tests for contributors

From a checkout with a C11 compiler, make, pkg-config, json-c, libarchive and OpenSSL development files, plus Bash, coreutils, diffutils, tar and gzip:

```sh
make
make check
bash scripts/build_release.sh --output dist
```

The C and Bash unit/regression suite uses temporary directories, fake downloads and subprocess fixtures. It needs no account and makes no network or model requests. Bootstrap tests execute the actual shell script with a mocked platform and package manager. Release tests inspect real generated source archives, checksums and release-gate behavior. No Python test runner or fixture generator is required.

GitHub Actions checks the C/Bash suite with GCC and Clang on Linux and compares repeated source builds. Release tags must also pass the device-evidence gate. Linux CI is a separate result from Android device acceptance.

Regression coverage includes checksum failures, invalid archives, interrupted downloads, hostile paths, launcher ownership, update interruption, mutation locks, leased releases, stale DNS, nested contexts, rollback and removal. Assertions should test the user-visible outcome and recovery, not repeat the implementation.

## Maintainer device acceptance

Use a dedicated disposable root. Do not replace the real `claude` link during acceptance. Record the exact installed package versions and source commit. Exercise the public bootstrap, version/help/init, interactive session, shell/shebang and file tools, nested execution, optional package-manager/MCP fixtures, update failure, successful update, rollback, offline repair and uninstall.

Include sentinel files outside the owned root and a foreign launcher fixture so removal proves preservation, not just deletion. Check original vendor hashes. Exercise signal handling and interrupted maintenance using bounded fixtures. Review reports before committing them.

The release gate requires a matching maintainer report with PASS for `install`, `startup_version`, `startup_help`, `shell_tools`, `update`, `rollback` and `uninstall`, plus exact platform/software metadata. It rejects stale project/runtime versions and missing, skipped or failed required checks. Release assertions remain the maintainer's responsibility: a JSON label cannot replace the actual test run.
