/* SPDX-License-Identifier: MPL-2.0 */
/* Loads the native backend's resolver object into an initialized process and
 * reports what it left on descriptor 99. musl, which loads the object in
 * production, runs its constructor the same way after its own startup. */
#define _GNU_SOURCE 1
#include <dlfcn.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char **argv) {
    if (argc != 3)
        return 64;
    /* "occupied" starts with another file already on descriptor 99. */
    if (!strcmp(argv[2], "occupied")) {
        int fd = open("/dev/null", O_RDONLY);
        if (fd < 0 || dup2(fd, 99) != 99)
            return 65;
        close(fd);
    }
    if (!dlopen(argv[1], RTLD_NOW)) {
        fprintf(stderr, "%s\n", dlerror());
        return 66;
    }
    char target[4096];
    ssize_t length = readlink("/proc/self/fd/99", target, sizeof target - 1);
    if (length < 0) {
        puts("none");
        return 0;
    }
    target[length] = 0;
    int flags = fcntl(99, F_GETFD);
    printf("%s %s\n", flags >= 0 && (flags & FD_CLOEXEC) ? "cloexec" : "inherited", target);
    return 0;
}
