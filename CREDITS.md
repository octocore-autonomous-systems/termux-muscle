# Credits and provenance

Termux Muscle is original OAS community tooling for maintaining Claude Code on Termux. Its design was informed by the projects below. We acknowledge the work even where we chose a different implementation.

The initial implementation does **not copy source code** from these projects. Our Bash lifecycle manager, C helper, bootstrap and tests are newly written. The reviewed repositories used MIT licenses at the revisions listed; their licenses continue to apply to their own code. Future copied or vendored code must retain the applicable notices and be recorded here.

| Source | Reviewed revision | What informed this project |
| --- | --- | --- |
| [pybe/claude-code-termux](https://github.com/pybe/claude-code-termux) | `a4cbfd9` | Android loader compatibility, subprocess identity and the limits of treating launch success as full functionality. |
| [markoboskoauroville/CLAUDE_CODE_TERMUX](https://github.com/markoboskoauroville/CLAUDE_CODE_TERMUX) | `6d1d716` | Native and Ubuntu/PRoot alternatives, explicit delivery limits and workflow testing. |
| [ferrumclaudepilgrim/claude-code-android](https://github.com/ferrumclaudepilgrim/claude-code-android) | `cf30402` | Staged validation, serialized updates, rollback and the value of testing beyond `--version`. |
| [gtbuchanan/claude-code-termux](https://github.com/gtbuchanan/claude-code-termux) | `47dd8fe` | Embedded binary dispatch, child execution paths, live Termux DNS and careful management of loader variables. |
| [Khronos31: running recent Claude Code on Termux](https://zenn.dev/khronos31/articles/termux-claude-code-latest) | Article reviewed 2026-09-14 | Official ARM64 musl payload, Alpine loader and PRoot resolver technique. Musl support and staged replacement are prior art, not inventions of this project. |
| [Anthropic issue #50270](https://github.com/anthropics/claude-code/issues/50270) | Discussion reviewed 2026-09-14 | Evidence of Android installation and native-runtime failures across client versions and devices. |

## Software downloaded separately

Release archives contain this project's source and notices, not Claude Code or a bundled Linux distribution. Installation retrieves verified payloads from the sources recorded in [compatibility.json](compatibility.json).

- **Claude Code:** supplied by Anthropic through its official npm registry package. It retains Anthropic's licenses, terms and access requirements. This project's MPL does not relicense Claude Code.
- **musl:** a separately downloaded Alpine package supplies the loader. See [musl's copyright notice](https://git.musl-libc.org/cgit/musl/tree/COPYRIGHT) and the Alpine package metadata. This project does not alter the loader bytes.
- **Termux, PRoot and system utilities:** installed by Termux's package manager under their respective licenses. See [Termux packages](https://github.com/termux/termux-packages) and [PRoot](https://github.com/proot-me/proot).
- **json-c, libarchive and OpenSSL:** provide JSON, archive and cryptographic routines through Termux packages. Their upstream licenses remain applicable; the project links the installed libraries rather than vendoring their source. See [json-c](https://github.com/json-c/json-c), [libarchive](https://github.com/libarchive/libarchive) and [OpenSSL](https://github.com/openssl/openssl).

The build and runtime also depend on the following separately installed software. Package-specific notices and any bundled-component exceptions remain authoritative:

| Software | Use | Upstream licensing reference |
| --- | --- | --- |
| Clang / LLVM | Compile the C helper on the device | [Apache-2.0 with LLVM exceptions and component notices](https://llvm.org/LICENSE.txt) |
| GNU make | Build and test orchestration | [GNU make](https://www.gnu.org/software/make/) |
| pkg-config | Find installed library build flags | [pkg-config](https://www.freedesktop.org/wiki/Software/pkg-config/) |
| GNU Bash and coreutils | Shell orchestration, checked downloads and local file operations | [Bash](https://www.gnu.org/software/bash/), [coreutils](https://www.gnu.org/software/coreutils/) |
| GNU tar and gzip | Source-release packaging and bootstrap extraction | [tar](https://www.gnu.org/software/tar/), [gzip](https://www.gnu.org/software/gzip/) |
| GNU diffutils | Compare exact bytes in mandatory regression tests | [diffutils](https://www.gnu.org/software/diffutils/) |
| curl | HTTPS downloads | [curl copyright and license](https://curl.se/docs/copyright.html) |
| ripgrep | Native search used by Claude Code | [ripgrep licensing and third-party notices](https://github.com/BurntSushi/ripgrep/blob/master/COPYING) |
| Mozilla CA certificate bundle | HTTPS trust roots supplied by Termux | [Bundle provenance and licensing](https://curl.se/docs/caextract.html) |
| zlib | Compression support used by installed libraries | [zlib license](https://zlib.net/zlib_license.html) |

See the [Termux package definitions](https://github.com/termux/termux-packages/tree/master/packages) for the exact source, patches and license metadata of each installed package, including Termux tools and termux-exec. These packages are not included in our source-release archive.

Our [LICENSE](LICENSE) is the unmodified Mozilla Public License 2.0 text obtained from [Mozilla](https://www.mozilla.org/media/MPL/2.0/index.txt). All original project source is subject to MPL-2.0. No additional trademark rights or Anthropic endorsement are implied.
