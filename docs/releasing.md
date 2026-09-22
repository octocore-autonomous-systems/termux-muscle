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

The [upstream release tracker](release-tracking.md) checks npm every six hours
and proposes newer observed releases through deduplicated testing issues. These
contain registry metadata, not compatibility approval. Resolve candidates through
the existing device-evidence and release gates; the tracker never advances the
pin or publishes a release.

Prefer a tested upstream pin to an unattended upgrade that silently changes compatibility. Candidate checks must run before activation. Preserve a rollback option and bound retained storage without deleting a leased release. A failed check is a reason to keep the working runtime, not to lower the gate.

If an upstream release changes package format, loader requirements, subprocess behavior or model selection, add a regression and fresh device evidence before calling it supported. Explicit experimental-version installation remains labeled as such. An urgent fix still needs evidence for the behavior it changes.

Record release decisions and acceptance evidence in the project's engineering records. Publish sanitized summaries that omit credentials, private paths and raw conversations.
