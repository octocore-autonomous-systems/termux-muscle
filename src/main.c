/* SPDX-License-Identifier: MPL-2.0 */
#include "tm.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
