# dirlir — antlir2-shaped directory layers from Nix, as hermetic Buck2 toolchains

dirlir transplants the architecture of [antlir2](https://github.com/facebook/antlir)
(Meta's buck2-integrated, deterministic image builder) onto **Nix + Buck2**,
producing plain **directory trees** instead of container images. The trees
serve as fully hermetic toolchains (gcc, ghc) and native deps (glibc,
openssl) for buck2 builds whose actions are **enclosed by default** and run
identically on the local machine and on remote-execution workers that have
**neither nix nor /nix/store — nor any other host tooling**.

## Concept mapping

| antlir2 | dirlir v2 |
|---|---|
| flavor (pinned package universe) | `flake.lock` |
| snapshot RPM repos + versionlock | https://nixos.snix.store + committed `nix/lock.json`/`lock.bzl`, every narinfo **ed25519-verified** at resolve time |
| `image.layer` | `nix_closure` (featureless, zero-copy) / `dir_layer` (features) |
| `feature.*` | `feature.nix_packages / install / symlink / ensure_dirs_exist / remove` |
| depgraph (validate → toposort, pre-build) | same logic, first phase of the single `dirlir_layer` action |
| compiler isolation (userns, RE-able) | `dirlir-shim` provision/enclose (see below) |
| btrfs local / cad-stack RE | buck2 tree artifacts; per-store-path artifacts + `symlinked_dir` composition |
| plan/compile split for packages | resolve (signed narinfo walk, committed) → buck2-NATIVE downloads |

## Architecture

```
tools/resolve.sh                     one nix evaluation; narinfo closure walk over snix;
  → nix/lock.json + nix/lock.bzl     every signature verified against pinned trusted keys

root//nix:<store-path-basename>      one target per locked path (buck2 uquery = supply chain):
  download_file(url, sha256=NarHash) buck2-native: snix serves UNCOMPRESSED NARs, so the
                                     file hash IS the NarHash — verification needs no tool
  nar-unpack (static C, exec_dep)    structural validation only; symlinks kept VERBATIM

nix_closure(packages)                store = symlinked_dir of per-path artifacts (zero-copy);
                                     facts written at ANALYSIS time from the lock

dir_layer(features, parent_layer)    ONE enclosed action: dirlir-shim + python (from the
                                     buildtools closure) runs layer.py: validate → toposort →
                                     assemble → slim facts

toolchains (cxx, haskell)            every tool = shim_run(/nix/store/<base>/bin/gcc, ...);
                                     no forests — content addressed by absolute store path
```

Every action's inputs are artifacts; no action needs a host interpreter,
host tools, the lockfile, or the network. The ONLY local_only action class
is the bootstrap: `nix_flake_tool` builds the two static tools
(`dirlir-shim`, `nar-unpack`) from this repo's flake via a local
`nix build` (the buck2.nix pattern) — leaf exec_deps, CAS-cached, never
run on RE workers, always in sync with the flake.

## dirlir-shim: provision / enclose / exec

- **provision** (additive): `--store DIR` merges DIR's entries into
  `/nix/store` (entries resolved with realpath first, so symlinked_dir
  compositions work). Masking the host store is the same operation.
- **enclose** (subtractive): `--enclose` pivots into a minimal root —
  provisioned store, exec root at its own path, fresh /tmp (mounted before
  the exec-root bind: RE work dirs live under /tmp), /dev subset, fresh
  /proc (new PID namespace; mounted pre-pivot per the kernel's
  visible-proc rule), minimal /etc. `pivot_root`, never chroot (chrooted
  processes cannot create nested user namespaces — dep-file processing
  nests shims). `--map-user/--map-group` re-map identity (an RE worker
  that looks like root privilege-drops actions to an unmapped uid).
- **exec**: `-- PROG ARGS...`; `@argfile` (shim args only — the command's
  own argfiles pass through); `--salt` (digest carrier);
  `--fail-hint STR` — the failure trailer's escape-hatch wording is
  INJECTED by the caller, never hardcoded.

## The isolation knob

`[dirlir] isolation = off | audit | enforce` (default enforce), read at
load time and placed in `cmd_args`, so **each mode has distinct action
digests** — an `off` build can never poison an `enforce` cache. Escape
hatch: `buck2 build -c dirlir.isolation=off <target>`. `audit` = provision
only + an strace summary of successful opens outside the allowed roots
(over-approximation with a small ignore-list; enforce is ground truth).
On failure under enforce, one stderr trailer names the visible roots and
the exact `-c` flags to bypass or compare.

## dirlir-run (rung 0)

`tools/dirlir-run -- buck2 build //...` wraps an existing build — daemon
included — in a namespace where /nix/store is masked to the build
infrastructure (buck2, nix+git for the sanctioned bootstrap, coreutils,
the flake's own sources). Guarantees: refuses a pre-existing outside
daemon (`--kill-daemon` to proceed; warm buck-out survives, only the
daemon restarts); verifies post-run that the daemon shared the mount
namespace (the banner IS that check); runs under a PID namespace and
removes the daemon record, so nothing enclosed outlives the wrapper.
`--audit` straces arbitrary commands instead. `DIRLIR_ISOLATION=off`
bypasses (env is fine here — dirlir-run has no cache to poison).

## User journey

- **R0** — zero repo changes: `nix develop -c tools/dirlir-run -- buck2 build //...`
  (first hermeticity signal; `--audit` for the observability variant).
- **R1** — adopt the toolchains; `[dirlir] isolation = enforce` is the
  default. A leak fails loudly with the trailer naming the off-switch.
- **R2** — wrap your own rules: `load("@root//dirlir:shim.bzl", "shim_run")`.
- R3+ (future): prelude-wide per-action manifests, localhost-RE
  per-action sandboxing, upstream integration. Users never see drivers or
  the provision/enclose taxonomy: the surface is one command and one knob.

## Buck2 from source, patch-ready

`nix/buck2/` builds buck2 at an exact pinned rev (initially the version v1
was characterized against) with the rev's nightly toolchain and a
committed Cargo.lock (upstream ships none). The bundled prelude is
embedded from the same tree by `build.rs` — the {buck2, prelude} pair is
matched by construction. **Carried patches are the primary remedy for RE
client misbehavior**: `patches/0001-find-missing-cache-upload-invalidation.patch`
fixes the OSS FindMissingBlobs cache never learning about this client's
own uploads (a stale Missing entry + OSS hard-failing soft errors poisoned
any remote action consuming content byte-identical to a previously
uploaded blob — chained layers, subpath excisions). With it, **every
dirlir action runs remotely**: `local dirlir actions: 0` in the RE demo.

## Guarantees and their tests (CI: ci.yml per push, nightly.yml cold+full, liveness.yml weekly)

| Guarantee | Test |
|---|---|
| NAR parser rejects malformed input (traversal, truncation, bombs) | `tests/unit/run-nar-tests.sh` |
| Signatures gate the lock; tampered fingerprints rejected | `tests/unit/test_ed25519.py`, resolve aborts |
| Tampered locked hash ⇒ build fails, no artifact | `tests/tamper.sh` |
| Bit-identical double builds; cross-machine identity vs goldens | `tests/determinism.sh` (type-aware manifest: symlinks literal) |
| Network only in native downloads (and bootstrap) | `tests/offline.sh` (salt re-runs everything in a no-net namespace) |
| Enclosure masks the host; failure UX; per-mode digests | `tests/enclosure.sh` (trailer TEXT asserted; re-execution proven) |
| Compile touches nothing outside the minimal roots | `tests/isolate-audit.sh` (strace) |
| Depgraph rejects conflicts/dangling requirements pre-build | `tests/depgraph-errors.sh` |
| Full rebuild inside a masked namespace | `tests/hermetic.sh` (via dirlir-run) |
| RE on a store-less worker; symlinks round-trip bit-exact FIRST | `tests/re-demo.sh` (NativeLink) |
| Second backend (variant C conditional until green) | `tests/re-buildbarn.sh` (nightly, allow-failure lane; hard round-trip gate) |
| Locked paths stay fetchable; narinfos immutable | `tests/liveness.py` |

## Known limitations

- Variant C (zero-copy closures, verbatim absolute symlinks) is proven on
  local + NativeLink; the Buildbarn leg keeps it CONDITIONAL (REv2 makes
  absolute-symlink handling per-server). Fallback (variant B: per-closure
  unpack with relative rewriting) is a bounded swap: composition action +
  an unpack manifest mode; toolchain addressing unchanged.
- Raw layer traversal without the shim dangles absolute store symlinks by
  design; every consumer is shim-mediated.
- RE workers must allow unprivileged user namespaces (nested).
- snix retention is externally owned: the weekly liveness sweep alarms;
  `caches[]` re-points; a raw-NAR mirror (`nix store dump-path`) is the
  documented plan-B (cache.nixos.org itself serves no uncompressed NARs).
