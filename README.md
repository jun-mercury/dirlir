# dirlir

antlir2's architecture (features → depgraph → layers, resolve/materialize
split, userns isolation) transplanted onto **Nix + Buck2**, producing plain
**directory trees** instead of container images. The trees serve as fully
hermetic toolchains (gcc, ghc) and native deps (glibc, openssl) for buck2
builds that work with remote execution — on workers that have neither nix
nor `/nix/store`.

See [DESIGN.md](DESIGN.md) for the full design and the antlir2 mapping,
and [PLAN.md](PLAN.md) for the original implementation plan.

## Quickstart

```sh
nix develop                                  # buck2, python 3.14, jq

buck2 build root//...                        # everything
buck2 run root//examples/tls_demo:main       # gcc + openssl, hermetically
buck2 build root//examples/hello_hs:main     # ghc

# refresh / extend the package lockfile (the antlir2 "versionlock" step)
python3 nix/resolve.py gcc binutils openssl python3 python314 hello \
    coreutils bash ghc '.#nix-store-shim'
```

## Proofs

```sh
./tests/depgraph-errors.sh   # plan-time validation failures (antlir2 depgraph analog)
./tests/hermetic.sh          # full rebuild with the host /nix/store masked to 33 infra paths
./tests/re-demo.sh           # NativeLink remote execution; the worker has NO /nix at all
```

## Layout

- `nix/resolve.py`, `nix/lock.json`, `nix/lock.bzl` — evaluation-free lockfile
- `nix/shim/shim.c` — static userns shim (bind layer stores at `/nix/store`)
- `nix/cache/` — committed binary cache for repo-built derivations (the shim)
- `dirlir/` — `dir_layer` + `feature.*` rules, depgraph, NAR materializer
- `toolchains/` — hermetic cxx/haskell/python-bootstrap toolchains from layers
- `layers/` — the layer definitions (gcc, ghc, openssl, python, ...)
- `examples/`, `tests/` — demos and proof harnesses
