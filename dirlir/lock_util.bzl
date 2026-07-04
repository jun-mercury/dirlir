# Load-time views over nix/lock.bzl: closure computation and store-path
# addressing. With these, the lockfile itself never enters the build graph.

load("@root//nix:lock.bzl", "PACKAGES", "PATHS")

def pkg_output(name, output = None):
    """Store path of a locked package (optionally a specific output)."""
    pkg = PACKAGES.get(name)
    if pkg == None:
        fail("package '{}' is not in nix/lock.json; add it to tools/resolve.sh and re-resolve".format(name))
    if output != None:
        path = pkg["outputs"].get(output)
        if path == None:
            fail("package '{}' has no output '{}' (has: {})".format(
                name, output, ", ".join(sorted(pkg["outputs"].keys()))))
        return path
    return pkg["storePath"]

def parse_spec(spec):
    """'gcc' or 'openssl.dev' -> store path."""
    name, sep, out = spec.partition(".")
    return pkg_output(name, out if sep else None)

def store_base(spec):
    """'openssl.dev' -> '<hash>-openssl-3.x-dev' (basename under /nix/store)."""
    return parse_spec(spec).split("/")[-1]

def closure(root_paths):
    """Transitive closure over the lockfile reference graph."""
    seen = {p: True for p in root_paths}
    frontier = list(root_paths)
    for _ in range(len(PATHS) + 1):
        if not frontier:
            break
        nxt = []
        for p in frontier:
            info = PATHS.get(p)
            if info == None:
                fail("store path '{}' missing from the lock paths table; re-resolve".format(p))
            for r in info["references"]:
                if r not in seen:
                    seen[r] = True
                    nxt.append(r)
        frontier = nxt
    return sorted(seen.keys())
