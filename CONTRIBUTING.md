# Contributing

Help is welcome with device tests, reproducible bug reports, documentation and code. You do not need an ELO account or installation. First read the [architecture](docs/architecture.md) and [testing guide](docs/testing.md) for the behavior a change must preserve.

## Report a device or bug

Run `termux-muscle test --output report.json`, review the file, then attach it to a [Device compatibility issue](https://github.com/octocore-autonomous-systems/termux-muscle/issues/new?template=device-compatibility.yml). Mark checks you did not run as SKIP. Add a short description of any manual test; do not infer working tools from a successful version check.

For a bug, use the [Bug report form](https://github.com/octocore-autonomous-systems/termux-muscle/issues/new?template=bug-report.yml), include the failing command and a sanitized error, and say what you expected. Never include OAuth tokens, API keys, Claude settings files, complete environment dumps or private conversations. Reports are public.

## Make a change

Fork the repository, clone your fork and create a narrow branch from current `main`:

```sh
git clone https://github.com/YOUR-ACCOUNT/termux-muscle.git
cd termux-muscle
git remote add upstream https://github.com/octocore-autonomous-systems/termux-muscle.git
git fetch upstream
git switch -c fix/recover-interrupted-update upstream/main
```

Use lowercase words separated by hyphens after one of these prefixes:

| Prefix | Purpose | Example |
| --- | --- | --- |
| `feat/` | New behavior | `feat/device-report-export` |
| `fix/` | Correct a defect | `fix/live-dns-selection` |
| `docs/` | Documentation | `docs/samsung-test-guide` |
| `test/` | Tests or device evidence | `test/pixel-android-16` |
| `chore/` | Build or maintenance | `chore/compiler-ci-matrix` |

One bug or coherent feature per PR is easier to review. Discuss a new runtime backend or a behavior change that affects existing installations before doing substantial work.

## C and header formatting

Use **clang-format 21** with the committed `.clang-format` for both `.c` and `.h` files. On Termux it is included in `pkg install clang`. Check `clang-format --version`; other major versions can produce different results. If needed, select a specific executable with `CLANG_FORMAT=clang-format-21 make check-format`.

Before enabling the repository's pre-commit hook, inspect any existing hook configuration:

```sh
git config --get core.hooksPath
```

The command prints any existing hook directory (and exits 1 if none is configured). Also check for active hooks in `.git/hooks`. If you already use hooks, keep them and call `bash scripts/check_format.sh --staged` from your existing pre-commit hook instead of replacing its configuration. Otherwise, enable this hook once per clone:

```sh
git config --local core.hooksPath .githooks
```

Git does not enable repository hooks automatically.

The hook checks the exact staged C/header contents against the staged formatting configuration, including partially staged files. A style change checks all staged C/header files. It rejects formatting errors without rewriting or staging anything. Documentation-only commits do not need the formatter. To fix a file, format it explicitly, review the diff, then stage only the intended changes:

```sh
clang-format -i --style=file src/example.c src/example.h
git diff
git add src/example.c src/example.h
make check-format
```

Replace the example paths with files you changed. `make check-format` checks tracked working-tree files; add newly created files before running it. CI runs the same check with clang-format 21. Developer hook regressions run with `make check-format-tooling`. These contributor checks require Git and clang-format; installing and running Termux Muscle does not.

Formatting covers layout. Compiler warnings and the regression suite check separate classes of defects. For shell contributions, **ShellCheck** finds likely bugs and **shfmt** formats shell syntax; neither substitutes for the C formatter.

## Validate and open a PR

Build with a C11 compiler, make, pkg-config and development files for json-c, libarchive and OpenSSL. The C and Bash suite needs no account, network or Python:

```sh
make
make check
bash scripts/build_release.sh --output dist
```

Run the source CLI with `bash bin/termux-muscle --help`. The installed launcher uses your Termux Bash path; `/usr/bin/env` is not assumed to exist on Android.

For shell/bootstrap, storage, download or runtime changes, add a regression that reproduces the original failure and checks recovery behavior. Use temporary roots; tests must not change your real launchers, credentials or Claude installation. See [testing.md](docs/testing.md) for device and authenticated tests.

Commit and push your branch, then open a PR in the browser or with GitHub CLI:

```sh
git add PATHS-YOU-CHANGED
git commit -m "Fix recovery after an interrupted update"
git push -u origin fix/recover-interrupted-update
gh pr create --repo octocore-autonomous-systems/termux-muscle --base main --fill
```

Explain the concrete failure and resulting behavior, link any issue, and state what you actually tested. Separate deterministic tests from device tests and paid-model tests. If you could not test something, say so. A maintainer will review the change and compatibility evidence before merging.

## Source, dependencies and releases

Contributions to this project's source are under [MPL-2.0](LICENSE). Preserve notices and identify borrowed code, its source and its license in the PR. Do not commit vendor binaries, credentials, personal paths or private logs. Keep dependencies small and deliberate; use the existing C libraries for JSON, archive and cryptographic parsing rather than adding custom parsers.

Maintainers use semantic versions independently of Anthropic's releases. A release updates `VERSION`, installer version, `compatibility.json`, changelog, device evidence and release notes together. The C helper's version is supplied by the build from `VERSION`. Contributors normally leave release numbering to maintainers. See [releasing.md](docs/releasing.md) for the release gate.
