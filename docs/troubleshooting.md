# Troubleshooting

Start with `termux-muscle doctor`, `termux-muscle versions` and `man termux-muscle`. Keep the error category and exact versions. This page describes 0.2.0; its [device report](../compatibility/galaxy-s26-ultra-0.2.0-20260915.md) distinguishes native lifecycle checks from authenticated workflows and public delivery. If you report a problem, use the [bug form](https://github.com/octocore-autonomous-systems/termux-muscle/issues/new?template=bug-report.yml) and attach a reviewed `termux-muscle test --output report.json` report.

| Symptom | Likely boundary | Next action |
| --- | --- | --- |
| `claude native binary not installed` | A different npm-installed wrapper or shell override may still select `claude`. Successful postinstall alone does not prove an Android payload exists. | Inspect `type -a claude` and `command -v claude`. Normal 0.2.0 installation sets up the executable command; see command recovery below for an opt-out or later replacement. |
| `command_links: FAIL` in a report | A tracked command/manual is missing, changed by another installer, or its ownership record is invalid. | Inspect the reported error before requesting restoration. Doctor reports the conflict without overwriting it; the owned manager can run the runtime directly while diagnosing a Claude-command conflict. |
| `termux-muscle` selects another program | A foreign management command was preserved, or a shell override wins. | Use the full owned manager path printed by installation; inspect PATH/aliases before changing a foreign command. |
| `man termux-muscle` cannot find the manual | The viewer/index may be missing, or a foreign manual was preserved. | Check that Termux `mandoc` is installed. Rerun the verified current installer to refresh an unchanged owned manual and its index, or read the full installed manual path printed by the installer. |
| Unsupported architecture/platform | The current backend requires native Termux on Android ARM64. | Run from native Termux and report ABI/device details. Do not force a Linux/x86 package onto the installation. |
| Missing compiler, C library, PRoot or certificate bundle | Termux prerequisites are incomplete. | Rerun the bootstrap. If `pkg` fails, resolve that package-manager error before retrying. |
| Compilation or offline tests fail | The new tooling did not pass local build acceptance. | Preserve the existing installation and report the failing build/test with exact compiler and library versions. |
| Integrity or checksum error | The source/cache bytes do not match the expected digest. | Preserve the working release. Retry on a reliable connection or use repair; do not bypass verification. |
| Installation healthy, login rejected or HTTP 401 | Account authentication is separate from runtime startup. | Run `claude auth login` and complete Anthropic's flow. Reinstalling cannot revoke or refresh an account token for you. |
| Requested model unavailable | Client version, provider or account policy may limit model access. | Check this release's compatibility manifest and the account's allowed models. Use the exact documented model ID. |
| DNS or TLS failure | The selected Termux resolver, certificates or network may be unavailable. | Check normal Termux networking and the health report. The manager uses your resolver; it does not replace it with public DNS. |
| Already traced / conflicting namespace | The command is inside an unrelated PRoot or a session pinned to another installation. | Start a fresh native Termux shell for maintenance. |
| Another maintenance operation is running | A process holds the mutation lock. | Let that operation finish, then retry. A leftover lock file by itself is not evidence of a live owner. |
| Bad behavior after an update | A newly selected runtime may be incompatible with your workflow. | Run `termux-muscle rollback`, preserve a report, and open an issue. |
| `self-update --version 0.1.x` is rejected | 0.1.x managers cannot read 0.2.0 manual ownership records. | Keep the current manager. For an intentional management downgrade, uninstall with the current manager before installing the older version; this is separate from Claude runtime rollback. |
| Upstream install/update tries to replace the managed executable | Claude's own installer does not manage this backend. | Use `termux-muscle update` for the runtime and `termux-muscle self-update` for this tool. |
| Android kills a long session or background process | OS/vendor process and battery restrictions may apply. | Record the Android/kernel/device configuration and exact scenario. Do not infer that a passing startup test guarantees background survival. |
| Cross-session messaging is disabled by a UID-mapping check | Claude cannot validate its default inbox ownership in this PRoot environment. | Single-session workflows can continue. See the dated [0.1.0 device report](../compatibility/galaxy-s26-ultra-20260914.md); no new messaging or background-agent support is claimed by 0.2.0. |

## Command selection and recovery

Normal installation takes over the executable `claude` selected from PATH, plus the Termux prefix and home-bin entries, only after the runtime passes validation. It backs up original commands. An installation made with `--no-link` deliberately leaves them unchanged; `--no-install` provides only the manager and manual.

A child installer cannot change an alias/function in your current shell or clear that shell's cached command location. Inspect `type -a claude`; open a fresh shell or run `hash -r` in Bash after confirming which executable should be selected. Shell startup files are not edited automatically.

For an opt-out setup or a command replaced since installation, first inspect the target. `termux-muscle link --replace --path /absolute/path/to/claude` explicitly requests one replacement with restoration information. Do not run it against an unrelated command without intending that replacement. The default `link` target is `$PREFIX/bin/claude`; use `man termux-muscle` for options. Several command registrations are individually recoverable; if a later one fails, inspect the result and retry or uninstall instead of deleting ownership records.

The ordinary launch command remains `claude`. For diagnosis or an intentionally unlinked root, `termux-muscle run -- --version` tests the owned runtime directly. If the management name itself conflicts, use `~/.local/share/termux-muscle/bin/termux-muscle` for the default root, or the exact owned path printed for a custom root.

The 0.2.0 manager rejects in-place self-update downgrades below 0.2.0. Directly running an old immutable installer bypasses that guard and is unsupported; it can partially replace tooling before encountering an incompatible ownership record. If this occurred, rerun the newer verified installer to recover, then inspect health and ownership. Use the current manager to uninstall before an intentional older-manager installation.

## Recovery without an account or network

`termux-muscle rollback` uses an available previous local release. `termux-muscle repair --offline` uses verified cached sources when present. Neither operation obtains a new account token. If no suitable release/cache remains, reconnect to retrieve verified sources.

An interrupted update must leave the previous current release usable or provide a clear recovery error. Do not manually delete `state.json`, ownership markers or release directories to clear an error; those records prevent accidental deletion and preserve rollback information.

## Removing the manager

Run `termux-muscle uninstall`. It removes owned files, commands and the manual, restores eligible unchanged owned replacements, preserves unrelated files, and leaves your Claude credentials, settings, sessions and projects alone. If a command or manual was changed afterward, the manager preserves that change and any necessary restoration evidence. It does not remove Termux dependencies such as `mandoc`. Read a retained `UNINSTALL-RECOVERY.txt` before attempting any manual cleanup.

Avoid sharing whole settings files, environment dumps, OAuth credentials or private Claude transcripts while debugging. A small reproduction, exact version report and error category are usually more useful.
