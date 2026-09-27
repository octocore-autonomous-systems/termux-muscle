/* SPDX-License-Identifier: MPL-2.0 */
#include "tm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <openssl/evp.h>

/* Serialize the self-update result in C. Base64 preserves arbitrary tool
 * output, including NUL and invalid UTF-8, in a valid JSON document. The
 * caller caps the transcript before invoking this command. */
static int self_update_json(int argc, char **argv) {
    if (argc != 11)
        tm_die("usage", "Invalid self-update result arguments.");
    json_object *result = json_object_new_object();
    json_object_object_add(result, "schema",
                           json_object_new_string("termux-muscle.self-update.v1"));
    json_object_object_add(result, "current_version", json_object_new_string(argv[1]));
    json_object_object_add(result, "target_version",
                           !strcmp(argv[2], "-") ? NULL : json_object_new_string(argv[2]));
    json_object_object_add(result, "forced", json_object_new_boolean(!strcmp(argv[3], "true")));
    json_object_object_add(result, "result", json_object_new_string(argv[4]));
    json_object_object_add(result, "exit_code", json_object_new_int(atoi(argv[5])));
    json_object_object_add(result, "error_code",
                           !strcmp(argv[6], "-") ? NULL : json_object_new_string(argv[6]));
    json_object_object_add(result, "message",
                           !strcmp(argv[7], "-") ? NULL : json_object_new_string(argv[7]));
    FILE *stream = fopen(argv[8], "rb");
    if (!stream)
        tm_die("log_missing", "Cannot read self-update transcript.");
    char *bytes = malloc(33554433);
    if (!bytes)
        tm_die("out_of_memory", "Cannot allocate self-update transcript.");
    size_t length = fread(bytes, 1, 33554433, stream);
    if (ferror(stream) || length > 33554432 || !feof(stream))
        tm_die("log_too_large", "Self-update transcript exceeds 32 MiB.");
    fclose(stream);
    /* Build/test output is arbitrary bytes, so base64 keeps even non-UTF-8 and
     * NUL output round-trippable without emitting invalid JSON. */
    size_t encoded_size = 4 * ((length + 2) / 3) + 1;
    unsigned char *encoded = malloc(encoded_size);
    if (!encoded)
        tm_die("out_of_memory", "Cannot encode self-update transcript.");
    EVP_EncodeBlock(encoded, (unsigned char *)bytes, (int)length);
    json_object *transcript = json_object_new_object();
    json_object_object_add(transcript, "complete",
                           json_object_new_boolean(!strcmp(argv[9], "true")));
    json_object_object_add(transcript, "encoding", json_object_new_string("base64"));
    json_object_object_add(transcript, "combined_output_base64",
                           json_object_new_string((char *)encoded));
    json_object *stages = json_object_new_array();
    FILE *events = strcmp(argv[10], "-") ? fopen(argv[10], "r") : NULL;
    if (strcmp(argv[10], "-") && !events)
        tm_die("invalid_events", "Cannot read self-update stage events.");
    size_t offsets[8] = {0}, stage_count = 0;
    char names[8][24] = {{0}}, event_line[80];
    if (events) {
        while (fgets(event_line, sizeof(event_line), events)) {
            unsigned long long offset;
            char name[24], extra;
            if (stage_count == 7 ||
                sscanf(event_line, "%23[a-z_] %llu %c", name, &offset, &extra) != 2 ||
                offset > length || (stage_count && offset < offsets[stage_count - 1]))
                tm_die("invalid_events", "Self-update stage events are invalid.");
            offsets[stage_count] = (size_t)offset;
            snprintf(names[stage_count], sizeof(names[stage_count]), "%s", name);
            stage_count++;
        }
        if (ferror(events))
            tm_die("invalid_events", "Cannot read self-update stage events.");
        fclose(events);
    }
    if (!stage_count) {
        snprintf(names[0], sizeof(names[0]), "manager");
        offsets[0] = 0;
        stage_count = 1;
    } else if (offsets[0] != 0) {
        for (size_t i = stage_count; i > 0; i--) {
            offsets[i] = offsets[i - 1];
            snprintf(names[i], sizeof(names[i]), "%s", names[i - 1]);
        }
        offsets[0] = 0;
        snprintf(names[0], sizeof(names[0]), "manager");
        stage_count++;
    }
    for (size_t i = 0; i < stage_count; i++) {
        size_t start = offsets[i], end = i + 1 < stage_count ? offsets[i + 1] : length;
        size_t encoded_len = 4 * ((end - start + 2) / 3) + 1;
        unsigned char *part = malloc(encoded_len);
        if (!part)
            tm_die("out_of_memory", "Cannot encode a self-update stage.");
        EVP_EncodeBlock(part, (unsigned char *)bytes + start, (int)(end - start));
        json_object *stage = json_object_new_object();
        json_object_object_add(stage, "name", json_object_new_string(names[i]));
        json_object_object_add(stage, "output_base64", json_object_new_string((char *)part));
        json_object_array_add(stages, stage);
        free(part);
    }
    json_object_object_add(transcript, "stages", stages);
    json_object_object_add(result, "transcript", transcript);
    puts(json_object_to_json_string_ext(result,
                                        JSON_C_TO_STRING_PLAIN | JSON_C_TO_STRING_NOSLASHESCAPE));
    free(bytes);
    free(encoded);
    json_object_put(result);
    return 0;
}

static int json_get(const char *file, const char *key) {
    json_object *j = tm_json_read(file), *v = j;
    char *path = tm_strdup(key), *save = NULL;
    for (char *part = strtok_r(path, ".", &save); part; part = strtok_r(NULL, ".", &save)) {
        if (!json_object_is_type(v, json_type_object) || !json_object_object_get_ex(v, part, &v))
            tm_die("missing_field", "Requested metadata field is unavailable.");
    }
    if (json_object_is_type(v, json_type_string)) {
        const char *s = json_object_get_string(v);
        if (strlen(s) != (size_t)json_object_get_string_len(v))
            tm_die("invalid_metadata", "Metadata contains a NUL byte.");
        puts(s);
    } else
        puts(json_object_to_json_string_ext(v, JSON_C_TO_STRING_PLAIN |
                                                   JSON_C_TO_STRING_NOSLASHESCAPE));
    free(path);
    json_object_put(j);
    return 0;
}
int main(int argc, char **argv) {
    if (argc < 2)
        tm_die("usage", "Use the termux-muscle command for installation and maintenance.");
    argc--;
    argv++;
    if (!strcmp(argv[0], "--version")) {
        puts("Termux Muscle " TM_VERSION);
        return 0;
    }
    if (!strcmp(argv[0], "json-get") && argc == 3)
        return json_get(argv[1], argv[2]);
    if (!strcmp(argv[0], "self-update-json"))
        return self_update_json(argc, argv);
    if (!strcmp(argv[0], "json-check") && argc == 2) {
        json_object_put(tm_json_read(argv[1]));
        return 0;
    }
    if (!strcmp(argv[0], "root-check") && argc == 2) {
        char *root = tm_store_root(argv[1]);
        puts(root);
        free(root);
        return 0;
    }
    if (!strcmp(argv[0], "version-check") && argc == 2) {
        if (!tm_version_valid(argv[1]))
            tm_die("invalid_version", "Use an exact version in X.Y.Z form.");
        return 0;
    }
    if (!strcmp(argv[0], "sha256") && argc == 2) {
        char digest[65];
        tm_sha256(argv[1], digest);
        puts(digest);
        return 0;
    }
    if (!strcmp(argv[0], "state") || !strcmp(argv[0], "with-lock"))
        return tm_state_main(argc, argv);
    if (!strcmp(argv[0], "run") || !strcmp(argv[0], "context") || !strcmp(argv[0], "shell-probe"))
        return tm_runtime_main(argc, argv);
    if (!strncmp(argv[0], "acquire-", 8))
        return tm_acquire_main(argc, argv);
    if (!strcmp(argv[0], "links"))
        return tm_links_main(argc, argv);
    if (!strcmp(argv[0], "migration"))
        return tm_migration_main(argc, argv);
    if (!strcmp(argv[0], "tooling"))
        return tm_tooling_main(argc, argv);
    if (!strcmp(argv[0], "report") || !strcmp(argv[0], "doctor") ||
        !strcmp(argv[0], "startup-check"))
        return tm_report_main(argc, argv);
    if (!strcmp(argv[0], "release-check") || !strcmp(argv[0], "release-notes"))
        return tm_release_main(argc, argv);
    tm_die("unknown_command",
           "This helper command is unavailable; check the installed project version.");
}
