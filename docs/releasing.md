# Releasing

Project releases use [Semantic Versioning](https://semver.org/), independently of Claude Code's version. Tag releases `vMAJOR.MINOR.PATCH`.

## When to release

Release when Termux Muscle itself changes. A new Claude Code version is not a reason: installations follow Anthropic's release channel and admit each version on Anthropic's signature, so `termux-muscle update` reaches it without us. From 0.8.0 to 0.20.0 the project cut a release for every upstream build, thirteen in eleven days, none of which changed the harness; that practice ended with channel-following updates.

Each release still names one Claude Code version as its pin: the version its device acceptance ran against, installable offline and with `--claude-version pinned`. Move the pin to the current upstream release when cutting a release for another reason, so the tested baseline stays close to what installations run. A release that only moves the pin is worth cutting in two cases: an upstream change breaks installation or startup and needs a harness fix anyway, or the pin has aged so far that a fresh installation with `--claude-version pinned` is no longer useful.

## Required evidence

Every release states:

- The exact Claude Code and musl versions selected by default, with official source URLs and digests.
- The date and official source for documented model IDs and required client versions.
- Which models were actually checked, with observed IDs, and the account-entitlement limitation.
- The exact tested device, Android/API, Termux build/source, kernel, page size and relevant package versions.
- Known limitations, FAIL/SKIP outcomes and meaningful changes since the previous release.

Update `VERSION`, the embedded `install.sh` version and `compatibility.json` together. `compatibility.json` also names the release's default backend and, for the native backend, pins the SHA-256 of the configured musl loader (`musl.native_loader_sha256`); when the loader pin changes, extract the new loader, check it against `musl.loader_sha256`, and run `build/tm-core native-loader-sha256 LOADER` to obtain the value to pin.

When the Claude Code pin moves, append the outgoing pin to `pin_history` in the same commit:
its exact version, `project_versions.first` and `.last` (the project releases that pinned it),
`verified_on` and the `report` of the last of those releases, which must be a maintainer report
passing every required lifecycle check. Set `claude.pinned_since` to the new project version. The
release gate refuses a manifest whose history leaves any `docs/releases/X.Y.Z.md` older than
`pinned_since` uncovered, so a moved pin cannot silently drop a verified version. Make supplies the C helper version from `VERSION`. Add the versioned `CHANGELOG.md` entry. Update the [device compatibility matrix](device-compatibility.md) only from reviewed evidence. A newer upstream model announcement is not an authenticated compatibility result.

## Build and verify

Run the deterministic suite and then device acceptance using an isolated installation as described in [testing.md](testing.md):

```sh
make check
bash scripts/build_release.sh --output dist --release
```

The release build rejects inconsistent versions, missing notices/model metadata, or missing qualifying device evidence. A development build without `--release` is useful while preparing acceptance; its generated notes explicitly do not assert device acceptance. Do not publish it as a verified release.

Artifacts are `termux-muscle-VERSION.tar.gz` containing project source, `install.sh`, `compatibility.json`, generated `RELEASE_NOTES.md` and `SHA256SUMS`. Verify that no vendor executable, credential, private log or personal path has entered the source or release. Build the same commit twice and compare source-archive checksums. Installed helpers are compiled locally; binary reproducibility across different toolchains is not claimed. Do not mutate release assets after publishing; fix a release with a new semantic version.

## Maintainer helpers

Two scripts cover the steps after publication. Each checks its own preconditions, stops at the first failure and never commits, tags or publishes. Both need an untraced shell: a native Termux shell, or a Claude Code session on the native backend.

| Step | Command | Effect |
| --- | --- | --- |
| Verify publication | `bash scripts/release_public_verify.sh P LOCAL_SHA256SUMS OUT` | Compares the public assets with the local build and runs the public installer in a disposable root, proving the live installation unchanged. |
| Upgrade the device | `bash scripts/release_live_upgrade.sh P OUT` | Runs `self-update`, follows the release channel with `update`, moves the active Claude Code version to the release's default backend if it is on the other one, and records versions and `doctor`. |

The preparation and registration edits are made by hand and reviewed: `VERSION`, the installer's `VERSION=`, the manual's `.TH` line, `compatibility.json`, the changelog, `docs/releases/VERSION.md`, the README banner and install URL, and the [device compatibility matrix](device-compatibility.md) row and footnote. `python3 -B scripts/readme_compatibility.py` regenerates the README's release and model tables from the manifest and the release-note filenames; add `--check` to detect stale tables. `python3 -B scripts/cli_schema.py` regenerates the CLI help and completion files. Both are maintainer tools; installation requires no Python.

Scripts that wrote those edits for pin-only releases (`release_prepare.py`, `release_register.py`, `release_validate.sh`) were removed with the practice they served. They are in the history up to 0.20.0.

## Publish

Use the reviewed source commit after both branch CI compiler jobs pass. Add reviewed human notes at `docs/releases/VERSION.md`; they are combined with the generated, verified metadata on the release page. Preserve mixed model results, failed features and untested workflows explicitly.

Then push a matching annotated tag. For example, after device acceptance and the branch checks pass:

```sh
git tag -a v0.1.0 -m "Release 0.1.0"
git push origin main v0.1.0
```

The tag starts a fresh GCC/Clang matrix. The `Publish verified tag` job depends on the entire matrix and receives release write permission only after its success condition is satisfied. `scripts/publish_release.sh` independently verifies that this exact workflow attempt has one completed successful GCC job and one completed successful Clang job for the checked-out commit. It rejects branch/manual/PR contexts, tag/version mismatches, changed checkouts, missing or failed jobs, and a remote tag that differs from the tested commit. It builds strict release assets from that checkout, verifies their checksums, rechecks the remote tag, and creates the release without overwriting existing releases or assets.

Use this automated publication path; do not substitute a manual `gh release create` command. GitHub administrators can still bypass repository automation manually, so this is a guarantee of the documented workflow, not a claim that administrators have lost their GitHub permissions. A failing, cancelled, skipped or incomplete matrix cannot reach the workflow's publication job. GitHub's [job dependency semantics](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax#jobsjob_idneeds) underpin that dependency; the publisher also checks the live job evidence.

Inspect the public repository visibility, tag, release notes and downloaded asset hashes. Then test the actual public `curl ... | sh` path on Termux with an isolated root. A successful local build does not prove the public asset names, redirects or install command are correct. Record that result in the release engineering evidence.

## Maintenance policy

Installations follow Anthropic's download channel (`https://downloads.claude.ai/claude-code-releases/latest`, the version `claude update` installs on supported platforms). The channel can lead npm's `latest` tag by hours; `update` then reports that the package is not yet available and the next attempt succeeds. The ARM64 musl package is still acquired from npm and verified against the registry's SHA-512 integrity, and its executable against the SHA-256 in Anthropic's signed manifest. A version Anthropic withdraws is replaced by the next release; `termux-muscle rollback` restores the previous runtime meanwhile.

No job in this repository watches upstream. The scheduled tracker that opened a testing issue for every new Claude Code version was removed: nothing waits on such an issue any more. To keep a device current, run `termux-muscle update` on whatever schedule suits it; the command changes nothing when the active release is current.

Candidate checks run before activation, on every device, for every version. Preserve a rollback option and bound retained storage without deleting a leased release. A failed check is a reason to keep the working runtime, not to lower the gate.

If an upstream release changes package format, loader requirements, subprocess behavior or its signing key, signed installs or candidate checks fail closed on devices and the pin stays installable. Fix the harness, add a regression and fresh device evidence, and release. An urgent fix still needs evidence for the behavior it changes.

Record release decisions and acceptance evidence in the project's engineering records. Publish sanitized summaries that omit credentials, private paths and raw conversations.
