/* SPDX-License-Identifier: MPL-2.0 */
#include "tm.h"
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

/* Only fixed check IDs, codes and advice leave this module. Configuration is
 * private input, not report material. Nothing read here is ever executed. */
#define MIGRATION_LIMIT (1024U * 1024U)
#define MIGRATION_DEPTH 32U
#define MIGRATION_ENTRIES 128U

typedef enum { READ_OK, READ_ABSENT, READ_UNREADABLE } read_state;
typedef struct {
    unsigned inspected;
    bool unreadable, conflict, home_path, limited;
} findings;

static void add_check(json_object *checks, const char *id, const char *status, const char *code,
                      const char *advice) {
    json_object *row = json_object_new_object();
    json_object_object_add(row, "id", json_object_new_string(id));
    json_object_object_add(row, "status", json_object_new_string(status));
    json_object_object_add(row, "detail_code", json_object_new_string(code));
    json_object_object_add(row, "advice", json_object_new_string(advice));
    json_object_array_add(checks, row);
}

/* Reject symlinks in every component, not just the final file. This intentionally
 * reports linked configuration as uninspected rather than following it outside
 * the requested tree. O_NONBLOCK prevents FIFO/device opens from hanging. */
static int open_private(const char *path, bool directory) {
    if (!path || !*path) {
        errno = EINVAL;
        return -1;
    }
    int fd = open(path[0] == '/' ? "/" : ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0)
        return -1;
    char *copy = tm_strdup(path), *save = NULL;
    char *part = strtok_r(copy, "/", &save);
    while (part) {
        char *next = strtok_r(NULL, "/", &save);
        int flags = O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK;
        if (next || directory)
            flags |= O_DIRECTORY;
        int child = openat(fd, part, flags);
        int error = errno;
        close(fd);
        fd = child;
        if (fd < 0) {
            errno = error;
            break;
        }
        part = next;
    }
    int error = errno;
    free(copy);
    errno = error;
    return fd;
}

static read_state read_private(const char *path, char **text, size_t *size) {
    *text = NULL;
    *size = 0;
    int fd = open_private(path, false);
    if (fd < 0)
        return errno == ENOENT ? READ_ABSENT : READ_UNREADABLE;
    struct stat info;
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_size < 0 ||
        (unsigned long long)info.st_size > MIGRATION_LIMIT) {
        close(fd);
        return READ_UNREADABLE;
    }
    char *buffer = tm_alloc(MIGRATION_LIMIT + 1);
    size_t used = 0;
    bool valid = true;
    for (;;) {
        ssize_t n = read(fd, buffer + used, MIGRATION_LIMIT + 1 - used);
        if (n < 0 && errno == EINTR)
            continue;
        if (n < 0) {
            valid = false;
            break;
        }
        if (!n)
            break;
        used += (size_t)n;
        if (used > MIGRATION_LIMIT) {
            valid = false;
            break;
        }
    }
    close(fd);
    if (!valid || memchr(buffer, 0, used)) {
        free(buffer);
        return READ_UNREADABLE;
    }
    buffer[used] = 0;
    *text = buffer;
    *size = used;
    return READ_OK;
}

static json_object *read_json(const char *path, findings *found) {
    char *text;
    size_t size;
    read_state state = read_private(path, &text, &size);
    if (state != READ_OK) {
        found->unreadable |= state == READ_UNREADABLE;
        return NULL;
    }
    struct json_tokener *tokener = json_tokener_new_ex(32);
    if (!tokener)
        tm_die("allocation_failed", "Cannot inspect migration metadata.");
    json_tokener_set_flags(tokener, JSON_TOKENER_STRICT | JSON_TOKENER_VALIDATE_UTF8);
    json_object *object = json_tokener_parse_ex(tokener, text, (int)size);
    bool valid = json_tokener_get_error(tokener) == json_tokener_success;
    size_t used = json_tokener_get_parse_end(tokener);
    while (used < size && isspace((unsigned char)text[used]))
        used++;
    valid = valid && used == size && json_object_is_type(object, json_type_object);
    json_tokener_free(tokener);
    free(text);
    if (!valid) {
        found->unreadable = true;
        json_object_put(object);
        return NULL;
    }
    found->inspected++;
    return object;
}

static void settings_file(const char *path, findings *found) {
    json_object *object = read_json(path, found), *env = NULL;
    if (object && json_object_object_get_ex(object, "env", &env)) {
        if (!json_object_is_type(env, json_type_object))
            found->unreadable = true;
        else {
            const char *keys[] = {"LD_PRELOAD", "LD_LIBRARY_PATH"};
            for (size_t i = 0; i < 2; i++) {
                json_object *value = NULL;
                if (!json_object_object_get_ex(env, keys[i], &value))
                    continue;
                if (!json_object_is_type(value, json_type_string))
                    found->unreadable = true;
                else if (json_object_get_string_len(value))
                    found->conflict = true;
            }
        }
    }
    json_object_put(object);
}

static void settings_checks(json_object *checks, const char *config, const char *cwd) {
    findings found = {0};
    if (config) {
        char *path = tm_path(config, "settings.json");
        settings_file(path, &found);
        free(path);
    } else
        found.unreadable = true;
    char *directory = cwd ? tm_strdup(cwd) : NULL;
    if (!directory)
        found.unreadable = true;
    unsigned depth = 0;
    while (directory && depth++ < MIGRATION_DEPTH) {
        const char *names[] = {".claude/settings.json", ".claude/settings.local.json"};
        for (size_t i = 0; i < 2; i++) {
            char *path = tm_path(directory, names[i]);
            settings_file(path, &found);
            free(path);
        }
        if (!strcmp(directory, "/"))
            break;
        char *slash = strrchr(directory, '/');
        if (!slash)
            break;
        if (slash == directory)
            slash[1] = 0;
        else
            *slash = 0;
    }
    found.limited = directory && strcmp(directory, "/") && depth > MIGRATION_DEPTH;
    free(directory);
    add_check(
        checks, "settings_loader_overrides",
        found.conflict                      ? "WARN"
        : found.unreadable || found.limited ? "SKIP"
                                            : "PASS",
        found.conflict ? "settings_loader_override_found" : "no_override_in_inspected_settings",
        "Review env.LD_PRELOAD and env.LD_LIBRARY_PATH in user and ancestor-project settings; remove obsolete workaround entries only after backing up the file. Settings are never rewritten.");
    add_check(
        checks, "settings_coverage", found.unreadable || found.limited ? "WARN" : "PASS",
        found.limited      ? "settings_scan_limit"
        : found.unreadable ? "settings_unreadable"
                           : "selected_settings_inspected",
        "Only the selected config directory and up to 32 current-directory ancestors are inspected. Linked, invalid, oversized or inaccessible settings require manual review; managed policies and explicit CLI settings are outside this scan.");
}

static bool home_path(const char *value) {
    return value && (!strcmp(value, "/home") || !strncmp(value, "/home/", 6));
}

/* Known path fields only: never search arbitrary prose or session transcripts. */
static void metadata_paths(json_object *object, findings *found, unsigned depth) {
    if (depth > MIGRATION_DEPTH) {
        found->limited = true;
        return;
    }
    if (json_object_is_type(object, json_type_array)) {
        size_t count = json_object_array_length(object);
        for (size_t i = 0; i < count; i++)
            metadata_paths(json_object_array_get_idx(object, i), found, depth + 1);
    } else if (json_object_is_type(object, json_type_object)) {
        json_object_object_foreach(object, key, value) {
            if (!strcmp(key, "installPath") || !strcmp(key, "installLocation") ||
                !strcmp(key, "projectPath") || !strcmp(key, "path") || !strcmp(key, "cwd")) {
                if (json_object_is_type(value, json_type_string)) {
                    const char *path = json_object_get_string(value);
                    if (strlen(path) != (size_t)json_object_get_string_len(value))
                        found->unreadable = true;
                    else if (home_path(path))
                        found->home_path = true;
                }
            }
            metadata_paths(value, found, depth + 1);
        }
    }
}

static void plugin_checks(json_object *checks, const char *config) {
    findings found = {0};
    const char *names[] = {"plugins/installed_plugins.json", "plugins/known_marketplaces.json"};
    for (size_t i = 0; config && i < 2; i++) {
        char *path = tm_path(config, names[i]);
        json_object *object = read_json(path, &found);
        metadata_paths(object, &found, 0);
        json_object_put(object);
        free(path);
    }
    if (!config)
        found.unreadable = true;
    add_check(
        checks, "plugin_paths",
        found.home_path || found.unreadable || found.limited ? "WARN" : "PASS",
        found.home_path                     ? "plugin_home_paths_require_review"
        : found.unreadable || found.limited ? "plugin_metadata_unreadable"
                                            : "no_home_paths_in_inspected_plugin_metadata",
        "Review plugin installation and marketplace metadata locally for old /home paths. Reinstall affected plugins through Claude after preserving configuration; do not mass-rewrite metadata. A /home path is a migration hint, not proof it is stale.");
}

static void git_pointer(const char *path, bool dotgit, findings *found) {
    char *text;
    size_t size;
    read_state state = read_private(path, &text, &size);
    if (state != READ_OK) {
        found->unreadable = true;
        return;
    }
    char *value = text;
    if (dotgit) {
        if (strncmp(value, "gitdir: ", 8)) {
            found->unreadable = true;
            free(text);
            return;
        }
        value += 8;
    }
    while (size && (text[size - 1] == '\n' || text[size - 1] == '\r'))
        text[--size] = 0;
    found->home_path |= home_path(value);
    found->inspected++;
    free(text);
}

static void git_checks(json_object *checks, const char *cwd) {
    findings found = {0};
    char *directory = cwd ? tm_strdup(cwd) : NULL;
    if (!directory)
        found.unreadable = true;
    unsigned depth = 0;
    while (directory && depth++ < MIGRATION_DEPTH) {
        char *git = tm_path(directory, ".git");
        struct stat info;
        if (!lstat(git, &info)) {
            if (S_ISREG(info.st_mode))
                git_pointer(git, true, &found);
            else if (S_ISDIR(info.st_mode)) {
                char *worktrees = tm_path(git, "worktrees");
                int fd = open_private(worktrees, true);
                if (fd < 0)
                    found.unreadable |= errno != ENOENT;
                else {
                    DIR *stream = fdopendir(fd);
                    if (!stream) {
                        close(fd);
                        found.unreadable = true;
                    } else {
                        struct dirent *entry;
                        unsigned count = 0;
                        for (;;) {
                            errno = 0;
                            entry = readdir(stream);
                            if (!entry) {
                                found.unreadable |= errno != 0;
                                break;
                            }
                            if (!strcmp(entry->d_name, ".") || !strcmp(entry->d_name, ".."))
                                continue;
                            if (++count > MIGRATION_ENTRIES) {
                                found.limited = true;
                                break;
                            }
                            char *child = tm_path(worktrees, entry->d_name);
                            char *pointer = tm_path(child, "gitdir");
                            git_pointer(pointer, false, &found);
                            free(pointer);
                            free(child);
                        }
                        closedir(stream);
                    }
                }
                free(worktrees);
            } else
                found.unreadable = true;
            free(git);
            break;
        }
        found.unreadable |= errno != ENOENT;
        free(git);
        if (!strcmp(directory, "/"))
            break;
        char *slash = strrchr(directory, '/');
        if (slash == directory)
            slash[1] = 0;
        else if (slash)
            *slash = 0;
        else
            break;
    }
    found.limited |= directory && strcmp(directory, "/") && depth > MIGRATION_DEPTH;
    free(directory);
    add_check(
        checks, "git_worktree_paths",
        found.home_path || found.unreadable || found.limited ? "WARN" : "PASS",
        found.home_path    ? "worktree_home_paths_require_review"
        : found.limited    ? "worktree_scan_limit"
        : found.unreadable ? "worktree_metadata_unreadable"
                           : "no_home_paths_in_inspected_worktree_pointers",
        "Inspect the current repository's worktrees with git worktree list. Preserve uncommitted files and use git worktree repair after verifying actual locations; this check does not follow a .git pointer, run Git, or scan other repositories.");
}

static void path_check(json_object *checks, const char *root) {
    const char *path = getenv("PATH");
    char *expected = tm_path(root, "bin/claude");
    struct stat managed;
    bool ready = !stat(expected, &managed) && S_ISREG(managed.st_mode) && !access(expected, X_OK);
    free(expected);
    const char *code = "no_executable_claude_on_path", *status = "WARN";
    if (!path || strlen(path) > 65536)
        code = "path_unavailable_or_oversized";
    else {
        char *copy = tm_strdup(path), *cursor = copy, *part;
        unsigned count = 0;
        while ((part = strsep(&cursor, ":"))) {
            if (++count > MIGRATION_ENTRIES) {
                code = "path_scan_limit";
                break;
            }
            char *entry = tm_path(*part ? part : ".", "claude");
            struct stat info;
            bool executable = !stat(entry, &info) && S_ISREG(info.st_mode) && !access(entry, X_OK);
            free(entry);
            if (executable) {
                bool same = ready && info.st_dev == managed.st_dev && info.st_ino == managed.st_ino;
                code = same ? "managed_executable_selected" : "unmanaged_executable_selected";
                status = same ? "PASS" : "WARN";
                break;
            }
        }
        free(copy);
    }
    add_check(
        checks, "executable_path", status, code,
        "Run type -a claude in your interactive shell and compare with the selected installation. PATH inspection cannot see parent-shell aliases, functions or command caches; use hash -r after intentional launcher changes.");
}

int tm_migration_main(int argc, char **argv) {
    if (argc != 3)
        tm_die("usage", "migration ROOT PREFIX");
    (void)argv[2];
    const char *override = getenv("CLAUDE_CONFIG_DIR"), *home = getenv("HOME");
    char *config = override && *override ? tm_strdup(override)
                   : home && *home       ? tm_path(home, ".claude")
                                         : NULL;
    char *cwd = getcwd(NULL, 0);
    json_object *report = json_object_new_object(), *checks = json_object_new_array();
    json_object_object_add(report, "schema", json_object_new_int(1));
    json_object_object_add(report, "kind", json_object_new_string("migration_advisories"));
    json_object_object_add(report, "checks", checks);
    settings_checks(checks, config, cwd);
    plugin_checks(checks, config);
    git_checks(checks, cwd);
    path_check(checks, argv[1]);
    add_check(
        checks, "shell_state", "SKIP", "parent_shell_state_not_visible",
        "Run type -a claude and hash -r in the shell that launches Claude; aliases and functions are not detectable from this child process.");
    add_check(
        checks, "session_history", "SKIP", "private_session_history_not_scanned",
        "Historical conversations are not read. If resuming an old session fails after migration, preserve it and start a new session from the actual project directory; do not bulk-rewrite transcripts.");
    add_check(
        checks, "runtime_context", "SKIP", "runtime_context_checked_at_launch",
        "Run installation and candidate checks from a fresh native Termux shell. The runtime launcher validates managed namespace identity and rejects foreign tracers; this read-only scan does not validate a runtime.");
    tm_json_print(report);
    json_object_put(report);
    free(config);
    free(cwd);
    return 0;
}
