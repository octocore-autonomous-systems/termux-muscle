# Troubleshooting

Start with `termux-muscle doctor` and `termux-muscle versions`. Keep the error category and exact versions. If you report a problem, use the [bug form](https://github.com/octocore-autonomous-systems/termux-muscle/issues/new?template=bug-report.yml) and attach a reviewed `termux-muscle test --output report.json` report.

| Symptom | Likely boundary | Next action |
| --- | --- | --- |
| `claude native binary not installed` | A different npm-installed wrapper may still own `claude`. Successful postinstall alone does not prove an Android payload exists. | Compare `command -v claude` with `termux-muscle run -- --version`. Use the manager's `link` command if you want it to own `claude`. |
| `command_links: FAIL` in a report | A tracked command is missing, changed by another installer, or its ownership record is invalid. | Use `termux-muscle run` directly and inspect the command that changed before requesting a link repair. Doctor reports the conflict without overwriting it. |
| Unsupported architecture/platform | The current backend requires native Termux on Android ARM64. | Run from native Termux and report ABI/device details. Do not force a Linux/x86 package onto the installation. |
| Missing compiler, C library, PRoot or certificate bundle | Termux prerequisites are incomplete. | Rerun the bootstrap. If `pkg` fails, resolve that package-manager error before retrying. |
| Compilation or offline tests fail | The new tooling did not pass local build acceptance. | Preserve the existing installation and report the failing build/test with exact compiler and library versions. |
| Integrity or checksum error | The source/cache bytes do not match the expected digest. | Preserve the working release. Retry on a reliable connection or use repair; do not bypass verification. |
| Installation healthy, login rejected or HTTP 401 | Account authentication is separate from runtime startup. | Run `termux-muscle run -- auth login` and complete Anthropic's flow. Reinstalling cannot revoke or refresh an account token for you. |
| Requested model unavailable | Client version, provider or account policy may limit model access. | Check this release's compatibility manifest and the account's allowed models. Use the exact documented model ID. |
| DNS or TLS failure | The selected Termux resolver, certificates or network may be unavailable. | Check normal Termux networking and the health report. The manager uses your resolver; it does not replace it with public DNS. |
| Already traced / conflicting namespace | The command is inside an unrelated PRoot or a session pinned to another installation. | Start a fresh native Termux shell for maintenance. |
| Another maintenance operation is running | A process holds the mutation lock. | Let that operation finish, then retry. A leftover lock file by itself is not evidence of a live owner. |
| Bad behavior after an update | A newly selected runtime may be incompatible with your workflow. | Run `termux-muscle rollback`, preserve a report, and open an issue. |
| Upstream install/update tries to replace the managed executable | Claude's own installer does not manage this backend. | Use `termux-muscle update` for the runtime and `termux-muscle self-update` for this tool. |
| Android kills a long session or background process | OS/vendor process and battery restrictions may apply. | Record the Android/kernel/device configuration and exact scenario. Do not infer that a passing startup test guarantees background survival. |
| Cross-session messaging is disabled by a UID-mapping check | Claude cannot validate its default inbox ownership in this PRoot environment. | Single-session workflows can continue. See the [device report](../compatibility/galaxy-s26-ultra-20260914.md); messaging and daemon-backed background agents are not verified in this release. |

## Recovery without an account or network

`termux-muscle rollback` uses an available previous local release. `termux-muscle repair --offline` uses verified cached sources when present. Neither operation obtains a new account token. If no suitable release/cache remains, reconnect to retrieve verified sources.

An interrupted update must leave the previous current release usable or provide a clear recovery error. Do not manually delete `state.json`, ownership markers or release directories to clear an error; those records prevent accidental deletion and preserve rollback information.

## Removing the manager

Run `termux-muscle uninstall`. It removes owned files and eligible managed links, preserves unrelated files, and leaves your Claude credentials, settings, sessions and projects alone. If a launcher was changed by another installer after linking, the manager must preserve that change and explain the conflict.

Avoid sharing whole settings files, environment dumps, OAuth credentials or private Claude transcripts while debugging. A small reproduction, exact version report and error category are usually more useful.
