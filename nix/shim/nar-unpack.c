// nar-unpack: unpack one NAR (Nix ARchive) file into a directory.
//
// usage: nar-unpack [--size N] NAR-FILE DEST-DIR
//
// Companion to dirlir-shim in the dirlir bootstrap (both static musl,
// built from the flake by a local nix-build action). Runs anywhere,
// including bare RE workers: no interpreter, no network, no host deps.
//
// Verification model (PLAN-v2): the NAR bytes were already hash-verified by
// buck2's native download_file (sha256 == the locked NarHash, since
// nixos.snix.store serves uncompressed NARs). This tool only validates
// STRUCTURE: token grammar, entry names (no '/', '.', '..', empty),
// strictly ascending sibling order (which also excludes duplicates),
// declared sizes, zero padding, and an optional --size cap on total bytes
// consumed.
//
// Variant C (PLAN-v2 M1 verdict): symlink targets are written EXACTLY as
// stored — no rewriting. Consumers view stores through dirlir-shim mounts,
// where absolute /nix/store targets resolve. A --manifest mode (variant B:
// merge many NARs into one tree with relative rewriting) is deliberately
// not implemented unless the C verdict flips.

#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

static const char *g_file = "";
static uint64_t g_consumed = 0;
static uint64_t g_limit = 0; // 0 = no cap
static FILE *g_in = NULL;

static void die(const char *fmt, const char *arg) {
    fprintf(stderr, "nar-unpack: %s: ", g_file);
    fprintf(stderr, fmt, arg);
    fprintf(stderr, "\n");
    exit(1);
}

static void read_exact(void *buf, uint64_t n) {
    g_consumed += n;
    if (g_limit && g_consumed > g_limit)
        die("stream exceeds --size cap%s", "");
    if (fread(buf, 1, n, g_in) != n)
        die("unexpected EOF%s", "");
}

static uint64_t read_u64(void) {
    unsigned char b[8];
    read_exact(b, 8);
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--)
        v = (v << 8) | b[i];
    return v;
}

static void read_padding(uint64_t n) {
    uint64_t pad = (8 - n % 8) % 8;
    unsigned char b[8];
    read_exact(b, pad);
    for (uint64_t i = 0; i < pad; i++)
        if (b[i] != 0)
            die("non-zero padding%s", "");
}

// Read a length-prefixed string into a fixed buffer (tokens and names are
// short; file contents use read_contents instead).
static uint64_t read_str(char *buf, uint64_t cap) {
    uint64_t n = read_u64();
    if (n >= cap)
        die("string too long%s", "");
    read_exact(buf, n);
    buf[n] = '\0';
    if (strlen(buf) != n)
        die("embedded NUL in string%s", "");
    read_padding(n);
    return n;
}

static void expect(const char *tok) {
    char buf[64];
    read_str(buf, sizeof buf);
    if (strcmp(buf, tok) != 0)
        die("expected token '%s'", tok);
}

static void read_contents(const char *path) {
    uint64_t n = read_u64();
    if (g_limit && g_consumed + n > g_limit)
        die("contents exceed --size cap%s", "");
    int fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0644);
    if (fd < 0)
        die("cannot create '%s'", path);
    char buf[1 << 16];
    uint64_t left = n;
    while (left > 0) {
        uint64_t chunk = left < sizeof buf ? left : sizeof buf;
        read_exact(buf, chunk);
        if (write(fd, buf, chunk) != (ssize_t)chunk)
            die("short write to '%s'", path);
        left -= chunk;
    }
    close(fd);
    read_padding(n);
}

static void check_name(const char *name) {
    if (name[0] == '\0' || strchr(name, '/') || strcmp(name, ".") == 0 ||
        strcmp(name, "..") == 0)
        die("illegal entry name '%s'", name);
}

static void restore_node(const char *path);

static void restore_directory(const char *path) {
    if (mkdir(path, 0755) < 0)
        die("cannot mkdir '%s'", path);
    char prev[256] = "";
    char tok[64];
    for (;;) {
        read_str(tok, sizeof tok);
        if (strcmp(tok, ")") == 0)
            return;
        if (strcmp(tok, "entry") != 0)
            die("expected 'entry' or ')', got '%s'", tok);
        expect("(");
        expect("name");
        char name[256];
        read_str(name, sizeof name);
        check_name(name);
        // NAR requires strictly ascending sibling names; this also rejects
        // duplicates (and case-collision attacks rely on the fs, not us).
        if (prev[0] && strcmp(prev, name) >= 0)
            die("entry names not strictly ascending at '%s'", name);
        strncpy(prev, name, sizeof prev - 1);
        expect("node");
        char child[PATH_MAX];
        if (snprintf(child, sizeof child, "%s/%s", path, name) >=
            (int)sizeof child)
            die("path too long at '%s'", name);
        restore_node(child);
        expect(")");
    }
}

static void restore_node(const char *path) {
    char tok[64];
    expect("(");
    expect("type");
    read_str(tok, sizeof tok);
    if (strcmp(tok, "regular") == 0) {
        read_str(tok, sizeof tok);
        int executable = 0;
        if (strcmp(tok, "executable") == 0) {
            executable = 1;
            expect("");
            read_str(tok, sizeof tok);
        }
        if (strcmp(tok, "contents") != 0)
            die("expected 'contents', got '%s'", tok);
        read_contents(path);
        if (chmod(path, executable ? 0755 : 0644) < 0)
            die("cannot chmod '%s'", path);
        expect(")");
    } else if (strcmp(tok, "symlink") == 0) {
        expect("target");
        char target[PATH_MAX];
        uint64_t n = read_str(target, sizeof target);
        if (n == 0)
            die("empty symlink target%s", "");
        if (symlink(target, path) < 0)
            die("cannot symlink '%s'", path);
        expect(")");
    } else if (strcmp(tok, "directory") == 0) {
        restore_directory(path);
    } else {
        die("unknown node type '%s'", tok);
    }
}

int main(int argc, char **argv) {
    int i = 1;
    if (i < argc && strcmp(argv[i], "--size") == 0 && i + 1 < argc) {
        g_limit = strtoull(argv[i + 1], NULL, 10);
        i += 2;
    }
    if (argc - i != 2) {
        fprintf(stderr, "usage: nar-unpack [--size N] NAR-FILE DEST-DIR\n");
        return 2;
    }
    g_file = argv[i];
    g_in = fopen(g_file, "rb");
    if (!g_in)
        die("cannot open%s", "");
    expect("nix-archive-1");
    restore_node(argv[i + 1]);
    // Exactly one archive; trailing bytes are an error.
    char c;
    if (fread(&c, 1, 1, g_in) != 0)
        die("trailing bytes after archive%s", "");
    fclose(g_in);
    return 0;
}
