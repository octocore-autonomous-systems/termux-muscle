# Galaxy S26 Ultra acceptance: Termux Muscle 0.21.0

Verified 2026-10-10 UTC on Samsung Galaxy S26 Ultra (SM-S948U), Android 17 / API 37, Termux 0.118.3 from GitHub. The [JSON report](galaxy-s26-ultra-0.21.0-20261010.json) records the exact kernel, page size, package versions, check results and sanitized workflow metadata. The tested pin is Claude Code **2.1.296** with musl **1.2.6-r2**, on the **native** backend, this release's default. The report was generated at **2026-10-10T22:09:39Z** by `scripts/maintainer_acceptance.sh` from a clean checkout of source commit **`5026120b4fdd6906357e8c292d721e0d938e3c0b`** (`source.uncommitted_changes: false`). Only the report's relative `evidence_notes` filename was adjusted when registering it; measured results are unchanged.

Immediately before acceptance, `make check` ran from the same checkout in an untraced native Termux shell. All **15 C and shell test programs passed**, including the signature, native preparation and launch, channel-rule and release-gate regressions. The optional runtime host-probe group was skipped without `TM_RUNTIME_HOST_PROBES=1`; it passed separately on the same day, 20 groups including the unmodified vendor executable under real PRoot, against the change that added the native backend. The cross-UID executable tooling fixture was skipped because no readable Bash executable owned by another UID was available.

A private source bootstrap with `--no-link --claude-version pinned` prepared and activated pinned 2.1.296 on the native backend and passed isolated version, help and initialization checks. An offline update activated a fresh candidate from the verified cache, rollback restored the previous candidate offline, and uninstall removed the owned root. Local diagnostics passed runtime integrity, DNS configuration, command link and shell environment checks. The live installation's commands, manual, completion and state records were fingerprinted before and after and were unchanged.

The authenticated workflow recorded at **2026-10-10T22:09:28Z** used the private runtime with only the Bash tool available. **Opus 5.5** (`claude-opus-5-5`) made exactly one Bash call on a nonce fixture using a portable shebang and `rg`. The script matched the successful tool result, fixture attestation and final response, and recorded `TracerPid: 0` for the tool process (`untraced_tools`: PASS). Every assistant message came from exactly `claude-opus-5-5`. Capture exited 0 in **4846 ms**, without timeout, under a **$0.50 API budget cap**. Raw events and session identifiers were not retained in the public report.

After the lifecycle, the PRoot backend was installed from the same verified cache with `update --offline --backend proot` and passed runtime integrity, isolated version, help and initialization, and its shell namespace check (`alternate_backend`: PASS). The fallback therefore starts on this device; its authenticated workflow was last exercised by the 0.20.0 report.

## Release channel and signature

In a separate disposable root built from the same commit, `termux-muscle update` read Anthropic's live channel (`latest` 2.1.296, `stable` 2.1.287) and reported the pinned 2.1.296 as current. `update --claude-version 2.1.295` downloaded that release's manifest, signature and npm archive, verified Anthropic's signature against the built-in key and the executable against the signed SHA-256, and activated it labelled `signed`. `update --claude-version stable` changed nothing, because 2.1.287 is older than the active release. `update` then returned to 2.1.296, `rollback` restored the signed 2.1.295, and the same version was reinstalled with `--backend proot`. The first install in that root also removed 11 unused source archives (1139 MiB) that had been copied into its cache.

## Timings

The same workload was run through Claude Code's Bash tool on each backend, three tool calls each, on two occasions the same day. It is 300 runs of `true`, `git status` on a checkout, reading every file of that checkout and a recursive `grep`. `TracerPid` of the tool process was 0 on the native backend and non-zero under PRoot.

| Workload | Native, run 1 | PRoot, run 1 | Native, run 2 | PRoot, run 2 |
| --- | ---: | ---: | ---: | ---: |
| 300 process starts | 3.1 s | 10.1 s | 1.9 s | 5.1 s |
| `git status` | 27 ms | 121 ms | 21 ms | 61 ms |
| Read a source tree | 39 ms | 164 ms | 25 ms | 129 ms |
| `grep -r` | 21 ms | 76 ms | 11 ms | 35 ms |

Figures are the median of three calls. Run 1 used the development build of the native backend with Claude Code 2.1.296; run 2 used this release's commit with 2.1.295. Absolute times moved with the state of the device between runs; the ratio did not: process creation 2.6 to 3.2 times faster natively, the other three 2.9 to 5.2 times faster. A plain Termux shell, outside Claude Code, measured 3.1 s, 26 ms, 38 ms and 25 ms beside run 1 and 2.8 s, 25 ms, 36 ms and 21 ms beside run 2, so the native backend adds no cost of its own.

## Not covered

Ordinary command takeover, indexed manual discovery, public HTTPS installer delivery, sustained interactive use, background and screen-off operation, MCP tool calls and other models were not exercised by this acceptance run. An interactive session was started on the native backend in a terminal and rendered its first screen; a hook was observed running through Android's `/bin/sh`. The lifecycle update and rollback checks create and switch local candidates of the pin; the cross-version update is the separate channel trial above. Earlier reports retain their dated scope. Public delivery can be tested only after publication.
