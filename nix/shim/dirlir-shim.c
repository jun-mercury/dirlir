// dirlir-shim: provision declared content, optionally enclose everything else.
//
// usage: dirlir-shim [OPTIONS] [@argfile] -- PROG [ARGS...]
//
// Flag classes (PLAN-v2 ADR-2; source sections below mirror them):
//   provision (additive)   --store DIR      merge DIR's entries into the
//                                           provisioned /nix/store (entries
//                                           may be symlinks; resolved before
//                                           any namespace work)
//   enclose  (subtractive) --enclose        pivot into a minimal root: the
//                                           provisioned /nix/store, the exec
//                                           root (cwd) at its own path, fresh
//                                           /tmp, a /dev subset, fresh /proc
//                                           (new PID namespace), minimal /etc
//                          --map-user N     uid to appear as (default: self)
//                          --map-group N    gid to appear as (default: self)
//                          --fail-hint STR  appended to the failure trailer;
//                                           callers inject their own escape-
//                                           hatch wording (no buck2/nix UX is
//                                           hardcoded here)
//   exec                   @argfile         read args, one per line
//                          --salt STR       no-op; exists so callers can
//                                           thread cache-invalidation state
//                                           into their action digests
//                          -- PROG ARGS...  command
//
// Without --enclose, the host view is kept and only /nix/store is replaced
// (masking the host store is the same operation). Enclose-class code
// contains no nix-specific logic; the store is provisioned content like any
// other. Children inherit the namespaces.

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
#include <sys/wait.h>
#include <unistd.h>

#define MAX_STORES 32
#define MAX_ENTRIES 4096
#define MAX_ARGS 4096

static void die(const char *what) {
    fprintf(stderr, "dirlir-shim: %s: %s\n", what, strerror(errno));
    exit(127);
}

static void write_file(const char *path, const char *content) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
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

// mkdir -p for an absolute path under a (possibly empty) root prefix.
static void mkpath(const char *prefix, const char *path) {
    char buf[PATH_MAX];
    if (snprintf(buf, sizeof buf, "%s%s", prefix, path) >= (int)sizeof buf)
        die("path too long");
    for (char *p = buf + strlen(prefix) + 1; *p; p++) {
        if (*p == '/') {
            *p = '\0';
            if (mkdir(buf, 0755) < 0 && errno != EEXIST)
                die(buf);
            *p = '/';
        }
    }
    if (mkdir(buf, 0755) < 0 && errno != EEXIST)
        die(buf);
}

// ===================== provision ==========================================
// Store entries are resolved (realpath) BEFORE any namespace changes, so
// symlinked_dir-composed stores (entries pointing at sibling artifacts)
// work, and resolution never depends on the masked view.

struct entry {
    char name[256];
    char resolved[PATH_MAX];
};

static struct entry g_entries[MAX_ENTRIES];
static int g_nentries = 0;

static void collect_store(const char *dir) {
    DIR *d = opendir(dir);
    if (!d)
        die(dir);
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        if (strcmp(e->d_name, ".") == 0 || strcmp(e->d_name, "..") == 0)
            continue;
        // first store wins on duplicate basenames (identical content by
        // construction: entries are content-addressed store paths)
        for (int i = 0; i < g_nentries; i++)
            if (strcmp(g_entries[i].name, e->d_name) == 0)
                goto next;
        if (g_nentries == MAX_ENTRIES)
            die("too many store entries");
        char src[PATH_MAX];
        if (snprintf(src, sizeof src, "%s/%s", dir, e->d_name) >= (int)sizeof src)
            die("store path too long");
        struct entry *ent = &g_entries[g_nentries];
        snprintf(ent->name, sizeof ent->name, "%s", e->d_name);
        if (!realpath(src, ent->resolved))
            die(src);
        g_nentries++;
    next:;
    }
    closedir(d);
}

// Mount the merged store at <root>/nix/store (root may be "").
static void provision_store(const char *root) {
    char store[PATH_MAX];
    snprintf(store, sizeof store, "%s/nix/store", root);
    if (mount("tmpfs", store, "tmpfs", 0, NULL) < 0)
        die(store);
    for (int i = 0; i < g_nentries; i++) {
        char dst[PATH_MAX];
        if (snprintf(dst, sizeof dst, "%s/%s", store, g_entries[i].name) >=
            (int)sizeof dst)
            die("store entry path too long");
        if (mkdir(dst, 0755) < 0 && errno != EEXIST)
            die(dst);
        bind(g_entries[i].resolved, dst);
    }
    if (mount(NULL, store, NULL, MS_REMOUNT | MS_BIND | MS_RDONLY, NULL) < 0) {
        // read-only remount is best-effort hardening; tolerate refusal
    }
}

// Replicate one filesystem entry (for the no-/nix provision fallback).
static void replicate(const char *src, const char *dst) {
    struct stat st;
    if (lstat(src, &st) < 0)
        return;
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

// ===================== enclose ============================================
// Everything here is content-agnostic: it builds a minimal root and denies
// the rest of the host. No store semantics.

static void pivot_into(const char *base, const char *cwd) {
    char put_old[PATH_MAX];
    snprintf(put_old, sizeof put_old, "%s/.oldroot", base);
    if (mkdir(put_old, 0755) < 0 && errno != EEXIST)
        die(put_old);
    if (syscall(SYS_pivot_root, base, put_old) < 0)
        die("pivot_root");
    if (chdir("/") < 0)
        die("chdir /");
    if (umount2("/.oldroot", MNT_DETACH) < 0)
        die("umount old root");
    rmdir("/.oldroot");
    if (chdir(cwd) < 0)
        die("chdir after pivot_root");
}

static void enclose_dev(const char *base) {
    char p[PATH_MAX];
    snprintf(p, sizeof p, "%s/dev", base);
    if (mkdir(p, 0755) < 0 && errno != EEXIST)
        die(p);
    static const char *nodes[] = {"null", "zero", "urandom", "random", "tty"};
    for (unsigned i = 0; i < sizeof nodes / sizeof *nodes; i++) {
        char src[PATH_MAX], dst[PATH_MAX];
        snprintf(src, sizeof src, "/dev/%s", nodes[i]);
        snprintf(dst, sizeof dst, "%s/dev/%s", base, nodes[i]);
        if (access(src, F_OK) != 0)
            continue; // tolerate hosts without e.g. /dev/tty
        int fd = open(dst, O_WRONLY | O_CREAT, 0644);
        if (fd < 0)
            die(dst);
        close(fd);
        if (mount(src, dst, NULL, MS_BIND, NULL) < 0)
            die(dst);
    }
    snprintf(p, sizeof p, "%s/dev/shm", base);
    if (mkdir(p, 01777) < 0 && errno != EEXIST)
        die(p);
    if (mount("tmpfs", p, "tmpfs", 0, "mode=1777") < 0)
        die(p);
    static const char *links[][2] = {
        {"fd", "/proc/self/fd"},
        {"stdin", "/proc/self/fd/0"},
        {"stdout", "/proc/self/fd/1"},
        {"stderr", "/proc/self/fd/2"},
    };
    for (unsigned i = 0; i < sizeof links / sizeof *links; i++) {
        snprintf(p, sizeof p, "%s/dev/%s", base, links[i][0]);
        if (symlink(links[i][1], p) < 0 && errno != EEXIST)
            die(p);
    }
}

static void enclose_etc(const char *base, uid_t uid, gid_t gid) {
    char p[PATH_MAX], content[256];
    snprintf(p, sizeof p, "%s/etc", base);
    if (mkdir(p, 0755) < 0 && errno != EEXIST)
        die(p);
    snprintf(p, sizeof p, "%s/etc/passwd", base);
    snprintf(content, sizeof content,
             "root:x:0:0::/:/noshell\nbuild:x:%u:%u::/tmp:/noshell\n",
             (unsigned)uid, (unsigned)gid);
    write_file(p, content);
    snprintf(p, sizeof p, "%s/etc/group", base);
    snprintf(content, sizeof content, "root:x:0:\nbuild:x:%u:\n",
             (unsigned)gid);
    write_file(p, content);
    snprintf(p, sizeof p, "%s/etc/hosts", base);
    write_file(p, "127.0.0.1 localhost\n");
}

// Build and enter the minimal root. Runs in the child of the PID-namespace
// fork (so the fresh /proc matches the new PID namespace).
static void enclose(const char *cwd, uid_t uid, gid_t gid) {
    const char *base = "/tmp/.dirlir-enclose";
    if (mkdir(base, 0755) < 0 && errno != EEXIST)
        die(base);
    if (mount("tmpfs", base, "tmpfs", 0, NULL) < 0)
        die("mount tmpfs newroot");

    char p[PATH_MAX];
    // provisioned store
    mkpath(base, "/nix/store");
    provision_store(base);
    // fresh /tmp FIRST: the exec root may itself live under /tmp (RE
    // workers commonly do), and its bind must land inside the fresh tmpfs
    // rather than be shadowed by it
    mkpath(base, "/tmp");
    snprintf(p, sizeof p, "%s/tmp", base);
    if (mount("tmpfs", p, "tmpfs", 0, "mode=1777") < 0)
        die(p);
    // exec root (cwd) at its own absolute path: buck2 actions address all
    // inputs/outputs relative to it
    mkpath(base, cwd);
    snprintf(p, sizeof p, "%s%s", base, cwd);
    bind(cwd, p);
    enclose_dev(base);
    enclose_etc(base, uid, gid);
    // Fresh /proc for the new PID namespace. Must be mounted BEFORE the
    // pivot: the kernel only permits a userns proc mount while a fully
    // visible proc instance still exists in the mount namespace.
    mkpath(base, "/proc");
    snprintf(p, sizeof p, "%s/proc", base);
    if (mount("proc", p, "proc", 0, NULL) < 0)
        die("mount /proc");

    pivot_into(base, cwd);
}

// Provision without enclosure: keep the host view, replace /nix/store.
static void provision_only(const char *cwd) {
    struct stat st;
    if (stat("/nix/store", &st) == 0 && S_ISDIR(st.st_mode)) {
        provision_store("");
        return;
    }
    if ((mkdir("/nix", 0755) == 0 || errno == EEXIST) &&
        (mkdir("/nix/store", 0755) == 0 || errno == EEXIST)) {
        provision_store("");
        return;
    }
    // No /nix and / not writable (bare worker): replicate the host root in
    // a tmpfs, add nix/store, pivot. (pivot_root, not chroot: chrooted
    // processes cannot create nested user namespaces.)
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
        char src[PATH_MAX], dst[PATH_MAX];
        snprintf(src, sizeof src, "/%s", n);
        snprintf(dst, sizeof dst, "%s/%s", base, n);
        replicate(src, dst);
    }
    closedir(d);
    mkpath(base, "/nix/store");
    provision_store(base);
    pivot_into(base, cwd);
}

// ===================== exec ===============================================

static char *g_args[MAX_ARGS];
static int g_nargs = 0;

static void push_arg(char *a) {
    if (g_nargs >= MAX_ARGS - 1)
        die("too many arguments");
    g_args[g_nargs++] = a;
}

// @argfile: one argument per line (no quoting; newline is the separator).
static void expand_argfile(const char *path) {
    FILE *f = fopen(path, "r");
    if (!f)
        die(path);
    char line[PATH_MAX * 2];
    while (fgets(line, sizeof line, f)) {
        size_t n = strlen(line);
        while (n > 0 && (line[n - 1] == '\n' || line[n - 1] == '\r'))
            line[--n] = '\0';
        if (n == 0)
            continue;
        push_arg(strdup(line));
    }
    fclose(f);
}

static void usage(void) {
    fprintf(stderr,
            "usage: dirlir-shim [OPTIONS] [@argfile] -- PROG [ARGS...]\n"
            "provision:  --store DIR       merge DIR into /nix/store\n"
            "enclose:    --enclose         minimal root (store, exec root,\n"
            "                              /tmp, /dev subset, /proc, /etc)\n"
            "            --map-user N      appear as uid N\n"
            "            --map-group N     appear as gid N\n"
            "            --fail-hint STR   appended to the failure trailer\n"
            "exec:       @argfile          read args, one per line\n"
            "            --salt STR        no-op digest carrier\n"
            "            -- PROG ARGS...   command to run\n");
    exit(2);
}

int main(int argc, char **argv) {
    // @argfile expansion applies only to the shim's OWN arguments (before
    // `--`); anything after belongs to the command verbatim (e.g. gcc's
    // @argsfiles use different quoting rules and must pass through).
    int seen_ddash = 0;
    for (int i = 1; i < argc; i++) {
        if (!seen_ddash && strcmp(argv[i], "--") == 0)
            seen_ddash = 1;
        if (!seen_ddash && argv[i][0] == '@')
            expand_argfile(argv[i] + 1);
        else
            push_arg(argv[i]);
    }

    const char *stores[MAX_STORES];
    int nstores = 0;
    int enclose_mode = 0;
    const char *fail_hint = "isolation is active; check the caller's isolation setting";
    uid_t uid = getuid(), map_uid = uid;
    gid_t gid = getgid(), map_gid = gid;

    int i = 0;
    while (i < g_nargs) {
        if (strcmp(g_args[i], "--store") == 0 && i + 1 < g_nargs &&
            nstores < MAX_STORES) {
            stores[nstores++] = g_args[i + 1];
            i += 2;
        } else if (strcmp(g_args[i], "--enclose") == 0) {
            enclose_mode = 1;
            i += 1;
        } else if (strcmp(g_args[i], "--map-user") == 0 && i + 1 < g_nargs) {
            map_uid = (uid_t)atoi(g_args[i + 1]);
            i += 2;
        } else if (strcmp(g_args[i], "--map-group") == 0 && i + 1 < g_nargs) {
            map_gid = (gid_t)atoi(g_args[i + 1]);
            i += 2;
        } else if (strcmp(g_args[i], "--fail-hint") == 0 && i + 1 < g_nargs) {
            fail_hint = g_args[i + 1];
            i += 2;
        } else if (strcmp(g_args[i], "--salt") == 0 && i + 1 < g_nargs) {
            i += 2; // digest carrier only; no semantics
        } else if (strcmp(g_args[i], "--") == 0) {
            i += 1;
            break;
        } else {
            usage();
        }
    }
    if (i >= g_nargs)
        usage();

    char cwd[PATH_MAX];
    if (!getcwd(cwd, sizeof cwd))
        die("getcwd");

    // Resolve all provisioned content before touching namespaces.
    for (int s = 0; s < nstores; s++)
        collect_store(stores[s]);

    int flags = CLONE_NEWUSER | CLONE_NEWNS;
    if (enclose_mode)
        flags |= CLONE_NEWPID;
    if (unshare(flags) < 0)
        die("unshare");

    char map[64];
    snprintf(map, sizeof map, "%u %u 1", (unsigned)map_uid, (unsigned)uid);
    write_file("/proc/self/uid_map", map);
    write_file("/proc/self/setgroups", "deny");
    snprintf(map, sizeof map, "%u %u 1", (unsigned)map_gid, (unsigned)gid);
    write_file("/proc/self/gid_map", map);

    if (mount(NULL, "/", NULL, MS_REC | MS_PRIVATE, NULL) < 0)
        die("remount / private");

    if (!enclose_mode) {
        if (nstores > 0)
            provision_only(cwd);
        execvp(g_args[i], &g_args[i]);
        die(g_args[i]);
    }

    // Enclosed: fork so the child populates the new PID namespace (fresh
    // /proc must belong to it); the parent waits and owns the trailer.
    pid_t child = fork();
    if (child < 0)
        die("fork");
    if (child == 0) {
        enclose(cwd, map_uid, map_gid);
        execvp(g_args[i], &g_args[i]);
        die(g_args[i]);
    }
    int status;
    if (waitpid(child, &status, 0) < 0)
        die("waitpid");
    int code = WIFEXITED(status) ? WEXITSTATUS(status)
                                 : 128 + WTERMSIG(status);
    if (code != 0) {
        fprintf(stderr,
                "dirlir-shim[enclose]: command failed inside minimal root "
                "(visible: /nix/store, %s, /tmp, /proc, /dev, minimal /etc); "
                "%s\n",
                cwd, fail_hint);
    }
    return code;
}
