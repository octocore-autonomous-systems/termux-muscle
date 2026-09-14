/* SPDX-License-Identifier: MPL-2.0 */
#include "tm.h"
#include <ctype.h>
#include <limits.h>
#include <openssl/evp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>

/* These checks make development builds with temporarily unlinked modules fail
 * the publication gate. Final main dispatch also links the required modules. */
extern int tm_links_main(int, char **) __attribute__((weak));
extern int tm_acquire_main(int, char **) __attribute__((weak));
extern int tm_report_main(int, char **) __attribute__((weak));
extern int tm_tooling_main(int, char **) __attribute__((weak));

static const char *required_checks[] = {"install", "startup_version", "startup_help", "shell_tools", "update", "rollback", "uninstall"};
static const char *required_packages[] = {"bash", "coreutils", "curl", "ca-certificates", "proot", "ripgrep", "clang", "make", "pkg-config", "json-c", "libarchive", "openssl"};

static _Noreturn void invalid(const char *why) { tm_die("release_invalid", why); }

static const char *text_field(json_object *obj, const char *key) {
    const char *s = tm_json_string(obj, key);
    if (!*s || strlen(s) > 4096) invalid("Required release text is empty or too long.");
    for (const unsigned char *p = (const unsigned char *)s; *p; p++)
        if (*p < 32 || *p == 127) invalid("Release text must not contain control characters.");
    return s;
}
static json_object *array_field(json_object *obj, const char *key) {
    json_object *value = tm_json_field(obj, key, json_type_array);
    if (json_object_array_length(value) > 512) invalid("Release metadata contains an excessive list.");
    return value;
}
static bool token(const char *s) {
    if (!s || !*s || strlen(s) > 128) return false;
    for (; *s; s++) if (!(isalnum((unsigned char)*s) || *s == '_' || *s == '-' || *s == '.')) return false;
    return true;
}
static bool project_version(const char *s) {
    if (!s || !*s || strlen(s) > 128) return false;
    const char *end = s + strcspn(s, "-+");
    size_t n = (size_t)(end - s);
    char core[129]; memcpy(core, s, n); core[n] = 0;
    if (!tm_version_valid(core)) return false;
    if (!*end) return true;
    bool prerelease = *end == '-';
    const char *p = end + 1, *part = p;
    bool numeric = true;
    for (;;) {
        if (!*p || *p == '.' || *p == '+') {
            size_t length = (size_t)(p - part);
            if (!length || (prerelease && numeric && length > 1 && *part == '0')) return false;
            if (!*p) return true;
            if (*p == '+') { if (!prerelease) return false; prerelease = false; }
            part = ++p; numeric = true;
        } else {
            if (!(isalnum((unsigned char)*p) || *p == '-')) return false;
            if (!isdigit((unsigned char)*p)) numeric = false;
            p++;
        }
    }
}
static int digit_number(const char *s, size_t count) {
    int value = 0;
    for (size_t i = 0; i < count; i++) {
        if (s[i] < '0' || s[i] > '9') return -1;
        value = value * 10 + s[i] - '0';
    }
    return value;
}
static bool date_valid(const char *s) {
    if (!s || strlen(s) != 10 || s[4] != '-' || s[7] != '-') return false;
    int year = digit_number(s, 4), month = digit_number(s + 5, 2), day = digit_number(s + 8, 2);
    if (year < 1970 || month < 1 || month > 12 || day < 1) return false;
    static const int days[] = {31,28,31,30,31,30,31,31,30,31,30,31};
    int max = days[month - 1] + (month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0));
    return day <= max;
}
static bool timestamp_valid(const char *s) {
    if (!s || strlen(s) < 20 || s[10] != 'T' || s[13] != ':' || s[16] != ':') return false;
    char date[11]; memcpy(date, s, 10); date[10] = 0;
    if (!date_valid(date)) return false;
    int hour = digit_number(s + 11, 2), minute = digit_number(s + 14, 2), second = digit_number(s + 17, 2);
    if (hour < 0 || hour > 23 || minute < 0 || minute > 59 || second < 0 || second > 59) return false;
    const char *p = s + 19;
    if (*p == '.') { p++; const char *start = p; while (isdigit((unsigned char)*p)) p++; if (p == start) return false; }
    if (!strcmp(p, "Z")) return true;
    if (strlen(p) != 6 || (*p != '+' && *p != '-') || p[3] != ':') return false;
    hour = digit_number(p + 1, 2); minute = digit_number(p + 4, 2);
    return hour >= 0 && hour <= 23 && minute >= 0 && minute <= 59;
}
static void ensure_date(const char *s) {
    char now[32]; tm_now(now); now[10] = 0;
    if (!date_valid(s) || strcmp(s, now) > 0) invalid("Release dates must be real YYYY-MM-DD dates, not future dates.");
}
static void unique_string(json_object *seen, const char *s) {
    json_object *existing;
    if (json_object_object_get_ex(seen, s, &existing)) invalid("Release metadata contains duplicate IDs or report references.");
    json_object_object_add(seen, s, json_object_new_boolean(true));
}
static void schema_one(json_object *obj) {
    if (json_object_get_int64(tm_json_field(obj, "schema", json_type_int)) != 1) invalid("Release and report schemas must be 1.");
}
static bool status_valid(const char *s) { return !strcmp(s,"PASS") || !strcmp(s,"FAIL") || !strcmp(s,"SKIP"); }
static char *source_path(const char *root, const char *relative) {
    if (!relative || !*relative || *relative == '/' || strlen(relative) >= PATH_MAX) invalid("Evidence paths must be repository-relative paths.");
    char *copy = tm_strdup(relative), *save = NULL, *path = tm_strdup(root);
    if (strstr(relative, "//") || relative[strlen(relative) - 1] == '/') invalid("Evidence paths must name regular files.");
    for (char *part = strtok_r(copy, "/", &save); part; part = strtok_r(NULL, "/", &save)) {
        if (!strcmp(part,".") || !strcmp(part,"..")) invalid("Evidence paths must stay inside the source tree.");
        for (const unsigned char *p = (const unsigned char *)part; *p; p++)
            if (!(isalnum(*p) || *p == '.' || *p == '_' || *p == '-')) invalid("Evidence paths must use portable project filenames.");
        char *next = tm_path(path, part); free(path); path = next;
        struct stat st;
        if (lstat(path, &st) || S_ISLNK(st.st_mode)) invalid("Evidence paths must exist without symlink components.");
    }
    free(copy); tm_regular(path); return path;
}
static void require_source(const char *root, const char *relative) {
    char *path = source_path(root, relative); size_t length;
    char *data = tm_read_file(path, TM_METADATA_MAX, &length);
    if (!length) invalid("Required source or notice is empty.");
    free(data); free(path);
}
static bool official_model_source(const char *s) {
    static const char *prefixes[] = {"https://code.claude.com/", "https://support.claude.com/", "https://docs.anthropic.com/", "https://platform.claude.com/", "https://www.anthropic.com/", "https://anthropic.com/", "https://claude.com/"};
    for (size_t i = 0; i < sizeof prefixes / sizeof *prefixes; i++)
        if (!strncmp(s, prefixes[i], strlen(prefixes[i]))) return true;
    return false;
}
static void verify_sri(const char *s) {
    if (strncmp(s, "sha512-", 7) || strlen(s + 7) != 88) invalid("Claude package integrity must be a canonical SHA-512 SRI value.");
    unsigned char decoded[80], encoded[100];
    int size = EVP_DecodeBlock(decoded, (const unsigned char *)s + 7, 88);
    if (size != 66 || strcmp(s + strlen(s) - 2, "==")) invalid("Claude package integrity must decode to SHA-512 bytes.");
    EVP_EncodeBlock(encoded, decoded, 64);
    if (strcmp((const char *)encoded, s + 7)) invalid("Claude package integrity is not canonical base64.");
}
static bool model_in(json_object *documented, const char *id) {
    for (size_t i = 0; i < json_object_array_length(documented); i++) {
        json_object *item = json_object_array_get_idx(documented, i);
        if (!strcmp(text_field(item, "id"), id)) return true;
    }
    return false;
}
static int compare_client_versions(const char *left, const char *right) {
    for (int part = 0; part < 3; part++) {
        size_t a = strcspn(left,"."), b = strcspn(right,".");
        if (a != b) return a > b ? 1 : -1;
        int difference = memcmp(left,right,a);
        if (difference) return difference;
        left += a; right += b;
        if (*left) left++;
        if (*right) right++;
    }
    return 0;
}
static void verify_pins(json_object *manifest) {
    json_object *claude = tm_json_field(manifest,"claude",json_type_object);
    json_object *musl = tm_json_field(manifest,"musl",json_type_object);
    const char *version = text_field(claude,"version");
    if (!tm_version_valid(version)) invalid("Claude Code needs an exact X.Y.Z version.");
    if (strcmp(text_field(claude,"package"),"@anthropic-ai/claude-code-linux-arm64-musl")) invalid("Only the official ARM64 musl package is supported.");
    char expected[512];
    snprintf(expected,sizeof expected,"https://registry.npmjs.org/@anthropic-ai/claude-code-linux-arm64-musl/-/claude-code-linux-arm64-musl-%s.tgz",version);
    if (strcmp(text_field(claude,"tarball"),expected)) invalid("Claude archive URL must match its official package and version.");
    verify_sri(text_field(claude,"integrity"));
    if (!tm_hex_valid(text_field(claude,"binary_sha256"),64) || !tm_hex_valid(text_field(musl,"sha256"),64) || !tm_hex_valid(text_field(musl,"loader_sha256"),64)) invalid("Pinned payload and loader digests must be SHA-256.");
    const char *loader_version = text_field(musl,"version"), *url = text_field(musl,"url");
    if (!token(loader_version)) invalid("Loader version is invalid.");
    const char *origin = "https://dl-cdn.alpinelinux.org/alpine/";
    snprintf(expected,sizeof expected,"/aarch64/musl-%s.apk",loader_version);
    size_t a = strlen(url), b = strlen(expected);
    if (strncmp(url,origin,strlen(origin)) || a < b || strcmp(url+a-b,expected) || strstr(url,"..") || strpbrk(url,"?#\\<>")) invalid("Loader URL must pin the matching Alpine aarch64 package.");
    if (strcmp(text_field(manifest,"backend"),"unmodified-musl-proot")) invalid("Compatibility backend is not implemented.");
}
static void verify_models(json_object *models, const char *client_version) {
    ensure_date(text_field(models,"checked_documentation_on"));
    if (!official_model_source(text_field(models,"source"))) invalid("Documented model metadata needs an official Anthropic source.");
    text_field(models,"availability_note");
    json_object *documented = array_field(models,"documented");
    if (!json_object_array_length(documented)) invalid("Every release must list documented models and their client requirements.");
    json_object *seen = json_object_new_object();
    for (size_t i = 0; i < json_object_array_length(documented); i++) {
        json_object *item = json_object_array_get_idx(documented,i);
        const char *id = text_field(item,"id");
        if (!token(id) || strncmp(id,"claude-",7)) invalid("Documented model IDs must be explicit Claude IDs.");
        unique_string(seen,id); text_field(item,"name");
        const char *minimum = text_field(item,"minimum_claude_version");
        if (!tm_version_valid(minimum)) invalid("Models need exact minimum client versions.");
        if (compare_client_versions(minimum,client_version) > 0) invalid("A supported documented model requires a newer Claude Code version than this release pins.");
    }
    json_object_put(seen); array_field(models,"verified");
}
static bool known_value(const char *s) {
    return *s && strcmp(s,"unknown") && strcmp(s,"unavailable") && strcmp(s,"not-installed") && strcmp(s,"pending");
}
static void verify_environment(json_object *report) {
    json_object *environment = tm_json_field(report,"environment",json_type_object);
    const char *fields[] = {"manufacturer","model","android_version","abi","kernel","termux_version","termux_source"};
    for (size_t i = 0; i < sizeof fields / sizeof *fields; i++)
        if (!known_value(text_field(environment,fields[i]))) invalid("Maintainer evidence needs exact Android/Termux software and device details.");
    const char *abi = text_field(environment,"abi");
    if (strcmp(abi,"aarch64") && strcmp(abi,"arm64-v8a") && strcmp(abi,"arm64")) invalid("Qualifying device evidence must use Android ARM64.");
    if (json_object_get_int64(tm_json_field(environment,"android_api",json_type_int)) <= 0) invalid("Android API must be recorded as a positive integer.");
    int64_t page = json_object_get_int64(tm_json_field(environment,"page_size",json_type_int));
    if (page < 1024 || page > 1024*1024 || (page & (page-1))) invalid("Kernel page size must be recorded exactly.");
    json_object *packages = tm_json_field(environment,"packages",json_type_object);
    for (size_t i = 0; i < sizeof required_packages / sizeof *required_packages; i++)
        if (!known_value(text_field(packages,required_packages[i]))) invalid("Maintainer evidence needs exact compiler, build and runtime package versions.");
}
static void verify_model_results(json_object *results, json_object *documented, json_object *passed) {
    json_object *seen = json_object_new_object();
    for (size_t i = 0; i < json_object_array_length(results); i++) {
        json_object *item = json_object_array_get_idx(results,i);
        const char *requested = text_field(item,"requested"), *status = text_field(item,"status");
        if (!token(requested) || !status_valid(status)) invalid("Model results need explicit IDs and PASS, FAIL or SKIP status.");
        unique_string(seen,requested);
        json_object *observed = array_field(item,"observed"), *observed_ids = json_object_new_object();
        bool exact = json_object_array_length(observed) == 1;
        for (size_t j = 0; j < json_object_array_length(observed); j++) {
            json_object *value = json_object_array_get_idx(observed,j);
            if (!json_object_is_type(value,json_type_string)) invalid("Observed models must be an array of model IDs.");
            const char *id = json_object_get_string(value);
            if (strlen(id) != (size_t)json_object_get_string_len(value) || !token(id)) invalid("Observed model ID is invalid.");
            unique_string(observed_ids,id);
            if (strcmp(id,requested)) exact = false;
        }
        json_object_put(observed_ids);
        if (!strcmp(status,"PASS") && !exact) invalid("A passing model check must observe exactly the requested model, without fallback.");
        if (!strcmp(status,"PASS") && model_in(documented,requested)) json_object_object_add(passed,requested,json_object_new_boolean(true));
    }
    json_object_put(seen);
}
static const char *report_path(json_object *item) {
    if (json_object_is_type(item,json_type_string)) {
        const char *s = json_object_get_string(item);
        if (strlen(s) != (size_t)json_object_get_string_len(item)) invalid("Report path contains a NUL byte.");
        return s;
    }
    return text_field(item,"path");
}
static void verify_reports(const char *root, json_object *manifest, json_object *models) {
    const char *verified_on = text_field(manifest,"verified_on"); ensure_date(verified_on);
    if (strcmp(text_field(models,"checked_documentation_on"),verified_on) > 0) invalid("Verification date must include the documented-model review.");
    json_object *reports = array_field(manifest,"reports"), *seen = json_object_new_object(), *model_passes = json_object_new_object();
    json_object *documented = array_field(models,"documented");
    bool qualifying = false;
    for (size_t i = 0; i < json_object_array_length(reports); i++) {
        const char *relative = report_path(json_object_array_get_idx(reports,i)); unique_string(seen,relative);
        char *path = source_path(root,relative); json_object *report = tm_json_read(path); free(path); schema_one(report);
        json_object *project = tm_json_field(report,"project",json_type_object), *client = tm_json_field(report,"claude_code",json_type_object);
        if (strcmp(text_field(project,"version"),text_field(manifest,"project_version")) || strcmp(text_field(client,"version"),text_field(tm_json_field(manifest,"claude",json_type_object),"version"))) invalid("Device evidence project or Claude Code version does not match this release.");
        if (strcmp(text_field(client,"musl_version"),text_field(tm_json_field(manifest,"musl",json_type_object),"version"))) invalid("Device evidence musl loader version does not match this release.");
        const char *date = text_field(report,"generated_at");
        if (!timestamp_valid(date) || strncmp(date,verified_on,10) > 0) invalid("Device evidence needs a valid timestamp no later than the release verification date.");
        const char *provenance = text_field(report,"provenance");
        if (strcmp(provenance,"maintainer") && strcmp(provenance,"community")) invalid("Report provenance must be maintainer or community.");
        json_object *checks = array_field(report,"checks"), *ids = json_object_new_object();
        bool passed[sizeof required_checks / sizeof *required_checks] = {false};
        for (size_t j = 0; j < json_object_array_length(checks); j++) {
            json_object *check = json_object_array_get_idx(checks,j);
            const char *id = text_field(check,"id"), *status = text_field(check,"status");
            if (!token(id) || !status_valid(status)) invalid("Device checks need IDs and PASS, FAIL or SKIP status.");
            unique_string(ids,id);
            for (size_t k = 0; k < sizeof required_checks / sizeof *required_checks; k++)
                if (!strcmp(id,required_checks[k])) passed[k] = !strcmp(status,"PASS");
        }
        json_object_put(ids);
        bool complete = !strcmp(provenance,"maintainer") && !strncmp(date,verified_on,10);
        for (size_t k = 0; k < sizeof required_checks / sizeof *required_checks; k++) complete = complete && passed[k];
        if (complete) { verify_environment(report); qualifying = true; }
        verify_model_results(array_field(report,"models"),documented,model_passes);
        json_object_put(report);
    }
    if (!qualifying) invalid("Release needs a dated maintainer device report passing install, startup_version, startup_help, shell_tools, update, rollback and uninstall.");
    json_object_put(seen);
    json_object *verified = array_field(models,"verified"), *verified_ids = json_object_new_object();
    for (size_t i = 0; i < json_object_array_length(verified); i++) {
        json_object *item = json_object_array_get_idx(verified,i);
        const char *id;
        if (json_object_is_type(item,json_type_string)) {
            id = json_object_get_string(item);
            if (strlen(id) != (size_t)json_object_get_string_len(item)) invalid("Verified model ID contains a NUL byte.");
        } else {
            id = text_field(item,"requested");
            const char *status = tm_json_optional_string(item,"status");
            if (status && strcmp(status,"PASS")) invalid("A verified model claim cannot carry a failed, skipped or unknown status.");
            json_object *observed;
            if (json_object_object_get_ex(item,"observed",&observed)) {
                if (!json_object_is_type(observed,json_type_array) || json_object_array_length(observed) != 1) invalid("Verified model observations must name exactly the requested model.");
                json_object *value = json_object_array_get_idx(observed,0);
                if (!json_object_is_type(value,json_type_string) || strcmp(json_object_get_string(value),id) || strlen(json_object_get_string(value)) != (size_t)json_object_get_string_len(value)) invalid("Verified model observations must match the requested model.");
            }
        }
        if (!token(id) || !model_in(documented,id)) invalid("Verified models must also have documented compatibility metadata.");
        unique_string(verified_ids,id);
        json_object *value;
        if (!json_object_object_get_ex(model_passes,id,&value)) invalid("A verified model claim needs a matching exact observed-model PASS in a device report.");
    }
    json_object_put(verified_ids); json_object_put(model_passes);
}
static void markdown(const char *s) {
    /* Escape syntax and HTML, but retain normal UTF-8 prose. No metadata is
     * executed, and fields cannot inject new rows or headings. */
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (*p < 32 || *p == 127) fputc(' ',stdout);
        else if (*p == '&') fputs("&amp;",stdout);
        else if (*p == '<') fputs("&lt;",stdout);
        else if (*p == '>') fputs("&gt;",stdout);
        else { if (strchr("\\`*_{}[]()#+-.!|",*p)) putchar('\\'); putchar(*p); }
    }
}
static void source_link(const char *s) {
    fputs("[Anthropic model documentation](<",stdout);
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        if (*p <= 32 || *p == '<' || *p == '>' || *p == 127) printf("%%%02X",*p);
        else putchar(*p);
    }
    fputs(">)",stdout);
}
static void render_notes(json_object *manifest, json_object *models) {
    json_object *claude = tm_json_field(manifest,"claude",json_type_object), *musl = tm_json_field(manifest,"musl",json_type_object);
    fputs("# Termux Muscle ",stdout); markdown(text_field(manifest,"project_version"));
    fputs("\n\nClaude Code: **",stdout); markdown(text_field(claude,"version"));
    fputs("**. Musl loader: **",stdout); markdown(text_field(musl,"version")); fputs("**. Android ARM64 / aarch64.\n\n",stdout);
    const char *date = tm_json_optional_string(manifest,"verified_on");
    if (date && *date) { fputs("Device acceptance date recorded in metadata: ",stdout); markdown(date); fputs(". Publication still requires the complete release gate.\n\n",stdout); }
    else fputs("**Development evidence is incomplete. No device acceptance is asserted.**\n\n",stdout);
    fputs("The Bash manager and C helper are built from verified source on the target Termux installation. Anthropic's executable is downloaded separately and remains unmodified.\n\n## Documented model compatibility\n\nDocumentation checked ",stdout);
    markdown(text_field(models,"checked_documentation_on")); fputs(". Source: ",stdout); source_link(text_field(models,"source"));
    fputs("\n\n| Model | ID | Minimum Claude Code |\n| --- | --- | --- |\n",stdout);
    json_object *documented = array_field(models,"documented");
    for (size_t i = 0; i < json_object_array_length(documented); i++) {
        json_object *item = json_object_array_get_idx(documented,i);
        fputs("| ",stdout); markdown(text_field(item,"name")); fputs(" | ",stdout); markdown(text_field(item,"id"));
        fputs(" | ",stdout); markdown(text_field(item,"minimum_claude_version")); fputs(" |\n",stdout);
    }
    fputs("\n",stdout); markdown(text_field(models,"availability_note"));
    fputs("\n\n## Authenticated evidence\n\n",stdout);
    json_object *verified = array_field(models,"verified");
    if (!json_object_array_length(verified)) fputs("No authenticated model checks are claimed in this release metadata.\n",stdout);
    for (size_t i = 0; i < json_object_array_length(verified); i++) {
        json_object *item = json_object_array_get_idx(verified,i);
        const char *id = json_object_is_type(item,json_type_string) ? json_object_get_string(item) : text_field(item,"requested");
        fputs("- Claimed exact observed-model check: ",stdout); markdown(id); fputs(". The release gate requires its matching PASS report.\n",stdout);
    }
    fputs("\n## Device evidence and limitations\n\n",stdout);
    json_object *reports = array_field(manifest,"reports");
    if (!json_object_array_length(reports)) fputs("No device reports registered.\n",stdout);
    for (size_t i = 0; i < json_object_array_length(reports); i++) { fputs("- ",stdout); markdown(report_path(json_object_array_get_idx(reports,i))); fputc('\n',stdout); }
    fputs("\nSee the README capability matrix and CHANGELOG at this source tag for configurations, PASS/FAIL/SKIP outcomes and known limitations. A passing version probe does not certify tool workflows or every Android device.\n\nIndependent OAS community project. Not affiliated with, endorsed by, sponsored by, or authorized by Anthropic.\n",stdout);
}
int tm_release_main(int argc, char **argv) {
    if (argc != 2) tm_die("usage","Use release-check SOURCE_DIR or release-notes SOURCE_DIR.");
    bool strict = !strcmp(argv[0],"release-check");
    if (!strict && strcmp(argv[0],"release-notes")) tm_die("usage","Unknown release operation.");
    char *root = tm_canonical(argv[1],false); tm_directory(root,false);
    char *path = source_path(root,"VERSION"); size_t size; char *version = tm_read_file(path,129,&size); free(path);
    while (size && (version[size-1] == '\n' || version[size-1] == '\r')) version[--size] = 0;
    if (!project_version(version) || strcmp(version,TM_VERSION)) invalid("VERSION and the locally built helper version must agree and use semantic versions.");
    path = source_path(root,"compatibility.json"); json_object *manifest = tm_json_read(path); free(path); schema_one(manifest);
    if (strcmp(text_field(manifest,"project_version"),version)) invalid("Compatibility project_version and VERSION disagree.");
    verify_pins(manifest); json_object *models = tm_json_field(manifest,"models",json_type_object);
    verify_models(models,text_field(tm_json_field(manifest,"claude",json_type_object),"version"));
    array_field(manifest,"reports");
    require_source(root,"LICENSE"); require_source(root,"CREDITS.md");
    if (strict) {
        if (!tm_links_main || !tm_acquire_main || !tm_report_main || !tm_tooling_main) invalid("Required acquisition, launcher ownership, tooling or reporting commands are missing from this build.");
        const char *files[] = {"Makefile","install.sh","bin/termux-muscle","tests/run.sh","README.md","CONTRIBUTING.md","src/main.c","src/state.c","src/runtime.c","src/release.c","src/tooling.c","lib/tooling.sh","lib/acquire.sh","lib/diagnostics.sh"};
        for (size_t i = 0; i < sizeof files / sizeof *files; i++) require_source(root,files[i]);
        path = source_path(root,"install.sh"); char *installer = tm_read_file(path,TM_METADATA_MAX,NULL); free(path);
        char declaration[160]; snprintf(declaration,sizeof declaration,"\nVERSION=\"%s\"\n",version);
        if (!strstr(installer,declaration)) invalid("Installer VERSION must match the release."); free(installer);
        path = source_path(root,"CHANGELOG.md"); char *changelog = tm_read_file(path,TM_METADATA_MAX,NULL); free(path);
        char heading[160], bracket[160]; snprintf(heading,sizeof heading,"## %s",version); snprintf(bracket,sizeof bracket,"## [%s]",version);
        bool found = false; char *save = NULL;
        for (char *line = strtok_r(changelog,"\n",&save); line; line = strtok_r(NULL,"\n",&save)) {
            size_t n = strlen(heading);
            if ((!strncmp(line,heading,n) && (!line[n] || isspace((unsigned char)line[n]))) || !strncmp(line,bracket,strlen(bracket))) found = true;
        }
        free(changelog); if (!found) invalid("CHANGELOG must contain a heading for this exact release version.");
        verify_reports(root,manifest,models);
        printf("Release gate PASS: %s / Claude Code %s\n",version,text_field(tm_json_field(manifest,"claude",json_type_object),"version"));
    } else render_notes(manifest,models);
    json_object_put(manifest); free(version); free(root); return 0;
}
