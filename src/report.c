/* SPDX-License-Identifier: MPL-2.0 */
#include "tm.h"
#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/prctl.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Captured output is private, bounded memory. Only allowlisted fields reach a
 * report. A separate process group owns each probe, including its descendants. */
typedef struct { char *text; size_t size; int code; bool timeout, overflow; } probe_result;
typedef void (*probe_callback)(void *);
static volatile sig_atomic_t interrupted_probe;
static void probe_signal(int signum) { interrupted_probe = signum; }
static long long milliseconds(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts)) tm_die("clock_failed", "Cannot bound diagnostic checks.");
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
static probe_result capture(char *const argv[], const char *cwd, unsigned timeout_ms,
                            size_t maximum, probe_callback callback, void *context) {
    probe_result result = {.text = tm_alloc(maximum + 1), .code = -1};
    const int signals[] = {SIGTERM, SIGINT, SIGHUP}; struct sigaction previous[3];
    struct sigaction action = {.sa_handler = probe_signal}; sigemptyset(&action.sa_mask);
    interrupted_probe = 0;
    for (size_t i = 0; i < 3; i++) if (sigaction(signals[i], &action, &previous[i])) tm_die("probe_failed", "Cannot protect diagnostic cleanup.");
    int pipes[2];
    if (pipe2(pipes, O_CLOEXEC)) tm_die("probe_failed", "Cannot open a diagnostic pipe.");
    fflush(NULL);
    pid_t parent = getpid(), pid = fork();
    if (pid < 0) tm_die("probe_failed", "Cannot start a diagnostic check.");
    if (!pid) {
        action.sa_handler = SIG_DFL;
        for (size_t i = 0; i < 3; i++) if (sigaction(signals[i], &action, NULL)) _exit(125);
        if (setpgid(0, 0)) _exit(125);
        /* Linux/Android sends TERM to this direct child if its supervisor is
         * killed. For PRoot this permits --kill-on-exit cleanup. No general
         * detached-descendant guarantee is claimed after supervisor SIGKILL. */
        if (prctl(PR_SET_PDEATHSIG, SIGTERM) || getppid() != parent) _exit(125);
        close(pipes[0]);
        int nullfd = open("/dev/null", O_RDWR | O_CLOEXEC);
        if (nullfd < 0 || dup2(nullfd, STDIN_FILENO) < 0 || dup2(nullfd, STDERR_FILENO) < 0 ||
            dup2(pipes[1], STDOUT_FILENO) < 0) _exit(125);
        if (nullfd > STDERR_FILENO) close(nullfd);
        if (pipes[1] > STDERR_FILENO) close(pipes[1]);
        if (cwd && chdir(cwd)) _exit(125);
        /* Avoid startup scripts and injected shell functions in optional model
         * probes; credentials remain under the official client's control. */
        unsetenv("BASH_ENV"); unsetenv("ENV");
        setenv("DISABLE_AUTOUPDATER", "1", 1);
        setenv("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1", 1);
        if (callback) { callback(context); fflush(stdout); _exit(0); }
        execv(argv[0], argv); _exit(127);
    }
    close(pipes[1]);
    (void)setpgid(pid, pid);
    int flags = fcntl(pipes[0], F_GETFL);
    if (flags < 0 || fcntl(pipes[0], F_SETFL, flags | O_NONBLOCK)) {
        kill(-pid, SIGKILL); kill(pid, SIGKILL); close(pipes[0]);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        tm_die("probe_failed", "Cannot bound diagnostic output.");
    }
    long long deadline = milliseconds() + timeout_ms;
    bool finished = false, eof = false; int status = 0;
    while (!finished || !eof) {
        if (interrupted_probe) break;
        for (;;) {
            char block[8192]; ssize_t n = read(pipes[0], block, sizeof block);
            if (!n) { eof = true; break; }
            if (n < 0) { if (errno == EINTR) continue; if (errno != EAGAIN) eof = true; break; }
            if ((size_t)n > maximum - result.size) { result.overflow = true; break; }
            memcpy(result.text + result.size, block, (size_t)n); result.size += (size_t)n;
        }
        if (!finished) {
            pid_t got = waitpid(pid, &status, WNOHANG);
            if (got == pid) finished = true;
            else if (got < 0 && errno != EINTR) { finished = true; status = 125 << 8; }
        }
        if (finished && eof) break;
        if (result.overflow) break;
        long long remaining = deadline - milliseconds();
        if (remaining <= 0) { result.timeout = true; break; }
        struct pollfd pollfd = {.fd = pipes[0], .events = POLLIN};
        (void)poll(&pollfd, 1, remaining > 25 ? 25 : (int)remaining);
    }
    /* Give PRoot's kill-on-exit handler a short opportunity to clean tracees
     * before the unconditional group kill. This grace period is also bounded. */
    if (interrupted_probe || result.timeout || result.overflow) {
        kill(-pid, SIGTERM);
        struct timespec grace = {.tv_nsec = 100000000};
        while (nanosleep(&grace, &grace) < 0 && errno == EINTR) {}
    }
    /* Always reap the probe and stop children that outlived its main process. */
    kill(-pid, SIGKILL);
    if (!finished) {
        kill(pid, SIGKILL);
        while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    }
    close(pipes[0]); result.text[result.size] = 0;
    int interrupted = interrupted_probe;
    for (size_t i = 0; i < 3; i++) (void)sigaction(signals[i], &previous[i], NULL);
    if (interrupted) _exit(128 + interrupted);
    if (WIFEXITED(status)) result.code = WEXITSTATUS(status);
    else if (WIFSIGNALED(status)) result.code = 128 + WTERMSIG(status);
    return result;
}
static bool probe_ok(probe_result *result) {
    return !result->code && !result->timeout && !result->overflow && !memchr(result->text, 0, result->size);
}
static const char *probe_detail(probe_result *result) {
    return result->timeout ? "probe_timeout" : result->overflow ? "probe_output_limit" : "probe_failed";
}
static void addstr(json_object *object, const char *key, const char *value) {
    json_object_object_add(object, key, value ? json_object_new_string(value) : NULL);
}
static const char *string_value(json_object *object, const char *key) {
    json_object *value;
    if (!object || !json_object_object_get_ex(object, key, &value) ||
        !json_object_is_type(value, json_type_string)) return NULL;
    const char *text = json_object_get_string(value);
    return strlen(text) == (size_t)json_object_get_string_len(value) ? text : NULL;
}
static bool safe_text(const char *s, size_t maximum) {
    if (!s || !*s || strlen(s) > maximum) return false;
    for (const unsigned char *p = (const unsigned char *)s; *p; p++)
        if (!isalnum(*p) && !strchr(" ._+~:()-", *p)) return false;
    return true;
}
static bool model_id(const char *s) {
    if (!s || strncmp(s, "claude-", 7) || !s[7] || strlen(s) > 100) return false;
    for (const char *p = s + 7; *p; p++) if (!(*p >= 'a' && *p <= 'z') && !isdigit((unsigned char)*p) && *p != '-') return false;
    /* User-facing aliases do not establish which model answered. */
    return strcmp(s, "claude-opus") && strcmp(s, "claude-sonnet") && strcmp(s, "claude-haiku") && strcmp(s, "claude-fable");
}
static char *trim(probe_result *result) {
    while (result->size && (result->text[result->size-1] == '\n' || result->text[result->size-1] == '\r'))
        result->text[--result->size] = 0;
    return result->text;
}
static json_object *parse_optional(const char *text, size_t size) {
    if (!size || size > 2U*TM_METADATA_MAX || memchr(text, 0, size)) return NULL;
    struct json_tokener *tokener = json_tokener_new_ex(32);
    if (!tokener) return NULL;
    json_tokener_set_flags(tokener, JSON_TOKENER_STRICT | JSON_TOKENER_VALIDATE_UTF8);
    json_object *value = json_tokener_parse_ex(tokener, text, (int)size);
    bool valid = json_tokener_get_error(tokener) == json_tokener_success;
    size_t used = json_tokener_get_parse_end(tokener);
    while (used < size && isspace((unsigned char)text[used])) used++;
    json_tokener_free(tokener);
    if (!valid || used != size || !json_object_is_type(value, json_type_object)) { json_object_put(value); return NULL; }
    return value;
}
static void check(json_object *checks, const char *id, const char *status, const char *detail) {
    json_object *item = json_object_new_object(); addstr(item, "id", id);
    addstr(item, "status", status); addstr(item, "detail_code", detail); json_object_array_add(checks, item);
}
static bool nameserver_address(char *address) {
    unsigned char binary[16]; char *zone = strchr(address, '%');
    if (zone) {
        *zone++ = 0;
        if (!*zone || strlen(zone) > 64) return false;
        for (const unsigned char *p = (const unsigned char *)zone; *p; p++)
            if (!isalnum(*p) && !strchr("_.-", *p)) return false;
        return inet_pton(AF_INET6, address, binary) == 1;
    }
    return inet_pton(AF_INET, address, binary) == 1 || inet_pton(AF_INET6, address, binary) == 1;
}
static const char *resolver_configuration(const char *prefix) {
    char *default_path = tm_path(prefix, "etc/resolv.conf");
    const char *override = getenv("TM_RESOLV_CONF"), *selected = override ? override : default_path;
    char *resolved = realpath(selected, NULL); free(default_path);
    if (!resolved) return "resolver_unavailable";
    /* Match runtime bind-path restrictions, but follow legitimate resolver
     * symlinks as the launcher does. Never expose the selected path or IPs. */
    for (const unsigned char *p = (const unsigned char *)resolved; *p; p++)
        if (*p == ':' || *p < 32 || *p == 127) { free(resolved); return "resolver_path_invalid"; }
    int fd = open(resolved, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW); free(resolved);
    struct stat info;
    if (fd < 0) return "resolver_unavailable";
    if (fstat(fd, &info) || !S_ISREG(info.st_mode)) { close(fd); return "resolver_not_regular"; }
    enum { maximum = 65536 }; char buffer[maximum+1]; size_t size = 0;
    while (size < sizeof buffer) {
        ssize_t count = read(fd, buffer+size, sizeof buffer-size);
        if (count < 0) { if (errno == EINTR) continue; close(fd); return "resolver_unreadable"; }
        if (!count) break;
        size += (size_t)count;
    }
    close(fd);
    if (size > maximum) return "resolver_size_limit";
    if (memchr(buffer, 0, size)) return "resolver_contents_invalid";
    buffer[size] = 0;
    char *save = NULL;
    for (char *line = strtok_r(buffer, "\n", &save); line; line = strtok_r(NULL, "\n", &save)) {
        while (isspace((unsigned char)*line)) line++;
        if (strncmp(line, "nameserver", 10) || !isspace((unsigned char)line[10])) continue;
        char *address = line+10; while (isspace((unsigned char)*address)) address++;
        char *end = address; while (*end && !isspace((unsigned char)*end) && *end != '#' && *end != ';') end++;
        *end = 0;
        if (nameserver_address(address)) return "nameserver_configured";
    }
    return "nameserver_missing_or_invalid";
}
static void resolver_probe(void *prefix) { puts(resolver_configuration(prefix)); }
static bool dns_check(json_object *checks, const char *prefix) {
    probe_result result = capture(NULL, NULL, 2000, 128, resolver_probe, (void *)prefix);
    bool passed = probe_ok(&result) && !strcmp(trim(&result), "nameserver_configured");
    const char *detail = probe_detail(&result);
    if (probe_ok(&result)) {
        const char *allowed[] = {"nameserver_configured", "resolver_unavailable", "resolver_path_invalid", "resolver_not_regular", "resolver_unreadable", "resolver_size_limit", "resolver_contents_invalid", "nameserver_missing_or_invalid"};
        for (size_t i=0;i<sizeof allowed/sizeof *allowed;i++) if (!strcmp(result.text,allowed[i])) detail=allowed[i];
    }
    check(checks,"dns_configuration",passed?"PASS":"FAIL",detail);free(result.text);return passed;
}
static json_object *environment(const char *prefix) {
    json_object *result = json_object_new_object(), *packages = json_object_new_object();
    const char *keys[] = {"manufacturer", "model", "android_version", "android_api", "abi"};
    const char *properties[] = {"ro.product.manufacturer", "ro.product.model", "ro.build.version.release", "ro.build.version.sdk", "ro.product.cpu.abi"};
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) {
        char *args[] = {"/system/bin/getprop", (char *)properties[i], NULL};
        probe_result value = capture(args, NULL, 1500, 512, NULL, NULL);
        const char *s = trim(&value);
        if (probe_ok(&value) && safe_text(s, 128)) {
            if (i == 3) {
                char *end; long number = strtol(s, &end, 10);
                json_object_object_add(result, keys[i], !*end && number > 0 && number < 1000 ? json_object_new_int((int)number) : NULL);
            } else addstr(result, keys[i], s);
        } else addstr(result, keys[i], NULL);
        free(value.text);
    }
    const char *manufacturer = string_value(result, "manufacturer"), *model = string_value(result, "model");
    if (manufacturer && model && !strcasecmp(manufacturer, "samsung") && !strcmp(model, "SM-S948U"))
        addstr(result, "device_name", "Samsung Galaxy S26 Ultra");
    else addstr(result, "device_name", NULL);
    struct utsname system;
    addstr(result, "kernel", !uname(&system) && safe_text(system.release, 255) ? system.release : NULL);
    long page = sysconf(_SC_PAGESIZE);
    json_object_object_add(result, "page_size", page > 0 ? json_object_new_int64(page) : NULL);
    const char *termux = getenv("TERMUX_VERSION"), *source = getenv("TERMUX_APK_RELEASE");
    addstr(result, "termux_version", safe_text(termux, 64) && isdigit((unsigned char)termux[0]) ? termux : NULL);
    bool source_known = source && (!strcmp(source, "GITHUB") || !strcmp(source, "F_DROID") || !strcmp(source, "GOOGLE_PLAY_STORE"));
    addstr(result, "termux_source", source_known ? source : NULL);
    const char *names[] = {"bash", "coreutils", "curl", "ca-certificates", "proot", "ripgrep", "clang", "make", "pkg-config", "json-c", "libarchive", "openssl", "zlib", "termux-tools", "termux-exec", "diffutils", "tar", "gzip"};
    char *dpkg = tm_path(prefix, "bin/dpkg-query");
    for (size_t i = 0; i < sizeof names / sizeof *names; i++) {
        char *args[] = {dpkg, "-W", "-f=${Version}", "--", (char *)names[i], NULL};
        probe_result value = capture(args, NULL, 1500, 256, NULL, NULL);
        const char *s = trim(&value);
        addstr(packages, names[i], probe_ok(&value) && safe_text(s, 128) && isdigit((unsigned char)s[0]) ? s : NULL);
        free(value.text);
    }
    free(dpkg); json_object_object_add(result, "packages", packages); return result;
}
static void add_model(json_object *set, const char *id, bool *invalid) {
    if (!model_id(id) || json_object_object_length(set) > 32) { *invalid = true; return; }
    json_object_object_add(set, id, json_object_new_boolean(true));
}
static json_object *model_result(const char *requested, probe_result *probe) {
    json_object *result = json_object_new_object(), *observed = json_object_new_object();
    json_object *assistants = json_object_new_object(), *usage = json_object_new_object();
    bool invalid = memchr(probe->text, 0, probe->size) != NULL, success = false;
    unsigned finals = 0; const char *api_error = NULL;
    size_t begin = 0;
    while (begin < probe->size) {
        size_t end = begin;
        while (end < probe->size && probe->text[end] != '\n') end++;
        size_t length = end - begin;
        if (length && probe->text[begin + length - 1] == '\r') length--;
        json_object *event = length ? parse_optional(probe->text + begin, length) : NULL;
        if (length && !event) invalid = true;
        const char *type = string_value(event, "type");
        if (type && !strcmp(type, "assistant")) {
            json_object *message = NULL;
            json_object_object_get_ex(event, "message", &message);
            const char *id = string_value(message, "model");
            add_model(assistants, id, &invalid); add_model(observed, id, &invalid);
        }
        if (type && !strcmp(type, "result")) {
            finals++;
            const char *subtype = string_value(event, "subtype"); json_object *error = NULL, *models = NULL;
            json_object_object_get_ex(event, "is_error", &error);
            success = subtype && !strcmp(subtype, "success") && json_object_is_type(error, json_type_boolean) && !json_object_get_boolean(error);
            if (json_object_object_get_ex(event, "modelUsage", &models)) {
                if (!json_object_is_type(models, json_type_object)) invalid = true;
                else { json_object_object_foreach(models, id, value) {
                    (void)value; add_model(usage, id, &invalid); add_model(observed, id, &invalid);
                } }
            }
        }
        json_object *error = NULL;
        if (event) json_object_object_get_ex(event, "error", &error);
        const char *error_type = string_value(error, "type");
        if (error_type) {
            if (!strcmp(error_type, "authentication_error")) api_error = "authentication_failed";
            else if (!strcmp(error_type, "permission_error")) api_error = "account_permission";
            else if (!strcmp(error_type, "rate_limit_error")) api_error = "rate_limited";
            else if (!strcmp(error_type, "overloaded_error")) api_error = "service_unavailable";
            else if (!strcmp(error_type, "not_found_error")) api_error = "model_unavailable";
            else api_error = "model_api_error";
        }
        json_object_put(event); begin = end + 1;
    }
    bool fallback = false; json_object *ids = json_object_new_array();
    json_object_object_foreach(observed, id, value) {
        (void)value; json_object_array_add(ids, json_object_new_string(id));
        if (strcmp(id, requested)) fallback = true;
    }
    const char *status = "SKIP", *detail = "model_evidence_insufficient";
    if (api_error) { status = "FAIL"; detail = api_error; }
    else if (!probe_ok(probe)) { status = "FAIL"; detail = probe_detail(probe); }
    else if (invalid || finals > 1) { status = "FAIL"; detail = "model_evidence_invalid"; }
    else if (finals == 1 && !success) { status = "FAIL"; detail = "model_api_error"; }
    else if (fallback) { status = "FAIL"; detail = "model_fallback_observed"; }
    else if (finals == 1 && json_object_object_length(assistants) == 1 && json_object_object_length(usage) == 1) {
        status = "PASS"; detail = "exact_model_verified";
    }
    addstr(result, "requested", requested); addstr(result, "status", status); addstr(result, "detail_code", detail);
    json_object_object_add(result, "observed", ids);
    json_object_put(observed); json_object_put(assistants); json_object_put(usage); return result;
}
typedef struct { const char *root; } metadata_context;
static void command_links_probe(void *root) {
    /* The links component validates ownership and snapshots every tracked
     * command without recovering or changing its journal. Paths stay inside
     * this bounded private pipe; only the owned booleans inform the report. */
    char *args[] = {"links", root, "status", NULL};
    fputs("{\"entries\":", stdout);
    if (tm_links_main(3, args)) _exit(1);
    fputs("}\n", stdout);
}
static void command_links_check(json_object *checks, const char *root) {
    probe_result result = capture(NULL, NULL, 5000, 2U*TM_METADATA_MAX, command_links_probe, (void *)root);
    json_object *value = probe_ok(&result) ? parse_optional(result.text, result.size) : NULL, *entries = NULL;
    const char *status = "FAIL", *detail = "command_ownership_invalid";
    if (result.timeout || result.overflow) detail = probe_detail(&result);
    if (value && json_object_object_get_ex(value, "entries", &entries) && json_object_is_type(entries, json_type_array)) {
        size_t count = json_object_array_length(entries); bool valid = true, owned = true;
        for (size_t i = 0; i < count; i++) {
            json_object *row = json_object_array_get_idx(entries, i), *current = NULL;
            if (!json_object_is_type(row, json_type_object) || !json_object_object_get_ex(row, "owned", &current) ||
                !json_object_is_type(current, json_type_boolean)) { valid = false; break; }
            owned = owned && json_object_get_boolean(current);
        }
        if (valid) {
            status = !count ? "SKIP" : owned ? "PASS" : "FAIL";
            detail = !count ? "no_managed_commands" : owned ? "managed_commands_owned" : "managed_command_changed_or_missing";
        }
    }
    check(checks, "command_links", status, detail); json_object_put(value); free(result.text);
}
static void metadata_probe(void *data) {
    metadata_context *context = data;
    char *root = tm_store_root(context->root);
    json_object *state = tm_store_state(root);
    const char *id = tm_json_optional_string(state, "current");
    if (!id) _exit(10);
    int lease = tm_store_lease(root, id, false, false);
    char *release = tm_store_release(root, id); tm_store_verify(release);
    char *path = tm_path(release, "payload.json"); json_object *receipt = tm_json_read(path);
    const char *version = tm_json_string(receipt, "version");
    const char *musl = tm_json_string(tm_json_field(receipt, "musl", json_type_object), "version");
    if (!tm_version_valid(version) || !safe_text(musl, 64) || !isdigit((unsigned char)musl[0])) _exit(11);
    json_object *value = json_object_new_object(); addstr(value, "id", id);
    addstr(value, "version", version); addstr(value, "musl_version", musl); tm_json_print(value);
    json_object_put(value); json_object_put(receipt); json_object_put(state); close(lease); free(path); free(release); free(root);
}
static char *self_executable(void) {
    char path[PATH_MAX]; ssize_t size = readlink("/proc/self/exe", path, sizeof path - 1);
    if (size < 1 || size >= (ssize_t)sizeof path - 1) tm_die("probe_failed", "Cannot locate the diagnostic helper.");
    path[size] = 0; return tm_strdup(path);
}
static probe_result runtime_probe(const char *self, const char *root, const char *prefix,
                                   const char *id, const char *cwd, char *const args[], unsigned timeout) {
    char *argv[64]; size_t n = 0;
    argv[n++] = (char *)self; argv[n++] = "run"; argv[n++] = (char *)root; argv[n++] = (char *)prefix;
    argv[n++] = (char *)id; argv[n++] = "probe"; argv[n++] = "--";
    for (size_t i = 0; args[i]; i++) { if (n >= 63) tm_die("usage", "Too many diagnostic arguments."); argv[n++] = args[i]; }
    argv[n] = NULL; return capture(argv, cwd, timeout, 2U*TM_METADATA_MAX, NULL, NULL);
}
static json_object *collect_report(const char *root, const char *prefix, const char *source, size_t model_count, char **models) {
    (void)source; json_object *report = json_object_new_object(), *project = json_object_new_object();
    json_object *client = json_object_new_object(), *checks = json_object_new_array(), *model_results = json_object_new_array();
    json_object_object_add(report, "schema", json_object_new_int(1)); char now[32]; tm_now(now); addstr(report, "generated_at", now);
    addstr(project, "name", "Termux Muscle"); addstr(project, "version", TM_VERSION); json_object_object_add(report, "project", project);
    addstr(client, "version", NULL); addstr(client, "musl_version", NULL); json_object_object_add(report, "claude_code", client);
    json_object_object_add(report, "environment", environment(prefix)); addstr(report, "provenance", "community");
    json_object_object_add(report, "checks", checks); json_object_object_add(report, "models", model_results);
    bool dns_ready = dns_check(checks, prefix);
    command_links_check(checks, root);
    metadata_context context = {.root = root};
    probe_result metadata = capture(NULL, NULL, 30000, 4096, metadata_probe, &context);
    json_object *receipt = probe_ok(&metadata) ? parse_optional(metadata.text, metadata.size) : NULL;
    const char *id = string_value(receipt, "id"), *version = string_value(receipt, "version"), *musl = string_value(receipt, "musl_version");
    bool valid = id && tm_release_valid(id) && version && tm_version_valid(version) && safe_text(musl, 64);
    check(checks, "runtime_integrity", valid ? "PASS" : "FAIL", valid ? "receipt_hashes_match" : "runtime_unavailable_or_invalid");
    char *self = self_executable();
    char *temporary = tm_path(prefix, "tmp/.termux-muscle-report-XXXXXXXX");
    bool temporary_ready = mkdtemp(temporary) != NULL, local_ready = valid && temporary_ready && dns_ready, model_flags_ready = false;
    if (valid) {
        addstr(client, "version", version); addstr(client, "musl_version", musl);
        const char *check_ids[] = {"startup_version", "startup_help", "namespace_shell"};
        for (size_t i = 0; i < 3; i++) {
            if (!temporary_ready) { check(checks, check_ids[i], "FAIL", "temporary_directory_unavailable"); continue; }
            probe_result probe;
            if (i < 2) { char *args[] = {i == 0 ? "--version" : "--help", NULL}; probe = runtime_probe(self, root, prefix, id, temporary, args, 30000); }
            else { char *args[] = {self, "shell-probe", (char *)root, (char *)prefix, (char *)id, NULL}; probe = capture(args, temporary, 30000, 4096, NULL, NULL); }
            bool passed = probe_ok(&probe); const char *detail = passed ? "local_probe_passed" : probe_detail(&probe);
            if (passed && !i) {
                char expected[128]; snprintf(expected, sizeof expected, "%s (Claude Code)", version);
                passed = !strcmp(trim(&probe), expected); if (!passed) detail = "runtime_version_mismatch";
            } else if (passed && i == 1) {
                passed = strstr(probe.text, "Usage:") && strstr(probe.text, "--model"); if (!passed) detail = "help_output_unrecognized";
                const char *required[] = {"--safe-mode", "--tools", "--strict-mcp-config", "--mcp-config", "--setting-sources", "--settings", "--no-session-persistence", "--disable-slash-commands", "--no-chrome", "--output-format", "--verbose"};
                model_flags_ready = passed;
                for (size_t j = 0; j < sizeof required / sizeof *required; j++) model_flags_ready = model_flags_ready && strstr(probe.text, required[j]);
            }
            else if (passed && i == 2) { passed = !strcmp(trim(&probe), "namespace_shell:PASS"); if (!passed) detail = "namespace_probe_unrecognized"; }
            local_ready = local_ready && passed;
            check(checks, check_ids[i], passed ? "PASS" : "FAIL", detail); free(probe.text);
        }
    } else {
        check(checks, "startup_version", "SKIP", "runtime_unavailable"); check(checks, "startup_help", "SKIP", "runtime_unavailable");
        check(checks, "namespace_shell", "SKIP", "runtime_unavailable");
    }
    const char *lifecycle[] = {"install", "update", "rollback", "uninstall"};
    for (size_t i = 0; i < sizeof lifecycle / sizeof *lifecycle; i++) check(checks, lifecycle[i], "SKIP", "requires_isolated_lifecycle_test");
    check(checks, "shell_tools", "SKIP", "requires_explicit_claude_tool_test");
    check(checks, "interactive", "SKIP", "requires_manual_test");
    check(checks, "background", "SKIP", "requires_manual_test");
    check(checks, "screen_off", "SKIP", "requires_manual_test");
    for (size_t i = 0; i < model_count; i++) {
        if (!local_ready || !model_flags_ready) {
            json_object *value = json_object_new_object(); addstr(value, "requested", models[i]); addstr(value, "status", "SKIP");
            addstr(value, "detail_code", !local_ready ? "runtime_unavailable" : "safe_model_flags_unavailable"); json_object_object_add(value, "observed", json_object_new_array()); json_object_array_add(model_results, value); continue;
        }
        char *args[] = {"-p", "Reply with OK.", "--model", models[i], "--output-format", "stream-json", "--verbose",
            "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--setting-sources", "",
            "--settings", "{\"disableAllHooks\":true}", "--no-session-persistence", "--disable-slash-commands", "--safe-mode", "--no-chrome", NULL};
        probe_result probe = runtime_probe(self, root, prefix, id, temporary, args, 90000);
        json_object_array_add(model_results, model_result(models[i], &probe)); free(probe.text);
    }
    if (temporary_ready) (void)rmdir(temporary);
    free(temporary); free(self); free(metadata.text); json_object_put(receipt); return report;
}
typedef struct { int fd; char *leaf; } report_parent;
static report_parent open_report_parent(const char *path) {
    char *copy = tm_strdup(path), *slash = strrchr(copy, '/');
    char *leaf = tm_strdup(slash ? slash + 1 : copy);
    if (!*leaf || !strcmp(leaf, ".") || !strcmp(leaf, ".."))
        tm_die("report_publish_failed", "Choose a new report filename.");
    if (slash) { if (slash == copy) slash[1] = 0; else *slash = 0; }
    else { free(copy); copy = tm_strdup("."); }
    char *resolved = realpath(copy, NULL); free(copy);
    if (!resolved) tm_die("report_publish_failed", "The report directory is unavailable.");
    int fd = open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); free(resolved);
    if (fd < 0) tm_die("report_publish_failed", "Cannot open the report directory.");
    return (report_parent){.fd = fd, .leaf = leaf};
}
static int publish_report(const char *temporary, const char *destination) {
    /* Android can prohibit hard links. NOREPLACE atomically preserves any
     * existing destination. Source identity is checked, not locked against a
     * concurrent same-user entry replacement. The wrapper owns its mktemp. */
    report_parent source = open_report_parent(temporary), target = open_report_parent(destination);
    int fd = openat(source.fd, source.leaf, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW); struct stat opened, named;
    if (fd < 0 || fstat(fd, &opened) || !S_ISREG(opened.st_mode) || opened.st_uid != getuid() ||
        fstatat(source.fd, source.leaf, &named, AT_SYMLINK_NOFOLLOW) || named.st_dev != opened.st_dev || named.st_ino != opened.st_ino ||
        fchmod(fd, 0600) || fstat(fd, &opened) || (opened.st_mode & 0777) != 0600 || fsync(fd))
        tm_die("report_publish_failed", "Cannot secure the completed report; choose a directory supporting private files.");
    /* Detect unsupported directory sync before publication. Retain these FDs
     * through rename and final sync, including for ~/storage/... symlinks. */
    if (fsync(source.fd) || fsync(target.fd)) tm_die("report_publish_failed", "The report directory does not support durable publication.");
#ifdef SYS_renameat2
    if (syscall(SYS_renameat2, source.fd, source.leaf, target.fd, target.leaf, 1U))
        tm_die("report_publish_failed", "Report output must be a new file on a filesystem supporting atomic publication.");
#else
    tm_die("report_publish_failed", "This system does not support atomic report publication.");
#endif
    if (fsync(target.fd) || fsync(source.fd)) tm_die("report_publish_failed", "The report was published but its directory could not be synced.");
    close(fd); close(source.fd); close(target.fd); free(source.leaf); free(target.leaf); return 0;
}
int tm_report_main(int argc, char **argv) {
    if (argc == 4 && !strcmp(argv[0], "report") && !strcmp(argv[1], "--publish")) return publish_report(argv[2], argv[3]);
    if (argc < 4) tm_die("usage", "report ROOT PREFIX SOURCE [--model exact-model-id ...]");
    char *models[8]; size_t count = 0;
    for (int i = 4; i < argc; i += 2) {
        if (!strcmp(argv[0], "doctor") || strcmp(argv[i], "--model") || i+1 >= argc || count == 8 || !model_id(argv[i+1]))
            tm_die("invalid_model", "Only test accepts up to eight explicit claude-* model IDs; model checks can use account credits.");
        for (size_t j = 0; j < count; j++) if (!strcmp(models[j], argv[i+1])) tm_die("invalid_model", "Choose each model only once.");
        models[count++] = argv[i+1];
    }
    json_object *report = collect_report(argv[1], argv[2], argv[3], count, models); tm_json_print(report);
    bool failed = false; const char *arrays[] = {"checks", "models"};
    for (size_t i = 0; i < 2; i++) {
        json_object *values; json_object_object_get_ex(report, arrays[i], &values);
        for (size_t j = 0; j < json_object_array_length(values); j++) {
            const char *status = string_value(json_object_array_get_idx(values, j), "status");
            if (status && !strcmp(status, "FAIL")) failed = true;
        }
    }
    json_object_put(report); return failed ? 1 : 0;
}
