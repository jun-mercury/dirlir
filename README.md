# dirlir

antlir2's architecture (features → depgraph → layers, resolve/materialize
split, userns isolation) transplanted onto **Nix + Buck2**, producing plain
**directory trees** instead of container images. Nix packages become
buck2-native artifacts (downloads hash-verified by buck2 itself against
signed, locked NarHashes); toolchains (gcc, ghc) and native deps (openssl)
run **enclosed in minimal namespaces by default**, identically on the local
machine and on remote-execution workers that have no nix, no store, and no
host tooling at all.

See [DESIGN.md](DESIGN.md) for the architecture and the guarantee→test
matrix, [PLAN-v2.md](PLAN-v2.md) for the v2 plan and ADRs.

## Quickstart

```sh
nix develop                                  # buck2 (from source, patch-ready), python3, jq

buck2 build root//...                        # everything, enclosed by default
buck2 run root//examples/tls_demo:main       # gcc + openssl, hermetically
buck2 build -c dirlir.isolation=off <t>      # per-invocation escape hatch
buck2 build -c dirlir.isolation=audit <t>    # observe instead of deny

# rung 0 — wrap any build (daemon included) in a store-masked namespace:
tools/dirlir-run -- buck2 build root//...
tools/dirlir-run --audit -- buck2 build root//...

# refresh / extend the package lock (signed narinfo walk over snix):
tools/resolve.sh
```

## Proofs (all in CI: ci.yml per push, nightly cold+full, weekly liveness)

```sh
./tests/hermetic.sh          # full rebuild, host store masked to build infra
./tests/re-demo.sh           # NativeLink RE: store-less worker, symlink round-trip first,
                             #   every dirlir action remote (local count: 0)
./tests/enclosure.sh         # mask semantics, failure-UX trailer, per-mode digests
./tests/determinism.sh       # double build + cross-machine golden manifests
./tests/offline.sh           # everything re-runs without network (downloads excepted)
./tests/tamper.sh            # flipped locked hash -> rejected, no artifact
./tests/isolate-audit.sh     # strace: compiles touch nothing outside minimal roots
./tests/depgraph-errors.sh   # plan-time validation failures
```

## Layout

- `nix/resolve.py` + `nix/ed25519.py` → `nix/lock.{json,bzl}` — signed, evaluation-free lock
- `nix/shim/` — `dirlir-shim` (provision/enclose/exec) and `nar-unpack`, static musl
- `nix/buck2/` — buck2 from source at a pinned rev, carried patches
- `dirlir/` — rules: per-path artifacts, `nix_closure`, `dir_layer`, `shim_run`, bootstrap
- `toolchains/`, `layers/` — hermetic cxx/haskell toolchains and the layer definitions
- `tools/dirlir-run` — rung-0 wrapper; `tests/` — the guarantee suite
