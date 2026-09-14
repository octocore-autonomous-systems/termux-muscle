/* SPDX-License-Identifier: MPL-2.0 */
#include "tm.h"
#include <archive.h>
#include <archive_entry.h>
#include <ctype.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <openssl/crypto.h>
#include <openssl/evp.h>
#include <regex.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define PACKAGE "@anthropic-ai/claude-code-linux-arm64-musl"
#define REGISTRY "https://registry.npmjs.org/"
#define ALPINE "https://dl-cdn.alpinelinux.org/alpine/"
#define INTERPRETER "/lib/ld-musl-aarch64.so.1"
#define LIBC "libc.musl-aarch64.so.1"
#define MAX_ARCHIVE (384ULL * 1024 * 1024)
#define MAX_BINARY (512ULL * 1024 * 1024)
#define MAX_DECODED (768ULL * 1024 * 1024)
#define MAX_LOADER (8ULL * 1024 * 1024)

static void add_string(json_object *obj, const char *key, const char *value) {
    json_object_object_add(obj, key, json_object_new_string(value));
}
static bool matches(const char *value, const char *pattern) {
    if (!value || strlen(value) > 2048) return false;
    regex_t re;
    if (regcomp(&re, pattern, REG_EXTENDED | REG_NOSUB))
        tm_die("invalid_pattern", "Cannot validate artifact metadata.");
    bool ok = regexec(&re, value, 0, NULL, 0) == 0;
    regfree(&re); return ok;
}
static void exact_array(json_object *obj, const char *key, const char *value) {
    json_object *array = tm_json_field(obj, key, json_type_array);
    json_object *item = json_object_array_get_idx(array, 0);
    if (json_object_array_length(array) != 1 || !json_object_is_type(item, json_type_string)
            || strcmp(json_object_get_string(item), value)
            || json_object_get_string_len(item) != (int)strlen(value))
        tm_die("invalid_metadata", "The package does not identify the supported Linux ARM64 musl platform.");
}
static char *tarball_url(const char *version) {
    if (!tm_version_valid(version)) tm_die("invalid_version", "Choose an exact X.Y.Z Claude Code version.");
    char *value = tm_alloc(256);
    snprintf(value, 256, REGISTRY PACKAGE "/-/claude-code-linux-arm64-musl-%s.tgz", version);
    return value;
}
static void sri_hex(const char *integrity, char out[129]) {
    if (!integrity || strlen(integrity) != 95 || strncmp(integrity, "sha512-", 7)
            || strcmp(integrity + 93, "=="))
        tm_die("invalid_integrity", "The npm source needs its canonical SHA-512 integrity value.");
    for (size_t i = 7; i < 93; i++) {
        unsigned char c = (unsigned char)integrity[i];
        if (!(isalnum(c) || c == '+' || c == '/'))
            tm_die("invalid_integrity", "The npm SHA-512 integrity encoding is invalid.");
    }
    unsigned char bytes[68];
    if (EVP_DecodeBlock(bytes, (const unsigned char *)integrity + 7, 88) != 66)
        tm_die("invalid_integrity", "Cannot decode the npm SHA-512 integrity value.");
    unsigned char canonical[89];
    EVP_EncodeBlock(canonical, bytes, 64);
    if (strcmp((const char *)canonical, integrity + 7))
        tm_die("invalid_integrity", "The npm SHA-512 integrity encoding is not canonical.");
    for (size_t i = 0; i < 64; i++) snprintf(out + i * 2, 3, "%02x", bytes[i]);
}
static json_object *claude_source(json_object *source, bool require_binary) {
    const char *version = tm_json_string(source, "version");
    const char *package = tm_json_string(source, "package");
    const char *url = tm_json_string(source, "tarball");
    const char *integrity = tm_json_string(source, "integrity");
    const char *hash = tm_json_optional_string(source, "binary_sha256");
    char *expected = tarball_url(version), decoded[129];
    if (strcmp(package, PACKAGE) || strcmp(url, expected))
        tm_die("invalid_source", "The source must be the exact official ARM64 musl npm package URL.");
    free(expected); sri_hex(integrity, decoded);
    if ((hash && !tm_hex_valid(hash, 64)) || (require_binary && !hash))
        tm_die("invalid_integrity", "The project pin needs a valid original-binary SHA-256.");
    json_object *out = json_object_new_object();
    add_string(out, "version", version); add_string(out, "package", package);
    add_string(out, "tarball", url); add_string(out, "integrity", integrity);
    if (hash) add_string(out, "binary_sha256", hash);
    return out;
}
static json_object *musl_source(json_object *source) {
    const char *version = tm_json_string(source, "version");
    const char *url = tm_json_string(source, "url");
    const char *hash = tm_json_string(source, "sha256");
    const char *loader_hash = tm_json_string(source, "loader_sha256");
    if (!matches(version, "^[0-9]+\\.[0-9]+\\.[0-9]+-r[0-9]+$")
            || strncmp(url, ALPINE "v", strlen(ALPINE) + 1))
        tm_die("invalid_source", "The loader needs an exact official Alpine musl source pin.");
    const char *branch = url + strlen(ALPINE), *slash = strchr(branch, '/');
    if (!slash || (size_t)(slash - branch) >= 32)
        tm_die("invalid_source", "The Alpine distribution path is invalid.");
    char distribution[32]; memcpy(distribution, branch, (size_t)(slash - branch)); distribution[slash - branch] = 0;
    if (!matches(distribution, "^v[0-9]+\\.[0-9]+$"))
        tm_die("invalid_source", "The Alpine distribution path is invalid.");
    char expected[256];
    snprintf(expected, sizeof expected, ALPINE "%s/main/aarch64/musl-%s.apk", distribution, version);
    if (strcmp(url, expected) || !tm_hex_valid(hash, 64) || !tm_hex_valid(loader_hash, 64))
        tm_die("invalid_source", "The Alpine URL or its archive/loader hashes do not match a supported pin.");
    json_object *out = json_object_new_object();
    add_string(out, "version", version); add_string(out, "url", url);
    add_string(out, "sha256", hash); add_string(out, "loader_sha256", loader_hash);
    return out;
}
static bool source_unverified(json_object *manifest) {
    const char *status = tm_json_optional_string(manifest, "compatibility_status");
    if (status && strcmp(status, "pinned") && strcmp(status, "unverified"))
        tm_die("invalid_metadata", "Unknown compatibility status in the source receipt.");
    json_object *verified;
    bool flagged = false;
    if (json_object_object_get_ex(manifest, "verified", &verified)) {
        if (!json_object_is_type(verified, json_type_boolean))
            tm_die("invalid_metadata", "The source verification label has an invalid type.");
        flagged = !json_object_get_boolean(verified);
    }
    return flagged || (status && !strcmp(status, "unverified"));
}
static json_object *download_entry(const char *kind, const char *url, const char *algorithm,
                                  const char *digest, uint64_t maximum) {
    json_object *entry = json_object_new_object();
    char key[160]; snprintf(key, sizeof key, "%s-%s.archive", algorithm, digest);
    add_string(entry, "kind", kind); add_string(entry, "url", url);
    add_string(entry, "algorithm", algorithm); add_string(entry, "digest", digest);
    add_string(entry, "cache_key", key);
    json_object_object_add(entry, "max_bytes", json_object_new_int64((int64_t)maximum));
    return entry;
}
static void add_downloads(json_object *plan) {
    json_object *claude = tm_json_field(plan, "claude", json_type_object);
    json_object *musl = tm_json_field(plan, "musl", json_type_object);
    char hex[129]; sri_hex(tm_json_string(claude, "integrity"), hex);
    json_object *entries = json_object_new_array();
    json_object_array_add(entries, download_entry("claude", tm_json_string(claude, "tarball"), "sha512", hex, MAX_ARCHIVE));
    json_object_array_add(entries, download_entry("musl", tm_json_string(musl, "url"), "sha256", tm_json_string(musl, "sha256"), MAX_LOADER));
    json_object_object_add(plan, "downloads", entries);
}
static json_object *ready_plan(json_object *manifest) {
    if (json_object_get_int(tm_json_field(manifest, "schema", json_type_int)) != 1)
        tm_die("invalid_metadata", "Unsupported compatibility metadata schema.");
    const char *status = tm_json_optional_string(manifest, "status");
    if (status && strcmp(status, "ready"))
        tm_die("invalid_metadata", "Resolve source metadata before verifying or extracting artifacts.");
    bool unverified = source_unverified(manifest);
    json_object *out = json_object_new_object();
    json_object_object_add(out, "schema", json_object_new_int(1));
    add_string(out, "status", "ready"); add_string(out, "backend", "unmodified-musl-proot");
    json_object *claude = claude_source(tm_json_field(manifest, "claude", json_type_object), !unverified);
    json_object_object_add(out, "claude", claude);
    json_object_object_add(out, "musl", musl_source(tm_json_field(manifest, "musl", json_type_object)));
    add_string(out, "version", tm_json_string(claude, "version"));
    add_string(out, "compatibility_status", unverified ? "unverified" : "pinned");
    json_object_object_add(out, "verified", json_object_new_boolean(!unverified));
    add_downloads(out); return out;
}
static json_object *make_plan(const char *path, const char *selector, const char *policy, const char *metadata_path) {
    bool allow = !strcmp(policy, "allow-unverified");
    if (!allow && strcmp(policy, "pinned")) tm_die("invalid_policy", "Use pinned or allow-unverified acquisition policy.");
    json_object *manifest = tm_json_read(path), *plan = ready_plan(manifest);
    if (source_unverified(plan) && !allow)
        tm_die("unverified_version", "This saved release remains unverified; explicitly allow it before repair.");
    const char *pinned = tm_json_string(plan, "version");
    if (!strcmp(selector, "pinned") || !strcmp(selector, pinned)) {
        json_object_put(manifest); return plan;
    }
    if (strcmp(selector, "latest") && !tm_version_valid(selector))
        tm_die("invalid_version", "Use pinned, latest, or an exact X.Y.Z version.");
    if (!allow) tm_die("unverified_version", "Explicitly allow an unverified release before selecting another version.");
    if (!metadata_path) {
        json_object *pending = json_object_new_object(); char url[256];
        snprintf(url, sizeof url, REGISTRY "@anthropic-ai%%2fclaude-code-linux-arm64-musl/%s", selector);
        json_object_object_add(pending, "schema", json_object_new_int(1));
        add_string(pending, "status", "metadata_required"); add_string(pending, "metadata_url", url);
        add_string(pending, "selector", selector); json_object_put(plan); json_object_put(manifest); return pending;
    }
    json_object *metadata = tm_json_read(metadata_path);
    if (strcmp(tm_json_string(metadata, "name"), PACKAGE)) tm_die("invalid_metadata", "The registry returned a different package.");
    exact_array(metadata, "os", "linux"); exact_array(metadata, "cpu", "arm64"); exact_array(metadata, "libc", "musl");
    const char *version = tm_json_string(metadata, "version");
    if (!tm_version_valid(version) || (strcmp(selector, "latest") && strcmp(selector, version)))
        tm_die("invalid_metadata", "The registry returned a different or invalid version.");
    json_object *dist = tm_json_field(metadata, "dist", json_type_object), *source = json_object_new_object();
    add_string(source, "version", version); add_string(source, "package", PACKAGE);
    add_string(source, "tarball", tm_json_string(dist, "tarball")); add_string(source, "integrity", tm_json_string(dist, "integrity"));
    json_object *validated = claude_source(source, false);
    if (strcmp(version, pinned)) {
        json_object_object_add(plan, "claude", validated); add_string(plan, "version", version);
        add_string(plan, "compatibility_status", "unverified");
        json_object_object_add(plan, "verified", json_object_new_boolean(false)); add_downloads(plan);
    } else json_object_put(validated); /* Keep the stronger original pin, not mutable metadata. */
    json_object_put(source); json_object_put(metadata); json_object_put(manifest); return plan;
}
static json_object *entry_for(json_object *plan, const char *kind) {
    int index = !strcmp(kind, "claude") ? 0 : !strcmp(kind, "musl") ? 1 : -1;
    if (index < 0) tm_die("invalid_arguments", "Choose the claude or musl artifact.");
    return json_object_array_get_idx(tm_json_field(plan, "downloads", json_type_array), (size_t)index);
}
static int verify_archive(json_object *plan, const char *kind, const char *path) {
    json_object *entry = entry_for(plan, kind);
    uint64_t maximum = (uint64_t)json_object_get_int64(tm_json_field(entry, "max_bytes", json_type_int));
    tm_regular(path); struct stat st;
    if (lstat(path, &st) || st.st_size < 0 || (uint64_t)st.st_size > maximum)
        tm_die("artifact_too_large", "The source archive exceeds its supported size limit.");
    int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0 || fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid())
        tm_die("integrity_failed", "Cannot open the source archive safely.");
    const EVP_MD *md = EVP_get_digestbyname(tm_json_string(entry, "algorithm"));
    EVP_MD_CTX *context = EVP_MD_CTX_new();
    if (!md || !context || EVP_DigestInit_ex(context, md, NULL) != 1)
        tm_die("integrity_failed", "Cannot initialize source verification.");
    uint64_t total = 0; unsigned char buffer[65536], digest[EVP_MAX_MD_SIZE]; unsigned int length;
    for (;;) {
        ssize_t n = read(fd, buffer, sizeof buffer);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) tm_die("integrity_failed", "Cannot finish reading the source archive.");
        if (!n) break;
        total += (uint64_t)n;
        if (total > maximum) tm_die("artifact_too_large", "The source archive grew beyond its supported size.");
        if (EVP_DigestUpdate(context, buffer, (size_t)n) != 1) tm_die("integrity_failed", "Cannot hash the source archive.");
    }
    if (EVP_DigestFinal_ex(context, digest, &length) != 1) tm_die("integrity_failed", "Cannot finish source verification.");
    EVP_MD_CTX_free(context); char actual[129];
    if (length > 64) tm_die("integrity_failed", "Unexpected source digest size.");
    for (unsigned int i = 0; i < length; i++) snprintf(actual + i * 2, 3, "%02x", digest[i]);
    const char *expected = tm_json_string(entry, "digest");
    if (strlen(expected) != length * 2 || CRYPTO_memcmp(actual, expected, length * 2))
        tm_die("integrity_failed", "Source integrity failed; the existing runtime was preserved.");
    if (lseek(fd, 0, SEEK_SET) < 0) tm_die("integrity_failed", "Cannot rewind the verified source archive.");
    return fd;
}

struct decoded_reader { struct archive *raw; uint64_t total; unsigned char buffer[65536]; };
static la_ssize_t decoded_read(struct archive *tar, void *data, const void **buffer) {
    (void)tar; struct decoded_reader *reader = data;
    la_ssize_t n = archive_read_data(reader->raw, reader->buffer, sizeof reader->buffer);
    if (n < 0) tm_die("invalid_archive", "The gzip source is corrupt or truncated.");
    reader->total += (uint64_t)n;
    if (reader->total > MAX_DECODED)
        tm_die("archive_too_large", "The decoded archive exceeds its supported size, including padding.");
    *buffer = reader->buffer; return n;
}
static char *normalized_name(const char *raw) {
    if (!raw || !*raw || strlen(raw) >= PATH_MAX || raw[0] == '/')
        tm_die("unsafe_archive", "The archive contains an unsafe entry path.");
    for (const unsigned char *p = (const unsigned char *)raw; *p; p++)
        if (*p == '\\' || *p < 32 || *p == 127) tm_die("unsafe_archive", "The archive contains invalid path bytes.");
    char *copy = tm_strdup(raw), *out = tm_alloc(strlen(raw) + 1), *save = NULL;
    for (char *part = strtok_r(copy, "/", &save); part; part = strtok_r(NULL, "/", &save)) {
        if (!strcmp(part, "..")) tm_die("unsafe_archive", "The archive contains a traversing path.");
        if (!strcmp(part, ".")) continue;
        if (*out) strcat(out, "/"); strcat(out, part);
    }
    free(copy); return out;
}
static int child_directory(int root, const char *name) {
    if (mkdirat(root, name, 0700) && errno != EEXIST) tm_die("write_failed", "Cannot create a candidate directory.");
    int fd = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (fd < 0 || fstat(fd, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid())
        tm_die("unsafe_path", "A candidate subdirectory is unsafe.");
    return fd;
}
static char *extract_files(int source_fd, int root, bool musl, int lib, int licenses) {
    struct archive *raw = archive_read_new(), *tar = archive_read_new();
    if (!raw || !tar) tm_die("memory", "Cannot create archive readers.");
    archive_read_support_filter_gzip(raw); archive_read_support_format_raw(raw);
    if (archive_read_open_fd(raw, source_fd, 65536) != ARCHIVE_OK)
        tm_die("invalid_archive", "Cannot read the gzip source archive.");
    struct archive_entry *entry;
    if (archive_read_next_header(raw, &entry) != ARCHIVE_OK || archive_filter_code(raw, 0) != ARCHIVE_FILTER_GZIP)
        tm_die("invalid_archive", "Expected a gzip-compressed source archive.");
    archive_read_support_format_tar(tar);
    if (archive_read_set_format_option(tar, "tar", "read_concatenated_archives", "1") != ARCHIVE_OK)
        tm_die("archive_unsupported", "libarchive lacks concatenated tar support; update that package.");
    struct decoded_reader reader = {.raw = raw, .total = 0};
    if (archive_read_open(tar, &reader, NULL, decoded_read, NULL) != ARCHIVE_OK)
        tm_die("invalid_archive", "Cannot read the bounded tar source.");
    unsigned int seen = 0, count = 0; char *manifest = NULL; int status;
    while ((status = archive_read_next_header(tar, &entry)) != ARCHIVE_EOF) {
        if (status != ARCHIVE_OK || ++count > 10000)
            tm_die("invalid_archive", "The tar source is malformed or has too many entries.");
        char *name = normalized_name(archive_entry_pathname(entry));
        mode_t type = archive_entry_filetype(entry);
        bool linked = archive_entry_symlink(entry) || archive_entry_hardlink(entry);
        if ((!strcmp(name, "package") || !strcmp(name, "lib")) && (type != AE_IFDIR || linked))
            tm_die("unsafe_archive", "An archive parent is not a plain directory.");
        unsigned int bit = 0; const char *target = NULL; int parent = root; uint64_t maximum = TM_METADATA_MAX;
        if (!musl && !strcmp(name, "package/claude")) { bit = 1; target = "claude"; maximum = MAX_BINARY; }
        if (!musl && !strcmp(name, "package/package.json")) bit = 2;
        if (!musl && !strcmp(name, "package/LICENSE.md")) { bit = 4; target = "claude-LICENSE.md"; parent = licenses; }
        if (musl && !strcmp(name, "lib/ld-musl-aarch64.so.1")) { bit = 8; target = "ld-musl-aarch64.so.1"; parent = lib; maximum = MAX_LOADER; }
        free(name);
        if (!bit) { if (archive_read_data_skip(tar) != ARCHIVE_OK) tm_die("invalid_archive", "Cannot skip an unused archive member."); continue; }
        if ((seen & bit) || type != AE_IFREG || linked || archive_entry_sparse_count(entry) > 0
                || !archive_entry_size_is_set(entry) || archive_entry_size(entry) < 0
                || (uint64_t)archive_entry_size(entry) > maximum)
            tm_die("unsafe_archive", "A selected archive member is duplicated, linked, sparse, or oversized.");
        seen |= bit;
        uint64_t expected = (uint64_t)archive_entry_size(entry), done = 0;
        int output = -1;
        if (target) {
            output = openat(parent, target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, bit == 4 ? 0600 : 0700);
            if (output < 0) tm_die("candidate_not_empty", "Candidate output already exists or cannot be safely created.");
        } else manifest = tm_alloc((size_t)expected + 1);
        unsigned char buffer[65536]; la_ssize_t n;
        while ((n = archive_read_data(tar, buffer, sizeof buffer)) > 0) {
            done += (uint64_t)n;
            if (done > expected || done > maximum) tm_die("invalid_archive", "An archive member exceeded its declared size.");
            if (target) tm_write_all(output, buffer, (size_t)n);
            else {
                if (memchr(buffer, 0, (size_t)n)) tm_die("invalid_metadata", "The package manifest contains NUL bytes.");
                memcpy(manifest + done - (uint64_t)n, buffer, (size_t)n);
            }
        }
        if (n < 0 || done != expected) tm_die("invalid_archive", "An archive member is corrupt or truncated.");
        if (output >= 0) { if (fsync(output) || close(output)) tm_die("sync_failed", "Cannot durably save a candidate payload."); }
    }
    /* Even a tar end marker must not hide a decompression bomb after it. */
    const void *ignored;
    while (decoded_read(tar, &reader, &ignored) > 0) {}
    if ((musl && !(seen & 8)) || (!musl && (seen & 3) != 3))
        tm_die("invalid_archive", "The official archive is missing a required file.");
    archive_read_free(tar); archive_read_free(raw); return manifest;
}
static void read_at(int fd, uint64_t size, uint64_t offset, void *buffer, size_t count) {
    if (offset > size || count > size - offset) tm_die("invalid_elf", "An ELF structure points outside its source file.");
    size_t done = 0;
    while (done < count) {
        ssize_t n = pread(fd, (char *)buffer + done, count - done, (off_t)(offset + done));
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) tm_die("invalid_elf", "The ELF source was truncated while checking it.");
        done += (size_t)n;
    }
}
static json_object *inspect_elf(const char *path, bool loader) {
    tm_regular(path); int fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); struct stat st;
    if (fd < 0 || fstat(fd, &st) || st.st_size < 0 || (uint64_t)st.st_size > (loader ? MAX_LOADER : MAX_BINARY))
        tm_die("invalid_elf", "The ELF source is missing or exceeds its supported size.");
    uint64_t size = (uint64_t)st.st_size; Elf64_Ehdr header;
    read_at(fd, size, 0, &header, sizeof header);
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
    tm_die("invalid_elf", "This verifier currently requires a little-endian build host.");
#endif
    if (memcmp(header.e_ident, ELFMAG, SELFMAG) || header.e_ident[EI_CLASS] != ELFCLASS64
            || header.e_ident[EI_DATA] != ELFDATA2LSB || header.e_ident[EI_VERSION] != EV_CURRENT
            || header.e_version != EV_CURRENT || header.e_machine != EM_AARCH64
            || (header.e_type != ET_EXEC && header.e_type != ET_DYN) || header.e_ehsize != sizeof header
            || header.e_phentsize != sizeof(Elf64_Phdr) || !header.e_phnum || header.e_phnum > 256)
        tm_die("invalid_elf", "Expected a supported little-endian ARM64 ELF payload.");
    Elf64_Phdr program[256];
    read_at(fd, size, header.e_phoff, program, header.e_phnum * sizeof program[0]);
    unsigned int interpreters = 0, dynamics = 0, loads = 0; Elf64_Phdr dynamic = {0};
    for (unsigned int i = 0; i < header.e_phnum; i++) {
        Elf64_Phdr p = program[i];
        if (p.p_offset > size || p.p_filesz > size - p.p_offset || p.p_vaddr > UINT64_MAX - p.p_filesz)
            tm_die("invalid_elf", "An ELF segment is out of bounds.");
        if (p.p_type == PT_LOAD) {
            loads++;
            if (p.p_filesz > p.p_memsz || p.p_vaddr > UINT64_MAX - p.p_memsz)
                tm_die("invalid_elf", "An ELF load segment has an inconsistent memory range.");
        }
        if (p.p_type == PT_INTERP) {
            interpreters++; char interpreter[sizeof INTERPRETER];
            if (p.p_filesz != sizeof INTERPRETER) tm_die("invalid_elf", "The ELF interpreter is unsupported.");
            read_at(fd, size, p.p_offset, interpreter, sizeof interpreter);
            if (memcmp(interpreter, INTERPRETER, sizeof interpreter)) tm_die("invalid_elf", "The ELF interpreter is unsupported.");
        }
        if (p.p_type == PT_DYNAMIC) { dynamics++; dynamic = p; }
    }
    if (!loads || interpreters != (loader ? 0U : 1U) || dynamics > 1 || (!loader && !dynamics))
        tm_die("invalid_elf", "The ELF interpreter or dynamic-linking layout is unsupported.");
    struct dynamic_string { uint64_t index; Elf64_Sxword tag; } strings_used[32];
    uint64_t strings_address = 0, strings_size = 0; unsigned int count = 0, needed = 0, addresses = 0, lengths = 0;
    if (dynamics) {
        if (dynamic.p_filesz > TM_METADATA_MAX || dynamic.p_filesz % sizeof(Elf64_Dyn))
            tm_die("invalid_elf", "The ELF dynamic table is invalid.");
        bool terminated = false;
        for (uint64_t offset = 0; offset < dynamic.p_filesz; offset += sizeof(Elf64_Dyn)) {
            Elf64_Dyn value; read_at(fd, size, dynamic.p_offset + offset, &value, sizeof value);
            if (value.d_tag == DT_NULL) { terminated = true; break; }
            if (value.d_tag == DT_STRTAB) { strings_address = value.d_un.d_ptr; addresses++; }
            if (value.d_tag == DT_STRSZ) { strings_size = value.d_un.d_val; lengths++; }
            if (value.d_tag == DT_NEEDED || value.d_tag == DT_RPATH || value.d_tag == DT_RUNPATH) {
                if (count == 32) tm_die("invalid_elf", "The ELF has too many dynamic dependencies.");
                if (value.d_tag == DT_NEEDED) needed++;
                strings_used[count++] = (struct dynamic_string){.index = value.d_un.d_val, .tag = value.d_tag};
            }
        }
        if (!terminated) tm_die("invalid_elf", "The ELF dynamic table has no terminator.");
    }
    if (needed != (loader ? 0U : 1U)) tm_die("invalid_elf", "The ELF requires unsupported shared libraries.");
    if (count) {
        if (addresses != 1 || lengths != 1 || !strings_size || strings_size > 16 * TM_METADATA_MAX
                || strings_address > UINT64_MAX - strings_size)
            tm_die("invalid_elf", "The ELF string table is invalid.");
        uint64_t offset = 0; unsigned int mappings = 0;
        for (unsigned int i = 0; i < header.e_phnum; i++) {
            Elf64_Phdr p = program[i];
            if (p.p_type == PT_LOAD && p.p_vaddr <= strings_address && strings_address + strings_size <= p.p_vaddr + p.p_filesz) {
                offset = p.p_offset + strings_address - p.p_vaddr; mappings++;
            }
        }
        if (mappings != 1) tm_die("invalid_elf", "The ELF string table has no unique file mapping.");
        char *strings = tm_alloc((size_t)strings_size); read_at(fd, size, offset, strings, (size_t)strings_size);
        for (unsigned int i = 0; i < count; i++) {
            uint64_t index = strings_used[i].index;
            if (index >= strings_size || !memchr(strings + index, 0, (size_t)(strings_size - index)))
                tm_die("invalid_elf", "An ELF dependency name is invalid.");
            if ((strings_used[i].tag == DT_NEEDED && strcmp(strings + index, LIBC)) ||
                    (strings_used[i].tag != DT_NEEDED && strings[index]))
                tm_die("invalid_elf", "The ELF requires an unsupported dependency or library search path.");
        }
        free(strings);
    }
    close(fd); json_object *out = json_object_new_object(), *libraries = json_object_new_array();
    json_object_object_add(out, "class", json_object_new_int(64)); add_string(out, "endianness", "little");
    add_string(out, "machine", "aarch64");
    json_object_object_add(out, "interpreter", loader ? NULL : json_object_new_string(INTERPRETER));
    if (!loader) json_object_array_add(libraries, json_object_new_string(LIBC));
    json_object_object_add(out, "needed", libraries); return out;
}
static void extract_payload(json_object *plan, const char *npm, const char *apk, const char *release) {
    int npm_fd = verify_archive(plan, "claude", npm), apk_fd = verify_archive(plan, "musl", apk);
    tm_directory(release, false); int root = open(release, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (root < 0) tm_die("unsafe_path", "The candidate directory is unavailable.");
    struct stat existing;
    if (!fstatat(root, "payload.json", &existing, AT_SYMLINK_NOFOLLOW) || errno != ENOENT)
        tm_die("candidate_not_empty", "The candidate already contains payload metadata.");
    int lib = child_directory(root, "lib"), licenses = child_directory(root, "licenses");
    char *manifest_text = extract_files(npm_fd, root, false, lib, licenses);
    json_object *manifest = tm_json_parse(manifest_text, strlen(manifest_text));
    json_object *claude = tm_json_field(plan, "claude", json_type_object), *musl = tm_json_field(plan, "musl", json_type_object);
    if (strcmp(tm_json_string(manifest, "name"), PACKAGE)
            || strcmp(tm_json_string(manifest, "version"), tm_json_string(claude, "version")))
        tm_die("invalid_metadata", "The npm archive manifest does not match the selected package/version.");
    exact_array(manifest, "os", "linux"); exact_array(manifest, "cpu", "arm64"); exact_array(manifest, "libc", "musl");
    free(manifest_text); json_object_put(manifest);
    free(extract_files(apk_fd, root, true, lib, licenses)); close(npm_fd); close(apk_fd);
    char *binary = tm_path(release, "claude"), *loader = tm_path(release, "lib/ld-musl-aarch64.so.1"), hash[65];
    tm_sha256(binary, hash); const char *expected = tm_json_optional_string(claude, "binary_sha256");
    if (expected && strcmp(expected, hash)) tm_die("integrity_failed", "The original Claude binary differs from its recorded SHA-256.");
    add_string(claude, "binary_sha256", hash);
    tm_sha256(loader, hash);
    if (strcmp(tm_json_string(musl, "loader_sha256"), hash)) tm_die("integrity_failed", "The extracted musl loader differs from its recorded SHA-256.");
    json_object_object_add(claude, "elf", inspect_elf(binary, false));
    json_object_object_add(musl, "elf", inspect_elf(loader, true));
    if (fsync(lib) || fsync(licenses) || fsync(root)) tm_die("sync_failed", "Cannot durably save the candidate directories.");
    close(lib); close(licenses); close(root);
    json_object_object_del(plan, "downloads"); json_object_object_del(plan, "status");
    char *receipt = tm_path(release, "payload.json"); tm_json_write(receipt, plan); tm_json_print(plan);
    free(receipt); free(binary); free(loader);
}
static void print_field(const char *path, const char *field) {
    json_object *input = tm_json_read(path);
    const char *status = tm_json_optional_string(input, "status");
    if (status && !strcmp(status, "metadata_required")) {
        if (json_object_get_int(tm_json_field(input, "schema", json_type_int)) != 1)
            tm_die("invalid_metadata", "Unsupported source-plan schema.");
        const char *selector = tm_json_string(input, "selector");
        if (strcmp(selector, "latest") && !tm_version_valid(selector)) tm_die("invalid_metadata", "Invalid metadata selector.");
        if (!strcmp(field, "status")) puts("metadata_required");
        else if (!strcmp(field, "metadata-url")) printf(REGISTRY "@anthropic-ai%%2fclaude-code-linux-arm64-musl/%s\n", selector);
        else tm_die("invalid_arguments", "A version must be resolved before reading source fields.");
    } else {
        json_object *plan = ready_plan(input);
        if (!strcmp(field, "status")) puts("ready");
        else if (!strcmp(field, "version")) puts(tm_json_string(plan, "version"));
        else {
            const char *dash = strchr(field, '-');
            if (!dash || (strncmp(field, "claude-", 7) && strncmp(field, "musl-", 5)))
                tm_die("invalid_arguments", "Unknown acquisition scalar field.");
            json_object *entry = entry_for(plan, field[0] == 'c' ? "claude" : "musl");
            const char *key = dash + 1;
            if (!strcmp(key, "url")) puts(tm_json_string(entry, "url"));
            else if (!strcmp(key, "cache")) puts(tm_json_string(entry, "cache_key"));
            else if (!strcmp(key, "max")) printf("%" PRId64 "\n", json_object_get_int64(tm_json_field(entry, "max_bytes", json_type_int)));
            else tm_die("invalid_arguments", "Unknown acquisition scalar field.");
        }
        json_object_put(plan);
    }
    json_object_put(input);
}
int tm_acquire_main(int argc, char **argv) {
    if (!strcmp(argv[0], "acquire-plan") && (argc == 4 || argc == 5)) {
        json_object *plan = make_plan(argv[1], argv[2], argv[3], argc == 5 ? argv[4] : NULL);
        tm_json_print(plan); json_object_put(plan); return 0;
    }
    if (!strcmp(argv[0], "acquire-field") && argc == 3) { print_field(argv[1], argv[2]); return 0; }
    if (!strcmp(argv[0], "acquire-elf") && argc == 3) {
        if (strcmp(argv[2], "binary") && strcmp(argv[2], "loader")) tm_die("invalid_arguments", "Choose binary or loader ELF validation.");
        json_object *elf = inspect_elf(argv[1], !strcmp(argv[2], "loader")); tm_json_print(elf); json_object_put(elf); return 0;
    }
    if (!strcmp(argv[0], "acquire-verify") && argc == 4) {
        json_object *input = tm_json_read(argv[1]), *plan = ready_plan(input);
        close(verify_archive(plan, argv[2], argv[3])); json_object_put(plan); json_object_put(input); return 0;
    }
    if (!strcmp(argv[0], "acquire-extract") && argc == 5) {
        json_object *input = tm_json_read(argv[1]), *plan = ready_plan(input);
        extract_payload(plan, argv[2], argv[3], argv[4]); json_object_put(plan); json_object_put(input); return 0;
    }
    tm_die("invalid_arguments", "Invalid acquisition helper command or argument count.");
}
