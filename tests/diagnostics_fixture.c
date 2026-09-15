/* SPDX-License-Identifier: MPL-2.0 */
/* Include the collector to exercise its private parser/process boundaries.
 * Fixtures are synthetic; these tests never invoke an authenticated client. */
#include "../src/report.c"
#include <assert.h>
#include <sys/prctl.h>

static void evidence(const char *events, int code, const char *status, const char *detail) {
    probe_result probe = {.text = (char *)events, .size = strlen(events), .code = code};
    json_object *result = model_result("claude-fable-5-1", &probe);
    assert(!strcmp(string_value(result, "status"), status));
    assert(!strcmp(string_value(result, "detail_code"), detail));
    const char *json = json_object_to_json_string(result);
    assert(!strstr(json, "PRIVATE_SECRET"));
    assert(!strstr(json, "session_id"));
    assert(!strstr(json, "content"));
    json_object_put(result);
}
#define ASSISTANT                                                                                  \
    "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-fable-5-1\",\"content\":[{\"text\":\"PRIVATE_SECRET\"}]},\"session_id\":\"PRIVATE_SECRET\"}\n"
#define RESULT                                                                                     \
    "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"modelUsage\":{\"claude-fable-5-1\":{}},\"result\":\"PRIVATE_SECRET\"}\n"
static void save_pid(const char *path, pid_t pid) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    assert(fd >= 0);
    char text[32];
    int length = snprintf(text, sizeof text, "%ld\n", (long)pid);
    tm_write_all(fd, text, (size_t)length);
    close(fd);
}
static void interruption(const char *self, const char *path, int signum) {
    unlink(path);
    pid_t supervisor = fork();
    assert(supervisor >= 0);
    if (!supervisor) {
        char *args[] = {(char *)self, signum == SIGKILL ? "child-sleep" : "child-grandchild",
                        (char *)path, NULL};
        probe_result result = capture(args, NULL, 5000, 4096, NULL, NULL);
        free(result.text);
        _exit(0);
    }
    pid_t descendant = 0;
    long long deadline = milliseconds() + 2000;
    while (!descendant && milliseconds() < deadline) {
        FILE *file = fopen(path, "r");
        long pid = 0;
        if (file) {
            if (fscanf(file, "%ld", &pid) == 1)
                descendant = (pid_t)pid;
            fclose(file);
        }
        struct timespec pause = {.tv_nsec = 1000000};
        nanosleep(&pause, NULL);
    }
    assert(descendant > 0);
    assert(!kill(supervisor, signum));
    int status;
    assert(waitpid(supervisor, &status, 0) == supervisor);
    if (signum != SIGKILL)
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 128 + signum);
    bool gone = false;
    deadline = milliseconds() + 2000;
    while (milliseconds() < deadline) {
        pid_t got = waitpid(descendant, &status, WNOHANG);
        if (got == descendant) {
            gone = true;
            assert(WIFSIGNALED(status));
            break;
        }
        assert(got >= 0 || errno == EINTR);
        struct timespec pause = {.tv_nsec = 1000000};
        nanosleep(&pause, NULL);
    }
    assert(gone);
    unlink(path);
}
static void tests(const char *self, const char *pid_path) {
    evidence(ASSISTANT RESULT, 0, "PASS", "exact_model_verified");
    evidence("{\"type\":\"system\",\"model\":\"claude-fable-5-1\"}\n" RESULT, 0, "SKIP",
             "model_evidence_insufficient");
    evidence(ASSISTANT, 0, "SKIP", "model_evidence_insufficient");
    evidence(ASSISTANT RESULT RESULT, 0, "FAIL", "model_evidence_invalid");
    evidence(ASSISTANT RESULT "not json PRIVATE_SECRET\n", 0, "FAIL", "model_evidence_invalid");
    evidence(
        ASSISTANT
        "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"modelUsage\":{\"claude-fable-5-1\":{},\"claude-sonnet-5\":{}}}\n",
        0, "FAIL", "model_fallback_observed");
    evidence("{\"type\":\"assistant\",\"message\":{\"model\":\"claude-sonnet-5\"}}\n" RESULT, 0,
             "FAIL", "model_fallback_observed");
    evidence(
        "{\"type\":\"assistant\",\"message\":{\"model\":\"claude-fable-5-1\\u0000PRIVATE_SECRET\"}}\n" RESULT,
        0, "FAIL", "model_evidence_invalid");
    evidence(
        ASSISTANT
        "{\"type\":\"result\",\"subtype\":\"error_during_execution\",\"is_error\":true,\"errors\":[\"PRIVATE_SECRET\"]}\n",
        0, "FAIL", "model_api_error");
    evidence(
        "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"PRIVATE_SECRET\"}}\n",
        1, "FAIL", "authentication_failed");
    evidence("{\"type\":\"error\",\"error\":{\"type\":\"permission_error\"}}\n", 1, "FAIL",
             "account_permission");
    evidence(ASSISTANT RESULT, 1, "FAIL", "probe_failed");
    evidence("", 0, "SKIP", "model_evidence_insufficient");
    assert(!model_id("opus"));
    assert(!model_id("claude-opus"));
    assert(!model_id("claude-X"));
    assert(!model_id("claude-5\n"));
    assert(model_id("claude-opus-5"));
    assert(!safe_text("PRIVATE_SECRET\nmore", 100));
    assert(!safe_text("/private/path", 100));
    char *args[] = {(char *)self, "child-ok", NULL};
    probe_result result = capture(args, NULL, 1000, 4096, NULL, NULL);
    assert(probe_ok(&result));
    assert(!strcmp(result.text, "ok\n"));
    free(result.text);
    args[1] = "child-sleep";
    long long start = milliseconds();
    result = capture(args, NULL, 100, 4096, NULL, NULL);
    assert(result.timeout);
    assert(milliseconds() - start < 1500);
    free(result.text);
    args[1] = "child-flood";
    result = capture(args, NULL, 1000, 100, NULL, NULL);
    assert(result.overflow);
    assert(result.size <= 100);
    free(result.text);
    /* Subreaper permits a direct wait of the fixture grandchild after cleanup.
     * It is a test-only process setting, never enabled in the product. */
    assert(!prctl(PR_SET_CHILD_SUBREAPER, 1));
    args[1] = "child-grandchild";
    result = capture(args, NULL, 150, 4096, NULL, NULL);
    assert(result.timeout);
    pid_t grandchild = (pid_t)strtol(result.text, NULL, 10);
    assert(grandchild > 0);
    int status;
    assert(waitpid(grandchild, &status, 0) == grandchild);
    assert(WIFSIGNALED(status));
    free(result.text);
    interruption(self, pid_path, SIGTERM);
    interruption(self, pid_path, SIGHUP);
    interruption(self, pid_path, SIGINT);
    /* This proves direct-child PDEATHSIG only; detached descendant cleanup
     * after SIGKILL is deliberately outside the evidence claim. */
    interruption(self, pid_path, SIGKILL);
    puts(
        "PASS diagnostics parser redaction, model evidence, bounds, deadlines, signal cleanup and direct-child parent-death signal");
}
static void validate_report(const char *path) {
    json_object *report = tm_json_read(path);
    assert(json_object_get_int(tm_json_field(report, "schema", json_type_int)) == 1);
    assert(!strcmp(tm_json_string(report, "provenance"), "community"));
    json_object *checks = tm_json_field(report, "checks", json_type_array);
    const char *lifecycle[] = {"install", "update", "rollback", "uninstall", "shell_tools"};
    for (size_t i = 0; i < sizeof lifecycle / sizeof *lifecycle; i++) {
        bool found = false;
        for (size_t j = 0; j < json_object_array_length(checks); j++) {
            json_object *check = json_object_array_get_idx(checks, j);
            if (!strcmp(tm_json_string(check, "id"), lifecycle[i])) {
                found = true;
                assert(!strcmp(tm_json_string(check, "status"), "SKIP"));
            }
        }
        assert(found);
    }
    json_object *env = tm_json_field(report, "environment", json_type_object);
    assert(!json_object_object_get_ex(env, "serial", NULL));
    json_object *packages = tm_json_field(env, "packages", json_type_object);
    assert(json_object_object_length(packages) == 19);
    assert(json_object_object_get_ex(packages, "mandoc", NULL));
    assert(!strstr(json_object_to_json_string(report), "PRIVATE_SECRET"));
    assert(!strstr(json_object_to_json_string(report), "/data/data/"));
    json_object_put(report);
}
int main(int argc, char **argv) {
    if (argc == 5 && !strcmp(argv[1], "links-check")) {
        json_object *checks = json_object_new_array();
        command_links_check(checks, argv[2]);
        assert(json_object_array_length(checks) == 1);
        json_object *value = json_object_array_get_idx(checks, 0);
        assert(!strcmp(string_value(value, "id"), "command_links"));
        assert(!strcmp(string_value(value, "status"), argv[3]));
        assert(!strcmp(string_value(value, "detail_code"), argv[4]));
        const char *json = json_object_to_json_string(checks);
        assert(!strstr(json, "PRIVATE_SECRET") && !strstr(json, argv[2]) && !strstr(json, "path") &&
               !strstr(json, "target"));
        json_object_put(checks);
        return 0;
    }
    if (argc == 4 && !strcmp(argv[1], "resolver")) {
        const char *detail = resolver_configuration(argv[2]);
        assert(!strcmp(detail, argv[3]));
        json_object *checks = json_object_new_array();
        bool passed = dns_check(checks, argv[2]);
        assert(passed == !strcmp(argv[3], "nameserver_configured"));
        const char *json = json_object_to_json_string(checks);
        assert(!strstr(json, "203.0.113.53") && !strstr(json, "2001:db8") &&
               !strstr(json, "PRIVATE_SECRET"));
        json_object_put(checks);
        return 0;
    }
    if (argc >= 3 && !strcmp(argv[1], "exec-reset-signals")) {
        assert(signal(SIGINT, SIG_DFL) != SIG_ERR);
        assert(signal(SIGQUIT, SIG_DFL) != SIG_ERR);
        execv(argv[2], argv + 2);
        return 127;
    }
    if (argc == 3 && !strcmp(argv[1], "tests")) {
        tests(argv[0], argv[2]);
        return 0;
    }
    if (!strcmp(argv[1], "child-ok")) {
        puts("ok");
        fputs("PRIVATE_SECRET", stderr);
        return 0;
    }
    if (!strcmp(argv[1], "child-sleep")) {
        if (argc == 3)
            save_pid(argv[2], getpid());
        for (;;)
            pause();
    }
    if (!strcmp(argv[1], "child-flood")) {
        char bytes[4096];
        memset(bytes, 'x', sizeof bytes);
        for (;;)
            tm_write_all(1, bytes, sizeof bytes);
    }
    if (!strcmp(argv[1], "child-grandchild")) {
        pid_t pid = fork();
        assert(pid >= 0);
        if (!pid) {
            for (;;)
                pause();
        }
        if (argc == 3)
            save_pid(argv[2], pid);
        printf("%ld\n", (long)pid);
        fflush(stdout);
        return 0;
    }
    if (!strcmp(argv[1], "doctor") && getenv("TM_REPORT_TEST_PIDFILE")) {
        FILE *file = fopen(getenv("TM_REPORT_TEST_PIDFILE"), "w");
        assert(file);
        fprintf(file, "%ld %ld\n", (long)getpid(), (long)getppid());
        assert(!fclose(file));
        puts("{\"schema\":1}");
        fflush(stdout);
        for (;;)
            pause();
    }
    if (!strcmp(argv[1], "validate") && argc == 3) {
        validate_report(argv[2]);
        return 0;
    }
    return 2;
}
