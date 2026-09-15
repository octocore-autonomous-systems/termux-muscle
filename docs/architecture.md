# Architecture and boundaries

Termux Muscle manages Claude Code on native Android Termux. Version 0.2.0 retains the official Linux ARM64 musl executable and musl loader used by 0.1.0, inside one PRoot namespace. Bash sequences lifecycle commands, and a C helper handles parsing, integrity, owned filesystem state and execution. The helper is compiled on the target device. Vendor payloads are fetched separately with the URLs and digests in `compatibility.json`. The [fresh 0.2.0 report](../compatibility/galaxy-s26-ultra-0.2.0-20260915.md) records native command/manual and runtime lifecycle acceptance plus a separate authenticated Sonnet tool workflow; older 0.1.0 model observations remain historical evidence.

## Why installation needs a manager

Termux uses Android's C library and reports Android to Node/npm. A Linux optional-dependency package is not selected simply because the CPU is ARM64. The incident behind this project had a successful npm postinstall and a wrapper that could not find a platform binary. Repeating postinstall did not provide a missing Android artifact.

Pinning an old JavaScript client restored startup but prevented use of required newer-client features. Protecting the old global package with filesystem permissions also failed: npm could rename and replace the package tree. This project therefore controls its own storage and explicitly selects the upstream musl payload.

## Acquisition and launch

The downloader accepts the official ARM64 musl package, validates archive integrity and ELF requirements, and extracts only selected members into an owned candidate. Selected members must be regular files at their expected archive paths; duplicate or unsafe selected entries are rejected. Unselected archive entries are skipped, including Alpine's libc symlink. Decoded archive data remains bounded even for skipped entries. The Alpine loader has separately pinned archive and loader digests. Cached archives are verified again before reuse. No downloaded npm lifecycle script runs.

The runtime keeps the executable and loader bytes unchanged. PRoot maps only the needed paths:

| Process-visible path | Source |
| --- | --- |
| `/lib/ld-musl-aarch64.so.1` | Candidate's verified musl loader |
| `/lib/libc.musl-aarch64.so.1` | The same loader/library |
| `/etc/resolv.conf` | Live Termux resolver file selected for this launch |
| `/bin/sh` | Termux bash |
| `/usr/bin/env` | Termux env utility |
| `/tmp` | Private runtime temporary directory |
| Runtime namespace marker | The selected installation and release identity |

The launcher selects Termux certificates and external ripgrep, clears incompatible loader variables and disables Claude's unmanaged self-updater. It preserves the caller's arguments, working directory and account configuration. It does not force a public DNS service or overlay all of `/bin`.

Nested execution recognizes a context bound inside the existing namespace and keeps that session's release pinned. A foreign tracer or conflicting installation context produces a diagnostic. Candidate validation belongs in a fresh native Termux shell when an existing session is pinned to a different release.

PRoot is part of this design. The project does not claim zero overhead, root-level isolation, universal Android compatibility or equivalence to a supported desktop installation. Ordinary sessions and bounded test probes have different process-lifetime requirements; terminating a health probe must not imply killing legitimate background work in ordinary use.

## Installation and update transactions

An installation has a private identity and an atomic state record. New candidates are prepared at permanent release paths. Promotion changes the state record after checks pass, keeping the prior working release available. Shared leases protect releases in use; an exclusive maintenance lock prevents concurrent mutations and is released by the operating system after process death.

Cleanup removes only owned, inactive releases and preserves current, previous and leased releases. Recovery checks interrupted work instead of treating the mere presence of a lock file as proof that an updater is running. Hash mismatches fail closed; an arbitrary directory is never treated as an installation to delete.

Management-tool updates are separate from runtime updates. The curl bootstrap fetches a versioned source archive and checksum manifest over HTTPS, verifies the exact named asset, then validates its predictable paths and regular-file/directory types before extraction into private temporary storage. It builds with make and runs offline C/Bash tests before invoking the bootstrap entry point. Reproducible ordering, timestamps and permissions make identical source produce identical source-release bytes; binaries built by different toolchains need not be identical.

Installed Bash entries invoke a stable C dispatcher. It selects and leases a versioned tool directory before starting Bash, so a concurrent self-update cannot remove the code a command is using. Tool publication and removal have recovery journals; current, previous and leased tool versions are retained. Self-update builds and tests the downloaded source before taking the publication lock. Changed entry points and unsupported metadata schemas are preserved with an error instead of being overwritten.

The 0.2.0 self-update command rejects a requested management version below 0.2.0 before invoking its installer: 0.1.x tooling cannot read regular-manual ownership records. This is a guard in the new manager, not a universal minimum-reader enforcement mechanism. Directly executing a retained old installer bypasses it and is unsupported; an old bootstrap can partially publish old tooling before discovering an incompatible record. Recovery uses the newer verified installer, or the current manager's uninstall before intentionally installing an older manager. Claude runtime rollback is separate and remains available when a previous runtime exists.

The C helper links installed json-c, libarchive and OpenSSL libraries. Local compilation adapts our helper to the target compiler, Bionic and Termux prefix. It does not compile Claude Code, supply a missing vendor ABI, or prove compatibility with a different Android kernel. Clang and the build tools add installation footprint; the installer does not remove a user's compiler or shared libraries afterward. Python is not required for installation, execution, builds or mandatory tests.

Checksums detect mismatched or damaged downloads against the published metadata. Because that metadata is fetched from the same release source, it is not an independent signature or protection against a compromised maintainer account.

## User data and command ownership

Claude Code retains control of its authentication and application data. The manager does not rewrite credentials, Claude settings, projects or shell startup files. Ordinary use is `claude` and `claude auth login`; the manager's `run` command remains available for explicit roots, opt-out installations and diagnosis.

Normal installation first validates and activates the runtime, then registers `$PREFIX/bin/claude`, `$HOME/.local/bin/claude` and the first existing executable `claude` found elsewhere on PATH. A replaced regular file's bytes and mode, or a symlink's literal target, are recorded before replacement. This covers a custom executable that shadows the prefix command. It does not rewrite parent-shell aliases/functions or invalidate that shell's command cache. The installer verifies executable PATH selection and reports affected entries.

Each entry has its own recoverable transaction. Several command entries are not a single atomic filesystem operation: a later conflict can leave earlier entries managed. A reported partial failure therefore requires inspection and retry or owned uninstall, not deletion of restoration records. Subsequent runtime updates do not silently reclaim commands another program has changed.

`--no-link` installs a runtime without changing Claude command entries. Bootstrap `--no-install` installs only the management tool and manual; it never redirects Claude to an installation without a runtime. Management convenience entries in `$PREFIX/bin` and `$HOME/.local/bin` preserve unrelated commands named `termux-muscle`; the full owned manager path remains available when a convenience entry conflicts.

Uninstall restores an original command only while its managed replacement remains unchanged and owned. It preserves later foreign changes and retains their original backups and recovery explanation. Cleanup and uninstall never use command ownership as authority over Claude account data or Termux packages.

A running client, a healthy installation and a working account are separate states. Network/authentication failures do not justify deleting a runtime, replacing a token or claiming that installation failed. Paid model probes are explicit and report the exact model observed.

## One installed manual

The installer obtains Termux's `mandoc` package, which supplies `man`, and installs one manual page at `$PREFIX/share/man/man1/termux-muscle.1`. This is a copied regular file with an ownership snapshot, rather than a symlink into a versioned tool directory. The regular file is discoverable by Termux's manual index. Publication, refresh and removal use targeted index operations for this page.

Self-update refreshes a manual only while its contents and permissions match its recorded owned state. An unrelated pre-existing manual or a later foreign replacement is preserved, and the versioned manual can still be read by its full pathname. The same ownership rules govern removal and eligible restoration. The installer does not rewrite MANPATH or shell startup files, and uninstall leaves `mandoc` and other shared Termux dependencies installed.

## Scope of support

The compatibility matrix is evidence for named configurations and checks. ARM64 is required by this backend. Android release, kernel, page size, Termux build and vendor restrictions can all affect behavior. Hardware identity provides context; it is not a substitute for these software details.

MCP transports, hooks, terminal behavior, cross-session messaging, Android background-process limits and authenticated tool execution require their own evidence. A successful `--version` proves only that startup path. We add support claims when reproducible tests establish them and keep FAIL and SKIP visible.

`versions` inspects retained runtime releases and `rollback` selects the previous validated one. Arbitrary installed-version selection, persistent kept versions and an upstream version catalog are not implemented by this change.
