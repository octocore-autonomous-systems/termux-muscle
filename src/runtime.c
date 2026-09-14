/* SPDX-License-Identifier: MPL-2.0 */
#include "tm.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

extern char **environ;

#define TM_NAMESPACE_PATH "/.termux-muscle-namespace.json"
#define TM_CONTEXT_NAME "namespace.json"
#define TM_CONTEXT_MAX (16U * 1024U)

static void bind_path_check(const char *path) {
    if (!path || path[0] != '/')
        tm_die("runtime_path_invalid", "Runtime paths must be absolute.");
    for (const unsigned char *p = (const unsigned char *)path; *p; ++p)
        if (*p == ':' || *p < 32 || *p == 127)
            tm_die("runtime_path_invalid", "Runtime paths cannot contain colon or control characters.");
}

static char *canonical_directory(const char *path) {
    char *resolved = tm_canonical(path, false);
    bind_path_check(resolved);
    tm_directory(resolved, false);
    return resolved;
}

static void executable(const char *path) {
    tm_regular(path);
    if (access(path, R_OK | X_OK) != 0)
        tm_die("runtime_dependency_missing", "A required runtime executable is unavailable; check prerequisites or repair.");
}

static char *prefix_executable(const char *prefix, const char *name) {
    char *entry = tm_path(prefix, name);
    /* Termux command entries may be symlinks to a multicall executable. Resolve
     * their source, while keeping the precise guest destination and argv[0]. */
    char *resolved = tm_canonical(entry, false);
    free(entry);
    bind_path_check(resolved);
    struct stat info;
    if (stat(resolved, &info) || !S_ISREG(info.st_mode) || access(resolved, R_OK | X_OK))
        tm_die("runtime_dependency_missing", "A required Termux executable is unavailable.");
    return resolved;
}

static json_object *read_context(const char *path) {
    size_t size = 0;
    char *text = tm_read_file(path, TM_CONTEXT_MAX, &size);
    json_object *value = tm_json_parse(text, size);
    free(text);
    if (!json_object_is_type(value, json_type_object))
        tm_die("runtime_context_invalid", "Runtime namespace metadata must be an object; run repair.");
    return value;
}

static void set_environment(const char *key, const char *value) {
    if (setenv(key, value, 1) != 0)
        tm_die("runtime_environment_failed", "Cannot prepare the runtime environment.");
}

static void context_create(const char *root, const char *prefix, const char *id) {
    tm_store_require_lock(root);
    char *release = tm_store_release(root, id);
    bind_path_check(release);
    char *binary = tm_path(release, "claude");
    char *loader = tm_path(release, "lib/ld-musl-aarch64.so.1");
    executable(binary);
    executable(loader);
    tm_store_verify(release);
    char binary_hash[65], loader_hash[65];
    tm_sha256(binary, binary_hash);
    tm_sha256(loader, loader_hash);
    json_object *identity = tm_store_identity(root);
    json_object *context = json_object_new_object();
    json_object_object_add(context, "schema", json_object_new_int(1));
    json_object_object_add(context, "installation_id", json_object_new_string(tm_json_string(identity, "id")));
    json_object_object_add(context, "root", json_object_new_string(root));
    json_object_object_add(context, "prefix", json_object_new_string(prefix));
    json_object_object_add(context, "release", json_object_new_string(release));
    json_object_object_add(context, "release_id", json_object_new_string(id));
    json_object_object_add(context, "binary_sha256", json_object_new_string(binary_hash));
    json_object_object_add(context, "loader_sha256", json_object_new_string(loader_hash));
    char *temporary = tm_path(release, "runtime-tmp");
    tm_directory(temporary, true);
    if (chmod(temporary, 0700) != 0)
        tm_die("runtime_path_invalid", "Cannot secure the runtime temporary directory.");
    char *context_path = tm_path(release, TM_CONTEXT_NAME);
    tm_json_write(context_path, context);
    free(context_path);
    free(temporary);
    json_object_put(context);
    json_object_put(identity);
    free(binary);
    free(loader);
    free(release);
}

/* Return an allocated validated release ID. Environment flags do not establish
 * namespace membership: only the bound sentinel and matching stored context do. */
static char *context_validate(json_object *context, const char *root, const char *prefix) {
    json_object *identity = tm_store_identity(root);
    if (json_object_get_int64(tm_json_field(context, "schema", json_type_int)) != 1 ||
        strcmp(tm_json_string(context, "installation_id"), tm_json_string(identity, "id")) != 0 ||
        strcmp(tm_json_string(context, "root"), root) != 0 ||
        strcmp(tm_json_string(context, "prefix"), prefix) != 0)
        tm_die("runtime_nested_conflict", "A different installation owns this namespace; start a fresh Termux shell.");
    const char *id = tm_json_string(context, "release_id");
    char *release = tm_store_release(root, id);
    if (strcmp(tm_json_string(context, "release"), release) != 0 ||
        !tm_hex_valid(tm_json_string(context, "binary_sha256"), 64) ||
        !tm_hex_valid(tm_json_string(context, "loader_sha256"), 64))
        tm_die("runtime_context_invalid", "Runtime namespace identity is invalid; run repair.");
    char *payload_path = tm_path(release, "payload.json");
    json_object *payload = tm_json_read(payload_path);
    json_object *claude = tm_json_field(payload, "claude", json_type_object);
    json_object *musl = tm_json_field(payload, "musl", json_type_object);
    if (strcmp(tm_json_string(context, "binary_sha256"), tm_json_string(claude, "binary_sha256")) != 0 ||
        strcmp(tm_json_string(context, "loader_sha256"), tm_json_string(musl, "loader_sha256")) != 0)
        tm_die("runtime_context_invalid", "Namespace source hashes disagree with the release receipt; run repair.");
    free(payload_path);
    json_object_put(payload);
    char *context_path = tm_path(release, TM_CONTEXT_NAME);
    json_object *stored = read_context(context_path);
    if (!json_object_equal(context, stored))
        tm_die("runtime_nested_conflict", "Runtime namespace metadata changed; start a fresh Termux shell.");
    char *result = tm_strdup(id);
    free(context_path);
    free(release);
    json_object_put(stored);
    json_object_put(identity);
    return result;
}

static long tracer_pid(void) {
    FILE *stream = fopen("/proc/self/status", "re");
    if (!stream)
        tm_die("runtime_trace_unknown", "Cannot inspect process tracing state; use a native Termux shell.");
    char line[512];
    long tracer = -1;
    while (fgets(line, sizeof(line), stream)) {
        if (strncmp(line, "TracerPid:", 10) == 0) {
            char *end = NULL;
            errno = 0;
            tracer = strtol(line + 10, &end, 10);
            if (errno || end == line + 10 || tracer < 0)
                tracer = -1;
            break;
        }
    }
    fclose(stream);
    if (tracer < 0)
        tm_die("runtime_trace_unknown", "Process tracing state is unavailable; use a native Termux shell.");
    return tracer;
}

static char *nested_release(const char *root, const char *prefix) {
    struct stat info;
    if (lstat(TM_NAMESPACE_PATH, &info) == 0) {
        json_object *context = read_context(TM_NAMESPACE_PATH);
        char *id = context_validate(context, root, prefix);
        json_object_put(context);
        return id;
    }
    if (errno != ENOENT)
        tm_die("runtime_context_invalid", "Cannot inspect the runtime namespace; start a fresh Termux shell.");
    if (tracer_pid() != 0)
        tm_die("runtime_foreign_tracer", "This process is already traced outside the managed runtime; use a fresh Termux shell.");
    return NULL;
}

static char *readable_source(const char *value) {
    char *resolved = tm_canonical(value, false);
    bind_path_check(resolved);
    struct stat info;
    if (stat(resolved, &info) || !S_ISREG(info.st_mode) || access(resolved, R_OK) != 0)
        tm_die("runtime_dependency_missing", "Required resolver or certificate data is not readable.");
    return resolved;
}

static char *bind_argument(const char *source, const char *destination) {
    bind_path_check(source);
    size_t size = strlen(source) + strlen(destination) + 3;
    char *value = tm_alloc(size);
    snprintf(value, size, "%s:%s!", source, destination);
    return value;
}

static int run_runtime(int argc, char **argv, const char *root, const char *prefix) {
    bool shell_probe = strcmp(argv[0], "shell-probe") == 0;
    if (shell_probe && argc != 4)
        tm_die("usage", "Usage: shell-probe ROOT PREFIX current|RELEASE_ID");
    if (!shell_probe && (argc < 6 || strcmp(argv[5], "--") != 0 ||
        (strcmp(argv[4], "normal") != 0 && strcmp(argv[4], "probe") != 0)))
        tm_die("usage", "Usage: run ROOT PREFIX current|RELEASE_ID normal|probe -- ARGUMENTS");
    bool probe = shell_probe || strcmp(argv[4], "probe") == 0;
    char *pinned = nested_release(root, prefix);
    char *selected = NULL;
    if (strcmp(argv[3], "current") == 0) {
        if (pinned) {
            selected = tm_strdup(pinned);
        } else {
            json_object *state = tm_store_state(root);
            const char *current = tm_json_optional_string(state, "current");
            if (!current)
                tm_die("not_installed", "No runtime is active; run install first.");
            selected = tm_strdup(current);
            json_object_put(state);
        }
    } else {
        if (!tm_release_valid(argv[3]))
            tm_die("invalid_release", "The selected runtime identifier is invalid.");
        selected = tm_strdup(argv[3]);
    }
    if (pinned && strcmp(pinned, selected) != 0)
        tm_die("runtime_nested_conflict", "This session pins another release; run candidate checks from a fresh Termux shell.");

    int lease = tm_store_lease(root, selected, false, false);
    char *release = tm_store_release(root, selected);
    bind_path_check(release);
    tm_store_verify(release);
    char *context_path = tm_path(release, TM_CONTEXT_NAME);
    json_object *context = read_context(context_path);
    char *context_id = context_validate(context, root, prefix);
    if (strcmp(context_id, selected) != 0)
        tm_die("runtime_context_invalid", "Selected release and namespace metadata disagree; run repair.");
    free(context_id);
    json_object_put(context);
    int descriptor_flags = fcntl(lease, F_GETFD);
    if (descriptor_flags < 0 || fcntl(lease, F_SETFD, descriptor_flags & ~FD_CLOEXEC) != 0)
        tm_die("runtime_lease_failed", "Cannot retain the release lease across runtime execution.");

    char *binary = tm_path(release, "claude");
    char *loader = tm_path(release, "lib/ld-musl-aarch64.so.1");
    executable(binary);
    executable(loader);
    char *proot = prefix_executable(prefix, "bin/proot");
    char *shell = prefix_executable(prefix, "bin/bash");
    char *env_command = prefix_executable(prefix, "bin/env");
    char *ripgrep = prefix_executable(prefix, "bin/rg");
    if (shell_probe) {
        const char *helpers[] = {"bin/mktemp", "bin/chmod", "bin/rm"};
        for (size_t i = 0; i < sizeof(helpers) / sizeof(helpers[0]); ++i) {
            char *helper = prefix_executable(prefix, helpers[i]);
            free(helper);
        }
        /* The diagnostic fixture must not source user startup hooks. Ordinary
         * vendor runs retain those settings for the user's actual workflow. */
        if (unsetenv("BASH_ENV") != 0 || unsetenv("ENV") != 0)
            tm_die("runtime_environment_failed", "Cannot isolate the shell diagnostic from startup hooks.");
    }

    if (unsetenv("LD_PRELOAD") != 0 || unsetenv("LD_LIBRARY_PATH") != 0)
        tm_die("runtime_environment_failed", "Cannot clear incompatible loader settings.");
    set_environment("DISABLE_AUTOUPDATER", "1");
    set_environment("USE_BUILTIN_RIPGREP", "0");
    if (!getenv("SHELL")) set_environment("SHELL", shell);
    if (!getenv("PATH")) {
        char *bin = tm_path(prefix, "bin");
        set_environment("PATH", bin);
        free(bin);
    }
    char *resolver_default = tm_path(prefix, "etc/resolv.conf");
    const char *resolver_override = getenv("TM_RESOLV_CONF");
    char *resolver = readable_source(resolver_override ? resolver_override : resolver_default);
    free(resolver_default);
    char *ca_default = tm_path(prefix, "etc/tls/cert.pem");
    const char *ca_override = getenv("SSL_CERT_FILE");
    char *certificate = readable_source(ca_override ? ca_override : ca_default);
    free(ca_default);
    char *temporary = tm_path(release, "runtime-tmp");
    tm_directory(temporary, false);
    if (access(temporary, W_OK | X_OK) != 0)
        tm_die("runtime_path_invalid", "Runtime temporary storage is not writable; run repair.");
    set_environment("TMPDIR", temporary);
    set_environment("BUN_TMPDIR", temporary);
    set_environment("SSL_CERT_FILE", certificate);
    char descriptor_text[32];
    snprintf(descriptor_text, sizeof(descriptor_text), "%d", lease);
    set_environment("TM_RELEASE_FD", descriptor_text);

    char **command = tm_alloc(((size_t)argc + 32) * sizeof(char *));
    size_t n = 0;
    if (!pinned) {
        command[n++] = proot;
        if (probe) command[n++] = "--kill-on-exit";
        const char *sources[] = {loader, loader, resolver, shell, env_command, temporary, context_path};
        const char *destinations[] = {"/lib/ld-musl-aarch64.so.1", "/lib/libc.musl-aarch64.so.1",
                                     "/etc/resolv.conf", "/bin/sh", "/usr/bin/env", "/tmp", TM_NAMESPACE_PATH};
        for (size_t i = 0; i < sizeof(sources) / sizeof(sources[0]); ++i) {
            command[n++] = "-b";
            command[n++] = bind_argument(sources[i], destinations[i]);
        }
    }
    if (shell_probe) {
        /* Constant shell source, with all host paths supplied as positional
         * arguments. This exercises our namespace without executing vendor
         * code, reading account data, or claiming authenticated tool coverage.
         * Normal exits/signals remove scratch; SIGKILL residue stays beneath
         * the leased release's private runtime-tmp for later release cleanup. */
        static char script[] =
            "set -euo pipefail\n"
            "umask 077\n"
            "prefix=$1\n"
            "ripgrep=$2\n"
            "work=$(\"$prefix/bin/mktemp\" -d \"$TMPDIR/.namespace-probe.XXXXXXXX\")\n"
            "trap '\"$prefix/bin/rm\" -rf -- \"$work\"' EXIT\n"
            "trap 'exit 129' HUP\n"
            "trap 'exit 130' INT\n"
            "trap 'exit 143' TERM\n"
            "[[ $(/bin/sh -c 'test -n \"${BASH_VERSION:-}\" && printf namespace-sh-ok') == namespace-sh-ok ]]\n"
            "printf '%s\\n' '#!/usr/bin/env bash' 'set -euo pipefail' "
                "'[[ -n ${BASH_VERSION:-} ]]' 'printf namespace-env-ok' > \"$work/portable hook\"\n"
            "\"$prefix/bin/chmod\" 700 \"$work/portable hook\"\n"
            "[[ $(\"$work/portable hook\") == namespace-env-ok ]]\n"
            "printf '%s\\n' namespace-rg-ok > \"$work/rg input\"\n"
            "[[ $(\"$ripgrep\" -F -x namespace-rg-ok \"$work/rg input\") == namespace-rg-ok ]]\n"
            "printf '%s\\n' namespace_shell:PASS\n";
        command[n++] = shell;
        command[n++] = "--noprofile";
        command[n++] = "--norc";
        command[n++] = "-c";
        command[n++] = script;
        command[n++] = "termux-muscle-namespace-probe";
        command[n++] = (char *)prefix;
        command[n++] = ripgrep;
    } else {
        command[n++] = binary;
        for (int i = 6; i < argc; ++i) command[n++] = argv[i];
    }
    command[n] = NULL;
    /* No shell command string and no script substitution for the vendor's
     * executable path. Native self-reexecution retains its own argv[0]. */
    execve(command[0], command, environ);
    tm_die("runtime_exec_failed", "The runtime could not start; run doctor to check dependencies.");
}

int tm_runtime_main(int argc, char **argv) {
    if (argc < 4)
        tm_die("usage", "Usage: context ROOT PREFIX RELEASE_ID, or run ROOT PREFIX SELECTOR MODE -- ARGUMENTS");
    char *root = tm_store_root(argv[1]);
    bind_path_check(root);
    char *prefix = canonical_directory(argv[2]);
    if (strcmp(argv[0], "context") == 0) {
        if (argc != 4) tm_die("usage", "Usage: context ROOT PREFIX RELEASE_ID");
        context_create(root, prefix, argv[3]);
        free(prefix);
        free(root);
        return 0;
    }
    if (strcmp(argv[0], "run") != 0 && strcmp(argv[0], "shell-probe") != 0)
        tm_die("usage", "Unknown runtime command.");
    return run_runtime(argc, argv, root, prefix);
}
