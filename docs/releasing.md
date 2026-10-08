# Releasing

Project releases use [Semantic Versioning](https://semver.org/), independently of Claude Code's version. Tag releases `vMAJOR.MINOR.PATCH`. Describe user-visible compatibility changes in the changelog; do not imply a new project release always installs the newest upstream client.

## Required evidence

Every release states:

- The exact Claude Code and musl versions selected by default, with official source URLs and digests.
- The date and official source for documented model IDs and required client versions.
- Which models were actually checked, with observed IDs, and the account-entitlement limitation.
- The exact tested device, Android/API, Termux build/source, kernel, page size and relevant package versions.
- Known limitations, FAIL/SKIP outcomes and meaningful changes since the previous release.

Update `VERSION`, the embedded `install.sh` version and `compatibility.json` together.

When the Claude Code pin moves, append the outgoing pin to `pin_history` in the same commit:
its exact version, `project_versions.first` and `.last` (the project releases that pinned it),
`verified_on` and the `report` of the last of those releases, which must be a maintainer report
passing every required lifecycle check. Set `claude.pinned_since` to the new project version. The
release gate refuses a manifest whose history leaves any `docs/releases/X.Y.Z.md` older than
`pinned_since` uncovered, so a moved pin cannot silently drop a verified version. Make supplies the C helper version from `VERSION`. Add the versioned `CHANGELOG.md` entry. Update README's device matrix only from reviewed evidence. A newer upstream model announcement is not an authenticated compatibility result.

## Build and verify

Run the deterministic suite and then device acceptance using an isolated installation as described in [testing.md](testing.md):

```sh
make check
bash scripts/build_release.sh --output dist --release
```

The release build rejects inconsistent versions, missing notices/model metadata, or missing qualifying device evidence. A development build without `--release` is useful while preparing acceptance; its generated notes explicitly do not assert device acceptance. Do not publish it as a verified release.

Artifacts are `termux-muscle-VERSION.tar.gz` containing project source, `install.sh`, `compatibility.json`, generated `RELEASE_NOTES.md` and `SHA256SUMS`. Verify that no vendor executable, credential, private log or personal path has entered the source or release. Build the same commit twice and compare source-archive checksums. Installed helpers are compiled locally; binary reproducibility across different toolchains is not claimed. Do not mutate release assets after publishing; fix a release with a new semantic version.

## Pin-move helpers

When a release only moves the Claude Code pin, five maintainer scripts do the mechanical steps.
Each checks its own preconditions, stops at the first failure, and never commits, tags or
publishes. They are written for the maintainer's reference device and an Opus 5.5 model check;
review every diff they produce.

| Step | Command | Effect |
| --- | --- | --- |
| Validate the candidate | `bash scripts/release_validate.sh X OUT` | Installs Claude Code X through the unverified-version path, runs `doctor` and one authenticated model test, and matches the cached npm archive and extracted executable to the registry and install receipt. Prints the two digests. |
| Prepare | `python3 -B scripts/release_prepare.py P X INTEGRITY BINARY_SHA256 WHY_FILE` | Writes the version, installer, manual, manifest (including `pin_history`), changelog, release note and README edits for a release whose device evidence is still pending. |
| Register | `python3 -B scripts/release_register.py` | After `make check` and `scripts/maintainer_acceptance.sh` pass from the clean preparation commit, renames the report, writes its notes and fills the manifest, README, changelog and release note from the report. |
| Verify publication | `bash scripts/release_public_verify.sh P LOCAL_SHA256SUMS OUT` | Compares the public assets with the local build and runs the public installer in a disposable root, proving the live installation unchanged. |
| Upgrade the device | `bash scripts/release_live_upgrade.sh P X OUT` | Runs `self-update`, re-registers X as the project pin, and records versions and `doctor`. |

The shell helpers need a native, untraced Termux shell. `release_register.py` writes that the
release changes no harness code and that the deterministic suite skipped only the optional host
probes and the cross-UID fixture; edit those sentences when either is untrue. The "Why" paragraph
in `WHY_FILE` is always written by hand from the upstream release notes.

`python3 -B -m unittest discover -s tests/dev -p 'test_release_helpers.py' -v` replays the next
pin move on a copy of the tree. It fails when an edit removes a README, changelog or manifest
anchor the helpers depend on.

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

Since 0.18.0 the maintainer moves the pin when Anthropic's own download channel
(`https://downloads.claude.ai/claude-code-releases/latest`) names a newer version. That is the
version `claude update` installs on natively supported platforms, and it can lead npm's `latest`
tag by hours, during which npm lists the same version under `next`. Following it keeps Termux
users level with everyone else, for example when a new model needs a newer client. Only the
timing changes: the ARM64 musl package is still acquired from npm, verified against the
registry's SHA-512 integrity and the recorded executable SHA-256, and accepted on a device before
release. "The current upstream release" in the changelog means that channel's version. A version
Anthropic withdraws before promoting it on npm is replaced by the next release; `termux-muscle
rollback` restores the previous runtime meanwhile.

Prefer a tested upstream pin to an unattended upgrade that silently changes compatibility. Candidate checks must run before activation. Preserve a rollback option and bound retained storage without deleting a leased release. A failed check is a reason to keep the working runtime, not to lower the gate.

If an upstream release changes package format, loader requirements, subprocess behavior or model selection, add a regression and fresh device evidence before calling it supported. Explicit experimental-version installation remains labeled as such. An urgent fix still needs evidence for the behavior it changes.

Record release decisions and acceptance evidence in the project's engineering records. Publish sanitized summaries that omit credentials, private paths and raw conversations.
