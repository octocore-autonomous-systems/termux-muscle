/* SPDX-License-Identifier: MPL-2.0 */
/* Disposable executable fixture. It never reads account data or uses a network. */
#define _GNU_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <unistd.h>

extern char **environ;

static void hex(const char *label, const char *value) {
    printf("%s:", label);
    for (const unsigned char *p = (const unsigned char *)value; *p; ++p)
        printf("%02x", *p);
    putchar('\n');
}

static void execute(char **command) {
    execve(command[0], command, environ);
    perror("fixture exec");
    exit(71);
}

int main(int argc, char **argv) {
    const char *name = strrchr(argv[0], '/');
    name = name ? name + 1 : argv[0];
    if (strcmp(name, "proot") == 0) {
        for (int i = 1; i < argc; ++i)
            hex("arg", argv[i]);
        const char *names[] = {"LD_PRELOAD",
                               "LD_LIBRARY_PATH",
                               "DISABLE_AUTOUPDATER",
                               "USE_BUILTIN_RIPGREP",
                               "TM_CUSTOM_TEST",
                               "TMPDIR",
                               "BUN_TMPDIR",
                               "SSL_CERT_FILE",
                               "SHELL",
                               "PATH"};
        for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); ++i) {
            const char *value = getenv(names[i]);
            if (value)
                hex(names[i], value);
        }
        const char *fd_text = getenv("TM_RELEASE_FD");
        int flags = fd_text ? fcntl(atoi(fd_text), F_GETFD) : -1;
        puts(flags >= 0 && !(flags & FD_CLOEXEC) ? "lease:inherited" : "lease:missing");
        if (getenv("TM_PROBE_SIGNAL"))
            raise(atoi(getenv("TM_PROBE_SIGNAL")));
        return getenv("TM_PROBE_EXIT") ? atoi(getenv("TM_PROBE_EXIT")) : 0;
    }
    if (argc >= 2 && strcmp(argv[1], "--shell") == 0) {
        char *command[] = {"/bin/sh", "-c", "test -n \"$BASH_VERSION\" && printf shell-ok", NULL};
        execute(command);
    }
    if (argc >= 3 && strcmp(argv[1], "--portable") == 0) {
        execute(argv + 2);
    }
    if (argc == 5 && strcmp(argv[1], "--nested") == 0) {
        char self[4096];
        ssize_t size = readlink("/proc/self/exe", self, sizeof(self) - 1);
        if (size < 0)
            return 72;
        self[size] = '\0';
        char *command[] = {argv[2],  "run", argv[3],       argv[4], "current",
                           "normal", "--",  "--self-path", self,    NULL};
        execute(command);
    }
    if (argc == 6 && strcmp(argv[1], "--nested-exact") == 0) {
        char *command[] = {argv[2], "run", argv[3],       argv[4], argv[5],
                           "probe", "--",  "--native-ok", NULL};
        execute(command);
    }
    if (argc == 5 && strcmp(argv[1], "--nested-shell-probe") == 0) {
        char *command[] = {argv[2], "shell-probe", argv[3], argv[4], "current", NULL};
        execute(command);
    }
    if (argc == 2 && strcmp(argv[1], "--native-ok") == 0) {
        puts("native-ok");
        return 0;
    }
    if (argc >= 4 && strcmp(argv[1], "--exec-argv0") == 0) {
        execve(argv[2], argv + 3, environ);
        perror("fixture custom argv0 exec");
        return 71;
    }
    if (argc == 3 && strcmp(argv[1], "--self-path") == 0) {
        char value[4096];
        ssize_t size = readlink("/proc/self/exe", value, sizeof(value) - 1);
        if (size < 0)
            return 72;
        value[size] = '\0';
        if (strcmp(value, argv[2]) != 0)
            return 73;
        puts("native-identity-ok");
        return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--hold") == 0) {
        FILE *ready = fopen(argv[2], "w");
        if (!ready)
            return 74;
        fprintf(ready, "%ld\n", (long)getpid());
        fclose(ready);
        for (;;)
            pause();
    }
    if (argc == 8 && strcmp(argv[1], "--supervise") == 0) {
        pid_t child = fork();
        if (child < 0)
            return 75;
        if (child == 0) {
            if (setsid() < 0)
                _exit(76);
            char *command[] = {argv[2],  "run", argv[3],  argv[4], argv[5],
                               "normal", "--",  "--hold", argv[6], NULL};
            execute(command);
        }
        FILE *record = fopen(argv[7], "w");
        if (!record)
            return 77;
        fprintf(record, "%ld\n", (long)child);
        fclose(record);
        for (;;)
            pause();
    }
    fputs("fixture: unsupported invocation\n", stderr);
    return 64;
}
