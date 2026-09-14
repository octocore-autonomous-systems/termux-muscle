/* SPDX-License-Identifier: MPL-2.0 */
/* Offline source fixtures. Never invoke a vendor binary or a package script. */
#include "tm.h"
#include <archive.h>
#include <archive_entry.h>
#include <elf.h>
#include <errno.h>
#include <fcntl.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define PACKAGE "@anthropic-ai/claude-code-linux-arm64-musl"
#define INTERPRETER "/lib/ld-musl-aarch64.so.1"
#define LIBC "libc.musl-aarch64.so.1"

static void value(json_object *obj, const char *key, const char *text) {
    json_object_object_add(obj, key, json_object_new_string(text));
}
static void platform_field(json_object *obj, const char *key, const char *text) {
    json_object *array = json_object_new_array(); json_object_array_add(array, json_object_new_string(text));
    json_object_object_add(obj, key, array);
}
static void make_elf(unsigned char bytes[768], bool loader, const char *mode) {
    memset(bytes, 0, 768); Elf64_Ehdr header = {0};
    memcpy(header.e_ident, ELFMAG, SELFMAG); header.e_ident[EI_CLASS] = ELFCLASS64;
    header.e_ident[EI_DATA] = ELFDATA2LSB; header.e_ident[EI_VERSION] = EV_CURRENT;
    header.e_type = loader ? ET_DYN : ET_EXEC; header.e_machine = (!loader && !strcmp(mode, "wrong-arch")) ? EM_X86_64 : EM_AARCH64;
    header.e_version = EV_CURRENT; header.e_ehsize = sizeof header;
    header.e_phoff = 64; header.e_phentsize = sizeof(Elf64_Phdr); header.e_phnum = loader ? 1 : 3;
    memcpy(bytes, &header, sizeof header);
    Elf64_Phdr load = {.p_type = PT_LOAD, .p_flags = PF_R | PF_X, .p_vaddr = 0x400000, .p_filesz = 768, .p_memsz = 768, .p_align = 4096};
    if (!loader && !strcmp(mode, "wrong-load-size")) load.p_memsz = 767;
    if (!loader && !strcmp(mode, "wrong-load-range")) load.p_memsz = UINT64_MAX;
    if (loader && !strcmp(mode, "loader-no-load")) load.p_type = PT_NOTE;
    memcpy(bytes + 64, &load, sizeof load);
    if (loader) return;
    const char *interpreter = !strcmp(mode, "wrong-interpreter") ? "/lib/ld-linux-aarch64.so.1" : INTERPRETER;
    const char *needed = !strcmp(mode, "wrong-dependency") ? "libunavailable.so" : LIBC;
    Elf64_Phdr interp = {.p_type = PT_INTERP, .p_flags = PF_R, .p_offset = 256,
                        .p_filesz = strlen(interpreter) + 1, .p_memsz = strlen(interpreter) + 1, .p_align = 1};
    Elf64_Phdr dynamic = {.p_type = PT_DYNAMIC, .p_flags = PF_R, .p_offset = 320, .p_filesz = 64, .p_memsz = 64, .p_align = 8};
    memcpy(bytes + 120, &interp, sizeof interp); memcpy(bytes + 176, &dynamic, sizeof dynamic);
    memcpy(bytes + 256, interpreter, strlen(interpreter) + 1); memcpy(bytes + 513, needed, strlen(needed) + 1);
    Elf64_Dyn values[4] = {{.d_tag = DT_NEEDED, .d_un.d_val = 1},
        {.d_tag = DT_STRTAB, .d_un.d_ptr = 0x400200},
        {.d_tag = DT_STRSZ, .d_un.d_val = strlen(needed) + 2}, {.d_tag = DT_NULL}};
    memcpy(bytes + 320, values, sizeof values);
    if (!strcmp(mode, "rpath-first") || !strcmp(mode, "runpath-first") || !strcmp(mode, "wrong-searchpath-first")) {
        Elf64_Dyn reordered[5] = {{.d_tag = !strcmp(mode, "runpath-first") ? DT_RUNPATH : DT_RPATH, .d_un.d_val = 0}};
        memcpy(reordered + 1, values, sizeof values);
        if (!strcmp(mode, "wrong-searchpath-first")) {
            const char path[] = "$ORIGIN/../outside";
            size_t index = strlen(needed) + 2;
            memcpy(bytes + 512 + index, path, sizeof path);
            reordered[0].d_un.d_val = index;
            reordered[3].d_un.d_val = index + sizeof path;
        }
        memcpy(bytes + 320, reordered, sizeof reordered);
        dynamic.p_filesz = dynamic.p_memsz = sizeof reordered;
        memcpy(bytes + 176, &dynamic, sizeof dynamic);
    }
}
static struct archive *writer(const char *path) {
    struct archive *a = archive_write_new();
    archive_write_add_filter_gzip(a); archive_write_set_format_pax_restricted(a);
    if (archive_write_open_filename(a, path) != ARCHIVE_OK) tm_die("fixture_failed", "Cannot create archive fixture.");
    return a;
}
static void member(struct archive *a, const char *name, const void *bytes, size_t size, const char *link) {
    struct archive_entry *entry = archive_entry_new();
    archive_entry_set_pathname(entry, name); archive_entry_set_filetype(entry, link ? AE_IFLNK : AE_IFREG);
    archive_entry_set_perm(entry, 0700); archive_entry_set_mtime(entry, 1, 12345);
    if (link) { archive_entry_set_symlink(entry, link); archive_entry_set_size(entry, 0); }
    else archive_entry_set_size(entry, (la_int64_t)size);
    if (archive_write_header(a, entry) != ARCHIVE_OK
            || (!link && archive_write_data(a, bytes, size) != (la_ssize_t)size))
        tm_die("fixture_failed", "Cannot write archive fixture member.");
    archive_entry_free(entry);
}
static void finish(struct archive *a) {
    if (archive_write_close(a) != ARCHIVE_OK || archive_write_free(a) != ARCHIVE_OK)
        tm_die("fixture_failed", "Cannot finish archive fixture.");
}
static void append_file(FILE *out, const char *path) {
    FILE *in = fopen(path, "rb"); unsigned char bytes[65536]; size_t size;
    if (!in) tm_die("fixture_failed", "Cannot read archive fragment.");
    while ((size = fread(bytes, 1, sizeof bytes, in)) != 0)
        if (fwrite(bytes, 1, size, out) != size) tm_die("fixture_failed", "Cannot join archive fragments.");
    if (ferror(in) || fclose(in)) tm_die("fixture_failed", "Cannot finish archive fragment.");
}
static void padding_archive(const char *path) {
    struct archive *a = archive_write_new(); archive_write_add_filter_gzip(a); archive_write_set_format_raw(a);
    if (archive_write_open_filename(a, path) != ARCHIVE_OK) tm_die("fixture_failed", "Cannot create padding fixture.");
    struct archive_entry *entry = archive_entry_new(); archive_entry_set_pathname(entry, "padding");
    archive_entry_set_filetype(entry, AE_IFREG); archive_entry_set_size(entry, 769LL * 1024 * 1024);
    if (archive_write_header(a, entry) != ARCHIVE_OK) tm_die("fixture_failed", "Cannot create padding header.");
    unsigned char zeros[65536] = {0};
    for (size_t i = 0; i < (769ULL * 1024 * 1024) / sizeof zeros; i++)
        if (archive_write_data(a, zeros, sizeof zeros) != sizeof zeros) tm_die("fixture_failed", "Cannot write padding fixture.");
    archive_entry_free(entry); finish(a);
}
int main(int argc, char **argv) {
    if (argc != 3) tm_die("invalid_arguments", "Fixture needs an existing directory and scenario.");
    const char *directory = argv[1], *mode = argv[2]; tm_directory(directory, false);
    unsigned char binary[768], loader[768]; make_elf(binary, false, mode); make_elf(loader, true, mode);
    char *binary_path = tm_path(directory, "original-claude"), *loader_path = tm_path(directory, "original-loader");
    tm_atomic_write(binary_path, binary, sizeof binary, 0700); tm_atomic_write(loader_path, loader, sizeof loader, 0700);
    char *npm_path = tm_path(directory, "npm.tgz"), *apk_path = tm_path(directory, "musl.apk");
    const char *version = !strcmp(mode, "unverified") ? "2.1.271" : "2.1.270";
    json_object *package = json_object_new_object(); value(package, "name", PACKAGE);
    value(package, "version", !strcmp(mode, "manifest-mismatch") ? "9.9.9" : version);
    platform_field(package, "os", "linux"); platform_field(package, "cpu", "arm64"); platform_field(package, "libc", "musl");
    const char *package_text = json_object_to_json_string_ext(package, JSON_C_TO_STRING_PLAIN);
    struct archive *a = writer(npm_path);
    if (!strcmp(mode, "traversal")) member(a, "../../escape", "unsafe", 6, NULL);
    if (!strcmp(mode, "symlink")) member(a, "package/claude", NULL, 0, "/system/bin/sh");
    if (!strcmp(mode, "parent-link")) member(a, "package", NULL, 0, "/tmp");
    member(a, "package/claude", binary, sizeof binary, NULL);
    if (!strcmp(mode, "duplicate")) member(a, "./package/claude", binary, sizeof binary, NULL);
    if (!strcmp(mode, "manifest-nul")) {
        size_t length = strlen(package_text); char *nul_text = tm_alloc(length + 5);
        memcpy(nul_text, package_text, length); memcpy(nul_text + length + 1, "bad", 3);
        member(a, "package/package.json", nul_text, length + 4, NULL); free(nul_text);
    } else member(a, "package/package.json", package_text, strlen(package_text), NULL);
    member(a, "package/LICENSE.md", "Fixture vendor license\n", 23, NULL); finish(a);
    char *signature = tm_path(directory, "signature.gz"), *metadata = tm_path(directory, "metadata.gz"), *payload = tm_path(directory, "payload.gz");
    a = writer(signature); member(a, ".SIGN.RSA.fixture", "signature", 9, NULL); finish(a);
    a = writer(metadata); member(a, ".PKGINFO", "pkgname = musl\n", 15, NULL); finish(a);
    a = writer(payload);
    if (strcmp(mode, "missing-loader")) member(a, "lib/ld-musl-aarch64.so.1", loader, sizeof loader, NULL);
    member(a, "lib/libc.musl-aarch64.so.1", NULL, 0, "ld-musl-aarch64.so.1"); finish(a);
    FILE *joined = fopen(apk_path, "wb"); if (!joined) tm_die("fixture_failed", "Cannot create APK fixture.");
    append_file(joined, signature); append_file(joined, metadata); append_file(joined, payload);
    if (!strcmp(mode, "expansion-bomb")) {
        char *padding = tm_path(directory, "padding.gz"); padding_archive(padding); append_file(joined, padding); free(padding);
    }
    if (fclose(joined)) tm_die("fixture_failed", "Cannot finish APK fixture.");
    if (!strcmp(mode, "truncated")) { struct stat st; if (stat(npm_path, &st) || truncate(npm_path, st.st_size - 9)) tm_die("fixture_failed", "Cannot truncate source fixture."); }
    char binary_hash[65], loader_hash[65], apk_hash[65]; tm_sha256(binary_path, binary_hash); tm_sha256(loader_path, loader_hash); tm_sha256(apk_path, apk_hash);
    unsigned char digest[EVP_MAX_MD_SIZE], encoded[89]; unsigned int length;
    tm_digest(npm_path, "sha512", digest, &length); EVP_EncodeBlock(encoded, digest, (int)length);
    char integrity[96]; snprintf(integrity, sizeof integrity, "sha512-%s", encoded);
    json_object *manifest = json_object_new_object(), *claude = json_object_new_object(), *musl = json_object_new_object();
    json_object_object_add(manifest, "schema", json_object_new_int(1));
    value(claude, "version", "2.1.270"); value(claude, "package", PACKAGE);
    value(claude, "tarball", !strcmp(mode, "nonofficial") ? "https://evil.invalid/payload.tgz" : "https://registry.npmjs.org/" PACKAGE "/-/claude-code-linux-arm64-musl-2.1.270.tgz");
    value(claude, "integrity", integrity); value(claude, "binary_sha256", !strcmp(mode, "wrong-binary-hash") ? "0000000000000000000000000000000000000000000000000000000000000000" : binary_hash);
    value(musl, "version", "1.2.6-r2"); value(musl, "url", "https://dl-cdn.alpinelinux.org/alpine/v3.24/main/aarch64/musl-1.2.6-r2.apk");
    value(musl, "sha256", apk_hash); value(musl, "loader_sha256", !strcmp(mode, "wrong-loader-hash") ? "0000000000000000000000000000000000000000000000000000000000000000" : loader_hash);
    json_object_object_add(manifest, "claude", claude); json_object_object_add(manifest, "musl", musl);
    char *manifest_path = tm_path(directory, "compatibility.json"); tm_json_write(manifest_path, manifest);
    json_object *dist = json_object_new_object(); char url[256];
    snprintf(url, sizeof url, "https://registry.npmjs.org/" PACKAGE "/-/claude-code-linux-arm64-musl-%s.tgz", version);
    value(dist, "tarball", !strcmp(mode, "metadata-other") ? "https://registry.npmjs.org/other/-/other-1.0.0.tgz" : url);
    value(dist, "integrity", integrity); json_object_object_add(package, "dist", dist);
    char *metadata_path = tm_path(directory, "registry.json"); tm_json_write(metadata_path, package);
    json_object_put(package); json_object_put(manifest);
    free(binary_path); free(loader_path); free(npm_path); free(apk_path); free(signature); free(metadata); free(payload); free(manifest_path); free(metadata_path);
    return 0;
}
