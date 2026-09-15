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

The original diagnostic was:

```text
Error: claude native binary not installed.

Either postinstall did not run (--ignore-scripts, some pnpm configs)
or the platform-native optional dependency was not downloaded
(--omit=optional).
```

That message listed possible causes; it did not establish which one occurred. The investigation distinguished the wrapper's generic diagnostic from installation logs and the platform packages that actually existed. The practical lesson is to test the premise before applying the suggested repair.

## Decisions and source credit

The runtime uses an unmodified official musl payload and narrowly scoped PRoot mappings. This follows existing musl prior art while choosing a different packaging and lifecycle implementation. We do not claim to have invented musl-on-Termux, staging or rollback. The [credits](../CREDITS.md) identify the repositories and article that informed the work; [architecture.md](architecture.md) explains the current choices and limits.

The initial supported-configuration claim must come from this project's own acceptance on a Samsung Galaxy S26 Ultra, with the exact Android, Termux, runtime and dependency versions. Earlier experiments on the host are useful research but do not count as a passed release test.
