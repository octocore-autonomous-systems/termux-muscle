# Moving an existing Claude setup to Termux Muscle

Termux Muscle keeps Claude settings, authentication and conversations under Claude's control.
It does not rewrite configuration, execute migration hooks, edit shell startup files, or convert
old session paths. Back up the specific files you intend to change before manual recovery.

## Run the read-only preflight

From the actual project directory in a **fresh native Termux shell**, run:

```sh
termux-muscle migration
```

The command works before a runtime is installed and does not need a model account. It produces
JSON containing fixed check IDs, statuses, detail codes and guidance, never settings values,
private paths, environment dumps or transcript contents. It does not upload the report.
`WARN` means review is needed, not that installation is necessarily broken. These advisories
exit successfully; malformed command usage still fails. This report is separate from the
compatibility report produced by `termux-muscle test`.

The bounded scan covers:

- `settings.json` under a nonempty `CLAUDE_CONFIG_DIR`, or otherwise `$HOME/.claude`;
- `.claude/settings.json` and `.claude/settings.local.json` in the current directory and up to
  31 ancestors, looking only for nonempty `env.LD_PRELOAD` and `env.LD_LIBRARY_PATH`;
- `plugins/installed_plugins.json` and `plugins/known_marketplaces.json` under the selected
  configuration directory, looking for `/home` paths in known path fields;
- the nearest ancestor repository's `.git` pointer, or up to 128 entries in its
  `.git/worktrees` directory, without invoking Git or following `.git` pointers;
- the first executable `claude` in up to 128 inherited PATH entries, compared with this
  installation's `bin/claude` target.

Each input file is limited to 1 MiB. JSON must be valid and no more than 32 levels deep.
Symlinked configuration, special files, malformed input and inaccessible files are reported as
uninspected, not healthy. Symlinks in input directory components are also not followed.
A `/home` path is a migration hint, **not proof it is stale**; it can be valid in your environment.
Missing optional settings or metadata files are normal. The scan cannot establish complete
Claude configuration precedence, and intentionally does not inspect enterprise managed policy,
explicit `--settings` inputs, other projects or historical session contents.

## Loader workarounds

An old glibc/Bionic workaround may put `LD_PRELOAD` or `LD_LIBRARY_PATH` inside Claude's
`settings.json` `env` object. The runtime launcher clears incompatible inherited loader
variables, but settings can reintroduce them into Claude's subprocesses.

Review the user and ancestor-project settings locally. Remove only entries that belong to the
obsolete workaround, preserving unrelated settings and hooks. An empty string is not reported
as a nonempty override. Do not paste whole settings files into a public issue.

## Which `claude` is running?

In the **same interactive shell** used to start Claude:

```sh
type -a claude
hash -r
claude --version
```

A child process cannot inspect or clear its parent's aliases, functions or command cache. The
preflight therefore checks executable PATH selection and explicitly leaves shell state untested.
Inspect your own aliases/functions and startup files if the result differs. Do not delete a
foreign launcher just because it exists; use the manager's documented command ownership and
restoration behavior, or `termux-muscle run` for an explicit launch.

## Plugins, worktrees and previous conversations

A plugin installed under a distribution's `/home/...` can retain that path after moving back
to native Termux. Inspect plugin and marketplace entries locally; reinstall affected plugins
using Claude's supported commands after preserving their configuration. Do not globally replace
`/home` in JSON files: paths can refer to distinct projects or intentional locations.

For Git, inspect `git worktree list` from the intended repository. Preserve uncommitted files,
confirm the actual repository/worktree locations, and use `git worktree repair` where appropriate.
The preflight does not follow a linked worktree's `.git` pointer into another directory or inspect
all repositories. A clean result does not validate every Git administrative path.

Historical session JSONL files are not opened. If a resumed session depends on an obsolete
working directory, preserve its history and start a new session from the actual project path.
Do not mass-rewrite conversations to make them appear migrated.

## What this does not prove

Run installation and candidate validation outside another distribution's PRoot session.
The existing runtime launcher validates its namespace marker and rejects foreign tracers;
this preflight intentionally does not validate an active runtime. Passing these limited
checks does not certify authenticated tools, MCP, DNS, performance, Android background survival,
or compatibility on another device. Keep those checks separate in device evidence.
