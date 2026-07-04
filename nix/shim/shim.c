// nix-store-shim: run a program with a directory bind-mounted at /nix/store.
//
// usage: nix-store-shim [--store DIR]... [--map-user N] [--map-group N]
//                       -- PROG [ARGS]...
//
// Each DIR plays the role of /nix/store itself (its entries are store paths).
// The shim creates a user+mount namespace mapped to the invoking uid/gid
// (or to --map-user/--map-group when given, e.g. to appear as a non-root
// user inside an outer root-mapped namespace), mounts the store dir(s) at
// /nix/store (masking any host store), and execs PROG. Children (cc1, as,
// ld, ...) inherit the namespace. With no --store, it is a plain userns
// exec wrapper.
//
// If the host has no /nix at all (a bare remote-execution worker; /nix cannot
// be created inside a userns because / is owned by unmapped root), the shim
// rebuilds the root filesystem in a tmpfs: bind every top-level entry of /,
// add nix/store from the given dirs, chroot, and restore the original cwd.

#define _GNU_SOURCE
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <sched.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <unistd.h>

#define MAX_STORES 32

static void die(const char *what) {
    fprintf(stderr, "nix-store-shim: %s: %s\n", what, strerror(errno));
    exit(127);
}

static void write_file(const char *path, const char *content) {
    int fd = open(path, O_WRONLY);
    if (fd < 0)
        die(path);
    ssize_t len = (ssize_t)strlen(content);
    if (write(fd, content, len) != len)
        die(path);
    close(fd);
}

static void bind(const char *src, const char *dst) {
    if (mount(src, dst, NULL, MS_BIND | MS_REC, NULL) < 0)
        die(dst);
}

// Replicate one filesystem entry `src` at `dst`: symlinks are recreated,
// directories and files get a mountpoint stub and a recursive bind.
static void replicate(const char *src, const char *dst) {
    struct stat st;
    if (lstat(src, &st) < 0)
        return; // vanished between readdir and here; skip
    if (S_ISLNK(st.st_mode)) {
        char target[PATH_MAX];
        ssize_t k = readlink(src, target, sizeof target - 1);
        if (k < 0)
            die(src);
        target[k] = '\0';
        if (symlink(target, dst) < 0 && errno != EEXIST)
            die(dst);
    } else if (S_ISDIR(st.st_mode)) {
        if (mkdir(dst, 0755) < 0 && errno != EEXIST)
            die(dst);
        bind(src, dst);
    } else {
        int fd = open(dst, O_WRONLY | O_CREAT, 0644);
        if (fd < 0 && errno != EEXIST)
            die(dst);
        if (fd >= 0)
            close(fd);
        bind(src, dst);
    }
}

// Bind every entry of store dir `src` into directory `dst` (a merged store).
static void bind_store_entries(const char *src, const char *dst) {
    DIR *d = opendir(src);
    if (!d)
        die(src);
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
            continue;
        char s[PATH_MAX], t[PATH_MAX];
        snprintf(s, sizeof s, "%s/%s", src, e->d_name);
        snprintf(t, sizeof t, "%s/%s", dst, e->d_name);
        replicate(s, t);
    }
    closedir(d);
}

static void mount_stores_at(char resolved[][PATH_MAX], int nstores,
                            const char *storedir) {
    if (nstores == 1) {
        bind(resolved[0], storedir);
    } else {
        if (mount("tmpfs", storedir, "tmpfs", 0, NULL) < 0)
            die(storedir);
        for (int s = 0; s < nstores; s++)
            bind_store_entries(resolved[s], storedir);
    }
}

// Fallback for hosts without /nix: rebuild / in a tmpfs, with nix/store added.
static void setup_newroot(char resolved[][PATH_MAX], int nstores,
                          const char *cwd) {
    const char *base = "/tmp/.dirlir-root";
    if (mkdir(base, 0755) < 0 && errno != EEXIST)
        die(base);
    if (mount("tmpfs", base, "tmpfs", 0, NULL) < 0)
        die("mount tmpfs newroot");

    DIR *d = opendir("/");
    if (!d)
        die("/");
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        const char *n = e->d_name;
        if (strcmp(n, ".") == 0 || strcmp(n, "..") == 0 || strcmp(n, "nix") == 0)
            continue;
        char s[PATH_MAX], t[PATH_MAX];
        snprintf(s, sizeof s, "/%s", n);
        snprintf(t, sizeof t, "%s/%s", base, n);
        replicate(s, t);
    }
    closedir(d);

    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/nix", base);
    if (mkdir(p, 0755) < 0 && errno != EEXIST)
        die(p);
    snprintf(p, sizeof p, "%s/nix/store", base);
    if (mkdir(p, 0755) < 0 && errno != EEXIST)
        die(p);
    mount_stores_at(resolved, nstores, p);

    // pivot_root, NOT chroot: the kernel refuses unshare(CLONE_NEWUSER)
    // for chrooted processes, which would break nested shims (e.g. a
    // dep-file-processing python shim spawning the gcc shim).
    snprintf(p, sizeof p, "%s/.oldroot", base);
    if (mkdir(p, 0755) < 0 && errno != EEXIST)
        die(p);
    if (syscall(SYS_pivot_root, base, p) < 0)
        die("pivot_root");
    if (chdir("/") < 0)
        die("chdir /");
    if (umount2("/.oldroot", MNT_DETACH) < 0)
        die("umount old root");
    rmdir("/.oldroot");
    if (chdir(cwd) < 0)
        die("chdir after pivot_root");
}

int main(int argc, char **argv) {
    const char *stores[MAX_STORES];
    int nstores = 0;
    uid_t map_uid = getuid();
    gid_t map_gid = getgid();
    int i = 1;
    while (i < argc) {
        if (strcmp(argv[i], "--store") == 0 && i + 1 < argc &&
            nstores < MAX_STORES) {
            stores[nstores++] = argv[i + 1];
            i += 2;
        } else if (strcmp(argv[i], "--map-user") == 0 && i + 1 < argc) {
            map_uid = (uid_t)atoi(argv[i + 1]);
            i += 2;
        } else if (strcmp(argv[i], "--map-group") == 0 && i + 1 < argc) {
            map_gid = (gid_t)atoi(argv[i + 1]);
            i += 2;
        } else if (strcmp(argv[i], "--") == 0) {
            i++;
            break;
        } else {
            break;
        }
    }
    if (i >= argc) {
        fprintf(stderr,
                "usage: nix-store-shim [--store DIR]... [--map-user N] "
                "[--map-group N] -- PROG [ARGS]...\n");
        return 2;
    }

    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof cwd))
        die("getcwd");
    static char resolved[MAX_STORES][PATH_MAX];
    for (int s = 0; s < nstores; s++)
        if (!realpath(stores[s], resolved[s]))
            die(stores[s]);

    uid_t uid = getuid();
    gid_t gid = getgid();
    if (unshare(CLONE_NEWUSER | CLONE_NEWNS) < 0)
        die("unshare(CLONE_NEWUSER|CLONE_NEWNS)");
    // Map uid/gid (to themselves by default, so created files keep real
    // ownership). setgroups must be denied before gid_map can be written.
    char map[64];
    snprintf(map, sizeof map, "%u %u 1", (unsigned)map_uid, (unsigned)uid);
    write_file("/proc/self/uid_map", map);
    write_file("/proc/self/setgroups", "deny");
    snprintf(map, sizeof map, "%u %u 1", (unsigned)map_gid, (unsigned)gid);
    write_file("/proc/self/gid_map", map);

    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0)
        die("remount / private");

    struct stat st;
    if (nstores == 0) {
        // Plain userns exec wrapper; nothing to mount.
    } else if (stat("/nix/store", &st) == 0 && S_ISDIR(st.st_mode)) {
        mount_stores_at(resolved, nstores, "/nix/store");
    } else if (mkdir("/nix", 0755) == 0 || errno == EEXIST) {
        // /nix missing but / (or /nix) is writable to us; try the direct way.
        if (mkdir("/nix/store", 0755) < 0 && errno != EEXIST)
            setup_newroot(resolved, nstores, cwd);
        else
            mount_stores_at(resolved, nstores, "/nix/store");
    } else {
        setup_newroot(resolved, nstores, cwd);
    }

    execvp(argv[i], &argv[i]);
    die(argv[i]);
}
