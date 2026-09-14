/* SPDX-License-Identifier: MPL-2.0 */
#include "tm.h"
#include <assert.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

static void rejects_json(const char *s, size_t n) {
    fflush(NULL);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        int null = open("/dev/null", O_WRONLY);
        assert(null >= 0);
        dup2(null, 2);
        close(null);
        json_object_put(tm_json_parse(s, n));
        _exit(0);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    if (!WIFEXITED(status) || WEXITSTATUS(status) == 0)
        fprintf(stderr, "Unexpected JSON acceptance: %.*s\n", (int)n, s);
    assert(WIFEXITED(status) && WEXITSTATUS(status) != 0);
}
int main(void) {
    char near_limit[PATH_MAX];
    memset(near_limit, 'a', sizeof near_limit);
    near_limit[PATH_MAX - 4] = 0;
    char *joined = tm_path(near_limit, "b");
    assert(strlen(joined) == PATH_MAX - 2 && joined[PATH_MAX - 4] == '/' &&
           joined[PATH_MAX - 3] == 'b');
    assert(!memcmp(joined, near_limit, PATH_MAX - 4));
    free(joined);
    near_limit[PATH_MAX - 4] = 'a';
    near_limit[PATH_MAX - 3] = 0;
    fflush(NULL);
    pid_t path_child = fork();
    assert(path_child >= 0);
    if (!path_child) {
        int null = open("/dev/null", O_WRONLY);
        assert(null >= 0);
        dup2(null, 2);
        close(null);
        free(tm_path(near_limit, "b"));
        _exit(0);
    }
    int path_status;
    assert(waitpid(path_child, &path_status, 0) == path_child);
    assert(WIFEXITED(path_status) && WEXITSTATUS(path_status));
    puts("PASS C unit: joined paths preserve exact boundary bytes and reject excessive length");
    assert(tm_version_valid("0.1.0"));
    assert(tm_version_valid("2.1.270"));
    const char *invalid[] = {"", "2.1", "2.1.0-beta", "02.1.0", "-1.0.0", "2.1.0\n", "2.1.0/../x"};
    for (size_t i = 0; i < sizeof invalid / sizeof *invalid; i++)
        assert(!tm_version_valid(invalid[i]));
    assert(tm_release_valid("2.1.270-012345abcdef"));
    assert(!tm_release_valid("../../2.1.270-012345abcdef"));
    assert(!tm_release_valid("2.1.270-012345abcdeg"));
    puts("PASS C unit: versions and release identifiers cannot contain paths or shell syntax");
    const char *bad[] = {"{", "[]", "{}{}", "{\"x\":NaN}", "{\"x\":1,}", "{\"x\":\"\xff\"}"};
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++)
        rejects_json(bad[i], strlen(bad[i]));
    rejects_json("{}\0junk", 7);
    const char *nul_key = "{\"schema\\u0000ignored\":1}";
    const char *nul_value = "{\"value\":\"\\u0000\"}";
    rejects_json(nul_key, strlen(nul_key));
    rejects_json(nul_value, strlen(nul_value));
    char deep[2048];
    size_t at = 0;
    for (int i = 0; i < 40; i++) {
        memcpy(deep + at, "{\"x\":", 5);
        at += 5;
    }
    deep[at++] = '0';
    for (int i = 0; i < 40; i++)
        deep[at++] = '}';
    rejects_json(deep, at);
    const char *valid = "{\"quoted\":\"$(false)\",\"n\":1}\n";
    json_object *j = tm_json_parse(valid, strlen(valid));
    assert(!strcmp(tm_json_string(j, "quoted"), "$(false)"));
    json_object_put(j);
    const char *literal = "{\"literal\":\"\\\\u0000\",\"encoded\":\"\\u005cu0000\"}";
    j = tm_json_parse(literal, strlen(literal));
    assert(!strcmp(tm_json_string(j, "literal"), "\\u0000"));
    assert(!strcmp(tm_json_string(j, "encoded"), "\\u0000"));
    json_object_put(j);
    puts(
        "PASS C unit: bounded strict UTF-8 JSON rejects truncation, trailing objects and excessive nesting");
    char template[4096];
    snprintf(template, sizeof template, "%s/tm-common.XXXXXX",
             getenv("TMPDIR") ? getenv("TMPDIR") : "/tmp");
    char *root = mkdtemp(template);
    assert(root);
    char *p = tm_path(root, "state.json");
    tm_atomic_write(p, "before", 6, 0600);
    tm_atomic_write(p, "after", 5, 0600);
    size_t size;
    char *value = tm_read_file(p, 100, &size);
    assert(size == 5 && !strcmp(value, "after"));
    free(value);
    struct stat st;
    assert(!stat(p, &st));
    assert((st.st_mode & 0777) == 0600);
    char digest[65];
    tm_sha256(p, digest);
    assert(!strcmp(digest, "f39592393ef0859cb196a52693d2cea00fb2df784b3c04ae54aa7cadb8e562f8"));
    puts(
        "PASS C unit: atomic replacement preserves complete bytes, private permissions and known digest");
    char *link = tm_path(root, "foreign.json");
    assert(!symlink(p, link));
    fflush(NULL);
    pid_t child = fork();
    assert(child >= 0);
    if (!child) {
        int null = open("/dev/null", O_WRONLY);
        dup2(null, 2);
        close(null);
        tm_atomic_write(link, "bad", 3, 0600);
        _exit(0);
    }
    int status;
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status));
    value = tm_read_file(p, 100, &size);
    assert(size == 5 && !strcmp(value, "after"));
    free(value);
    assert(!lstat(link, &st) && S_ISLNK(st.st_mode));
    puts("PASS C unit: unsafe metadata symlink and its target are preserved");
    j = json_object_new_object();
    json_object_object_add(j, "payload", json_object_new_string(""));
    size_t overhead = strlen(json_object_to_json_string_ext(j, JSON_C_TO_STRING_PRETTY |
                                                                   JSON_C_TO_STRING_NOSLASHESCAPE));
    size_t payload_size = TM_METADATA_MAX - overhead;
    char *large = tm_alloc(payload_size + 1);
    memset(large, 'a', payload_size);
    json_object_object_add(j, "payload", json_object_new_string_len(large, (int)payload_size));
    free(large);
    assert(strlen(json_object_to_json_string_ext(
               j, JSON_C_TO_STRING_PRETTY | JSON_C_TO_STRING_NOSLASHESCAPE)) == TM_METADATA_MAX);
    fflush(NULL);
    child = fork();
    assert(child >= 0);
    if (!child) {
        int null = open("/dev/null", O_WRONLY);
        dup2(null, 2);
        close(null);
        tm_json_write(p, j);
        _exit(0);
    }
    assert(waitpid(child, &status, 0) == child);
    assert(WIFEXITED(status) && WEXITSTATUS(status));
    value = tm_read_file(p, 100, &size);
    assert(size == 5 && !strcmp(value, "after"));
    free(value);
    json_object_put(j);
    puts("PASS C unit: metadata at the size boundary cannot publish a file its reader rejects");
    char *fifo = tm_path(root, "metadata.fifo");
    assert(!mkfifo(fifo, 0600));
    for (int operation = 0; operation < 2; operation++) {
        fflush(NULL);
        child = fork();
        assert(child >= 0);
        if (!child) {
            int null = open("/dev/null", O_WRONLY);
            dup2(null, 2);
            close(null);
            alarm(2);
            if (operation)
                tm_sha256(fifo, digest);
            else {
                value = tm_read_file(fifo, 100, &size);
                free(value);
            }
            _exit(0);
        }
        assert(waitpid(child, &status, 0) == child);
        assert(WIFEXITED(status) && WEXITSTATUS(status));
    }
    puts("PASS C unit: FIFO metadata and payload paths reject immediately without a writer");
    unlink(fifo);
    free(fifo);
    unlink(link);
    unlink(p);
    rmdir(root);
    free(link);
    free(p);
    return 0;
}
