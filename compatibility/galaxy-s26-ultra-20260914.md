# Galaxy S26 Ultra acceptance — 2026-09-14

Maintainer evidence for Termux Muscle 0.1.0, original Claude Code 2.1.270 and musl 1.2.6-r2. The [JSON report](galaxy-s26-ultra-20260914.json) contains the exact device, Android/API, kernel, page size, Termux source/version and eighteen dependency versions. Results cover this configuration only.

The report combines automatically collected local checks with separately exercised installation and workflow checks. It is a reviewed maintainer report; the ordinary volunteer command leaves those additional checks SKIP.

The root used for automatic local collection has no external command entries, so `command_links` remains SKIP there. Separate real ownership fixtures passed intact-command checks and detected missing/replaced commands without changing them or their records.

| Exercise | Observation |
| --- | --- |
| Packaged manager installation | Checksummed source archive, restricted extraction, actual local compilation and all eleven C/Bash test programs passed; the installed manager ran and uninstalled cleanly. Pre-publication delivery used a local shim for exactly three GitHub project assets. Public HTTPS delivery is a separate release-engineering check. |
| Original vendor installation | Real source bootstrap and installed dispatcher successfully ran the original pinned Claude executable's version/help. Already verified official archives were reused. |
| Update and rollback | A distinct candidate became current; rollback restored the previous release and started it offline. |
| Failed update | A deliberately corrupted disposable cache made offline update fail; active state remained byte-for-byte unchanged and the current runtime still ran. |
| Repair | A deliberately corrupted active executable was rejected. Offline repair reconstructed a fresh candidate matching the pinned original hash. |
| Removal | The complete owned root and manager alias disappeared. A replaced foreign launcher recovered its exact bytes and mode; fixture Claude settings and project files were unchanged. |
| Authenticated shell tools | One bounded Sonnet 5 session made the exact allowed Bash fixture call, returned a matching successful tool result and completed successfully. Native `/bin/sh`, an executable `#!/usr/bin/env bash` script, native ripgrep and a nested launcher all passed. |
| Command hooks | Isolated Setup and SessionStart hooks ran through `--init-only`; no model conversation was started. |
| Local MCP | A disposable C stdio server recorded initialization and tools-list requests; Claude reported Connected. Actual MCP tool invocation was not tested. |
| Interactive startup | The authenticated Sonnet 5 prompt rendered and responded to Ctrl-C; the client exited normally. No conversational prompt was submitted during this TUI check. |

The packaged development source snapshot had SHA-256 `dd657c2c2b19150e5592dd0a8b6ddc8befe6acc144cbacfdd9565c69629aec2e`. That snapshot precedes these final evidence/documentation files; it is not the final release-asset checksum. The frozen helper used for authenticated workflow probes had SHA-256 `678e9206f907338b50f08dc828ae10092eec468d521350694cabbe0075f0178e`. Vendor binary and loader integrity remained pinned throughout.

## Model observations

Sonnet 5 and Opus 5 passed automated checks with exactly the requested assistant and usage model IDs. They are the manifest's verified models.

Two automated Fable 5.1 checks observed Opus 5 instead, so the report retains FAIL for exact Fable verification. A separate direct launcher check returned an actual Fable 5.1 assistant response and a successful final result; its usage record also included auxiliary Haiku. A further diagnostic-context check with automatic switching turned off returned an upstream Fable safeguard refusal. This establishes that the runtime can execute Fable requests, but does not justify claiming every diagnostic request passed. We did not establish whether the different diagnostic environment, workspace context or variable upstream classification caused the differing results.

Anthropic documents [content-based model fallback and workspace context](https://code.claude.com/docs/en/model-config#automatic-model-fallback). Account access, service availability and these vendor safeguards remain separate from native installation health. This release documents Opus 5; it makes no claim about an Opus 5.1 model.

## Limits and test-harness correction

Cross-session messaging was disabled by the vendor's default socket ownership/UID-mapping check on this host. No namespace policy or socket override was changed. Background operation (including daemon-backed agents), screen-off operation, actual MCP tool calls, remote MCP authentication and arbitrary custom integrations remain untested. [Anthropic documents that sessions can continue without a messaging inbox](https://code.claude.com/docs/en/cross-session-messaging#the-sessions-inbox-socket) when its ownership checks fail.

An initial interactive test showed a blank terminal because GNU `timeout` created a background process group and terminal job control stopped the client. Repeating it with `timeout --foreground` rendered the same runtime normally. The test command was corrected; no runtime change was needed. Use a foreground-aware deadline when testing interactive terminal programs.

Raw session streams, identifiers, account configuration and private paths are excluded. The private ELO session retains exact commands and detailed provenance; contributors do not need ELO to reproduce the public checks in [testing.md](../docs/testing.md).
