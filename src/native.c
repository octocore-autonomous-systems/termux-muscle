/* SPDX-License-Identifier: MPL-2.0 */
/* Native backend: Claude Code runs as an ordinary process, without PRoot.
 *
 * The PRoot backend leaves every downloaded byte alone and has PRoot answer for
 * three paths Android lacks. That costs a ptrace stop on every system call of
 * every process Claude Code starts. This backend prepares the release once, at
 * installation, so that nothing has to be translated while it runs:
 *
 *   1. The executable's ELF interpreter path, /lib/ld-musl-aarch64.so.1, is
 *      set to the release's own copy of the musl loader. patchelf does the
 *      edit: it adds a page for the longer path and updates the file's header
 *      tables, and leaves Anthropic's code and data as they were. The path is
 *      read back from the file and checked here.
 *   2. Three constants in that private loader copy are replaced (see settings
 *      below), so it finds a resolver file and leaves Android's linker
 *      variables to the Android programs they are meant for.
 *   3. A small object of ours, tm-resolver.so, is placed beside the loader. It
 *      opens the resolver file when a Claude Code process starts.
 *
 * Both originals are verified against their pinned or signed digests before
 * any of this, the configured loader must match a digest pinned in
 * compatibility.json, and the receipt records the digest of each installed
 * file for the check made at every launch. */
#include "tm.h"
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <openssl/evp.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#define LOADER "lib/ld-musl-aarch64.so.1"
#define RESOLVER "lib/tm-resolver.so"
#define MAX_LOADER (8U * 1024U * 1024U)
#define MAX_RESOLVER (1024U * 1024U)

/* Each constant is replaced by one of the same length, so no offset in the
 * loader moves. Each must occur exactly once, terminator included.
 *
 * - musl reads nameservers from /etc/resolv.conf, which Android does not have
 *   and an application cannot create. Descriptor 99 is where tm-resolver.so
 *   opens the resolver file the launcher selected.
 * - LD_PRELOAD and LD_LIBRARY_PATH in a Termux environment name Android
 *   (Bionic) libraries, normally termux-exec. musl cannot load those and
 *   would refuse to start. Reading differently named variables lets the
 *   caller's environment pass through untouched to the Android programs
 *   Claude Code runs, where termux-exec keeps #!/usr/bin/env scripts working. */
static const struct {
    const char *from, *to;
} settings[] = {
    {"/etc/resolv.conf", "/proc/self/fd/99"},
    {"LD_PRELOAD", "TM_PRELOAD"},
    {"LD_LIBRARY_PATH", "TM_LIBRARY_PATH"},
};

/* The loader's bytes with every setting applied; the file is not changed. */
static char *configured_loader(const char *path, size_t *total) {
    size_t size;
    char *bytes = tm_read_file(path, MAX_LOADER, &size);
    for (size_t i = 0; i < sizeof settings / sizeof *settings; i++) {
        size_t length = strlen(settings[i].from) + 1, found = 0;
        char *match = NULL;
        if (strlen(settings[i].to) + 1 != length)
            tm_die("native_unsupported", "A loader setting changes the length of its constant.");
        for (char *p = bytes; size - (size_t)(p - bytes) >= length;) {
            p = memmem(p, size - (size_t)(p - bytes), settings[i].from, length);
            if (!p)
                break;
            match = p++;
            found++;
        }
        if (found != 1)
            tm_die(
                "native_unsupported",
                "This musl loader cannot be configured for native execution; use --backend proot.");
        memcpy(match, settings[i].to, length);
    }
    *total = size;
    return bytes;
}

static void configure_loader(const char *path, const char *expected) {
    size_t size;
    char *bytes = configured_loader(path, &size);
    tm_atomic_write(path, bytes, size, 0700);
    free(bytes);
    char actual[65];
    tm_sha256(path, actual);
    if (strcmp(actual, expected))
        tm_die("integrity_failed", "The configured musl loader differs from its recorded SHA-256.");
}

/* native-loader-sha256 LOADER: the digest to pin as musl.native_loader_sha256
 * for a verified, unconfigured loader. Maintainers run it when the loader pin
 * changes; installation only ever compares against the pinned value. */
int tm_native_main(int argc, char **argv) {
    if (argc != 2 || strcmp(argv[0], "native-loader-sha256"))
        tm_die("usage", "Usage: native-loader-sha256 LOADER");
    tm_regular(argv[1]);
    size_t size;
    char *bytes = configured_loader(argv[1], &size);
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int length = 0;
    if (EVP_Digest(bytes, size, digest, &length, EVP_sha256(), NULL) != 1 || length != 32)
        tm_die("integrity_failed", "Cannot hash the configured loader.");
    for (unsigned int i = 0; i < length; i++)
        printf("%02x", digest[i]);
    putchar('\n');
    free(bytes);
    return 0;
}

/* tm-resolver.so is built with the helper and installed beside it. */
static void copy_resolver(const char *target) {
    char self[PATH_MAX];
    ssize_t length = readlink("/proc/self/exe", self, sizeof self - 1);
    if (length <= 0 || (size_t)length >= sizeof self - 1)
        tm_die("native_failed", "Cannot locate the installed helper.");
    self[length] = 0;
    char *slash = strrchr(self, '/');
    if (!slash)
        tm_die("native_failed", "Cannot locate the installed helper.");
    *slash = 0;
    char *source = tm_path(self, "tm-resolver.so");
    tm_regular(source);
    size_t size;
    char *bytes = tm_read_file(source, MAX_RESOLVER, &size);
    if (size < sizeof(Elf64_Ehdr) || memcmp(bytes, ELFMAG, SELFMAG))
        tm_die("native_failed",
               "The resolver object is missing from this build; rebuild with make.");
    tm_atomic_write(target, bytes, size, 0700);
    free(bytes);
    free(source);
}

/* The interpreter path an ELF executable asks the kernel for. */
static char *read_interpreter(const char *path) {
    tm_regular(path);
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    Elf64_Ehdr header;
    if (fd < 0 || pread(fd, &header, sizeof header, 0) != (ssize_t)sizeof header ||
        memcmp(header.e_ident, ELFMAG, SELFMAG) || header.e_ident[EI_CLASS] != ELFCLASS64 ||
        header.e_phentsize != sizeof(Elf64_Phdr) || !header.e_phnum || header.e_phnum > 256)
        tm_die("invalid_elf", "Cannot read the prepared executable's program headers.");
    char *interpreter = NULL;
    for (unsigned int i = 0; i < header.e_phnum; i++) {
        Elf64_Phdr p;
        if (header.e_phoff > (uint64_t)INT64_MAX - (i + 1) * sizeof p ||
            pread(fd, &p, sizeof p, (off_t)(header.e_phoff + i * sizeof p)) != (ssize_t)sizeof p)
            tm_die("invalid_elf", "Cannot read the prepared executable's program headers.");
        if (p.p_type != PT_INTERP)
            continue;
        if (interpreter || !p.p_filesz || p.p_filesz > PATH_MAX || p.p_offset > INT64_MAX)
            tm_die("invalid_elf", "The prepared executable has no single loader path.");
        interpreter = tm_alloc((size_t)p.p_filesz + 1);
        if (pread(fd, interpreter, (size_t)p.p_filesz, (off_t)p.p_offset) != (ssize_t)p.p_filesz ||
            strlen(interpreter) + 1 != p.p_filesz)
            tm_die("invalid_elf", "The prepared executable's loader path is malformed.");
    }
    close(fd);
    if (!interpreter)
        tm_die("invalid_elf", "The prepared executable has no single loader path.");
    return interpreter;
}

static void set_interpreter(const char *binary, const char *loader) {
    pid_t child = fork();
    if (child < 0)
        tm_die("native_failed", "Cannot start patchelf.");
    if (!child) {
        int null = open("/dev/null", O_RDWR | O_CLOEXEC);
        if (null < 0 || dup2(null, 0) < 0 || dup2(null, 1) < 0)
            _exit(126);
        char *arguments[] = {"patchelf", "--set-interpreter", (char *)loader, (char *)binary, NULL};
        execvp(arguments[0], arguments);
        _exit(127);
    }
    int code = 0;
    while (waitpid(child, &code, 0) < 0)
        if (errno != EINTR)
            tm_die("native_failed", "Cannot finish preparing the executable.");
    if (WIFEXITED(code) && WEXITSTATUS(code) == 127)
        tm_die("prerequisites", "The native backend needs patchelf (Termux package: patchelf).");
    if (!WIFEXITED(code) || WEXITSTATUS(code) != 0)
        tm_die(
            "native_failed",
            "patchelf could not set the executable's loader path; the existing runtime was preserved.");
    /* Trust the file, not the tool's exit status. */
    char *actual = read_interpreter(binary);
    if (strcmp(actual, loader))
        tm_die("native_failed",
               "The executable's loader path was not set; the existing runtime was preserved.");
    free(actual);
}

json_object *tm_native_install(const char *release, const char *expected_loader) {
    char *binary = tm_path(release, "claude"), *loader = tm_path(release, LOADER),
         *resolver = tm_path(release, RESOLVER);
    /* The loader splits its preload list at spaces and colons, so a release
     * path containing one could not name the resolver object. */
    for (const unsigned char *p = (const unsigned char *)loader; *p; p++)
        if (*p <= 32 || *p == 127 || *p == ':')
            tm_die(
                "native_unsupported",
                "The native backend needs an installation path without spaces or colons; use --backend proot or another --root.");
    configure_loader(loader, expected_loader);
    copy_resolver(resolver);
    set_interpreter(binary, loader);
    json_object *native = json_object_new_object();
    const char *keys[] = {"binary_sha256", "loader_sha256", "resolver_sha256"},
               *paths[] = {binary, loader, resolver};
    for (int i = 0; i < 3; i++) {
        char digest[65];
        tm_sha256(paths[i], digest);
        json_object_object_add(native, keys[i], json_object_new_string(digest));
    }
    json_object_object_add(native, "interpreter", json_object_new_string(loader));
    free(binary);
    free(loader);
    free(resolver);
    return native;
}
