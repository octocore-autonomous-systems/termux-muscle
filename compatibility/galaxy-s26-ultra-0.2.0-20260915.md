# Galaxy S26 Ultra — Termux Muscle 0.2.0 acceptance

Fresh maintainer evidence for **Termux Muscle 0.2.0**, original **Claude Code 2.1.270** and musl **1.2.6-r2**. The [JSON report](galaxy-s26-ultra-0.2.0-20260915.json) was assembled at **2026-09-15T03:53:49Z** from local diagnostics collected at **03:44:19Z**, an actual isolated native lifecycle run spanning **03:44:03Z–03:44:22Z**, and an authenticated tool-workflow receipt generated at **03:51:30Z**. Both acceptance executions returned exit 0. The UTC date is September 15; the device's local date was September 14 CDT.

The lifecycle run used source bootstrap, the locally built helper, real Termux dependencies and verified original vendor archives. The mutable command paths, home, data root and manual tree were private fixtures. It made no model requests; a separate bounded authenticated Sonnet 5 workflow then exercised an actual Claude-issued Bash tool call. Neither changed live-host commands or downloaded the 0.2.0 installer from a published release. Remote CI, tag publication and public installer delivery are separate release-engineering evidence.

## Measured configuration

| Field | Value |
| --- | --- |
| Device | Samsung Galaxy S26 Ultra, SM-S948U |
| Android | 16 / API 36 |
| Android security patch | 2026-08-05, read from `ro.build.version.security_patch` |
| ABI / page size | arm64-v8a / 4096 bytes |
| Kernel | `6.12.30-android16-5-pd30ff70-abogkiS948USQS4AZHL-4k` |
| Termux | 0.118.3, GitHub build |

All nineteen package versions below come from this run's local report, rather than the older 0.1.0 report:

| Package | Version | Package | Version |
| --- | --- | --- | --- |
| bash | 5.3.15 | coreutils | 9.11-1 |
| curl | 8.22.0 | ca-certificates | 1:2026.08.13 |
| proot | 5.1.107.92 | ripgrep | 15.2.0 |
| clang | 21.1.8-3 | make | 4.4.1-1 |
| pkg-config | 0.29.2-3 | json-c | 0.19 |
| libarchive | 3.8.9 | openssl | 1:3.6.3 |
| zlib | 1.3.2 | termux-tools | 1.46.0+really1.45.0-1 |
| termux-exec | 1:2.5.0-1 | diffutils | 3.12-2 |
| tar | 1.35-3 | gzip | 1.14-1 |
| mandoc | 1.14.6-7 | | |

## Actual observed behavior

| Exercise | Result and scope |
| --- | --- |
| Source bootstrap and normal commands | PASS. The executable Claude fixture ahead of the prefix in PATH, prefix entry and home-bin entry selected the managed runtime after activation. `termux-muscle --version` reported 0.2.0; ordinary `claude --version` reported 2.1.270 and help succeeded. |
| Local doctor | PASS for resolver syntax, tracked command ownership, original payload integrity, startup version/help and namespace shell. Resolver validation makes no DNS query. |
| Namespace shell/shebang/ripgrep | PASS. The actual C runtime probe exercised the mapped shell, portable executable shebang and native ripgrep. **This was not a Claude-issued Bash tool call.** |
| Authenticated Claude tools | PASS in a separate Sonnet 5 run. Exactly one permitted Bash fixture invocation had one matching successful tool result, independent matching attestation and a successful final result. Native shell, portable shebang, ripgrep and nested launcher all passed. |
| Installed manual | PASS. The page was a mode-0644 regular file. `man termux-muscle` discovered and rendered it with no warning; an unrelated neighboring manual remained available. |
| Management-only refresh | PASS. A real `--no-install` source bootstrap refreshed the manual and it still rendered by name without warnings. The repaired runtime remained selected. This was not a public-network `self-update` request. |
| Update and rollback | PASS. An offline update activated a distinct candidate; rollback restored the previous release. |
| Failed update | PASS. Deliberate cache corruption made offline update fail while state remained byte-identical and ordinary `claude --version` still worked. |
| Corruption and repair | PASS. Deliberate active-executable corruption was rejected. Offline repair created a different candidate from verified recorded archives, and ordinary startup succeeded again. |
| Removal and restoration | PASS. Uninstall removed the owned root, prefix/home manager aliases, manual and its index entry. It restored the executable PATH fixture's exact original bytes and mode 0751 and the prefix link's literal original target. The neighboring manual and known settings/project fixture bytes remained unchanged. |

The automated doctor originally left separate lifecycle checks SKIP. The reviewed report promotes only checks demonstrated by the actual exercises above. The lifecycle harness's broad label `shell_tools` describes a namespace probe and did not by itself satisfy the Claude-tool requirement. **`shell_tools: PASS` comes from the separate authenticated workflow**, not the namespace probe or a copied 0.1.0 result.

## Models and workflow limits

**Sonnet 5 is the only newly verified model for 0.2.0.** Its requested and observed model ID was exactly `claude-sonnet-5`. The workflow allowed only one pre-created harmless Bash fixture, at most two turns and a $0.50 maximum budget; it did not enable unrestricted tool approval. Capture completed in **4,849 ms**, with **5,043 bytes**, exit 0, no timeout and no output overflow. The helper used for the runtime invocation had SHA-256 `c754ae0f073df5d79166974efc66d619e61bc46def1a021bb3e9ff27329492c3`. The budget is a limit, not a statement of actual charges.

Interactive operation, background/screen-off behavior, current hooks/MCP and cross-session messaging were not retested by this bounded 0.2.0 workflow. Successful Sonnet tool acceptance does not certify arbitrary integrations or other models.

The separate [0.1.0 report from 2026-09-14](galaxy-s26-ultra-20260914.md) retains its exact Opus 5/Sonnet 5 PASS results, direct Fable response plus automated fallback/refusal, actual authenticated shell-tool evidence, hooks, interactive acceptance and MCP initialization. It also records the default cross-session messaging UID-mapping failure and untested actual MCP calls/background/screen-off behavior. Those dated results remain historical; neither an Opus 5.1 identifier nor universal Fable success is asserted.

## Test-harness preparation

An initial harness compilation included an unrelated acquisition-test object and stopped before invoking Claude; the object list was corrected to use production sources. A subsequent capture used 120 milliseconds where 120 seconds was intended. That attempt terminated after 245 ms with exit 143 and zero captured bytes, producing no acceptance attestation or model result. Empty output alone cannot establish whether any account request began. The corrected **120,000 ms** deadline produced the successful bounded result described above. These preparation errors are not evidence of runtime incompatibility or a model-capability failure.

Maintainer records retain the exact source-bootstrap harness, operation log, manual renderings, shell probe and fixture-preservation comparisons. This public report includes no secrets, user account data, private filesystem paths or raw conversations. It applies only to the stated device/software configuration and named exercises.
