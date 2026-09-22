/* SPDX-License-Identifier: MPL-2.0 */
#ifndef TM_H
#define TM_H
#define _GNU_SOURCE 1
#include <json-c/json.h>
#include <stdbool.h>
#include <stddef.h>
#include <sys/types.h>

#ifndef TM_VERSION
#define TM_VERSION "0.1.0"
#endif
#define TM_METADATA_MAX (1024U * 1024U)
#define TM_OWNER "termux-muscle"

/* Fatal errors are intentional at command boundaries: no untrusted payload is
 * executed after a failed validation. The kernel closes locks on exit. */
_Noreturn void tm_die(const char *code, const char *message);
void *tm_alloc(size_t size);
char *tm_strdup(const char *s);
char *tm_path(const char *base, const char *suffix);
char *tm_canonical(const char *path, bool allow_missing_leaf);
void tm_regular(const char *path);
void tm_directory(const char *path, bool create);
void tm_write_all(int fd, const void *data, size_t size);
void tm_sync_dir(const char *path);
void tm_atomic_write(const char *path, const void *data, size_t size, mode_t mode);
char *tm_read_file(const char *path, size_t maximum, size_t *size);
void tm_random_hex(char *out, size_t bytes);
void tm_sha256(const char *path, char out[65]);
void tm_digest(const char *path, const char *algorithm, unsigned char *out, unsigned int *length);
void tm_now(char out[32]);
bool tm_version_valid(const char *s);
bool tm_release_valid(const char *s);
bool tm_hex_valid(const char *s, size_t length);
json_object *tm_json_read(const char *path);
json_object *tm_json_parse(const char *text, size_t size);
void tm_json_write(const char *path, json_object *obj);
json_object *tm_json_field(json_object *obj, const char *key, enum json_type type);
const char *tm_json_string(json_object *obj, const char *key);
const char *tm_json_optional_string(json_object *obj, const char *key);
void tm_json_print(json_object *obj);

/* Store paths returned here are allocated. Returned JSON objects are owned by
 * the caller. Validation rejects symlink roots/metadata and foreign objects. */
char *tm_store_root(const char *path);
json_object *tm_store_identity(const char *root);
json_object *tm_store_state(const char *root);
void tm_store_require_lock(const char *root);
char *tm_store_release(const char *root, const char *id);
void tm_store_verify(const char *release);
int tm_store_lease(const char *root, const char *id, bool exclusive, bool nonblock);

/* Dispatch argv[0] is the subcommand, e.g. "state", "run", "acquire-plan". */
int tm_state_main(int argc, char **argv);
int tm_links_main(int argc, char **argv);
int tm_runtime_main(int argc, char **argv);
int tm_acquire_main(int argc, char **argv);
int tm_report_main(int argc, char **argv);
int tm_migration_main(int argc, char **argv);
int tm_release_main(int argc, char **argv);
int tm_tooling_main(int argc, char **argv);
#endif
