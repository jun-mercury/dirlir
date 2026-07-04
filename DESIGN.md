# dirlir — antlir2-shaped directory layers from Nix, as hermetic Buck2 toolchains

dirlir transplants the architecture of [antlir2](https://github.com/facebook/antlir)
(Meta's buck2-integrated, deterministic image builder — see Vinnie Magro's
All Systems Go 2023 talk *"antlir2: Deterministic image builds with buck2"*)
onto **Nix + Buck2**, with one deliberate change of product: instead of
container images, it builds **plain directory trees**. Those trees are
buck2 tree artifacts — natively content-addressed, CAS-uploadable, and
therefore remote-execution compatible — and they serve as fully hermetic
toolchains (gcc, ghc) and native dependencies (glibc, openssl) for buck2
builds on workers that have **neither nix nor /nix/store**.

## Concept mapping

| antlir2 | dirlir |
|---|---|
| flavor (pinned OS/package universe) | pinned nixpkgs via `flake.lock` |
| snapshot RPM repos + versionlock JSON | cache.nixos.org + committed `nix/lock.json` (store paths, NarHashes, nar URLs) + committed `nix/cache/` file cache for repo-built derivations |
| `image.layer` | `dir_layer` rule → output-directory tree artifact |
| `feature.*` (install, rpms_install, symlink, remove, ...) | `feature.nix_packages`, `feature.install`, `feature.ensure_dirs_exist`, `feature.symlink`, `feature.remove` |
| depgraph (Rust+SQLite; validates provides/requires, toposorts before building) | `dirlir/tools/depgraph.py` plan action → `plan.json`; facts flow parent → child |
| compiler (userns-isolated, not nspawn, so it can run on RE) | `dirlir/tools/materialize.py` (NAR fetch/verify/unpack + feature application) |
| btrfs subvolume (local-only) / cad-stack (RE) | buck2 tree artifact; parent chaining via `cp -a --reflink=auto` |
| plan/compile split (dnf resolve → transaction → install exactly that) | resolve (nix eval + narinfo walk, run rarely, committed) → materialize (pure downloads by locked hash) |
| runtime isolation | static userns **shim** (`nix/shim/shim.c`) bind-mounting layer stores at `/nix/store` |
| packaging stage (tar/oci/ext4) | none — the directory is the product |

## Architecture

### 1. Resolve — `nix/resolve.py` (the versionlock analog)

Run occasionally (`nix develop -c python3 nix/resolve.py gcc openssl ...`),
commit the outputs. It does the only nix evaluation in the whole system:

- evaluates requested attrs against the flake-pinned nixpkgs → output store paths;
- walks the closure **via `.narinfo` fetches from cache.nixos.org** — no
  local builds; the walk doubles as the guarantee that every path is
  fetchable at materialize time (resolve fails fast, antlir2-style);
- flake-local packages (the shim) are built and pushed to the committed
  repo-local binary cache `nix/cache/` (`nix copy --to file://...`);
- emits `nix/lock.json` (packages, and a `paths` table with narHash /
  narSize / references / nar URL per store path) and `nix/lock.bzl`
  (load-time mirror: the pinned action interpreter `PYTHON3`, the shim
  store path, per-package output paths — Starlark cannot read JSON at
  load time).

Closures are not stored per package; they are derived by walking the
lockfile's `references` graph at plan time.

### 2. Layers — `dirlir/defs.bzl` (the image.layer analog)

`dir_layer(name, features=[...], parent_layer=...)` runs **two actions**,
preserving antlir2's plan/compile split:

1. **plan** (`dirlir_plan`): `depgraph.py` validates provides/requires
   (Entry/Dir items per feature, validated against parent facts + the
   lockfile), detects path conflicts naming both offending features,
   toposorts within a fixed class order (`ensure_dirs_exist` →
   `nix_packages` → `remove` → `install`/`symlink` — remove-before-install
   enables antlir2-style replace-a-parent-file), resolves nix closures →
   `plan.json`. All errors fire here, before any materialization.
2. **materialize** (`dirlir_materialize`): copies the parent tree
   (`cp -a --reflink=auto`), fetches NARs, applies features, emits the
   tree + `facts.json` (a full walk consumed by child layers' plans).

Both are `local_only = True` (they need network and the host-pinned
python). **Everything consuming a layer sees only tree artifacts + the
static shim and is RE-able** — the same posture as antlir2's local-only
btrfs builds with RE-able consumers.

### 3. Materialization — pure NAR download (no nix at build time)

`materialize.py` + `nar.py` (python stdlib only; python 3.14 for stdlib
zstd):

- download the compressed NAR from the locked cache URL;
- unpack with a ~100-line streaming NAR parser;
- **verify the NarHash of the uncompressed stream against the lockfile**,
  capped at the locked NarSize (decompression-bomb guard);
- **rewrite every absolute `/nix/store/...` symlink target to relative**
  (targets always stay within the tree) so the artifact is self-contained
  for CAS upload — file *contents* (shebangs, PT_INTERP, RPATH) are never
  touched; the runtime bind mount resolves them;
- build buildEnv-style relative-symlink forests (`bin/`, `lib/`,
  `include/`) at the layer root; collisions are hard errors.

**Discovery: FileHash cannot be locked.** cache.nixos.org re-compresses
its zstd NARs server-side over time — the narinfo FileHash observed at
resolve time does not match later downloads. The NarHash of the
uncompressed stream (which is also what nix signatures cover) is the
stable authority; the download cache (`~/.cache/dirlir/nars`) is keyed by
it, and a bad cached file is refetched once.

### 4. The shim — `nix/shim/shim.c` (static musl, pkgsStatic)

`nix-store-shim [--store DIR]... [--map-user N] [--map-group N] -- PROG ARGS...`

- `unshare(CLONE_NEWUSER|CLONE_NEWNS)`, uid/gid mapped to the invoking
  user (so outputs keep real ownership), `MS_REC|MS_PRIVATE` on `/`.
- **Fast path** (host has `/nix/store`): bind the store dir over it —
  mounting and masking the host store are the same operation. Multiple
  `--store` dirs are merged via tmpfs + per-entry binds.
- **Fallback** (bare RE worker, no `/nix`; it cannot be created inside a
  userns because `/` belongs to unmapped root): rebuild the root in a
  tmpfs — bind every top-level entry of `/`, add `nix/store` — then
  **`pivot_root`, not `chroot`**: the kernel refuses
  `unshare(CLONE_NEWUSER)` from chrooted processes, which would break
  nested shims (buck2's dep-file processing wraps the compile in a
  python shim that then spawns the gcc shim).
- `--map-user/--map-group` turn the shim into a general userns exec
  wrapper (used to run the RE worker itself; see below).

Tool invocations inherit the namespace, so gcc's cc1/as/ld and ghc's
subprocesses all resolve their hardcoded `/nix/store/...` interpreter,
RPATH, and shebang paths through the mount. Nothing is ever rewritten
inside file contents, so nix's hash self-references stay intact.

The shim enters the build graph through `nix_store_import`, which
materializes it from the committed `nix/cache/` via the same NAR pipeline
— machines never need to build it.

### 5. Toolchains — `toolchains/nix_cxx.bzl`, `toolchains/nix_haskell.bzl`

Modeled on the prelude's `_cxx_toolchain_from_cxx_tools_info`, with every
tool a `RunInfo(shim --store <layer>/nix/store -- <layer>/bin/gcc)`; the
layer directory rides along as a cmd_args input, so RE workers receive it
automatically. Deliberate differences from the prelude version:

- no `-fuse-ld=lld` injection (gnu ld from the layer);
- binutils (`nm`, `objcopy`, `strip`, ...) come from the layer, not host
  PATH;
- links/archives are **not** forced local — all inputs are tracked, so
  they are RE-able.

The toolchain layer is just nixpkgs' wrapped `gcc`: the cc-wrapper bakes
in glibc headers/crt/dynamic-linker AND forwards all bintools programs
into its `bin/`, so adding `binutils` separately only creates forest
collisions. `python_bootstrap` (used by prelude-internal helper scripts:
dep-file processing, compilation databases) is the nix python layer via
the shim. openssl is consumed as `prebuilt_cxx_library` via `dir_subpath`
excisions (dereferencing copies made with the **coreutils layer's own cp
through the shim** — RE workers have no host tools), with an absolute
store RPATH that the shim's mounted store satisfies at run time.

## Remote execution

Proven with a local NativeLink (static musl release binary) running CAS +
scheduler + worker, where the **worker runs inside a namespace with `/nix`
masked read-only** — a genuinely store-less worker. Compile and link
actions execute remotely (through the shim's pivot_root fallback); all
`dirlir_*` actions (plan/materialize/import/subpath) stay local by
design. dir_subpath would work remotely too, but this buck2's OSS RE
client caches FindMissingBlobs responses without invalidating after its
own uploads, and OSS buck2 hard-fails every soft error — so remote
subpath outputs whose blobs buck2 uploaded earlier (as layer contents)
poison later remote consumers; keeping it local sidesteps the bug.

Configuration notes (all in `tests/re-demo.sh` / `tests/re-demo/`):

- buck2 builds its RE client from the **daemon startup** buckconfig —
  `.buckconfig.local` (written for the demo's duration), not
  `--config-file`;
- `digest_algorithms = SHA256` (NativeLink speaks SHA256, buck2's default
  is SHA1);
- buck2's isolation-dir state must be reset together with the CAS: with
  deferred materialization, daemon state that remembers artifacts as
  remotely-available outlives a wiped CAS, and buck2 cannot re-upload
  inputs it never downloaded ("missing in the CAS but expected to
  exist"). (Buck2's OSS RE client also records ttl=0 on execute-response
  outputs — the eager `materializations = all` escape hatch named in its
  own error message no longer exists in this buck2 version; a clean
  CAS+state pairing avoids the whole class.);
- a custom execution platform (`platforms/`) with `remote_enabled = True`
  and `use_limited_hybrid = True` (the prelude default platform hardcodes
  remote off); local_only actions still run locally;
- **worker uid pitfall**: a worker that appears to run as root (uid 0 in
  a root-mapped namespace) drops spawned actions to `nobody` — an
  *unmapped* uid, and unmapped uids cannot create user namespaces, so the
  shim EPERMs. The demo therefore starts the worker via the shim's
  `--map-user` remap so it sees a normal non-zero uid. (With `/nix`
  masked, no host binary — `unshare` included — exists, so only the
  static shim can do this remap.)

Deployment requirement for real RE fleets: workers must allow unprivileged
user namespaces. Fallback for hardened fleets: pre-populate a `/nix/store`
volume in the worker image and give the shim an `--if-missing`-style
passthrough mode (not implemented).

## Determinism model

- `flake.lock` pins the package universe (the "flavor").
- `nix/lock.json` pins every store path and its NarHash; buck2 actions
  never run nix evaluation, so action cache keys are exactly right:
  a resolve re-run that changes nothing is byte-identical (`--check`),
  and one that changes a package re-runs precisely the affected layers.
- NAR unpacking is byte-exact: `nix hash path` over an unpacked store
  path equals the locked NarHash (verified in tests).
- Materialized trees contain no absolute symlinks and no store-path
  rewrites — bit-identical regardless of host.

## Verification

- `nix develop -c buck2 build root//...` — everything builds.
- `nix develop -c ./tests/depgraph-errors.sh` — plan-time failures:
  path conflict / dangling symlink / missing parent dir, each naming the
  offending feature targets.
- `nix develop -c ./tests/hermetic.sh` — rebuilds the C examples from a
  fresh isolation dir inside a namespace where `/nix/store` is a tmpfs
  holding only the build-infrastructure closures (buck2, action python,
  coreutils/bash/awk/grep/sed, CA certs — 33 paths vs 118k on the host);
  then runs the binaries under the shim with the gcc + openssl layer
  stores merged. Any host-store dependence in an action ⇒ ENOENT ⇒ red.
- `nix develop -c ./tests/re-demo.sh` — the NativeLink demo above.

## Known limitations / future work

- **Forest planning**: forest link names are only known at materialize
  time (planning would need package listings in the lockfile), so forest
  collisions are materialize-time, not plan-time, errors.
- **Materialize on RE**: `materialize.py` is stdlib python + network; with
  a python layer bootstrap (or a static rust port) and network-enabled
  workers, layer materialization itself could run remotely.
- **NAR download cache** (`~/.cache/dirlir/nars`) grows unboundedly; no GC.
- **No users/groups/genrule features** (antlir2 has them; directories used
  as toolchains don't need them).
- **Layer size**: gcc ≈ 0.4 GB, ghc ≈ 2.5 GB per materialized copy in
  buck-out (reflink-cheap on CoW filesystems) and one-time in CAS
  (file-level dedup). `feature.remove` of `share/{doc,man,info,locale}`
  is the mitigation; parent-less toolchain layers avoid copies.
- **cache.nixos.org GC**: nixpkgs-unstable paths are effectively permanent,
  but a self-hosted cache (or the repo file cache) is the durable answer.
