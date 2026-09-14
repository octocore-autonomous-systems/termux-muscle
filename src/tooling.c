/* SPDX-License-Identifier: MPL-2.0 */
#include "tm.h"
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static void uninstall(const char *root, bool keep_root);

static bool present(const char *p) {
    struct stat st;
    if (!lstat(p, &st))
        return true;
    if (errno != ENOENT)
        tm_die("tooling_path", "Cannot inspect tooling path.");
    return false;
}
static void string_set(json_object *j, const char *key, const char *s) {
    json_object_object_add(j, key, s ? json_object_new_string(s) : NULL);
}
static void identity_check(const char *root, json_object *j) {
    json_object *id = tm_store_identity(root);
    if (json_object_get_int(tm_json_field(j, "schema", json_type_int)) != 1 ||
        strcmp(tm_json_string(j, "installation_id"), tm_json_string(id, "id")))
        tm_die("tooling_identity", "Unsupported tooling schema or another "
                                   "installation's metadata; preserved.");
    json_object_put(id);
}
static json_object *record_new(const char *root) {
    json_object *j = json_object_new_object(), *id = tm_store_identity(root);
    json_object_object_add(j, "schema", json_object_new_int(1));
    string_set(j, "installation_id", tm_json_string(id, "id"));
    json_object_put(id);
    return j;
}
static bool relative_safe(const char *s) {
    if (!s || !*s || *s == '/' || strstr(s, "//") || strlen(s) >= PATH_MAX)
        return false;
    const char *part = s;
    for (const char *p = s;; p++) {
        if (!*p || *p == '/') {
            size_t n = (size_t)(p - part);
            if (!n || (n == 1 && *part == '.') || (n == 2 && !memcmp(part, "..", 2)))
                return false;
            if (!*p)
                return true;
            part = p + 1;
        } else if (!(isalnum((unsigned char)*p) || *p == '.' || *p == '_' || *p == '-'))
            return false;
    }
}
static json_object *tool_state(const char *root) {
    char *p = tm_path(root, "tooling.json");
    json_object *j;
    if (present(p)) {
        j = tm_json_read(p);
        identity_check(root, j);
    } else {
        j = record_new(root);
        string_set(j, "previous", NULL);
        json_object_object_add(j, "history", json_object_new_array());
        json_object_object_add(j, "stable", json_object_new_object());
    }
    free(p);
    json_object *a = tm_json_field(j, "history", json_type_array);
    if (json_object_array_length(a) > 4096)
        tm_die("tooling_state", "Tool history exceeds its limit.");
    for (size_t i = 0; i < json_object_array_length(a); i++) {
        json_object *v = json_object_array_get_idx(a, i);
        if (!json_object_is_type(v, json_type_string) ||
            !tm_release_valid(json_object_get_string(v)))
            tm_die("tooling_state", "Tool history contains an invalid identifier.");
    }
    const char *old = tm_json_optional_string(j, "previous");
    if (old && !tm_release_valid(old))
        tm_die("tooling_state", "Previous tool identifier is invalid.");
    tm_json_field(j, "stable", json_type_object);
    return j;
}
static char *tool_path(const char *root, const char *id) {
    if (!tm_release_valid(id))
        tm_die("tooling_id", "Invalid tool version identifier.");
    char *base = tm_path(root, "tools");
    tm_directory(base, false);
    char *p = tm_path(base, id);
    free(base);
    tm_directory(p, false);
    return p;
}
static json_object *tool_record(const char *root, const char *id, char **directory) {
    char *p = tool_path(root, id), *marker = tm_path(p, ".owned.json");
    json_object *j = tm_json_read(marker);
    free(marker);
    identity_check(root, j);
    if (strcmp(tm_json_string(j, "id"), id) || strcmp(tm_json_string(j, "phase"), "complete"))
        tm_die("tooling_identity", "Tool version ownership is incomplete or does not match.");
    const char *version = tm_json_string(j, "version");
    if (!tm_version_valid(version) || strncmp(id, version, strlen(version)) ||
        id[strlen(version)] != '-')
        tm_die("tooling_identity", "Tool version and ownership identifier disagree.");
    if (directory)
        *directory = p;
    else
        free(p);
    tm_json_field(j, "files", json_type_object);
    return j;
}
static void tool_verify(const char *root, const char *id) {
    char *dir;
    json_object *j = tool_record(root, id, &dir),
                *files = tm_json_field(j, "files", json_type_object);
    if (json_object_object_length(files) < 4 || json_object_object_length(files) > 1024)
        tm_die("tooling_integrity", "Tool file inventory is incomplete or excessive.");
    json_object_object_foreach(files, name, entry) {
        if (!relative_safe(name))
            tm_die("tooling_integrity", "Tool inventory contains an unsafe path.");
        char *components = tm_strdup(name), *part = components;
        for (char *slash; (slash = strchr(part, '/')); part = slash + 1) {
            *slash = 0;
            char *parent = tm_path(dir, components);
            tm_directory(parent, false);
            free(parent);
            *slash = '/';
        }
        free(components);
        char *p = tm_path(dir, name), actual[65];
        tm_regular(p);
        tm_sha256(p, actual);
        struct stat st;
        if (lstat(p, &st) || strcmp(actual, tm_json_string(entry, "sha256")) ||
            (st.st_mode & 0777) !=
                (mode_t)json_object_get_int(tm_json_field(entry, "mode", json_type_int)))
            tm_die("tooling_integrity",
                   "Installed tool files changed; rerun the verified source installer.");
        free(p);
    }
    free(dir);
    json_object_put(j);
}
static char *current_pointer(const char *root, bool validate_target) {
    char *p = tm_path(root, "tools/current");
    if (!present(p)) {
        free(p);
        return NULL;
    }
    struct stat st;
    if (lstat(p, &st) || !S_ISLNK(st.st_mode) || st.st_uid != getuid())
        tm_die("tooling_pointer", "Current tooling pointer was replaced; preserved.");
    char buf[128];
    ssize_t n = readlink(p, buf, sizeof buf - 1);
    free(p);
    if (n < 0 || (size_t)n >= sizeof buf - 1)
        tm_die("tooling_pointer", "Current tooling pointer is invalid.");
    buf[n] = 0;
    if (!tm_release_valid(buf))
        tm_die("tooling_pointer", "Current tooling pointer must name a relative owned version.");
    if (validate_target)
        json_object_put(tool_record(root, buf, NULL));
    return tm_strdup(buf);
}
static char *current_tool(const char *root) {
    return current_pointer(root, true);
}
static int lease_open(const char *root, const char *id, bool exclusive, bool nonblock) {
    char *dir;
    json_object_put(tool_record(root, id, &dir));
    char *p = tm_path(dir, ".lease");
    free(dir);
    int fd = open(p, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    struct stat a;
    if (fd < 0 || fstat(fd, &a) || !S_ISREG(a.st_mode) || a.st_uid != getuid())
        tm_die("tooling_lease", "Tool lease is missing or was replaced.");
    free(p);
    if (flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | (nonblock ? LOCK_NB : 0))) {
        int error = errno;
        close(fd);
        if (nonblock && (error == EAGAIN || error == EWOULDBLOCK))
            return -1;
        tm_die("tooling_lease", "Cannot protect tool files from concurrent maintenance.");
    }
    json_object_put(tool_record(root, id, NULL));
    return fd;
}
static char *shell_quote(const char *s) {
    size_t n = 3;
    for (const char *p = s; *p; p++)
        n += *p == '\'' ? 4 : 1;
    char *out = tm_alloc(n), *q = out;
    *q++ = '\'';
    for (; *s; s++) {
        if (*s == '\'') {
            memcpy(q, "'\\''", 4);
            q += 4;
        } else
            *q++ = *s;
    }
    *q++ = '\'';
    *q = 0;
    return out;
}
static char *wrapper(const char *root, const char *prefix, bool claude) {
    char *bp = tm_path(prefix, "bin/bash"), *bash = tm_canonical(bp, false);
    free(bp);
    /* Package-provided dependencies can belong to root (for example on CI).
   * Ownership checks apply to our files, not to the system's Bash executable. */
    struct stat shell_stat;
    if (stat(bash, &shell_stat) || !S_ISREG(shell_stat.st_mode) || access(bash, R_OK | X_OK) ||
        strpbrk(bash, " \t\r\n"))
        tm_die("tooling_shell", "Termux Bash must have an executable absolute path "
                                "without whitespace.");
    char *dispatch = tm_path(root, "bin/.tm-dispatch"), *quoted = shell_quote(dispatch),
         *qr = shell_quote(root);
    size_t n = strlen(bash) + strlen(quoted) + strlen(qr) + 256;
    char *s = tm_alloc(n);
    snprintf(s, n,
             "#!%s\n# Owned by Termux Muscle; tooling protocol 1.\nexec %s "
             "tooling %s run current -- %s\"$@\"\n",
             bash, quoted, qr, claude ? "run -- " : "");
    free(bash);
    free(dispatch);
    free(quoted);
    free(qr);
    return s;
}
static void hash_memory(const char *s, char hex[65]) {
    unsigned char digest[EVP_MAX_MD_SIZE];
    unsigned int n;
    if (EVP_Digest(s, strlen(s), digest, &n, EVP_sha256(), NULL) != 1 || n != 32)
        tm_die("tooling_integrity", "Cannot hash a generated launcher.");
    for (size_t i = 0; i < 32; i++)
        snprintf(hex + i * 2, 3, "%02x", digest[i]);
}
static void copy_regular(const char *source, const char *target, mode_t mode) {
    size_t size;
    char *data = tm_read_file(source, 32U * 1024U * 1024U, &size);
    tm_atomic_write(target, data, size, mode);
    free(data);
}
static bool stage_top(const char *s) {
    const char *allowed[] = {"bin",       "lib",
                             "libexec",   "docs",
                             "VERSION",   "compatibility.json",
                             "README.md", "CONTRIBUTING.md",
                             "LICENSE",   "CREDITS.md"};
    for (size_t i = 0; i < sizeof allowed / sizeof *allowed; i++)
        if (!strcmp(s, allowed[i]))
            return true;
    return false;
}
static void copy_tree(const char *source, const char *destination, const char *relative,
                      json_object *files, size_t *total, unsigned int depth) {
    if (depth > 16)
        tm_die("tooling_stage", "Tool source is nested too deeply.");
    DIR *dir = opendir(source);
    if (!dir)
        tm_die("tooling_stage", "Cannot inspect staged tooling.");
    struct dirent *e;
    while ((e = readdir(dir))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
            continue;
        if (!relative_safe(e->d_name) || (depth == 0 && !stage_top(e->d_name)))
            tm_die("tooling_stage", "Staged tooling contains an unexpected path.");
        char *src = tm_path(source, e->d_name), *dst = tm_path(destination, e->d_name),
             *name = *relative ? tm_path(relative, e->d_name) : tm_strdup(e->d_name);
        struct stat st;
        if (lstat(src, &st) || st.st_uid != getuid())
            tm_die("tooling_stage", "Staged tooling is not owned by this user.");
        if (S_ISDIR(st.st_mode)) {
            tm_directory(dst, true);
            copy_tree(src, dst, name, files, total, depth + 1);
            tm_sync_dir(dst);
        } else if (S_ISREG(st.st_mode)) {
            if (st.st_size < 0 || (uintmax_t)st.st_size > 32U * 1024U * 1024U ||
                *total + (size_t)st.st_size > 32U * 1024U * 1024U ||
                json_object_object_length(files) >= 1024)
                tm_die("tooling_stage", "Staged tooling exceeds its size limit.");
            *total += (size_t)st.st_size;
            mode_t mode =
                (!strncmp(name, "bin/", 4) || !strncmp(name, "libexec/", 8)) ? 0700 : 0600;
            copy_regular(src, dst, mode);
            char hash[65];
            tm_sha256(dst, hash);
            json_object *item = json_object_new_object();
            string_set(item, "sha256", hash);
            json_object_object_add(item, "mode", json_object_new_int(mode));
            json_object_object_add(files, name, item);
        } else
            tm_die("tooling_stage", "Staged tooling must contain only regular files "
                                    "and directories, not links.");
        free(src);
        free(dst);
        free(name);
    }
    closedir(dir);
}
static void stable_write(const char *root, const char *name, const char *source,
                         const char *contents, json_object *before, json_object *after) {
    char *dir = tm_path(root, "bin");
    tm_directory(dir, false);
    char *p = tm_path(dir, name);
    const char *wanted = tm_json_string(after, name);
    if (present(p)) {
        tm_regular(p);
        struct stat st;
        if (lstat(p, &st) || (st.st_mode & 0777) != 0700)
            tm_die("tooling_conflict", "Stable launcher permissions changed; preserved.");
        char hash[65];
        tm_sha256(p, hash);
        if (!strcmp(hash, wanted)) {
            free(dir);
            free(p);
            return;
        }
        const char *old = tm_json_optional_string(before, name);
        if (!old || strcmp(hash, old))
            tm_die("tooling_conflict",
                   "A stable launcher changed outside this manager; it was preserved.");
    }
    if (contents)
        tm_atomic_write(p, contents, strlen(contents), 0700);
    else
        copy_regular(source, p, 0700);
    tm_sync_dir(dir);
    free(dir);
    free(p);
}
static void set_current(const char *root, const char *id) {
    char *dir = tm_path(root, "tools"), *p = tm_path(dir, "current");
    char random[25], name[64];
    tm_random_hex(random, 12);
    snprintf(name, sizeof name, ".current-%s", random);
    char *temporary = tm_path(dir, name);
    if (symlink(id, temporary) || rename(temporary, p))
        tm_die("tooling_publish", "Cannot atomically select the tested tool version.");
    tm_sync_dir(dir);
    free(dir);
    free(p);
    free(temporary);
}
static void recover_publish(const char *root) {
    char *path = tm_path(root, "tooling-pending.json");
    if (!present(path)) {
        free(path);
        return;
    }
    json_object *journal = tm_json_read(path);
    identity_check(root, journal);
    const char *id = tm_json_string(journal, "id"), *old = tm_json_optional_string(journal, "old");
    if (!tm_release_valid(id) || (old && !tm_release_valid(old)))
        tm_die("tooling_journal", "Tool publication journal is invalid.");
    char *current = current_tool(root);
    if ((current && strcmp(current, id) && (!old || strcmp(current, old))) || (!current && old))
        tm_die("tooling_conflict",
               "Tool pointer changed during publication; preserved for inspection.");
    tool_verify(root, id);
    char *dir;
    json_object *owned = tool_record(root, id, &dir),
                *state = tm_json_field(journal, "state", json_type_object);
    identity_check(root, state);
    json_object *before = tm_json_field(journal, "before", json_type_object),
                *after = tm_json_field(state, "stable", json_type_object);
    const char *prefix = tm_json_string(owned, "prefix");
    char *cli = wrapper(root, prefix, false), *claude = wrapper(root, prefix, true),
         *core = tm_path(dir, "libexec/tm-core");
    stable_write(root, ".tm-dispatch", core, NULL, before, after);
    stable_write(root, "termux-muscle", NULL, cli, before, after);
    stable_write(root, "claude", NULL, claude, before, after);
    char *metadata = tm_path(root, "tooling.json");
    tm_json_write(metadata, state);
    if (!current || strcmp(current, id))
        set_current(root, id);
    if (unlink(path))
        tm_die("tooling_publish", "Tool selection succeeded but its journal needs recovery.");
    tm_sync_dir(root);
    free(current);
    free(dir);
    free(core);
    free(cli);
    free(claude);
    free(metadata);
    free(path);
    json_object_put(owned);
    json_object_put(journal);
}
static void publish(const char *root, const char *stage, const char *version, const char *prefix) {
    char *pending_uninstall = tm_path(root, "tooling-uninstall.json");
    if (present(pending_uninstall)) {
        char *stage_path = tm_canonical(stage, false);
        if (!strncmp(stage_path, root, strlen(root)) && stage_path[strlen(root)] == '/')
            tm_die("tooling_stage",
                   "Resume removal with a source stage outside the installation root.");
        free(stage_path);
        uninstall(root, true);
    }
    free(pending_uninstall);
    recover_publish(root);
    if (!tm_version_valid(version))
        tm_die("invalid_version",
               "Tool releases currently require a stable X.Y.Z semantic version.");
    char *canonical = tm_canonical(stage, false), *package = tm_canonical(prefix, false);
    tm_directory(canonical, false);
    char *p = tm_path(canonical, "VERSION");
    size_t size;
    char *text = tm_read_file(p, 128, &size);
    free(p);
    while (size && (text[size - 1] == '\n' || text[size - 1] == '\r'))
        text[--size] = 0;
    if (strcmp(text, version))
        tm_die("tooling_version", "Staged VERSION does not match the selected tool release.");
    free(text);
    char *tools = tm_path(root, "tools");
    tm_directory(tools, false);
    char random[13], id[80], draft_name[100];
    tm_random_hex(random, 6);
    snprintf(id, sizeof id, "%s-%s", version, random);
    snprintf(draft_name, sizeof draft_name, ".creating-%s", id);
    char *draft = tm_path(tools, draft_name), *target = tm_path(tools, id);
    if (mkdir(draft, 0700))
        tm_die("tooling_stage", "Cannot create an owned tooling candidate.");
    json_object *owned = record_new(root);
    string_set(owned, "id", id);
    string_set(owned, "version", version);
    string_set(owned, "prefix", package);
    string_set(owned, "phase", "staging");
    p = tm_path(draft, ".owned.json");
    tm_json_write(p, owned);
    free(p);
    p = tm_path(draft, ".lease");
    int fd = open(p, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0 || fsync(fd))
        tm_die("tooling_stage", "Cannot create the tool lease.");
    close(fd);
    free(p);
    json_object *files = json_object_new_object();
    size_t total = 0;
    copy_tree(canonical, draft, "", files, &total, 0);
    const char *required[] = {"bin/termux-muscle", "libexec/tm-core", "compatibility.json",
                              "VERSION",           "LICENSE",         "CREDITS.md"};
    for (size_t i = 0; i < sizeof required / sizeof *required; i++) {
        json_object *entry;
        if (!json_object_object_get_ex(files, required[i], &entry))
            tm_die("tooling_stage", "Staged tooling is incomplete.");
    }
    json_object_object_add(owned, "files", files);
    string_set(owned, "phase", "complete");
    p = tm_path(draft, ".owned.json");
    tm_json_write(p, owned);
    free(p);
    tm_sync_dir(draft);
    if (present(target) || rename(draft, target))
        tm_die("tooling_publish", "Cannot publish the owned tooling directory.");
    tm_sync_dir(tools);
    tool_verify(root, id);
    json_object *state = tool_state(root),
                *before = json_object_get(tm_json_field(state, "stable", json_type_object)),
                *after = json_object_new_object();
    char *cli = wrapper(root, package, false), *claude = wrapper(root, package, true), hash[65];
    hash_memory(cli, hash);
    string_set(after, "termux-muscle", hash);
    hash_memory(claude, hash);
    string_set(after, "claude", hash);
    p = tm_path(target, "libexec/tm-core");
    tm_sha256(p, hash);
    free(p);
    string_set(after, ".tm-dispatch", hash);
    free(cli);
    free(claude);
    char *old = current_tool(root);
    string_set(state, "previous", old);
    json_object *history = tm_json_field(state, "history", json_type_array),
                *updated = json_object_new_array();
    json_object_array_add(updated, json_object_new_string(id));
    for (size_t i = 0; i < json_object_array_length(history); i++)
        json_object_array_add(updated, json_object_get(json_object_array_get_idx(history, i)));
    json_object_object_add(state, "history", updated);
    json_object_object_add(state, "stable", after);
    json_object *journal = record_new(root);
    string_set(journal, "id", id);
    string_set(journal, "old", old);
    json_object_object_add(journal, "before", before);
    json_object_object_add(journal, "state", state);
    p = tm_path(root, "tooling-pending.json");
    tm_json_write(p, journal);
    free(p);
    recover_publish(root);
    puts(id);
    free(old);
    free(canonical);
    free(package);
    free(tools);
    free(draft);
    free(target);
    json_object_put(owned);
    json_object_put(journal);
}
static void run_tool(const char *root, const char *selector, int argc, char **args) {
    char *id = !strcmp(selector, "current") ? current_tool(root) : tm_strdup(selector);
    if (!id)
        tm_die("tooling_missing", "No tooling release is active; rerun the source installer.");
    int fd = lease_open(root, id, false, false);
    tool_verify(root, id);
    char *dir;
    json_object *owned = tool_record(root, id, &dir);
    const char *prefix = tm_json_string(owned, "prefix");
    char *bash = tm_path(prefix, "bin/bash"), *script = tm_path(dir, "bin/termux-muscle");
    tm_regular(script);
    if (access(bash, X_OK))
        tm_die("tooling_shell", "Termux Bash is unavailable at the recorded package prefix.");
    int inherited = fcntl(fd, F_DUPFD, 10);
    if (inherited < 0)
        tm_die("tooling_lease", "Cannot preserve the tooling lease across execution.");
    close(fd);
    char number[32];
    snprintf(number, sizeof number, "%d", inherited);
    if (setenv("TM_TOOL_FD", number, 1) || setenv("TM_TOOL_ID", id, 1) ||
        setenv("TM_TOOL_ROOT", root, 1))
        tm_die("environment", "Cannot export the owned tooling context.");
    char **command = tm_alloc((size_t)(argc + 8) * sizeof *command);
    command[0] = bash;
    command[1] = script;
    command[2] = "--root";
    command[3] = (char *)root;
    command[4] = "--prefix";
    command[5] = (char *)prefix;
    for (int i = 0; i < argc; i++)
        command[i + 6] = args[i];
    execv(bash, command);
    tm_die("exec_failed", "Cannot start the selected Bash management tool.");
}

/* Deletion always records inode identity before rename. Recovery does not
 * depend on the .owned.json surviving an interrupted recursive removal. */
static void remove_children(int fd, unsigned int depth) {
    if (depth > 32)
        tm_die("tooling_cleanup", "Owned directory nesting is excessive; preserved.");
    int duplicate = dup(fd);
    DIR *dir = duplicate < 0 ? NULL : fdopendir(duplicate);
    if (!dir)
        tm_die("tooling_cleanup", "Cannot inspect owned deletion tree.");
    struct dirent *e;
    while ((e = readdir(dir))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
            continue;
        struct stat st;
        if (fstatat(fd, e->d_name, &st, AT_SYMLINK_NOFOLLOW) || st.st_uid != getuid())
            tm_die("tooling_cleanup", "Deletion entry changed or has a foreign owner.");
        int flag = 0;
        if (S_ISDIR(st.st_mode)) {
            int child = openat(fd, e->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            struct stat opened;
            if (child < 0 || fstat(child, &opened) || opened.st_dev != st.st_dev ||
                opened.st_ino != st.st_ino)
                tm_die("tooling_cleanup", "Deletion directory was replaced; preserved.");
            remove_children(child, depth + 1);
            close(child);
            flag = AT_REMOVEDIR;
        } else if (!S_ISREG(st.st_mode) && !S_ISLNK(st.st_mode))
            tm_die("tooling_cleanup", "Special file in owned data was preserved.");
        if (unlinkat(fd, e->d_name, flag))
            tm_die("tooling_cleanup", "Deletion interrupted; rerun uninstall or cleanup.");
    }
    closedir(dir);
    if (fsync(fd))
        tm_die("tooling_cleanup", "Cannot save deletion progress.");
}
static void recover_delete(const char *root, const int *guards, size_t guard_count) {
    char *journal_path = tm_path(root, "tooling-delete.json");
    if (!present(journal_path)) {
        free(journal_path);
        return;
    }
    json_object *j = tm_json_read(journal_path);
    identity_check(root, j);
    const char *area = tm_json_string(j, "area"), *name = tm_json_string(j, "name"),
               *tomb = tm_json_string(j, "tomb");
    if ((strcmp(area, "tools") && strcmp(area, "releases") && strcmp(area, ".")) ||
        !relative_safe(name) || strchr(name, '/') || !relative_safe(tomb) || strchr(tomb, '/') ||
        strncmp(tomb, ".tool-delete-", 13) || !tm_hex_valid(tomb + 13, 24) ||
        (!strcmp(area, ".") && strcmp(name, "cache")) ||
        (!strcmp(area, "releases") && !tm_release_valid(name)) ||
        (!strcmp(area, "tools") && !tm_release_valid(name) &&
         (strncmp(name, ".creating-", 10) || !tm_release_valid(name + 10))))
        tm_die("tooling_journal", "Deletion journal has unsafe paths.");
    char *base = !strcmp(area, ".") ? tm_strdup(root) : tm_path(root, area);
    tm_directory(base, false);
    char *original = tm_path(base, name), *target = tm_path(base, tomb);
    dev_t device = (dev_t)json_object_get_int64(tm_json_field(j, "device", json_type_int));
    ino_t inode = (ino_t)json_object_get_int64(tm_json_field(j, "inode", json_type_int));
    struct stat st;
    int recovery_lease = -1;
    if (!present(target) && present(original)) {
        if (lstat(original, &st) || !S_ISDIR(st.st_mode) || st.st_dev != device ||
            st.st_ino != inode)
            tm_die("tooling_conflict", "A deletion target was replaced; all "
                                       "replacement data was preserved.");
        if (strcmp(area, ".") && tm_release_valid(name)) {
            char *lease_path = tm_path(original, ".lease");
            struct stat lease_stat;
            if (lstat(lease_path, &lease_stat) || !S_ISREG(lease_stat.st_mode) ||
                lease_stat.st_uid != getuid())
                tm_die("tooling_lease", "Deletion recovery lease is missing or unsafe.");
            bool protected = false;
            for (size_t i = 0; i < guard_count; i++) {
                struct stat held;
                if (!fstat(guards[i], &held) && held.st_dev == lease_stat.st_dev &&
                    held.st_ino == lease_stat.st_ino)
                    protected = true;
            }
            if (!protected) {
                recovery_lease = open(lease_path, O_RDWR | O_NOFOLLOW | O_CLOEXEC);
                if (recovery_lease < 0 || flock(recovery_lease, LOCK_EX | LOCK_NB))
                    tm_die("busy", "A journaled version is now in use; retry cleanup "
                                   "after its session exits.");
            }
            free(lease_path);
        }
        if (rename(original, target))
            tm_die("tooling_cleanup", "Cannot recover the owned deletion rename.");
        tm_sync_dir(base);
    }
    if (present(target)) {
        if (lstat(target, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() ||
            st.st_dev != device || st.st_ino != inode)
            tm_die("tooling_conflict", "A deletion tombstone was replaced; preserved.");
        int fd = open(target, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        struct stat opened;
        if (fd < 0 || fstat(fd, &opened) || opened.st_dev != device || opened.st_ino != inode)
            tm_die("tooling_conflict", "Deletion inode changed while opening.");
        remove_children(fd, 0);
        close(fd);
        if (rmdir(target))
            tm_die("tooling_cleanup", "Cannot finish deletion of the owned directory.");
        tm_sync_dir(base);
    }
    if (unlink(journal_path))
        tm_die("tooling_cleanup", "Cannot retire completed deletion journal.");
    tm_sync_dir(root);
    free(base);
    free(original);
    free(target);
    free(journal_path);
    json_object_put(j);
    if (recovery_lease >= 0)
        close(recovery_lease);
}
static void delete_directory(const char *root, const char *area, const char *name,
                             const int *guards, size_t guard_count) {
    recover_delete(root, guards, guard_count);
    char *base = !strcmp(area, ".") ? tm_strdup(root) : tm_path(root, area),
         *p = tm_path(base, name);
    struct stat st;
    tm_directory(p, false);
    if (lstat(p, &st))
        tm_die("tooling_cleanup", "Cannot journal owned directory identity.");
    char random[25], tomb[64];
    tm_random_hex(random, 12);
    snprintf(tomb, sizeof tomb, ".tool-delete-%s", random);
    json_object *j = record_new(root);
    string_set(j, "area", area);
    string_set(j, "name", name);
    string_set(j, "tomb", tomb);
    json_object_object_add(j, "device", json_object_new_int64((int64_t)st.st_dev));
    json_object_object_add(j, "inode", json_object_new_int64((int64_t)st.st_ino));
    char *record = tm_path(root, "tooling-delete.json");
    tm_json_write(record, j);
    free(record);
    free(base);
    free(p);
    json_object_put(j);
    recover_delete(root, guards, guard_count);
}
static bool empty_directory(const char *p) {
    DIR *dir = opendir(p);
    if (!dir)
        tm_die("tooling_path", "Cannot inspect owned directory.");
    bool empty = true;
    struct dirent *e;
    while ((e = readdir(dir)))
        if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) {
            empty = false;
            break;
        }
    closedir(dir);
    return empty;
}
static void remove_owned_drafts(const char *root) {
    char *base = tm_path(root, "tools");
    DIR *dir = opendir(base);
    if (!dir)
        tm_die("tooling_stage", "Cannot inspect interrupted source stages.");
    struct dirent *entry;
    while ((entry = readdir(dir))) {
        if (strncmp(entry->d_name, ".creating-", 10) || !tm_release_valid(entry->d_name + 10))
            continue;
        char *path = tm_path(base, entry->d_name), *marker = tm_path(path, ".owned.json");
        tm_directory(path, false);
        if (present(marker)) {
            json_object *owned = tm_json_read(marker);
            identity_check(root, owned);
            const char *phase = tm_json_string(owned, "phase");
            if (strcmp(tm_json_string(owned, "id"), entry->d_name + 10) ||
                (strcmp(phase, "staging") && strcmp(phase, "complete")))
                tm_die("tooling_stage",
                       "Interrupted tooling ownership is inconsistent; preserved.");
            json_object_put(owned);
            delete_directory(root, "tools", entry->d_name, NULL, 0);
        }
        free(path);
        free(marker);
    }
    closedir(dir);
    free(base);
}
static void clean_tools(const char *root) {
    recover_publish(root);
    recover_delete(root, NULL, 0);
    remove_owned_drafts(root);
    json_object *state = tool_state(root);
    char *current = current_tool(root);
    const char *previous = tm_json_optional_string(state, "previous");
    char *base = tm_path(root, "tools");
    DIR *dir = opendir(base);
    if (!dir)
        tm_die("tooling_path", "Cannot inspect tooling versions.");
    struct dirent *e;
    while ((e = readdir(dir))) {
        if (!tm_release_valid(e->d_name) || (current && !strcmp(e->d_name, current)) ||
            (previous && !strcmp(e->d_name, previous)))
            continue;
        int fd = lease_open(root, e->d_name, true, true);
        if (fd < 0)
            continue;
        delete_directory(root, "tools", e->d_name, &fd, 1);
        close(fd);
    }
    closedir(dir);
    json_object *history = tm_json_field(state, "history", json_type_array),
                *next = json_object_new_array();
    for (size_t i = 0; i < json_object_array_length(history); i++) {
        const char *id = json_object_get_string(json_object_array_get_idx(history, i));
        char *p = tm_path(base, id);
        if (present(p))
            json_object_array_add(next, json_object_new_string(id));
        free(p);
    }
    json_object_object_add(state, "history", next);
    char *p = tm_path(root, "tooling.json");
    tm_json_write(p, state);
    free(p);
    free(current);
    free(base);
    json_object_put(state);
}
static int own_tool_fd(const char *root, const char *id) {
    const char *text = getenv("TM_TOOL_FD"), *saved_root = getenv("TM_TOOL_ROOT"),
               *saved_id = getenv("TM_TOOL_ID");
    if (!text || !saved_root || !saved_id || strcmp(root, saved_root) || strcmp(id, saved_id))
        return -1;
    char *end;
    errno = 0;
    long number = strtol(text, &end, 10);
    if (errno || !*text || *end || number < 3 || number > INT_MAX)
        tm_die("tooling_lease", "Inherited tooling lease is invalid.");
    char *dir = tool_path(root, id), *p = tm_path(dir, ".lease");
    struct stat a, b;
    if (fstat((int)number, &a) || lstat(p, &b) || !S_ISREG(a.st_mode) || a.st_uid != getuid() ||
        a.st_dev != b.st_dev || a.st_ino != b.st_ino)
        tm_die("tooling_lease", "Inherited tooling lease no longer matches its owned version.");
    free(dir);
    free(p);
    return (int)number;
}
static json_object *hold_all_leases(const char *root, int **fds, size_t *count) {
    json_object *ids = json_object_new_object();
    json_object_object_add(ids, "releases", json_object_new_array());
    json_object_object_add(ids, "tools", json_object_new_array());
    const char *areas[] = {"releases", "tools"};
    *fds = NULL;
    *count = 0;
    for (size_t a = 0; a < 2; a++) {
        char *base = tm_path(root, areas[a]);
        if (!present(base)) {
            free(base);
            continue;
        }
        tm_directory(base, false);
        DIR *dir = opendir(base);
        if (!dir)
            tm_die("tooling_path", "Cannot inspect active installation leases.");
        struct dirent *e;
        while ((e = readdir(dir))) {
            if (!tm_release_valid(e->d_name))
                continue;
            int fd;
            if (a == 0)
                fd = tm_store_lease(root, e->d_name, true, true);
            else {
                fd = own_tool_fd(root, e->d_name);
                if (fd >= 0) {
                    if (flock(fd, LOCK_EX | LOCK_NB))
                        tm_die("busy", "Another session is using this tool version; close "
                                       "it before uninstalling.");
                    fd = dup(fd);
                } else
                    fd = lease_open(root, e->d_name, true, true);
            }
            if (fd < 0)
                tm_die("busy", "Claude Code or another management session is still "
                               "running; close it before uninstalling.");
            int *more = realloc(*fds, (*count + 1) * sizeof **fds);
            if (!more)
                tm_die("memory", "Cannot hold installation leases for removal.");
            *fds = more;
            (*fds)[(*count)++] = fd;
            json_object_array_add(tm_json_field(ids, areas[a], json_type_array),
                                  json_object_new_string(e->d_name));
        }
        closedir(dir);
        free(base);
    }
    return ids;
}
static bool unlink_regular_if_owned(const char *path, const char *expected) {
    if (!present(path))
        return true;
    struct stat st;
    if (lstat(path, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid())
        return false;
    if (expected) {
        char actual[65];
        tm_sha256(path, actual);
        if (strcmp(actual, expected) || (st.st_mode & 0777) != 0700)
            return false;
    }
    if (unlink(path))
        tm_die("tooling_uninstall", "Cannot remove an owned installation file.");
    return true;
}
static void invoke_silently(int (*operation)(int, char **), int argc, char **argv) {
    fflush(stdout);
    int saved = dup(STDOUT_FILENO), sink = open("/dev/null", O_WRONLY);
    if (saved < 0 || sink < 0 || dup2(sink, STDOUT_FILENO) < 0)
        tm_die("tooling_output", "Cannot prepare maintenance diagnostics.");
    close(sink);
    operation(argc, argv);
    fflush(stdout);
    if (dup2(saved, STDOUT_FILENO) < 0)
        tm_die("tooling_output", "Cannot restore maintenance output.");
    close(saved);
}
static void uninstall(const char *root, bool keep_root) {
    struct stat original_root;
    if (lstat(root, &original_root) || !S_ISDIR(original_root.st_mode) ||
        original_root.st_uid != getuid())
        tm_die("tooling_identity", "Installation root is unavailable or was replaced.");
    int *leases;
    size_t count;
    json_object *ids = hold_all_leases(root, &leases, &count);
    /* Reject live sessions before any restoration or cleanup. Recover the
   * runtime's own deletion journal, then reacquire all surviving leases. */
    for (size_t i = 0; i < count; i++)
        close(leases[i]);
    free(leases);
    json_object_put(ids);
    const char *owned_dirs[] = {"releases", "tools", "cache", "bin", "backups"};
    for (size_t i = 0; i < 5; i++) {
        char *d = tm_path(root, owned_dirs[i]);
        tm_directory(d, true);
        free(d);
    }
    char *cleanup_args[] = {"state", (char *)root, "cleanup", "2", NULL};
    invoke_silently(tm_state_main, 4, cleanup_args);
    ids = hold_all_leases(root, &leases, &count);
    recover_publish(root);
    recover_delete(root, leases, count);
    remove_owned_drafts(root);
    char *pending_path = tm_path(root, "tooling-uninstall.json"), *current = NULL;
    if (present(pending_path)) {
        json_object *pending = tm_json_read(pending_path);
        identity_check(root, pending);
        const char *saved_id = tm_json_optional_string(pending, "current");
        if (saved_id && !tm_release_valid(saved_id))
            tm_die("tooling_journal", "Removal journal has an invalid current version.");
        current = saved_id ? tm_strdup(saved_id) : NULL;
        char *pointer = current_pointer(root, false);
        if (pointer && (!current || strcmp(pointer, current)))
            tm_die("tooling_conflict",
                   "Tool selection changed during interrupted removal; preserved.");
        free(pointer);
        json_object_put(pending);
    } else {
        current = current_tool(root);
        json_object *pending = record_new(root);
        string_set(pending, "current", current);
        tm_json_write(pending_path, pending);
        json_object_put(pending);
    }
    /* Restore-all retains entries whose external command changed. */
    char *link_args[] = {"links", (char *)root, "restore-all", NULL};
    invoke_silently(tm_links_main, 3, link_args);
    char *link_path = tm_path(root, "links.json");
    bool retain = false;
    size_t remaining = 0;
    if (present(link_path)) {
        json_object *links = tm_json_read(link_path);
        identity_check(root, links);
        remaining =
            (size_t)json_object_object_length(tm_json_field(links, "entries", json_type_object));
        retain = remaining > 0;
        json_object_put(links);
    }
    json_object *state = tool_state(root),
                *stable = tm_json_field(state, "stable", json_type_object);
    const char *areas[] = {"releases", "tools"};
    for (size_t a = 0; a < 2; a++) {
        json_object *list = tm_json_field(ids, areas[a], json_type_array);
        for (size_t i = 0; i < json_object_array_length(list); i++)
            delete_directory(root, areas[a],
                             json_object_get_string(json_object_array_get_idx(list, i)), leases,
                             count);
    }
    char *pointer = tm_path(root, "tools/current");
    if (current && present(pointer)) {
        char buf[128];
        ssize_t n = readlink(pointer, buf, sizeof buf - 1);
        if (n >= 0 && (size_t)n < sizeof buf - 1) {
            buf[n] = 0;
            if (!strcmp(buf, current)) {
                if (unlink(pointer))
                    tm_die("tooling_uninstall", "Cannot remove owned current pointer.");
            } else
                retain = true;
        } else
            retain = true;
    }
    free(pointer);
    free(current);
    const char *names[] = {"termux-muscle", "claude", ".tm-dispatch"};
    for (size_t i = 0; i < 3; i++) {
        const char *hash = tm_json_optional_string(stable, names[i]);
        char *bin = tm_path(root, "bin"), *p = tm_path(bin, names[i]);
        if (hash) {
            if (!unlink_regular_if_owned(p, hash))
                retain = true;
        } else if (present(p))
            retain = true;
        free(bin);
        free(p);
    }
    char *cache = tm_path(root, "cache");
    if (present(cache))
        delete_directory(root, ".", "cache", leases, count);
    free(cache);
    json_object *runtime = tm_store_state(root);
    string_set(runtime, "current", NULL);
    string_set(runtime, "previous", NULL);
    json_object_object_add(runtime, "history", json_object_new_array());
    json_object_object_add(runtime, "deletions", json_object_new_array());
    char *p = tm_path(root, "state.json");
    tm_json_write(p, runtime);
    free(p);
    json_object_put(runtime);
    string_set(state, "previous", NULL);
    json_object_object_add(state, "history", json_object_new_array());
    p = tm_path(root, "tooling.json");
    tm_json_write(p, state);
    free(p);
    const char *dirs[] = {"tools", "releases", "bin", "backups"};
    for (size_t i = 0; i < 4; i++) {
        p = tm_path(root, dirs[i]);
        if (present(p)) {
            tm_directory(p, false);
            if (empty_directory(p)) {
                if (!keep_root && rmdir(p))
                    tm_die("tooling_uninstall", "Cannot remove empty owned directory.");
            } else
                retain = true;
        }
        free(p);
    }
    DIR *directory = opendir(root);
    if (!directory)
        tm_die("tooling_uninstall", "Cannot inspect installation removal result.");
    struct dirent *e;
    const char *known[] = {"installation.json",
                           "state.json",
                           "tooling.json",
                           "links.json",
                           ".lock",
                           "UNINSTALL-RECOVERY.txt",
                           "tooling-uninstall.json",
                           "tools",
                           "releases",
                           "bin",
                           "backups",
                           "cache"};
    while ((e = readdir(directory))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, ".."))
            continue;
        bool allowed = false;
        for (size_t i = 0; i < sizeof known / sizeof *known; i++)
            if (!strcmp(e->d_name, known[i]))
                allowed = true;
        if (!allowed)
            retain = true;
    }
    closedir(directory);
    if (unlink(pending_path))
        tm_die("tooling_uninstall", "Cannot retire removal journal.");
    free(pending_path);
    tm_sync_dir(root);
    json_object *result = json_object_new_object();
    if (retain) {
        const char *note = "Claude Code and owned tooling were removed. Unfamiliar files or "
                           "changed external commands were preserved. links.json and backups "
                           "retain original command restoration evidence. Review this directory "
                           "before removing it; reinstalling this manager can reuse its identity "
                           "and evidence. Claude account data and Termux packages were not "
                           "changed.\n";
        p = tm_path(root, "UNINSTALL-RECOVERY.txt");
        if (!present(p))
            tm_atomic_write(p, note, strlen(note), 0600);
        free(p);
        string_set(result, "status", "removed_with_recovery");
        string_set(result, "recovery_root", root);
    } else if (!keep_root) {
        /* Detach the fully emptied installation atomically before removing its
     * final identity/lock records; a concurrent reinstall gets a fresh root. */
        char *parent = tm_strdup(root), *slash = strrchr(parent, '/');
        if (!slash || slash == parent)
            tm_die("tooling_uninstall", "Installation parent is invalid.");
        *slash = 0;
        char random[25], name[64];
        tm_random_hex(random, 12);
        snprintf(name, sizeof name, ".termux-muscle-removed-%s", random);
        char *detached = tm_path(parent, name);
        struct stat current_root;
        if (lstat(root, &current_root) || current_root.st_dev != original_root.st_dev ||
            current_root.st_ino != original_root.st_ino)
            tm_die("tooling_identity", "Installation root changed during removal; "
                                       "replacement files were preserved.");
        if (present(detached) || rename(root, detached))
            tm_die("tooling_uninstall", "Cannot detach the removed installation.");
        tm_sync_dir(parent);
        int dirfd = open(detached, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        struct stat detached_root;
        if (dirfd < 0 || fstat(dirfd, &detached_root) ||
            detached_root.st_dev != original_root.st_dev ||
            detached_root.st_ino != original_root.st_ino)
            tm_die("tooling_uninstall", "Cannot finish detached metadata cleanup.");
        /* Remove only reserved metadata names; a late-arriving unrelated file
     * makes rmdir fail and remains preserved in the detached directory. */
        const char *metadata[] = {"installation.json", "state.json", "tooling.json",
                                  "links.json",        ".lock",      "UNINSTALL-RECOVERY.txt"};
        for (size_t i = 0; i < sizeof metadata / sizeof *metadata; i++) {
            char *entry = tm_path(detached, metadata[i]);
            if (present(entry) && !unlink_regular_if_owned(entry, NULL))
                tm_die("tooling_uninstall", "Changed metadata was preserved in the "
                                            "detached recovery directory.");
            free(entry);
        }
        if (fsync(dirfd))
            tm_die("tooling_uninstall", "Cannot save metadata cleanup.");
        close(dirfd);
        if (rmdir(detached))
            tm_die("tooling_uninstall", "Cannot remove detached metadata directory.");
        tm_sync_dir(parent);
        free(detached);
        free(parent);
        string_set(result, "status", "removed");
    }
    if (keep_root) {
        for (size_t i = 0; i < 5; i++) {
            p = tm_path(root, owned_dirs[i]);
            tm_directory(p, true);
            free(p);
        }
    }
    json_object_object_add(result, "changed_links_preserved",
                           json_object_new_int64((int64_t)remaining));
    if (!keep_root)
        tm_json_print(result);
    for (size_t i = 0; i < count; i++)
        close(leases[i]);
    free(leases);
    free(link_path);
    json_object_put(ids);
    json_object_put(state);
    json_object_put(result);
}
int tm_tooling_main(int argc, char **argv) {
    if (argc < 3)
        tm_die("usage", "tooling ROOT publish|run|cleanup|show|uninstall");
    char *root = tm_store_root(argv[1]);
    const char *action = argv[2];
    if (!strcmp(action, "run") && argc >= 5 && !strcmp(argv[4], "--"))
        run_tool(root, argv[3], argc - 5, argv + 5);
    else if (!strcmp(action, "show") && argc == 3) {
        json_object *j = tool_state(root);
        char *current = current_tool(root);
        string_set(j, "current", current);
        tm_json_print(j);
        free(current);
        json_object_put(j);
    } else {
        tm_store_require_lock(root);
        if (!strcmp(action, "publish") && argc == 6)
            publish(root, argv[3], argv[4], argv[5]);
        else if (!strcmp(action, "cleanup") && argc == 3)
            clean_tools(root);
        else if (!strcmp(action, "uninstall") && argc == 3)
            uninstall(root, false);
        else
            tm_die("usage", "Unknown tooling command or incorrect arguments.");
    }
    free(root);
    return 0;
}
