/* SPDX-License-Identifier: MPL-2.0 */
/* Resolver configuration for the native backend.
 *
 * musl reads its nameservers from /etc/resolv.conf, a path Android does not
 * have and an application cannot create. The installation's private copy of
 * the musl loader reads /proc/self/fd/99 instead (see configure_loader in
 * acquire.c), and this object puts the resolver file there: when a Claude Code
 * process starts, it opens the file the launcher named in TM_RESOLV_CONF on
 * descriptor 99, close-on-exec, so no child process inherits it.
 *
 * That is all it does. It defines no function another module could call and
 * replaces none. The private loader loads it through TM_PRELOAD, the name that
 * loader reads in place of LD_PRELOAD; Android's own linker never sees it.
 *
 * It is built on the device, by a compiler that targets Android's C library,
 * and runs under musl. So it uses no header and no startup object, only four
 * functions every C library provides, and it names its one dependency "libc",
 * which musl's loader takes to mean itself. */
#define TM_RESOLVER_FD 99
#define TM_O_RDONLY 0
#define TM_O_CLOEXEC 02000000

extern char *getenv(const char *);
extern int open(const char *, int, ...);
extern int dup3(int, int, int);
extern int close(int);

__attribute__((constructor)) static void tm_open_resolver(void) {
    const char *path = getenv("TM_RESOLV_CONF");
    if (!path || path[0] != '/')
        return;
    int fd = open(path, TM_O_RDONLY | TM_O_CLOEXEC);
    if (fd < 0 || fd == TM_RESOLVER_FD)
        return;
    dup3(fd, TM_RESOLVER_FD, TM_O_CLOEXEC);
    close(fd);
}
