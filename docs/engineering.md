# Engineering record

This project grew out of repeated Claude Code failures on one Android host. This record connects those defects to design decisions, corrections and regression tests. Reliability claims depend on reproducible tests and device reports.

## Defects that shaped the design

| Observed defect or gap | Design response | Evidence needed |
| --- | --- | --- |
| npm replaced a usable client with an Android wrapper that had no matching native payload. Postinstall had run successfully. | Acquire the exact official ARM64 musl payload directly, verify it and avoid optional-dependency platform selection. | Package-selection and archive-verification regressions; device startup and tool tests. |
| Pinning an old JavaScript version restored startup but missed required newer-client features. | Version compatibility metadata includes required client versions and separates model documentation from actual requests. | Release metadata gate and explicit observed model IDs. |
| Read-only global package files did not stop npm renaming and replacing the tree. | Own a dedicated installation, preserve foreign launchers and track explicit links. | Conflict, restoration and changed-foreign-file regressions. |
| A revoked OAuth token was a separate failure from the runtime. | Keep authentication with Claude Code; perform account-independent installation checks. | Offline/no-account install tests plus explicit optional model tests. |
| Host-only scripts needed manually placed configuration and retained too many releases. | Provide a curl bootstrap, reproducible packaged tooling, bounded retention and owned storage. | Clean isolated install, rerun, rollback, retention and removal tests. |
| Copying resolver contents at install time could become stale. | Select the live Termux resolver at each launch. | DNS selection regression and device network checks. |
| A version probe did not prove shell tools, nested execution or complete lifecycle recovery. | Name capabilities separately, retain FAIL/SKIP and require actual workflow evidence. | Capability matrix with exact configurations and linked reports. |
| Pinning one Claude Code version per project release meant a release for every upstream build: 20 in 25 days, 13 of them changing no harness code. | Follow Anthropic's release channel and admit a version on Anthropic's own signature over its release manifest, plus the local candidate checks. The pin remains as the device-tested baseline. | Signature tests against a real signed manifest; channel-rule regressions; a device update through the live channel. |
| PRoot traced every system call of Claude Code and of every command it ran. Measured through the Bash tool on the reference device, process creation was 3 times slower and file-heavy commands 3 to 5 times slower than in a plain shell, and the project's own tests refused to run inside a session. | Prepare the release once, at installation, to find its own loader and resolver file, and run it as an ordinary process. PRoot stays available per release. | Preparation and launch regressions; device acceptance with an untraced tool process; the same timings on both backends. |

The original diagnostic was:

```text
Error: claude native binary not installed.

Either postinstall did not run (--ignore-scripts, some pnpm configs)
or the platform-native optional dependency was not downloaded
(--omit=optional).
```

That message listed possible causes; it did not establish which one occurred. The investigation distinguished the wrapper's generic diagnostic from installation logs and the platform packages that actually existed. The practical lesson is to test the premise before applying the suggested repair.

## Decisions and source credit

The PRoot backend uses an unmodified official musl payload and narrowly scoped PRoot mappings. The native backend, the default since it was added, sets the loader path in the installed executable and configures a private copy of the loader instead; [architecture.md](architecture.md#launch-two-backends) lists exactly what changes. Both follow existing musl prior art while choosing a different packaging and lifecycle implementation. We do not claim to have invented musl-on-Termux, staging or rollback. The [credits](../CREDITS.md) identify the repositories and article that informed the work; [architecture.md](architecture.md) explains the current choices and limits.

The initial supported-configuration claim must come from this project's own acceptance on a Samsung Galaxy S26 Ultra, with the exact Android, Termux, runtime and dependency versions. Earlier experiments on the host are useful research but do not count as a passed release test.
