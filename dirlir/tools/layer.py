"""dirlir layer assembly: validate -> toposort -> assemble -> facts.

One action per layer (PLAN-v2 M6), executed through dirlir-shim with the
buildtools closure provisioned — hermetic and RE-able: inputs are feature
JSONs, a store-path map (per-path artifacts), optional parent tree/facts,
and install sources. No network, no lockfile, no host paths.

Validation (the antlir2 depgraph) runs first and fails before any assembly:
Entry/Dir provides/requires per feature, path conflicts naming both
features, greedy toposort within the fixed class order
    ensure_dirs_exist -> nix_packages -> remove -> install/symlink
(remove-before-install enables replacing a parent file).

Store paths are copied from artifacts verbatim (variant C: symlinks stay
absolute; consumers view layers through shim mounts). Facts are SLIM:
store paths are atomic {"type": "store_path"} entries — layers treat them
as indivisible.
"""

import argparse
import json
import os
import posixpath
import shutil
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


def analyze(feature):
    """-> (provides_entries, provides_dirs, requires) for one feature."""
    kind, spec = feature["kind"], feature["spec"]
    entries, dirs, requires = set(), set(), []
    if kind == "ensure_dirs_exist":
        p = norm(spec["path"])
        dirs.update(parents_of(p) + [p] if p else [])
    elif kind == "nix_packages":
        dirs.update(["nix", "nix/store"])
        for p in spec["closure"]:
            entries.add("nix/store/" + posixpath.basename(p))
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


def plan(features, parent_paths):
    """Validate + toposort; returns features in execution order."""
    removed = {
        norm(f["spec"]["path"]) for f in features if f["kind"] == "remove"
    }
    provided_by = {}
    analyzed = []
    for feature in features:
        entries, dirs, requires = analyze(feature)
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

    satisfied_entries = set(parent_paths)
    satisfied_dirs = {""} | {
        p for p, info in parent_paths.items() if info.get("type") == "dir"
    }

    def is_satisfied(req):
        kind, path = req
        if kind == "dir":
            return path == "" or path in satisfied_dirs
        return path in satisfied_entries or path in satisfied_dirs

    remaining = sorted(
        analyzed, key=lambda a: (CLASS_ORDER[a[0]["kind"]], a[0]["id"]))
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
    return order


def copy_parent(parent, out):
    shutil.copytree(parent, out, symlinks=True)
    for dirpath, dirnames, _ in os.walk(out):
        for d in [dirpath] + [os.path.join(dirpath, x) for x in dirnames]:
            if not os.path.islink(d):
                os.chmod(d, os.stat(d).st_mode | 0o200)


def do_nix_packages(feature, store_map, out):
    out_store = os.path.join(out, "nix/store")
    os.makedirs(out_store, exist_ok=True)
    for store_path in feature["spec"]["closure"]:
        base = os.path.basename(store_path)
        dest = os.path.join(out_store, base)
        if os.path.lexists(dest):
            continue  # already present via parent
        src = store_map.get(store_path)
        if src is None:
            raise SystemExit(
                f"error: no artifact provided for {store_path} "
                f"(from {feature['label']})")
        # Verbatim copy: symlink targets stay absolute (variant C). Store
        # entries may be single files (e.g. source tarballs in closures).
        if os.path.isdir(src) and not os.path.islink(src):
            shutil.copytree(src, dest, symlinks=True)
        else:
            shutil.copy2(src, dest, follow_symlinks=False)


def do_install(feature, srcs, out):
    src = srcs[f"{feature['id']}:src"]
    dst = os.path.join(out, feature["spec"]["dst"].lstrip("/"))
    if os.path.isdir(src):
        shutil.copytree(src, dst, symlinks=True)
    else:
        shutil.copy2(src, dst)
    mode = feature["spec"].get("mode")
    if mode is not None:
        os.chmod(dst, mode)


def do_symlink(feature, out):
    link = feature["spec"]["link"].lstrip("/")
    target = feature["spec"]["target"]
    if target.startswith("/"):
        target = posixpath.relpath(target.lstrip("/"), posixpath.dirname(link))
    os.symlink(target, os.path.join(out, link))


def do_remove(feature, out):
    path = os.path.join(out, feature["spec"]["path"].lstrip("/"))
    if not os.path.lexists(path):
        if feature["spec"].get("must_exist", True):
            raise SystemExit(
                f"error: remove of non-existent '{feature['spec']['path']}' "
                f"(from {feature['label']})")
        return
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.unlink(path)


def emit_facts(out, facts_path):
    """Slim facts: store paths are atomic; everything else is walked."""
    facts = {}
    store = os.path.join(out, "nix/store")
    for dirpath, dirnames, filenames in os.walk(out):
        if os.path.realpath(dirpath) == os.path.realpath(store):
            for name in list(dirnames) + filenames:
                facts[f"nix/store/{name}"] = {"type": "store_path"}
            dirnames[:] = []  # do not descend into store paths
            continue
        for name in dirnames + filenames:
            full = os.path.join(dirpath, name)
            rel = os.path.relpath(full, out)
            if os.path.islink(full):
                facts[rel] = {"type": "symlink", "target": os.readlink(full)}
            elif os.path.isdir(full):
                facts[rel] = {"type": "dir"}
            else:
                facts[rel] = {
                    "type": "file",
                    "mode": os.stat(full).st_mode & 0o7777,
                }
    with open(facts_path, "w") as f:
        json.dump(facts, f, indent=1, sort_keys=True)
        f.write("\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--feature", action="append", default=[])
    ap.add_argument("--store-map", required=True)
    ap.add_argument("--srcs", required=True)
    ap.add_argument("--parent")
    ap.add_argument("--parent-facts")
    ap.add_argument("--out", required=True)
    ap.add_argument("--facts-out", required=True)
    args = ap.parse_args()

    features = []
    for i, path in enumerate(args.feature):
        with open(path) as f:
            feature = json.load(f)
        feature["id"] = i
        features.append(feature)
    with open(args.store_map) as f:
        store_map = json.load(f)
    with open(args.srcs) as f:
        srcs = json.load(f)
    parent_paths = {}
    if args.parent_facts:
        with open(args.parent_facts) as f:
            parent_paths = json.load(f)

    order = plan(features, parent_paths)

    if args.parent:
        copy_parent(args.parent, args.out)
    else:
        os.makedirs(args.out)

    for feature in order:
        kind = feature["kind"]
        if kind == "ensure_dirs_exist":
            os.makedirs(
                os.path.join(args.out, feature["spec"]["path"].lstrip("/")),
                exist_ok=True)
        elif kind == "nix_packages":
            do_nix_packages(feature, store_map, args.out)
        elif kind == "install":
            do_install(feature, srcs, args.out)
        elif kind == "symlink":
            do_symlink(feature, args.out)
        elif kind == "remove":
            do_remove(feature, args.out)

    emit_facts(args.out, args.facts_out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
