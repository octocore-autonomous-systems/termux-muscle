/* SPDX-License-Identifier: MPL-2.0 */
#include "tm.h"
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <openssl/evp.h>
#include <openssl/rand.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

_Noreturn void tm_die(const char *code, const char *message) {
    fprintf(stderr, "termux-muscle: %s: %s\n", code, message);
    exit(1);
}
void *tm_alloc(size_t size) {
    void *p = calloc(1, size ? size : 1);
    if (!p) tm_die("memory", "Not enough memory to finish this operation.");
    return p;
}
char *tm_strdup(const char *s) {
    if (!s) tm_die("invalid_value", "Required value is missing.");
    size_t n = strlen(s);
    char *out = tm_alloc(n + 1);
    memcpy(out, s, n + 1);
    return out;
}
char *tm_path(const char *base, const char *suffix) {
    if (!base || !suffix || strlen(base) + strlen(suffix) + 2 >= PATH_MAX)
        tm_die("unsafe_path", "Path is missing or too long.");
    size_t n = strlen(base) + strlen(suffix) + 2;
    char *p = tm_alloc(n);
    snprintf(p, n, "%s/%s", base, suffix);
    return p;
}
char *tm_canonical(const char *path, bool allow_missing_leaf) {
    if (!path || !*path || strlen(path) >= PATH_MAX)
        tm_die("unsafe_path", "Choose a valid local path.");
    char *r = realpath(path, NULL);
    if (r) return r;
    if (errno != ENOENT || !allow_missing_leaf)
        tm_die("unsafe_path", "The selected path is unavailable.");
    char *copy = tm_strdup(path);
    size_t n = strlen(copy);
    while (n > 1 && copy[n-1] == '/') copy[--n] = 0;
    char *slash = strrchr(copy, '/');
    const char *leaf = slash ? slash + 1 : copy;
    if (!*leaf || !strcmp(leaf, ".") || !strcmp(leaf, ".."))
        tm_die("unsafe_path", "Choose a dedicated installation directory.");
    char *name = tm_strdup(leaf);
    if (slash) *slash = 0;
    char *parent = tm_canonical(slash ? (*copy ? copy : "/") : ".", true);
    r = tm_path(parent, name);
    free(parent); free(name); free(copy);
    return r;
}
void tm_regular(const char *path) {
    struct stat st;
    if (lstat(path, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid())
        tm_die("unsafe_path", "Expected a regular file owned by this user.");
}
void tm_directory(const char *path, bool create) {
    if (create && mkdir(path, 0700) && errno != EEXIST)
        tm_die("directory_failed", "Cannot create the required private directory.");
    struct stat st;
    if (lstat(path, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid())
        tm_die("unsafe_path", "Expected a directory owned by this user, without a symlink.");
}
void tm_write_all(int fd, const void *data, size_t size) {
    const unsigned char *p = data;
    while (size) {
        ssize_t n = write(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) tm_die("write_failed", "Cannot write the complete managed file.");
        p += (size_t)n; size -= (size_t)n;
    }
}
void tm_sync_dir(const char *path) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 || fsync(fd)) tm_die("sync_failed", "Cannot durably save the directory update.");
    close(fd);
}
void tm_random_hex(char *out, size_t bytes) {
    static const char hex[] = "0123456789abcdef";
    unsigned char buf[64];
    if (bytes > sizeof buf) tm_die("invalid_value", "Random identifier request exceeds its limit.");
    if (RAND_bytes(buf, (int)bytes) != 1)
        tm_die("random_failed", "Cannot obtain a unique installation identifier.");
    for (size_t i = 0; i < bytes; i++) { out[i*2] = hex[buf[i] >> 4]; out[i*2+1] = hex[buf[i] & 15]; }
    out[bytes*2] = 0;
}
void tm_atomic_write(const char *path, const void *data, size_t size, mode_t mode) {
    char *copy = tm_strdup(path), *name = strrchr(copy, '/');
    if (!name || !name[1]) tm_die("unsafe_path", "Managed file needs a parent directory.");
    *name++ = 0;
    int dir = open(*copy ? copy : "/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (dir < 0) tm_die("unsafe_path", "Managed parent directory is unavailable.");
    struct stat old;
    if (!fstatat(dir, name, &old, AT_SYMLINK_NOFOLLOW)) {
        if (!S_ISREG(old.st_mode) || old.st_uid != getuid())
            tm_die("unsafe_path", "Managed metadata was replaced; run doctor.");
    } else if (errno != ENOENT) tm_die("unsafe_path", "Cannot inspect managed metadata.");
    char rnd[25]; tm_random_hex(rnd, 12);
    size_t len = strlen(name) + sizeof rnd + 8;
    char *tmp = tm_alloc(len);
    snprintf(tmp, len, ".%s-%s.tmp", name, rnd);
    int fd = openat(dir, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode);
    if (fd < 0) tm_die("write_failed", "Cannot stage the managed file.");
    tm_write_all(fd, data, size);
    if (fchmod(fd, mode) || fsync(fd)) tm_die("sync_failed", "Cannot durably save the managed file.");
    if (close(fd) || renameat(dir, tmp, dir, name) || fsync(dir))
        tm_die("write_failed", "Managed publication did not finish; retry or run doctor.");
    close(dir); free(tmp); free(copy);
}
char *tm_read_file(const char *path, size_t maximum, size_t *size) {
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (fd < 0 && errno == ELOOP) tm_die("unsafe_path", "Managed metadata was replaced with a symlink.");
    if (fd < 0 || fstat(fd, &st))
        tm_die("invalid_file", "A required file is unavailable.");
    if (!S_ISREG(st.st_mode)) tm_die("unsafe_path", "Expected a regular metadata file.");
    if (st.st_size < 0 || (uintmax_t)st.st_size > maximum)
        tm_die("invalid_file", "A required file is missing, unsafe, or exceeds its size limit.");
    size_t cap = (size_t)st.st_size, done = 0;
    char *buf = tm_alloc(cap + 1);
    while (done < cap) {
        ssize_t n = read(fd, buf + done, cap - done);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) tm_die("invalid_file", "A required file changed or was truncated while reading.");
        done += (size_t)n;
    }
    char extra;
    ssize_t tail;
    do { tail = read(fd, &extra, 1); } while (tail < 0 && errno == EINTR);
    if (tail != 0) tm_die("invalid_file", "A required file grew while reading.");
    close(fd);
    if (size) *size = done;
    return buf;
}
void tm_digest(const char *path, const char *algorithm, unsigned char *out, unsigned int *length) {
    int fd = open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode))
        tm_die("integrity_failed", "Cannot verify a missing or unsafe payload file.");
    const EVP_MD *md = EVP_get_digestbyname(algorithm);
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    if (!md || !ctx || EVP_DigestInit_ex(ctx, md, NULL) != 1)
        tm_die("integrity_failed", "The required digest algorithm is unavailable.");
    unsigned char buf[65536];
    for (;;) {
        ssize_t n = read(fd, buf, sizeof buf);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) tm_die("integrity_failed", "Cannot finish reading the payload.");
        if (!n) break;
        if (EVP_DigestUpdate(ctx, buf, (size_t)n) != 1)
            tm_die("integrity_failed", "Cannot finish hashing the payload.");
    }
    if (EVP_DigestFinal_ex(ctx, out, length) != 1)
        tm_die("integrity_failed", "Cannot finish verifying the payload.");
    EVP_MD_CTX_free(ctx); close(fd);
}
void tm_sha256(const char *path, char out[65]) {
    unsigned char bytes[EVP_MAX_MD_SIZE]; unsigned int n;
    tm_digest(path, "sha256", bytes, &n);
    if (n != 32) tm_die("integrity_failed", "Unexpected digest length.");
    for (unsigned int i = 0; i < n; i++) snprintf(out + i*2, 3, "%02x", bytes[i]);
}
void tm_now(char out[32]) {
    time_t t = time(NULL); struct tm value;
    if (!gmtime_r(&t, &value) || !strftime(out, 32, "%Y-%m-%dT%H:%M:%SZ", &value))
        tm_die("clock_failed", "Cannot determine the current time.");
}
bool tm_version_valid(const char *s) {
    if (!s || strlen(s) > 48) return false;
    for (int group = 0; group < 3; group++) {
        if (!isdigit((unsigned char)*s)) return false;
        if (*s == '0' && isdigit((unsigned char)s[1])) return false;
        while (isdigit((unsigned char)*s)) s++;
        if (group < 2 && *s++ != '.') return false;
    }
    return !*s;
}
bool tm_hex_valid(const char *s, size_t length) {
    if (!s || strlen(s) != length) return false;
    for (size_t i = 0; i < length; i++)
        if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f'))) return false;
    return true;
}
bool tm_release_valid(const char *s) {
    if (!s || strlen(s) > 61) return false;
    const char *dash = strrchr(s, '-');
    if (!dash || !tm_hex_valid(dash+1, 12)) return false;
    char version[49]; size_t n = (size_t)(dash-s);
    if (n >= sizeof version) return false;
    memcpy(version, s, n); version[n] = 0;
    return tm_version_valid(version);
}
static void finite_json(json_object *value) {
    if (json_object_is_type(value, json_type_double) && !isfinite(json_object_get_double(value)))
        tm_die("invalid_json", "Metadata numbers must be finite JSON values.");
    if (json_object_is_type(value, json_type_array)) {
        for (size_t i = 0; i < json_object_array_length(value); i++) finite_json(json_object_array_get_idx(value, i));
    } else if (json_object_is_type(value, json_type_object)) {
        json_object_object_foreach(value, key, child) { (void)key; finite_json(child); }
    }
}
json_object *tm_json_parse(const char *text, size_t size) {
    if (size > TM_METADATA_MAX || memchr(text, 0, size))
        tm_die("invalid_json", "Metadata is too large or contains invalid bytes.");
    /* json-c retains string-value lengths, but object keys are C strings: an
     * escaped NUL would silently turn "schema\u0000suffix" into "schema".
     * Reject decoded NULs before that information is lost. This only scans
     * string escapes; json-c remains the JSON syntax/UTF-8 parser. */
    bool in_string = false;
    for (size_t i = 0; i < size; i++) {
        if (text[i] == '"') in_string = !in_string;
        else if (in_string && text[i] == '\\') {
            if (size - i >= 6 && text[i+1] == 'u' && !memcmp(text+i+2, "0000", 4))
                tm_die("invalid_json", "Metadata strings and field names may not contain NUL bytes.");
            if (i + 1 < size) i++;
        }
    }
    json_tokener *tok = json_tokener_new_ex(32);
    if (!tok) tm_die("memory", "Cannot allocate a metadata parser.");
    json_tokener_set_flags(tok, JSON_TOKENER_STRICT | JSON_TOKENER_VALIDATE_UTF8);
    json_object *obj = json_tokener_parse_ex(tok, text, (int)size);
    size_t end = json_tokener_get_parse_end(tok);
    bool ok = json_tokener_get_error(tok) == json_tokener_success && obj;
    while (end < size && isspace((unsigned char)text[end])) end++;
    json_tokener_free(tok);
    if (!ok || end != size || !json_object_is_type(obj, json_type_object))
        tm_die("invalid_json", "Expected one complete JSON metadata object.");
    finite_json(obj);
    return obj;
}
json_object *tm_json_read(const char *path) {
    size_t n; char *s = tm_read_file(path, TM_METADATA_MAX, &n);
    json_object *j = tm_json_parse(s, n); free(s); return j;
}
void tm_json_write(const char *path, json_object *obj) {
    const char *s = json_object_to_json_string_ext(obj, JSON_C_TO_STRING_PRETTY | JSON_C_TO_STRING_NOSLASHESCAPE);
    size_t n = strlen(s);
    if (n >= TM_METADATA_MAX) tm_die("invalid_json", "Managed metadata including its final newline exceeds its size limit.");
    char *line = tm_alloc(n+2); memcpy(line, s, n); line[n++] = '\n';
    tm_atomic_write(path, line, n, 0600); free(line);
}
json_object *tm_json_field(json_object *obj, const char *key, enum json_type type) {
    json_object *v;
    if (!obj || !json_object_object_get_ex(obj, key, &v) || !json_object_is_type(v, type))
        tm_die("invalid_metadata", "Required metadata field is missing or has the wrong type.");
    return v;
}
const char *tm_json_string(json_object *obj, const char *key) {
    json_object *v = tm_json_field(obj, key, json_type_string);
    const char *s = json_object_get_string(v);
    if (strlen(s) != (size_t)json_object_get_string_len(v))
        tm_die("invalid_metadata", "Metadata strings may not contain NUL bytes.");
    return s;
}
const char *tm_json_optional_string(json_object *obj, const char *key) {
    json_object *v;
    if (!json_object_object_get_ex(obj, key, &v) || !v) return NULL;
    return tm_json_string(obj, key);
}
void tm_json_print(json_object *obj) {
    puts(json_object_to_json_string_ext(obj, JSON_C_TO_STRING_PRETTY | JSON_C_TO_STRING_NOSLASHESCAPE));
}
