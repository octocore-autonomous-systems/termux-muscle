# Changes

## 0.1.0

Initial Termux Muscle release, targeting Claude Code 2.1.270 and musl 1.2.6-r2 on Android ARM64 with native Termux.

- Install from a checksummed source archive with curl; build the Bash/C manager locally with Clang and make.
- Run the original Anthropic musl executable inside a small PRoot environment using Termux's shell, resolver and certificates.
- Validate candidates before activation; retain a previous release, support offline repair and rollback, and protect running sessions during cleanup.
- Preserve existing launchers, journal explicit replacements, and restore eligible entries on uninstall.
- Build and validate management-tool updates separately from runtime updates.
- Collect local platform and model evidence without uploading it; provide a volunteer issue form and capability matrix.
- Include C unit tests and Bash regression tests for damaged downloads, unsafe inputs, interrupted transactions, locks, leases, command ownership and evidence handling.

The initial compatibility manifest documents Fable 5.1, Opus 5 and Sonnet 5. Exact authenticated results, Samsung Galaxy S26 Ultra / Android 16 / Termux 0.118.3 acceptance, and remaining limitations are recorded in the release's compatibility report and notes. A successful build on another device does not establish workflow compatibility there.

Sonnet 5 and Opus 5 passed exact authenticated checks. Fable 5.1 returned a direct response but automated probes encountered vendor fallback/refusal. Default cross-session messaging was disabled by a vendor UID-mapping check; background/screen-off behavior and actual MCP tool calls remain untested. See the [maintainer report](compatibility/galaxy-s26-ultra-20260914.md) for evidence and limits.
