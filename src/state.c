/* SPDX-License-Identifier: MPL-2.0 */
#include "tm.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

static bool exists(const char *p) {
    struct stat s;
    if (!lstat(p, &s)) return true;
    if (errno != ENOENT) tm_die("unsafe_path", "Cannot inspect the managed path.");
    return false;
}
static void setstr(json_object *j, const char *key, const char *value) {
    json_object_object_add(j, key, value ? json_object_new_string(value) : NULL);
}
static bool uuid_valid(const char *s) {
    if (!s || strlen(s) != 36) return false;
    for (size_t i = 0; i < 36; i++) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (s[i] != '-') return false; }
        else if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return false;
    }
    return true;
}
static void new_uuid(char out[37]) {
    char rnd[33]; tm_random_hex(rnd, 16);
    snprintf(out, 37, "%.8s-%.4s-4%.3s-a%.3s-%.12s", rnd, rnd+8, rnd+13, rnd+17, rnd+20);
}
static void parents(const char *p) {
    if (exists(p)) return;
    char *copy = tm_strdup(p), *slash = strrchr(copy, '/');
    if (!slash || slash == copy) tm_die("unsafe_root", "Installation parent is unavailable.");
    *slash = 0; parents(copy); free(copy);
    tm_directory(p, true);
}
char *tm_store_root(const char *path) {
    char *clean = tm_strdup(path);
    size_t n = strlen(clean);
    while (n > 1 && clean[n-1] == '/') clean[--n] = 0;
    struct stat st;
    if (!lstat(clean, &st) && (!S_ISDIR(st.st_mode) || st.st_uid != getuid()))
        tm_die("unsafe_root", "Installation root must be a dedicated directory, not a symlink.");
    char *root = tm_canonical(clean, true); free(clean);
    unsigned int depth = 0;
    for (const char *p = root; *p; p++) if (*p == '/') depth++;
    char *home = getenv("HOME") ? realpath(getenv("HOME"), NULL) : NULL;
    char *prefix = getenv("PREFIX") ? realpath(getenv("PREFIX"), NULL) : NULL;
    if (depth < 3 || (home && !strcmp(home, root)) || (prefix && !strcmp(prefix, root)))
        tm_die("unsafe_root", "Choose a dedicated installation directory, not a home or system directory.");
    free(home); free(prefix);
    return root;
}
json_object *tm_store_identity(const char *root) {
    tm_directory(root, false);
    char *path = tm_path(root, "installation.json");
    json_object *j = tm_json_read(path); free(path);
    if (json_object_get_int(tm_json_field(j, "schema", json_type_int)) != 1 ||
        !uuid_valid(tm_json_string(j, "id")) || strcmp(tm_json_string(j, "owner"), TM_OWNER))
        tm_die("invalid_state", "Installation identity is invalid or belongs to another application.");
    return j;
}
static void identity_matches(const char *root, json_object *j) {
    json_object *identity = tm_store_identity(root);
    if (strcmp(tm_json_string(j, "installation_id"), tm_json_string(identity, "id")))
        tm_die("invalid_state", "Managed data belongs to another installation.");
    json_object_put(identity);
}
static void nullable_release(json_object *j, const char *key) {
    json_object *v;
    if (!json_object_object_get_ex(j, key, &v)) tm_die("invalid_state", "Release state is incomplete.");
    if (v && !tm_release_valid(tm_json_string(j, key)))
        tm_die("invalid_state", "Release state contains an unsafe identifier.");
}
json_object *tm_store_state(const char *root) {
    char *path = tm_path(root, "state.json"); json_object *j = tm_json_read(path); free(path);
    identity_matches(root, j);
    if (json_object_get_int(tm_json_field(j, "schema", json_type_int)) != 1 ||
        json_object_get_int64(tm_json_field(j, "generation", json_type_int)) < 0)
        tm_die("invalid_state", "Unsupported release state; run doctor.");
    nullable_release(j, "current"); nullable_release(j, "previous");
    json_object *history = tm_json_field(j, "history", json_type_array);
    if (json_object_array_length(history) > 10000) tm_die("invalid_state", "Release history exceeds its limit.");
    for (size_t i = 0; i < json_object_array_length(history); i++) {
        json_object *v = json_object_array_get_idx(history, i);
        if (!json_object_is_type(v, json_type_string) ||
            (size_t)json_object_get_string_len(v) != strlen(json_object_get_string(v)) ||
            !tm_release_valid(json_object_get_string(v))) tm_die("invalid_state", "Release history contains an unsafe identifier.");
    }
    json_object *d;
    if (json_object_object_get_ex(j, "deletions", &d) && !json_object_is_type(d, json_type_array))
        tm_die("invalid_state", "Invalid cleanup journal.");
    return j;
}
static void save_state(const char *root, json_object *j) {
    char *path = tm_path(root, "state.json"); tm_json_write(path, j); free(path);
}
static int open_lock(const char *p, bool create) {
    int fd = open(p, O_RDWR | O_NOFOLLOW | O_CLOEXEC | (create ? O_CREAT : 0), 0600);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid())
        tm_die("unsafe_lock", "Managed lock is unavailable or was replaced.");
    return fd;
}
void tm_store_require_lock(const char *root) {
    const char *text = getenv("TM_LOCK_FD"), *locked_root = getenv("TM_LOCK_ROOT");
    if (!text || !*text || !locked_root || strcmp(locked_root, root))
        tm_die("lock_required", "Maintenance must run through with-lock.");
    char *end; errno = 0; long parsed = strtol(text, &end, 10);
    if (errno || *end || parsed < 3 || parsed > INT_MAX)
        tm_die("lock_required", "Maintenance lock descriptor is invalid.");
    int fd = (int)parsed;
    char *p = tm_path(root, ".lock"); struct stat a, b;
    if (fstat(fd, &a) || lstat(p, &b) || !S_ISREG(a.st_mode) || !S_ISREG(b.st_mode) ||
        a.st_uid != getuid() || a.st_dev != b.st_dev || a.st_ino != b.st_ino || flock(fd, LOCK_EX | LOCK_NB))
        tm_die("lock_required", "The inherited maintenance lock no longer matches this installation.");
    free(p);
    json_object_put(tm_store_identity(root));
}
static bool identity_draft(const char *name) {
    const char *prefix = ".installation.json-"; size_t n = strlen(prefix);
    if (strlen(name) != n + 24 + 4 || strncmp(name, prefix, n) || strcmp(name+n+24, ".tmp")) return false;
    char hex[25]; memcpy(hex, name+n, 24); hex[24] = 0;
    return tm_hex_valid(hex, 24);
}
/* Inspect a foreign directory before creating, truncating or adopting .lock. */
static void preflight(const char *root, bool create, char pending[37]) {
    char *idpath = tm_path(root, "installation.json");
    if (exists(idpath)) {
        json_object *identity = tm_store_identity(root);
        snprintf(pending, 37, "%s", tm_json_string(identity, "id"));
        json_object_put(identity); free(idpath); return;
    }
    free(idpath);
    if (!create) tm_die("not_installed", "No managed installation exists; run install first.");
    if (!exists(root)) return;
    tm_directory(root, false);
    DIR *dir = opendir(root); if (!dir) tm_die("unsafe_root", "Cannot inspect installation directory.");
    unsigned int count = 0; bool drafts = false;
    struct dirent *e;
    while ((e = readdir(dir))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        count++;
        if (!strcmp(e->d_name, ".lock")) continue;
        if (!identity_draft(e->d_name)) tm_die("foreign_root", "The chosen directory contains foreign files; they were preserved.");
        char *p = tm_path(root, e->d_name); tm_regular(p); free(p); drafts = true;
    }
    closedir(dir);
    if (!count) return;
    char *lock = tm_path(root, ".lock"); struct stat st;
    if (lstat(lock, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid())
        tm_die("foreign_root", "The chosen directory contains foreign files; they were preserved.");
    if (!st.st_size && !drafts && count == 1) { free(lock); return; }
    json_object *j = tm_json_read(lock); free(lock);
    if (strcmp(tm_json_string(j, "owner"), TM_OWNER) || strcmp(tm_json_string(j, "phase"), "initializing") ||
        !uuid_valid(tm_json_string(j, "installation_id")))
        tm_die("foreign_root", "The chosen directory has an unknown ownership claim.");
    snprintf(pending, 37, "%s", tm_json_string(j, "installation_id")); json_object_put(j);
}
static bool dir_empty(const char *path) {
    DIR *dir = opendir(path); if (!dir) tm_die("unsafe_path", "Cannot inspect managed directory.");
    struct dirent *e; bool empty = true;
    while ((e = readdir(dir))) if (strcmp(e->d_name, ".") && strcmp(e->d_name, "..")) { empty = false; break; }
    closedir(dir); return empty;
}
static void initialize(const char *root, const char *id) {
    char *p = tm_path(root, "installation.json");
    if (!exists(p)) {
        json_object *j = json_object_new_object(); char now[32]; tm_now(now);
        json_object_object_add(j, "schema", json_object_new_int(1));
        setstr(j, "id", id); setstr(j, "owner", TM_OWNER); setstr(j, "created", now);
        tm_json_write(p, j); json_object_put(j);
    }
    free(p); json_object_put(tm_store_identity(root));
    const char *dirs[] = {"releases", "cache", "tools", "bin", "backups"};
    for (size_t i = 0; i < sizeof dirs / sizeof *dirs; i++) { p = tm_path(root, dirs[i]); tm_directory(p, true); free(p); }
    p = tm_path(root, "state.json");
    if (!exists(p)) {
        char *r = tm_path(root, "releases");
        if (!dir_empty(r)) tm_die("invalid_state", "State is missing but releases exist; preserved for manual recovery.");
        free(r);
        json_object *j = json_object_new_object();
        json_object_object_add(j, "schema", json_object_new_int(1));
        json_object_object_add(j, "generation", json_object_new_int64(0));
        setstr(j, "installation_id", id); setstr(j, "current", NULL); setstr(j, "previous", NULL);
        json_object_object_add(j, "history", json_object_new_array());
        json_object_object_add(j, "deletions", json_object_new_array());
        tm_json_write(p, j); json_object_put(j);
    }
    free(p); json_object_put(tm_store_state(root));
    DIR *dir = opendir(root); struct dirent *e;
    if (!dir) tm_die("unsafe_root", "Cannot complete initialization recovery.");
    while ((e = readdir(dir))) if (identity_draft(e->d_name)) {
        p = tm_path(root, e->d_name); tm_regular(p);
        if (unlink(p)) tm_die("cleanup_failed", "Cannot remove interrupted initialization draft.");
        free(p);
    }
    closedir(dir); tm_sync_dir(root);
}
static int with_lock(int argc, char **argv) {
    if (argc < 5 || strcmp(argv[3], "--") || (strcmp(argv[2], "create") && strcmp(argv[2], "existing")))
        tm_die("usage", "with-lock ROOT create|existing -- COMMAND ARGS...");
    char *root = tm_store_root(argv[1]); bool create = !strcmp(argv[2], "create");
    char pending[37] = {0}; preflight(root, create, pending);
    if (create) parents(root);
    char *lockpath = tm_path(root, ".lock"); int fd = open_lock(lockpath, true); free(lockpath);
    if (flock(fd, LOCK_EX | LOCK_NB)) tm_die("busy", "Another maintenance operation is running; retry when it finishes.");
    /* A concurrent initializer could finish between preflight and acquiring. */
    preflight(root, create, pending);
    if (!*pending) new_uuid(pending);
    char *idpath = tm_path(root, "installation.json"); bool initializing = !exists(idpath); free(idpath);
    json_object *record = json_object_new_object(); char now[32]; tm_now(now);
    setstr(record, "owner", TM_OWNER); setstr(record, "installation_id", pending);
    setstr(record, "phase", initializing ? "initializing" : "maintenance"); setstr(record, "started", now);
    json_object_object_add(record, "schema", json_object_new_int(1));
    json_object_object_add(record, "pid", json_object_new_int64(getpid()));
    const char *s = json_object_to_json_string_ext(record, JSON_C_TO_STRING_PLAIN);
    if (ftruncate(fd, 0) || lseek(fd, 0, SEEK_SET) < 0) tm_die("write_failed", "Cannot update ownership journal.");
    tm_write_all(fd, s, strlen(s)); if (fsync(fd)) tm_die("sync_failed", "Cannot save ownership journal.");
    json_object_put(record);
    if (create) initialize(root, pending); else json_object_put(tm_store_identity(root));
    int inherited = fcntl(fd, F_DUPFD, 10);
    if (inherited < 0) tm_die("lock_failed", "Cannot preserve maintenance lock across subprocesses.");
    close(fd); char text[32]; snprintf(text, sizeof text, "%d", inherited);
    if (setenv("TM_LOCK_FD", text, 1) || setenv("TM_LOCK_ROOT", root, 1)) tm_die("environment", "Cannot export maintenance lock.");
    execvp(argv[4], argv+4);
    tm_die("exec_failed", "Cannot start the requested maintenance command.");
}
char *tm_store_release(const char *root, const char *id) {
    if (!tm_release_valid(id)) tm_die("invalid_release", "Release identifier is invalid.");
    char *dir = tm_path(root, "releases"); tm_directory(dir, false);
    char *release = tm_path(dir, id); free(dir); tm_directory(release, false);
    char *path = tm_path(release, ".owned.json"); json_object *j = tm_json_read(path); free(path);
    identity_matches(root, j);
    if (strcmp(tm_json_string(j, "id"), id) || json_object_get_int(tm_json_field(j, "schema", json_type_int)) != 1)
        tm_die("foreign_release", "Release ownership record does not match; files were preserved.");
    json_object_put(j); return release;
}
void tm_store_verify(const char *release) {
    char *p = tm_path(release, "payload.json"); json_object *j = tm_json_read(p); free(p);
    if (json_object_get_int(tm_json_field(j, "schema", json_type_int)) != 1 ||
        strcmp(tm_json_string(j, "backend"), "unmodified-musl-proot") || !tm_version_valid(tm_json_string(j, "version")))
        tm_die("invalid_payload", "Release receipt is invalid.");
    const char *fields[] = {"claude", "musl"}, *keys[] = {"binary_sha256", "loader_sha256"};
    const char *paths[] = {"claude", "lib/ld-musl-aarch64.so.1"};
    p = tm_path(release, "lib"); tm_directory(p, false); free(p);
    for (int i = 0; i < 2; i++) {
        json_object *source = tm_json_field(j, fields[i], json_type_object);
        const char *expected = tm_json_string(source, keys[i]); char actual[65];
        if (!tm_hex_valid(expected, 64)) tm_die("invalid_payload", "Release digest is invalid.");
        p = tm_path(release, paths[i]); tm_regular(p); tm_sha256(p, actual); free(p);
        if (strcmp(expected, actual)) tm_die("integrity_failed", "Release integrity check failed; run repair or rollback.");
    }
    json_object_put(j);
}
int tm_store_lease(const char *root, const char *id, bool exclusive, bool nonblock) {
    char *release = tm_store_release(root, id), *p = tm_path(release, ".lease");
    int fd = open_lock(p, false); free(p); free(release);
    if (flock(fd, (exclusive ? LOCK_EX : LOCK_SH) | (nonblock ? LOCK_NB : 0))) {
        int error = errno; close(fd);
        if (nonblock && (error == EWOULDBLOCK || error == EAGAIN)) return -1;
        tm_die("lease_failed", "Cannot protect the selected release from concurrent cleanup.");
    }
    release = tm_store_release(root, id); free(release); return fd;
}

static void candidate(const char *root, const char *version) {
    if (!tm_version_valid(version)) tm_die("invalid_version", "Choose an exact version in X.Y.Z form.");
    json_object_put(tm_store_state(root));
    char random[13], id[64]; tm_random_hex(random, 6); snprintf(id, sizeof id, "%s-%s", version, random);
    char *releases = tm_path(root, "releases"); tm_directory(releases, false);
    char staging_name[80]; snprintf(staging_name, sizeof staging_name, ".creating-%s", id);
    char *staging = tm_path(releases, staging_name), *target = tm_path(releases, id);
    if (mkdir(staging, 0700)) tm_die("candidate_failed", "Cannot allocate a private candidate directory.");
    json_object *j = json_object_new_object(), *identity = tm_store_identity(root);
    json_object_object_add(j, "schema", json_object_new_int(1));
    setstr(j, "installation_id", tm_json_string(identity, "id")); setstr(j, "id", id);
    char *p = tm_path(staging, ".owned.json"); tm_json_write(p, j); free(p);
    p = tm_path(staging, ".lease"); int fd = open_lock(p, true); free(p);
    if (fsync(fd)) tm_die("sync_failed", "Cannot save candidate lease."); close(fd);
    tm_sync_dir(staging);
    if (exists(target) || rename(staging, target)) tm_die("candidate_failed", "Cannot publish the candidate directory.");
    tm_sync_dir(releases); puts(id);
    json_object_put(j); json_object_put(identity); free(releases); free(staging); free(target);
}
static char *payload_version(const char *release) {
    char *p = tm_path(release, "payload.json"); json_object *j = tm_json_read(p); free(p);
    char *version = tm_strdup(tm_json_string(j, "version")); json_object_put(j);
    return version;
}
static void check_acceptance(const char *release, json_object *acceptance) {
    char *version = payload_version(release);
    if (strcmp(tm_json_string(acceptance, "status"), "PASS") ||
        strcmp(tm_json_string(acceptance, "version"), version))
        tm_die("not_validated", "Candidate startup validation did not pass for this version.");
    free(version);
}
static void validate(const char *root, const char *id, const char *file) {
    char *release = tm_store_release(root, id); tm_store_verify(release);
    json_object *j = tm_json_read(file); check_acceptance(release, j);
    char *p = tm_path(release, "acceptance.json"); tm_json_write(p, j);
    free(p); free(release); json_object_put(j);
}
static void activate(const char *root, const char *id) {
    char *release = tm_store_release(root, id); int lease = tm_store_lease(root, id, false, false);
    tm_store_verify(release);
    char *p = tm_path(release, "acceptance.json"); json_object *a = tm_json_read(p); free(p);
    check_acceptance(release, a); json_object_put(a);
    char *version = payload_version(release);
    if (strncmp(id, version, strlen(version)) || id[strlen(version)] != '-')
        tm_die("invalid_release", "Candidate version does not match its owned identifier.");
    free(version);
    json_object *state = tm_store_state(root);
    const char *current = tm_json_optional_string(state, "current");
    if (current && !strcmp(current, id)) { close(lease); free(release); json_object_put(state); return; }
    char *previous = current ? tm_strdup(current) : NULL;
    json_object *history = tm_json_field(state, "history", json_type_array), *updated = json_object_new_array();
    json_object_array_add(updated, json_object_new_string(id));
    for (size_t i = 0; i < json_object_array_length(history); i++) {
        const char *old = json_object_get_string(json_object_array_get_idx(history, i));
        if (strcmp(old, id)) json_object_array_add(updated, json_object_new_string(old));
    }
    setstr(state, "previous", previous); setstr(state, "current", id);
    json_object_object_add(state, "history", updated);
    int64_t generation = json_object_get_int64(tm_json_field(state, "generation", json_type_int));
    if (generation == INT64_MAX) tm_die("invalid_state", "Release generation reached its limit.");
    json_object_object_add(state, "generation", json_object_new_int64(generation + 1));
    save_state(root, state);
    close(lease); free(previous); free(release); json_object_put(state);
}
static bool selected(json_object *state, const char *id, size_t keep) {
    const char *s = tm_json_optional_string(state, "current");
    if (s && !strcmp(s, id)) return true;
    s = tm_json_optional_string(state, "previous");
    if (s && !strcmp(s, id)) return true;
    json_object *history = tm_json_field(state, "history", json_type_array);
    for (size_t i = 0; i < json_object_array_length(history) && i < keep; i++)
        if (!strcmp(json_object_get_string(json_object_array_get_idx(history, i)), id)) return true;
    return false;
}
/* Never follow symlinks while removing an owned, exclusively leased tombstone.
 * Stale replacement inodes are rejected by recovery before entering this tree. */
static void remove_children(int dirfd, unsigned int depth) {
    if (depth > 32) tm_die("cleanup_failed", "Owned tree exceeds the supported nesting limit; preserved for inspection.");
    int duplicate = dup(dirfd); if (duplicate < 0) tm_die("cleanup_failed", "Cannot inspect deletion directory.");
    DIR *dir = fdopendir(duplicate); if (!dir) tm_die("cleanup_failed", "Cannot inspect deletion directory.");
    struct dirent *e;
    while ((e = readdir(dir))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        struct stat st;
        if (fstatat(dirfd, e->d_name, &st, AT_SYMLINK_NOFOLLOW)) tm_die("cleanup_failed", "Deletion entry changed during cleanup.");
        if (st.st_uid != getuid()) tm_die("cleanup_failed", "Deletion directory contains a foreign-owned entry.");
        int flags = 0;
        if (S_ISDIR(st.st_mode)) {
            int child = openat(dirfd, e->d_name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            struct stat opened;
            if (child < 0 || fstat(child, &opened) || opened.st_dev != st.st_dev || opened.st_ino != st.st_ino)
                tm_die("cleanup_failed", "Deletion directory was replaced; it was preserved.");
            remove_children(child, depth + 1); close(child); flags = AT_REMOVEDIR;
        } else if (!S_ISREG(st.st_mode) && !S_ISLNK(st.st_mode))
            tm_die("cleanup_failed", "Unexpected special file in release; preserved for inspection.");
        if (unlinkat(dirfd, e->d_name, flags)) tm_die("cleanup_failed", "Cleanup was interrupted; retry to recover the owned tombstone.");
    }
    closedir(dir);
    if (fsync(dirfd)) tm_die("cleanup_failed", "Cannot save deletion progress.");
}
static void remove_history(json_object *state, const char *id) {
    json_object *history = tm_json_field(state, "history", json_type_array), *updated = json_object_new_array();
    for (size_t i = 0; i < json_object_array_length(history); i++) {
        const char *s = json_object_get_string(json_object_array_get_idx(history, i));
        if (strcmp(s, id)) json_object_array_add(updated, json_object_new_string(s));
    }
    json_object_object_add(state, "history", updated);
}
static void recover_deletions(const char *root, json_object *state) {
    json_object *journal;
    if (!json_object_object_get_ex(state, "deletions", &journal)) {
        json_object_object_add(state, "deletions", json_object_new_array()); return;
    }
    char *releases = tm_path(root, "releases"); tm_directory(releases, false);
    while (json_object_array_length(journal)) {
        json_object *record = json_object_array_get_idx(journal, 0);
        const char *id = tm_json_string(record, "id");
        if (!tm_release_valid(id) || selected(state, id, 0)) tm_die("invalid_state", "Cleanup journal refers to an active or invalid release.");
        dev_t dev = (dev_t)json_object_get_int64(tm_json_field(record, "device", json_type_int));
        ino_t ino = (ino_t)json_object_get_int64(tm_json_field(record, "inode", json_type_int));
        char name[80]; snprintf(name, sizeof name, ".deleting-%s", id);
        char *target = tm_path(releases, name), *original = tm_path(releases, id);
        struct stat st; int lease = -1;
        if (!exists(target) && exists(original)) {
            if (lstat(original, &st) || !S_ISDIR(st.st_mode) || st.st_dev != dev || st.st_ino != ino)
                tm_die("cleanup_conflict", "A journaled release was replaced; all replacement files were preserved.");
            lease = tm_store_lease(root, id, true, true);
            if (lease < 0) tm_die("busy", "A release scheduled for cleanup is still in use; retry later.");
            if (rename(original, target)) tm_die("cleanup_failed", "Cannot recover the interrupted release rename.");
            tm_sync_dir(releases);
        }
        if (exists(target)) {
            if (lstat(target, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() || st.st_dev != dev || st.st_ino != ino)
                tm_die("cleanup_conflict", "A deletion tombstone was replaced; its contents were preserved.");
            int fd = open(target, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            struct stat opened;
            if (fd < 0 || fstat(fd, &opened) || opened.st_dev != dev || opened.st_ino != ino || opened.st_uid != getuid())
                tm_die("cleanup_conflict", "Deletion directory changed while opening; it was preserved.");
            remove_children(fd, 0); close(fd);
            if (rmdir(target)) tm_die("cleanup_failed", "Cannot remove the completed deletion directory.");
            tm_sync_dir(releases);
        }
        /* A different original inode appearing after the rename is preserved.
         * It cannot be adopted later without a valid ownership record. */
        remove_history(state, id);
        json_object_array_del_idx(journal, 0, 1); save_state(root, state);
        if (lease >= 0) close(lease);
        free(target); free(original);
    }
    free(releases);
}
static void cleanup(const char *root, size_t keep, bool dry_run) {
    if (keep < 2) tm_die("invalid_retention", "Keep at least the current and previous releases.");
    json_object *state = tm_store_state(root);
    if (!dry_run) recover_deletions(root, state);
    char *releases = tm_path(root, "releases"); tm_directory(releases, false);
    DIR *dir = opendir(releases); if (!dir) tm_die("cleanup_failed", "Cannot inspect managed releases.");
    json_object *results = json_object_new_array(); struct dirent *e;
    while ((e = readdir(dir))) {
        const char *id = e->d_name;
        if (!tm_release_valid(id) || selected(state, id, keep)) continue;
        char *release = tm_store_release(root, id);
        int fd = tm_store_lease(root, id, true, true);
        if (fd < 0) { free(release); continue; }
        json_object_array_add(results, json_object_new_string(id));
        if (!dry_run) {
            struct stat st;
            if (lstat(release, &st)) tm_die("cleanup_failed", "Cannot journal the inactive release.");
            json_object *record = json_object_new_object(), *journal;
            if (!json_object_object_get_ex(state, "deletions", &journal)) {
                journal = json_object_new_array(); json_object_object_add(state, "deletions", journal);
            }
            setstr(record, "id", id);
            json_object_object_add(record, "device", json_object_new_int64((int64_t)st.st_dev));
            json_object_object_add(record, "inode", json_object_new_int64((int64_t)st.st_ino));
            json_object_array_add(journal, record); save_state(root, state);
            char name[80]; snprintf(name, sizeof name, ".deleting-%s", id);
            char *target = tm_path(releases, name);
            if (exists(target) || rename(release, target)) tm_die("cleanup_failed", "Cannot stage the journaled release deletion.");
            tm_sync_dir(releases); free(target);
            recover_deletions(root, state);
        }
        close(fd); free(release);
    }
    closedir(dir); free(releases); tm_json_print(results); json_object_put(results); json_object_put(state);
}
int tm_state_main(int argc, char **argv) {
    if (!strcmp(argv[0], "with-lock")) return with_lock(argc, argv);
    if (argc < 3) tm_die("usage", "state ROOT show|current|candidate|validate|activate|rollback|cleanup|verify");
    char *root = tm_store_root(argv[1]); const char *cmd = argv[2];
    if (!strcmp(cmd, "show") && argc == 3) { json_object *j = tm_store_state(root); tm_json_print(j); json_object_put(j); }
    else if (!strcmp(cmd, "versions") && argc == 3) {
        json_object *j = tm_store_state(root), *history = tm_json_field(j, "history", json_type_array);
        const char *current = tm_json_optional_string(j, "current"), *previous = tm_json_optional_string(j, "previous");
        printf("%-10s %-14s %s\n", "Role", "Claude Code", "Source policy");
        for (size_t i = 0; i < json_object_array_length(history); i++) {
            const char *id = json_object_get_string(json_object_array_get_idx(history, i));
            const char *role = current && !strcmp(id, current) ? "Current" : previous && !strcmp(id, previous) ? "Previous" : "Retained";
            char *release = tm_store_release(root, id), *p = tm_path(release, "payload.json");
            json_object *receipt = tm_json_read(p);
            const char *policy = tm_json_optional_string(receipt, "compatibility_status");
            printf("%-10s %-14.*s %s\n", role, (int)(strchr(id, '-') - id), id, policy ? policy : "unknown");
            json_object_put(receipt); free(p); free(release);
        }
        if (!json_object_array_length(history)) puts("No active runtime. Run termux-muscle install.");
        json_object_put(j);
    }
    else if (!strcmp(cmd, "current") && argc == 3) {
        json_object *j = tm_store_state(root); const char *id = tm_json_optional_string(j, "current");
        if (!id) tm_die("not_installed", "No active Claude Code release; run install first.");
        puts(id); json_object_put(j);
    } else if (!strcmp(cmd, "verify") && argc == 4) {
        char *release = tm_store_release(root, argv[3]); int fd = tm_store_lease(root, argv[3], false, false);
        tm_store_verify(release); close(fd); free(release);
    } else {
        tm_store_require_lock(root);
        if (!strcmp(cmd, "assert-lock") && argc == 3) { /* Verified above, before Bash performs any work. */ }
        else if (!strcmp(cmd, "candidate") && argc == 4) candidate(root, argv[3]);
        else if (!strcmp(cmd, "validate") && argc == 5) validate(root, argv[3], argv[4]);
        else if (!strcmp(cmd, "activate") && argc == 4) activate(root, argv[3]);
        else if (!strcmp(cmd, "rollback") && argc == 3) {
            json_object *j = tm_store_state(root); const char *id = tm_json_optional_string(j, "previous");
            if (!id) tm_die("no_rollback", "No previous validated release is available.");
            activate(root, id); json_object_put(j);
        } else if (!strcmp(cmd, "cleanup") && (argc == 3 || argc == 4 || argc == 5)) {
            size_t keep = 2; bool dry = false;
            if (argc > 3) {
                char *end; errno = 0; unsigned long v = strtoul(argv[3], &end, 10);
                if (errno || !*argv[3] || *end || v > 10000) tm_die("invalid_retention", "Retention count is invalid."); keep = (size_t)v;
            }
            if (argc == 5) { if (strcmp(argv[4], "--dry-run")) tm_die("usage", "Unknown cleanup argument."); dry = true; }
            cleanup(root, keep, dry);
        } else tm_die("usage", "Unknown state command or incorrect arguments.");
    }
    free(root); return 0;
}
