/* SPDX-License-Identifier: MPL-2.0 */
#include "tm.h"

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define LINK_BACKUP_MAX (512ULL * 1024ULL * 1024ULL)

static bool exists(const char *path) {
    struct stat info;
    if (lstat(path, &info) == 0)
        return true;
    if (errno == ENOENT)
        return false;
    tm_die("link_conflict", "Cannot inspect the command entry; it was preserved.");
}

static void split_path(const char *path, char **parent, char **leaf) {
    if (!path || path[0] != '/' || strlen(path) >= PATH_MAX)
        tm_die("invalid_state", "Command metadata contains an invalid absolute path.");
    const char *slash = strrchr(path, '/');
    if (!slash[1] || !strcmp(slash + 1, ".") || !strcmp(slash + 1, ".."))
        tm_die("invalid_state", "A command entry must name a file.");
    *parent = tm_strdup(path);
    if (slash == path)
        (*parent)[1] = 0;
    else
        (*parent)[slash - path] = 0;
    *leaf = tm_strdup(slash + 1);
}

static char *command_path(const char *path) {
    char *absolute;
    if (path[0] == '/')
        absolute = tm_strdup(path);
    else {
        char *cwd = getcwd(NULL, 0);
        if (!cwd)
            tm_die("link_directory_missing", "The current directory is unavailable.");
        absolute = tm_path(cwd, path);
        free(cwd);
    }
    char *parent, *leaf;
    split_path(absolute, &parent, &leaf);
    char *resolved = realpath(parent, NULL);
    if (!resolved)
        tm_die("link_directory_missing", "The command directory does not exist.");
    tm_directory(resolved, false);
    char *result = tm_path(resolved, leaf);
    free(absolute);
    free(parent);
    free(leaf);
    free(resolved);
    return result;
}

static bool parent_unchanged(const char *path) {
    char *parent, *leaf;
    split_path(path, &parent, &leaf);
    char *current = realpath(parent, NULL);
    struct stat info;
    bool same = current && !strcmp(current, parent) && !lstat(parent, &info) &&
                S_ISDIR(info.st_mode) && info.st_uid == getuid();
    free(parent);
    free(leaf);
    free(current);
    return same;
}

static json_object *kind(const char *name) {
    json_object *value = json_object_new_object();
    json_object_object_add(value, "kind", json_object_new_string(name));
    return value;
}

static json_object *symlink_snapshot(const char *target) {
    json_object *value = kind("symlink");
    json_object_object_add(value, "target", json_object_new_string(target));
    return value;
}

static json_object *snapshot(const char *path) {
    if (!parent_unchanged(path))
        return kind("unavailable");
    struct stat info;
    if (lstat(path, &info) != 0) {
        if (errno == ENOENT)
            return kind("missing");
        tm_die("link_conflict", "Cannot inspect the existing command; it was preserved.");
    }
    if (info.st_uid != getuid())
        return kind("other");
    if (S_ISLNK(info.st_mode)) {
        char target[PATH_MAX + 1];
        ssize_t size = readlink(path, target, sizeof(target) - 1);
        if (size < 0 || (size_t)size >= sizeof(target) - 1)
            tm_die("link_conflict", "Cannot preserve the complete command symlink target.");
        target[size] = 0;
        return symlink_snapshot(target);
    }
    if (!S_ISREG(info.st_mode))
        return kind("other");
    if (info.st_size < 0 || (unsigned long long)info.st_size > LINK_BACKUP_MAX)
        tm_die("link_conflict", "The existing command is too large for automatic backup.");
    char hash[65];
    tm_sha256(path, hash);
    json_object *value = kind("file");
    json_object_object_add(value, "sha256", json_object_new_string(hash));
    json_object_object_add(value, "mode", json_object_new_int64(info.st_mode & 07777));
    json_object_object_add(value, "size", json_object_new_int64(info.st_size));
    return value;
}

static void snapshot_validate(json_object *value) {
    const char *type = tm_json_string(value, "kind");
    if (!strcmp(type, "missing"))
        return;
    if (!strcmp(type, "symlink")) {
        const char *target = tm_json_string(value, "target");
        if (!*target || strlen(target) >= PATH_MAX)
            tm_die("invalid_state", "Command symlink restoration data is invalid.");
        return;
    }
    if (!strcmp(type, "file")) {
        int64_t mode = json_object_get_int64(tm_json_field(value, "mode", json_type_int));
        int64_t size = json_object_get_int64(tm_json_field(value, "size", json_type_int));
        if (mode < 0 || mode > 07777 || size < 0 || (uint64_t)size > LINK_BACKUP_MAX ||
            !tm_hex_valid(tm_json_string(value, "sha256"), 64))
            tm_die("invalid_state", "Command file restoration data is invalid.");
        return;
    }
    tm_die("invalid_state", "Unsupported command restoration data.");
}

static void identity_check(const char *root, json_object *value) {
    json_object *identity = tm_store_identity(root);
    if (json_object_get_int64(tm_json_field(value, "schema", json_type_int)) != 1 ||
        strcmp(tm_json_string(value, "installation_id"), tm_json_string(identity, "id")))
        tm_die("invalid_state", "Command ownership data belongs to another installation.");
    json_object_put(identity);
}

static char *backup_path(const char *root, json_object *entry) {
    const char *name = tm_json_optional_string(entry, "backup");
    if (!name)
        return NULL;
    if (strlen(name) != 28 || strcmp(name + 24, ".bin"))
        tm_die("invalid_state", "Command backup identifier is invalid.");
    char hex[25];
    memcpy(hex, name, 24);
    hex[24] = 0;
    if (!tm_hex_valid(hex, 24))
        tm_die("invalid_state", "Command backup identifier is invalid.");
    char *folder = tm_path(root, "backups");
    tm_directory(folder, false);
    char *path = tm_path(folder, name);
    free(folder);
    return path;
}

static void entry_validate(const char *root, json_object *entry, const char *key) {
    const char *path = tm_json_string(entry, "path");
    const char *target = tm_json_string(entry, "target");
    char *parent, *leaf;
    split_path(path, &parent, &leaf);
    free(parent);
    free(leaf);
    if (key && strcmp(key, path))
        tm_die("invalid_state", "Command ownership key and path disagree.");
    split_path(target, &parent, &leaf);
    char *bin = tm_path(root, "bin");
    if (strcmp(parent, bin) || !strcmp(path, target))
        tm_die(
            "invalid_link_target",
            "Command target must be a distinct launcher directly inside the installation bin directory.");
    free(parent);
    free(leaf);
    free(bin);
    json_object *original = tm_json_field(entry, "original", json_type_object);
    snapshot_validate(original);
    char *backup = backup_path(root, entry);
    if ((!strcmp(tm_json_string(original, "kind"), "file")) != (backup != NULL))
        tm_die("invalid_state", "Command backup and original-file metadata disagree.");
    free(backup);
}

static json_object *index_read(const char *root) {
    char *path = tm_path(root, "links.json");
    json_object *data;
    if (!exists(path)) {
        json_object *identity = tm_store_identity(root);
        data = json_object_new_object();
        json_object_object_add(data, "schema", json_object_new_int(1));
        json_object_object_add(data, "installation_id",
                               json_object_new_string(tm_json_string(identity, "id")));
        json_object_object_add(data, "entries", json_object_new_object());
        json_object_put(identity);
    } else
        data = tm_json_read(path);
    free(path);
    identity_check(root, data);
    json_object *entries = tm_json_field(data, "entries", json_type_object);
    if (json_object_object_length(entries) > 1024)
        tm_die("invalid_state", "Command ownership index exceeds its supported limit.");
    json_object_object_foreach(entries, key, entry) {
        entry_validate(root, entry, key);
    }
    return data;
}

static void copy_fd(int source, int destination, uint64_t expected) {
    unsigned char buffer[65536];
    uint64_t total = 0;
    for (;;) {
        ssize_t count = read(source, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR)
            continue;
        if (count < 0)
            tm_die("backup_invalid", "Cannot read the complete original command.");
        if (!count)
            break;
        total += (uint64_t)count;
        if (total > expected || total > LINK_BACKUP_MAX)
            tm_die("link_conflict", "The original command grew during backup; it was preserved.");
        tm_write_all(destination, buffer, (size_t)count);
    }
    if (total != expected)
        tm_die("backup_invalid", "The original command changed size during backup.");
}

static char *save_original(const char *root, const char *path, json_object *original) {
    if (strcmp(tm_json_string(original, "kind"), "file"))
        return NULL;
    char random[25];
    tm_random_hex(random, 12);
    char name[29];
    snprintf(name, sizeof(name), "%s.bin", random);
    char *folder = tm_path(root, "backups");
    tm_directory(folder, false);
    char *destination = tm_path(folder, name);
    int source = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (source < 0 || fstat(source, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid())
        tm_die("link_conflict", "The original command changed before backup; it was preserved.");
    int target = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (target < 0)
        tm_die("backup_failed", "Cannot create a private command backup.");
    copy_fd(source, target,
            (uint64_t)json_object_get_int64(tm_json_field(original, "size", json_type_int)));
    if (fsync(target))
        tm_die("backup_failed", "Cannot durably save the original command.");
    close(source);
    close(target);
    tm_sync_dir(folder);
    char hash[65];
    tm_sha256(destination, hash);
    json_object *current = snapshot(path);
    if (strcmp(hash, tm_json_string(original, "sha256")) || !json_object_equal(current, original))
        tm_die("link_conflict",
               "The original command changed during backup; retry from a quiet shell.");
    json_object_put(current);
    free(folder);
    free(destination);
    return tm_strdup(name);
}

static bool clean_staging(json_object *operation) {
    const char *temporary = tm_json_optional_string(operation, "temporary");
    if (!temporary)
        return true;
    if (strlen(temporary) != 37 || strncmp(temporary, ".tm-link-", 9) ||
        strcmp(temporary + 33, ".tmp"))
        tm_die("invalid_state", "Pending command staging name is invalid.");
    char hex[25];
    memcpy(hex, temporary + 9, 24);
    hex[24] = 0;
    if (!tm_hex_valid(hex, 24))
        tm_die("invalid_state", "Pending command staging name is invalid.");
    json_object *entry = tm_json_field(operation, "entry", json_type_object);
    const char *path = tm_json_string(entry, "path");
    if (!parent_unchanged(path))
        return false;
    char *parent, *leaf;
    split_path(path, &parent, &leaf);
    free(leaf);
    char *staging = tm_path(parent, temporary);
    if (!exists(staging)) {
        free(staging);
        free(parent);
        return true;
    }
    json_object *device, *inode;
    struct stat info;
    bool matches = json_object_object_get_ex(operation, "temporary_device", &device) &&
                   json_object_object_get_ex(operation, "temporary_inode", &inode) &&
                   json_object_is_type(device, json_type_int) &&
                   json_object_is_type(inode, json_type_int) && !lstat(staging, &info) &&
                   info.st_uid == getuid() && (S_ISREG(info.st_mode) || S_ISLNK(info.st_mode)) &&
                   info.st_dev == (dev_t)json_object_get_int64(device) &&
                   info.st_ino == (ino_t)json_object_get_int64(inode);
    if (matches) {
        if (unlink(staging))
            tm_die("link_recovery_failed", "Cannot remove owned command staging data.");
        tm_sync_dir(parent);
    }
    free(staging);
    free(parent);
    return matches;
}

/* The pending transaction remains durable throughout retirement. A replay
 * after unlink but before journal removal can therefore recognize absence as
 * success. Never turn conflict recovery into an unreferenced-backup sweep. */
static bool retire_backup(const char *root, json_object *entry, json_object *entries) {
    const char *name = tm_json_optional_string(entry, "backup");
    if (!name)
        return true;
    json_object_object_foreach(entries, path, live) {
        (void)path;
        const char *referenced = tm_json_optional_string(live, "backup");
        if (referenced && !strcmp(name, referenced))
            return true;
    }
    char *folder = tm_path(root, "backups");
    tm_directory(folder, false);
    DIR *directory = opendir(folder);
    if (!directory)
        tm_die("link_recovery_failed", "Cannot inspect command backup recovery evidence.");
    struct dirent *item;
    errno = 0;
    while ((item = readdir(directory))) {
        /* Existing conflict records can contain this backup's only remaining
         * restoration reference. Preserve these evidence sets conservatively,
         * even if another command's normal restoration has now completed. */
        if (!strncmp(item->d_name, "link-conflict-", 14)) {
            closedir(directory);
            free(folder);
            return true;
        }
    }
    if (errno)
        tm_die("link_recovery_failed",
               "Cannot finish inspecting command backup recovery evidence.");
    int directory_fd = dirfd(directory);
    struct stat before, after;
    if (fstatat(directory_fd, name, &before, AT_SYMLINK_NOFOLLOW)) {
        int saved = errno;
        closedir(directory);
        free(folder);
        if (saved == ENOENT)
            return true;
        tm_die("link_recovery_failed", "Cannot inspect the completed command backup.");
    }
    json_object *original = tm_json_field(entry, "original", json_type_object);
    bool matching =
        S_ISREG(before.st_mode) && before.st_uid == getuid() && (before.st_mode & 07777) == 0600 &&
        before.st_size == json_object_get_int64(tm_json_field(original, "size", json_type_int));
    if (matching) {
        char *path = backup_path(root, entry), hash[65];
        tm_sha256(path, hash);
        free(path);
        matching = !strcmp(hash, tm_json_string(original, "sha256")) &&
                   !fstatat(directory_fd, name, &after, AT_SYMLINK_NOFOLLOW) &&
                   before.st_dev == after.st_dev && before.st_ino == after.st_ino &&
                   before.st_mode == after.st_mode && before.st_size == after.st_size &&
                   before.st_uid == after.st_uid;
    }
    if (matching && (unlinkat(directory_fd, name, 0) || fsync(directory_fd)))
        tm_die("link_recovery_failed", "Cannot durably retire the restored command backup.");
    closedir(directory);
    free(folder);
    return matching;
}

static void sync_restoration(const char *path, json_object *after) {
    /* A crash can leave the rename visible before its directory fsync. Finish
     * durability before retiring the only restoration copy in another folder. */
    if (!strcmp(tm_json_string(after, "kind"), "file")) {
        int fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
        struct stat info;
        if (fd < 0 || fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid())
            tm_die("link_recovery_failed",
                   "Cannot safely finish the restored command publication.");
        if (fsync(fd))
            tm_die("link_recovery_failed", "Cannot durably save the restored command.");
        close(fd);
    }
    char *parent, *leaf;
    split_path(path, &parent, &leaf);
    tm_sync_dir(parent);
    free(parent);
    free(leaf);
}

static const char *recover(const char *root) {
    char *pending = tm_path(root, "links-pending.json");
    if (!exists(pending)) {
        free(pending);
        return "clean";
    }
    json_object *operation = tm_json_read(pending);
    identity_check(root, operation);
    const char *action = tm_json_string(operation, "action");
    if (strcmp(action, "install") && strcmp(action, "restore"))
        tm_die("invalid_state", "Unknown pending command transaction.");
    json_object *entry = tm_json_field(operation, "entry", json_type_object);
    entry_validate(root, entry, NULL);
    json_object *before = tm_json_field(operation, "before", json_type_object);
    json_object *after = tm_json_field(operation, "after", json_type_object);
    snapshot_validate(before);
    snapshot_validate(after);
    json_object *expected_link = symlink_snapshot(tm_json_string(entry, "target"));
    if ((!strcmp(action, "install") && !json_object_equal(after, expected_link)) ||
        (!strcmp(action, "restore") &&
         (!json_object_equal(before, expected_link) ||
          !json_object_equal(after, tm_json_field(entry, "original", json_type_object)))))
        tm_die("invalid_state", "Pending command transaction has inconsistent desired state.");
    json_object_put(expected_link);
    const char *path = tm_json_string(entry, "path");
    json_object *current = snapshot(path);
    json_object *index = index_read(root);
    json_object *entries = tm_json_field(index, "entries", json_type_object);
    const char *result;
    if (json_object_equal(current, after)) {
        if (!strcmp(action, "install"))
            json_object_object_add(entries, path, json_object_get(entry));
        else {
            sync_restoration(path, after);
            json_object_object_del(entries, path);
        }
        char *index_path = tm_path(root, "links.json");
        tm_json_write(index_path, index);
        free(index_path);
        result = "committed";
    } else if (json_object_equal(current, before))
        result = "not_applied";
    else
        result = "foreign_change_preserved";
    bool staging_clean = clean_staging(operation);
    bool backup_clean = true;
    if (staging_clean && ((!strcmp(action, "restore") && !strcmp(result, "committed")) ||
                          (!strcmp(action, "install") && !strcmp(result, "not_applied"))))
        backup_clean = retire_backup(root, entry, entries);
    if (!staging_clean || !backup_clean || !strcmp(result, "foreign_change_preserved")) {
        char random[25], name[48];
        tm_random_hex(random, 12);
        snprintf(name, sizeof(name), "link-conflict-%s.json", random);
        char *folder = tm_path(root, "backups");
        tm_directory(folder, false);
        char *archive = tm_path(folder, name);
        tm_json_write(archive, operation);
        free(archive);
        free(folder);
        result = "foreign_change_preserved";
    }
    if (unlink(pending))
        tm_die("link_recovery_failed", "Cannot retire the completed command transaction.");
    tm_sync_dir(root);
    free(pending);
    json_object_put(current);
    json_object_put(index);
    json_object_put(operation);
    return result;
}

static void publish_check(const char *path, int directory, json_object *before) {
    char *parent, *leaf;
    split_path(path, &parent, &leaf);
    free(leaf);
    struct stat opened, current_parent;
    if (fstat(directory, &opened) || lstat(parent, &current_parent) ||
        opened.st_dev != current_parent.st_dev || opened.st_ino != current_parent.st_ino)
        tm_die("link_conflict",
               "The command directory changed during maintenance; it was preserved.");
    free(parent);
    json_object *current = snapshot(path);
    if (!json_object_equal(current, before))
        tm_die("link_conflict",
               "The command changed during staging; its newer entry was preserved.");
    json_object_put(current);
}

static void record_staging(const char *root, json_object *operation, int directory,
                           const char *temporary) {
    struct stat info;
    if (fstatat(directory, temporary, &info, AT_SYMLINK_NOFOLLOW))
        tm_die("link_replace_failed", "Cannot record staged command ownership.");
    json_object_object_add(operation, "temporary_device",
                           json_object_new_int64((int64_t)info.st_dev));
    json_object_object_add(operation, "temporary_inode",
                           json_object_new_int64((int64_t)info.st_ino));
    char *pending = tm_path(root, "links-pending.json");
    tm_json_write(pending, operation);
    free(pending);
}

static void replace_entry(const char *root, json_object *operation) {
    json_object *entry = tm_json_field(operation, "entry", json_type_object);
    json_object *desired = tm_json_field(operation, "after", json_type_object);
    json_object *before = tm_json_field(operation, "before", json_type_object);
    const char *path = tm_json_string(entry, "path");
    if (!parent_unchanged(path))
        tm_die("link_conflict", "The command directory changed; its contents were preserved.");
    char *parent, *leaf;
    split_path(path, &parent, &leaf);
    int directory = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (directory < 0)
        tm_die("link_directory_missing", "The command directory is unavailable.");
    const char *type = tm_json_string(desired, "kind");
    if (!strcmp(type, "missing")) {
        publish_check(path, directory, before);
        if (unlinkat(directory, leaf, 0))
            tm_die("link_replace_failed", "Cannot remove the owned command entry.");
        if (fsync(directory))
            tm_die("link_replace_failed", "Cannot durably save command removal.");
        close(directory);
        free(parent);
        free(leaf);
        return;
    }
    const char *temporary = tm_json_string(operation, "temporary");
    if (!strcmp(type, "symlink")) {
        if (symlinkat(tm_json_string(desired, "target"), directory, temporary))
            tm_die("link_replace_failed", "Cannot stage the command symlink.");
        record_staging(root, operation, directory, temporary);
    } else if (!strcmp(type, "file")) {
        char *backup = backup_path(root, entry);
        if (!backup)
            tm_die("backup_invalid", "Original command backup is unavailable.");
        tm_regular(backup);
        char hash[65];
        tm_sha256(backup, hash);
        if (strcmp(hash, tm_json_string(desired, "sha256")))
            tm_die(
                "backup_invalid",
                "Original command backup failed integrity validation; the current entry was preserved.");
        int source = open(backup, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
        int destination = openat(directory, temporary,
                                 O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (source < 0 || destination < 0)
            tm_die("backup_invalid", "Cannot stage the original command restoration.");
        record_staging(root, operation, directory, temporary);
        copy_fd(source, destination,
                (uint64_t)json_object_get_int64(tm_json_field(desired, "size", json_type_int)));
        mode_t mode = (mode_t)json_object_get_int64(tm_json_field(desired, "mode", json_type_int));
        if (fchmod(destination, mode) || fsync(destination))
            tm_die("backup_invalid", "Cannot durably restore original command permissions.");
        close(source);
        close(destination);
        free(backup);
        char *staging = tm_path(parent, temporary);
        json_object *staged = snapshot(staging);
        if (!json_object_equal(staged, desired))
            tm_die("backup_invalid",
                   "Staged command failed integrity validation; current entry was preserved.");
        json_object_put(staged);
        free(staging);
    } else
        tm_die("invalid_state", "Unsupported command replacement kind.");
    publish_check(path, directory, before);
    if (renameat(directory, temporary, directory, leaf))
        tm_die("link_replace_failed",
               "Command replacement could not be published; recover before retrying.");
    if (fsync(directory))
        tm_die("link_replace_failed", "Cannot durably save the command replacement.");
    close(directory);
    free(parent);
    free(leaf);
}

static void transaction(const char *root, const char *action, json_object *entry,
                        json_object *before, json_object *after) {
    json_object *identity = tm_store_identity(root);
    json_object *operation = json_object_new_object();
    json_object_object_add(operation, "schema", json_object_new_int(1));
    json_object_object_add(operation, "installation_id",
                           json_object_new_string(tm_json_string(identity, "id")));
    json_object_object_add(operation, "action", json_object_new_string(action));
    json_object_object_add(operation, "entry", json_object_get(entry));
    json_object_object_add(operation, "before", json_object_get(before));
    json_object_object_add(operation, "after", json_object_get(after));
    char random[25], temporary[48];
    tm_random_hex(random, 12);
    snprintf(temporary, sizeof(temporary), ".tm-link-%s.tmp", random);
    json_object_object_add(operation, "temporary", json_object_new_string(temporary));
    char *pending = tm_path(root, "links-pending.json");
    tm_json_write(pending, operation);
    json_object *current = snapshot(tm_json_string(entry, "path"));
    if (!json_object_equal(current, before)) {
        recover(root);
        tm_die("link_conflict",
               "The command changed during maintenance; its newer entry was preserved.");
    }
    json_object_put(current);
    replace_entry(root, operation);
    recover(root);
    free(pending);
    json_object_put(operation);
    json_object_put(identity);
}

static const char *install_link(const char *root, const char *path_arg, const char *target_arg,
                                bool replace) {
    recover(root);
    char *path = command_path(path_arg);
    char *target = command_path(target_arg);
    char *bin = tm_path(root, "bin");
    tm_directory(bin, false);
    char *parent, *leaf;
    split_path(target, &parent, &leaf);
    if (strcmp(parent, bin) || !strcmp(path, target))
        tm_die(
            "invalid_link_target",
            "Command target must be a distinct launcher directly inside the installation bin directory.");
    tm_regular(target);
    if (access(target, X_OK))
        tm_die("invalid_link_target", "The installed launcher is not executable.");
    free(bin);
    free(parent);
    free(leaf);
    json_object *before = snapshot(path), *after = symlink_snapshot(target),
                *index = index_read(root);
    const char *type = tm_json_string(before, "kind");
    if (!strcmp(type, "other") || !strcmp(type, "unavailable"))
        tm_die("link_conflict",
               "Existing command is not a replaceable file or symlink; it was preserved.");
    json_object *entries = tm_json_field(index, "entries", json_type_object), *previous = NULL;
    json_object_object_get_ex(entries, path, &previous);
    if (previous && json_object_equal(before, after) &&
        !strcmp(tm_json_string(previous, "target"), target)) {
        json_object_put(before);
        json_object_put(after);
        json_object_put(index);
        free(path);
        free(target);
        return "unchanged";
    }
    if (strcmp(type, "missing") && !json_object_equal(before, after) && !replace)
        tm_die(
            "link_conflict",
            "Another command already exists. Use --replace explicitly to preserve and replace it.");
    json_object *entry;
    if (previous && !strcmp(type, "missing")) {
        if (strcmp(tm_json_string(previous, "target"), target))
            tm_die(
                "link_conflict",
                "A missing owned command has a different recorded target; restore or recover it first.");
        entry = json_object_get(previous);
    } else {
        entry = json_object_new_object();
        json_object_object_add(entry, "path", json_object_new_string(path));
        json_object_object_add(entry, "target", json_object_new_string(target));
        json_object_object_add(entry, "original", json_object_get(before));
        char *backup = save_original(root, path, before);
        json_object_object_add(entry, "backup", backup ? json_object_new_string(backup) : NULL);
        free(backup);
    }
    transaction(root, "install", entry, before, after);
    json_object_put(entry);
    json_object_put(before);
    json_object_put(after);
    json_object_put(index);
    free(path);
    free(target);
    return "installed";
}

static const char *restore_link(const char *root, const char *path) {
    json_object *index = index_read(root),
                *entries = tm_json_field(index, "entries", json_type_object), *entry = NULL;
    if (!json_object_object_get_ex(entries, path, &entry)) {
        json_object_put(index);
        return "not_owned";
    }
    json_object *before = snapshot(path),
                *expected = symlink_snapshot(tm_json_string(entry, "target"));
    if (!json_object_equal(before, expected)) {
        json_object_put(before);
        json_object_put(expected);
        json_object_put(index);
        return "foreign_change_preserved";
    }
    transaction(root, "restore", entry, before, tm_json_field(entry, "original", json_type_object));
    json_object_put(before);
    json_object_put(expected);
    json_object_put(index);
    return "restored";
}

int tm_links_main(int argc, char **argv) {
    if (argc < 3)
        tm_die("usage", "links ROOT install|restore|restore-all|status|recover");
    char *root = tm_store_root(argv[1]);
    const char *command = argv[2];
    if (!strcmp(command, "status") && argc == 3) {
        json_object *index = index_read(root),
                    *entries = tm_json_field(index, "entries", json_type_object);
        json_object *result = json_object_new_array();
        json_object_object_foreach(entries, path, entry) {
            json_object *current = snapshot(path),
                        *expected = symlink_snapshot(tm_json_string(entry, "target"));
            json_object *row = json_object_new_object();
            json_object_object_add(row, "path", json_object_new_string(path));
            json_object_object_add(row, "owned",
                                   json_object_new_boolean(json_object_equal(current, expected)));
            json_object_array_add(result, row);
            json_object_put(current);
            json_object_put(expected);
        }
        tm_json_print(result);
        json_object_put(result);
        json_object_put(index);
    } else {
        tm_store_require_lock(root);
        if (!strcmp(command, "install") && (argc == 5 || argc == 6)) {
            if (argc == 6 && strcmp(argv[5], "--replace"))
                tm_die("usage", "Unknown link installation option.");
            puts(install_link(root, argv[3], argv[4], argc == 6));
        } else if (!strcmp(command, "restore") && argc == 4) {
            recover(root);
            char *path = command_path(argv[3]);
            puts(restore_link(root, path));
            free(path);
        } else if (!strcmp(command, "recover") && argc == 3)
            puts(recover(root));
        else if (!strcmp(command, "restore-all") && argc == 3) {
            recover(root);
            json_object *index = index_read(root),
                        *entries = tm_json_field(index, "entries", json_type_object);
            json_object *result = json_object_new_object();
            json_object_object_foreach(entries, path, entry) {
                (void)entry;
                json_object_object_add(result, path,
                                       json_object_new_string(restore_link(root, path)));
            }
            tm_json_print(result);
            json_object_put(result);
            json_object_put(index);
        } else
            tm_die("usage", "Unknown command-link operation or incorrect arguments.");
    }
    free(root);
    return 0;
}
