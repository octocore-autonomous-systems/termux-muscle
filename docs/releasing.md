# Releasing

Project releases use [Semantic Versioning](https://semver.org/), independently of Claude Code's version. Tag releases `vMAJOR.MINOR.PATCH`. Describe user-visible compatibility changes in the changelog; do not imply a new project release always installs the newest upstream client.

## Required evidence

Every release states:

- The exact Claude Code and musl versions selected by default, with official source URLs and digests.
- The date and official source for documented model IDs and required client versions.
- Which models were actually checked, with observed IDs, and the account-entitlement limitation.
- The exact tested device, Android/API, Termux build/source, kernel, page size and relevant package versions.
- Known limitations, FAIL/SKIP outcomes and meaningful changes since the previous release.

Update `VERSION`, the embedded `install.sh` version and `compatibility.json` together. Make supplies the C helper version from `VERSION`. Add the versioned `CHANGELOG.md` entry. Update README's device matrix only from reviewed evidence. A newer upstream model announcement is not an authenticated compatibility result.

## Build and verify

Run the deterministic suite and then device acceptance using an isolated installation as described in [testing.md](testing.md):

```sh
make check
bash scripts/build_release.sh --output dist --release
```

The release build rejects inconsistent versions, missing notices/model metadata, or missing qualifying device evidence. A development build without `--release` is useful while preparing acceptance; its generated notes explicitly do not assert device acceptance. Do not publish it as a verified release.

Artifacts are `termux-muscle-VERSION.tar.gz` containing project source, `install.sh`, `compatibility.json`, generated `RELEASE_NOTES.md` and `SHA256SUMS`. Verify that no vendor executable, credential, private log or personal path has entered the source or release. Build the same commit twice and compare source-archive checksums. Installed helpers are compiled locally; binary reproducibility across different toolchains is not claimed. Do not mutate release assets after publishing; fix a release with a new semantic version.

## Publish

Use the reviewed source commit, passing CI and a matching tag. For example, after the version has been chosen and the complete gate passes:

```sh
git tag -a v0.1.0 -m "Release 0.1.0"
git push origin main v0.1.0
gh release create v0.1.0 dist/termux-muscle-0.1.0.tar.gz dist/install.sh dist/compatibility.json dist/RELEASE_NOTES.md dist/SHA256SUMS --verify-tag --title "0.1.0 — Claude Code 2.1.270" --notes-file dist/RELEASE_NOTES.md
```

Inspect the public repository visibility, tag, release notes and downloaded asset hashes. Then test the actual public `curl ... | sh` path on Termux with an isolated root. A successful local build does not prove the public asset names, redirects or install command are correct. Record that result in the release engineering evidence.

## Maintenance policy

Prefer a tested upstream pin to an unattended upgrade that silently changes compatibility. Candidate checks must run before activation. Preserve a rollback option and bound retained storage without deleting a leased release. A failed check is a reason to keep the working runtime, not to lower the gate.

If an upstream release changes package format, loader requirements, subprocess behavior or model selection, add a regression and fresh device evidence before calling it supported. Explicit experimental-version installation remains labeled as such. An urgent fix still needs evidence for the behavior it changes.

Maintainers record release decisions and acceptance evidence through ELO. Public engineering records are sanitized summaries; ELO does not need to run on contributor machines or user devices.
