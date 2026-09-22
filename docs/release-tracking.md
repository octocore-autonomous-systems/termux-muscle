# Automated upstream release tracking

The **Track upstream Claude Code** GitHub Actions workflow checks the official
`@anthropic-ai/claude-code-linux-arm64-musl` npm package's `latest` tag every six
hours (00:23, 06:23, 12:23 and 18:23 UTC), comparing it with `claude.version` in
`main`'s `compatibility.json`.

For a newer observed version, it opens **one compatibility-testing issue per
version**, with registry metadata and a device acceptance checklist. It checks
all pages of open **and closed** issues before creation. Repeat runs do not
comment, overwrite maintainer edits, or reopen rejected/deferred versions.
Keep the hidden `termux-muscle:upstream-claude` version marker when editing;
deleting the issue or its marker permits recreation. Reopen manually to reconsider.

The tracker observes `latest` at each check, not every intervening release.
A backward-moving tag never proposes a downgrade. Prereleases and invalid or
mismatched package responses fail the run. Maintainers close superseded issues;
the tracker does not discard their evidence automatically.

## Discovery is not compatibility approval

The tracker does not download or execute Claude, change `compatibility.json`,
copy old device PASS results, publish a release, or update installed runtimes.
SHA-512 integrity is registry metadata, not independent archive verification or
an executable SHA-256. Discovery reports are marked `not_tested`.

Promotion requires the existing acquisition/integrity checks, isolated Android
startup and workflow acceptance, a reviewed compatibility PR with fresh evidence,
and the verified-tag process in [releasing.md](releasing.md). Use disposable
installations following [testing.md](testing.md), not a user's working runtime.
After a verified project release changes the pin, users run
`termux-muscle self-update` followed by `termux-muscle update`.

The explicit `update --claude-version latest --allow-unverified` path remains
experimental. Neither it nor this tracker searches backward for the newest
release compatible with a particular phone.

## Activation and operation

Merge the workflow and supporting files into the upstream repository's `main`
branch to activate scheduling. No new app, PAT, paid service, phone daemon or
separate scheduler is required. The built-in `GITHUB_TOKEN` receives
`contents: read` and `issues: write`, with no content/release write permission.
The job runs only for this repository's `main`, not forks or PRs. Actions and
Issues must be enabled and the job token must be allowed to write issues.

Under **Actions → Track upstream Claude Code → Run workflow**, select `main`:

- Leave **publish** unchecked for a read-only live registry check.
- Check **publish** for immediate deduplicated issue creation.

Successful runs include a summary and a 14-day JSON discovery artifact.
Failures remain failed Actions runs, never a claim that the pin is current.
Use normal Actions failure notifications as desired. A timed-out create request
may have succeeded server-side: the next run lists issues again before creating
instead of blindly retrying the POST. Workflow concurrency serializes manual
and scheduled runs.

GitHub [scheduled workflows](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule)
run from the default branch and may be delayed or dropped under load. GitHub can
disable public-repository schedules after 60 days without repository activity.
Check Actions and re-enable if necessary; this is periodic discovery, not
guaranteed real-time notification. Disable the workflow to pause tracking;
existing issues, compatibility metadata and installations remain unchanged.

## Maintainer development

Python 3 and GitHub CLI are runner/developer tools **only**, not new Termux
installation or offline C/Bash test prerequisites.

```sh
python3 -B -m unittest discover -s tests/dev -p 'test_track_upstream.py' -v
python3 -B scripts/track_upstream.py --output /tmp/upstream-release.json
```

The second command reads the live registry, makes no GitHub writes and needs no
account. `--publish` explicitly enables issue creation using existing GitHub CLI
authentication. Registry reads never receive GitHub authorization. The script
rejects redirects, bounds metadata size and network wait time, validates package
identity/platform, canonical archive URLs, stable versions and SHA-512 syntax.

Use `-B` to avoid leaving bytecode artifacts in the source tree; the release
builder accepts the two maintainer Python source files but rejects generated
bytecode and arbitrary extra Python files.

We considered Renovate's npm/custom-manager support. Our target is a tested
compatibility manifest with an executable hash and device evidence, not a normal
dependency. GitHub Actions already supplies scheduling and issue APIs without a
new app or self-hosted bot credential; this small tracker proposes testing
rather than advancing the pin.
