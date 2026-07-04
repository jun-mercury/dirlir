"""dirlir plan phase: validate features, toposort, resolve closures.

The antlir2 depgraph analog. Reads feature JSONs (in declaration order),
the lockfile, and optionally the parent layer's facts; emits plan.json for
materialize.py. All conflicts and unsatisfied requirements fail HERE,
before any materialization work happens.

Items are antlir2-style: Entry(path) (a file/symlink/dir occupying a path)
and Dir(path) (a directory that things can be placed under). Every feature
declares provides/requires; requirements must be satisfiable in some order
consistent with the fixed class order (antlir2's BuildPhase analog):

    ensure_dirs_exist -> nix_packages -> remove -> install/symlink
"""

import argparse
import json
import posixpath
import sys

CLASS_ORDER = {
    "ensure_dirs_exist": 0,
    "nix_packages": 1,
    "remove": 2,
    "install": 3,
    "symlink": 3,
}


def norm(path):
    p = posixpath.normpath(path.lstrip("/"))
    if p in (".", ""):
        return ""
    if p.startswith(".."):
        raise SystemExit(f"error: path escapes the layer: {path}")
    return p


def parents_of(path):
    parts = path.split("/")
    return ["/".join(parts[:i]) for i in range(1, len(parts))]


def resolve_roots(lock, feature):
    """Package specs ('gcc', 'openssl.dev') -> store path roots."""
    roots = []
    for spec in feature["spec"]["packages"]:
        name, _, output = spec.partition(".")
        pkg = lock["packages"].get(name)
        if pkg is None:
            raise SystemExit(
                f"error: package '{name}' (from {feature['label']}) is not in "
                f"the lockfile; add it to the nix/resolve.py invocation")
        if output:
            path = pkg["outputs"].get(output)
            if path is None:
                raise SystemExit(
                    f"error: package '{name}' has no output '{output}' "
                    f"(has: {', '.join(sorted(pkg['outputs']))})")
            roots.append(path)
        else:
            roots.append(pkg["storePath"])
    return roots


def closure_of(lock, roots):
    paths = lock["paths"]
    seen = set()
    stack = list(roots)
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        info = paths.get(p)
        if info is None:
            raise SystemExit(
                f"error: {p} is not in the lockfile paths table; "
                f"re-run nix/resolve.py")
        stack.extend(info["references"])
    return sorted(seen)


def analyze(lock, feature):
    """-> (provides_entries, provides_dirs, requires) for one feature."""
    kind, spec = feature["kind"], feature["spec"]
    entries, dirs, requires = set(), set(), []
    if kind == "ensure_dirs_exist":
        p = norm(spec["path"])
        dirs.update(parents_of(p) + [p] if p else [])
    elif kind == "nix_packages":
        dirs.update(["nix", "nix/store"])
        for p in feature["closure"]:
            entries.add("nix/store/" + posixpath.basename(p))
        # Forest link names are only known at materialize time (they come
        # from NAR contents); collisions there are still hard errors.
        for f in spec["forest"]:
            fp = norm(f)
            dirs.update(parents_of(fp) + [fp])
    elif kind == "install":
        dst = norm(spec["dst"])
        entries.add(dst)
        requires.append(("dir", posixpath.dirname(dst)))
    elif kind == "symlink":
        link = norm(spec["link"])
        entries.add(link)
        requires.append(("dir", posixpath.dirname(link)))
        target = spec["target"]
        if target.startswith("/"):
            requires.append(("exists", norm(target)))
        else:
            requires.append(
                ("exists", norm(posixpath.join(posixpath.dirname(link), target))))
    elif kind == "remove":
        p = norm(spec["path"])
        if spec.get("must_exist", True):
            requires.append(("exists", p))
    else:
        raise SystemExit(f"error: unknown feature kind '{kind}'")
    return entries, dirs, requires


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lock", required=True)
    ap.add_argument("--parent-facts")
    ap.add_argument("--feature", action="append", default=[])
    ap.add_argument("--out", required=True)
    args = ap.parse_args()

    with open(args.lock) as f:
        lock = json.load(f)

    parent_paths = {}
    if args.parent_facts:
        with open(args.parent_facts) as f:
            parent_paths = json.load(f)

    features = []
    for i, path in enumerate(args.feature):
        with open(path) as f:
            feature = json.load(f)
        feature["id"] = i
        if feature["kind"] == "nix_packages":
            feature["roots"] = resolve_roots(lock, feature)
            feature["closure"] = closure_of(lock, feature["roots"])
        features.append(feature)

    # Conflict detection: at most one feature may provide an Entry, and it
    # must not collide with parent content unless a remove tombstones it.
    removed = {
        norm(f["spec"]["path"]) for f in features if f["kind"] == "remove"
    }
    provided_by = {}
    analyzed = []
    for feature in features:
        entries, dirs, requires = analyze(lock, feature)
        analyzed.append((feature, entries, dirs, requires))
        for e in entries:
            if e in provided_by:
                raise SystemExit(
                    f"error: path conflict on '{e}': provided by both "
                    f"{provided_by[e]} and {feature['label']}")
            provided_by[e] = feature["label"]
            if e in parent_paths and e not in removed and \
                    feature["kind"] != "nix_packages":
                raise SystemExit(
                    f"error: '{e}' (from {feature['label']}) already exists "
                    f"in the parent layer; feature.remove it first")

    # Greedy toposort within the fixed class order.
    satisfied_entries = set(parent_paths)
    satisfied_dirs = {""} | {
        p for p, info in parent_paths.items() if info.get("type") == "dir"
    }

    def is_satisfied(req):
        kind, path = req
        if kind == "dir":
            return path == "" or path in satisfied_dirs
        return path in satisfied_entries or path in satisfied_dirs

    remaining = sorted(analyzed, key=lambda a: (CLASS_ORDER[a[0]["kind"]], a[0]["id"]))
    order = []
    while remaining:
        for i, (feature, entries, dirs, requires) in enumerate(remaining):
            if all(is_satisfied(r) for r in requires):
                order.append(feature)
                satisfied_entries.update(entries)
                satisfied_dirs.update(dirs)
                for e in entries:
                    satisfied_dirs.update(parents_of(e))
                del remaining[i]
                break
        else:
            problems = []
            for feature, _, _, requires in remaining:
                missing = [r for r in requires if not is_satisfied(r)]
                problems.append(f"  {feature['label']}: missing " + ", ".join(
                    f"{k}('{p}')" for k, p in missing))
            raise SystemExit(
                "error: unsatisfiable feature requirements:\n" + "\n".join(problems))

    plan = {"features": order}
    with open(args.out, "w") as f:
        json.dump(plan, f, indent=2, sort_keys=True)
        f.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
