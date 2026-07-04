# dirlir v2 — parsimony, deep hermeticity, RE-able everything, guarantee-tracking CI

## Context

dirlir v1 works end-to-end (repo DESIGN.md; proofs: hermetic.sh, re-demo.sh, depgraph-errors.sh).
v2 hardens it into a production-grade building block with **parsimony as the top priority** — it
deletes more than it adds. Requirements: (1) remove the pinned host-store interpreter
(`lock.bzl PYTHON3`); (2) make planning/materialization hermetic and **RE-able**; (3) switch NAR
fetching to **https://nixos.snix.store/**; (4) adversarial hermeticity validation + a second RE
backend; (5) GitHub Actions tracking the guarantees. A steering addendum additionally mandates:
patched-buck2 plumbing, a rung-0 `dirlir-run` wrapper, a provision/enclose shim taxonomy, and a
first-class adoption DX (user journey, one knob, escape hatches, self-explanatory failures) —
while staying compatible with a v3 direction (drivers D1–D3) that v2 must not build or foreclose.
On approval: committed as **PLAN-v2.md** (M0); every milestone ends with commit+push. Written for
a generic OSS buck2 repository; no organization-specific assumptions.

## Empirical findings that shape v2

- **snix.store** (verified live): narinfo signed with `cache.nixos.org-1` (ed25519); `URL` points
  to an **uncompressed** NAR (castore URL, only discoverable via narinfo); `sha256(body) ==
  NarHash`, `Content-Length == NarSize`. cache.nixos.org serves no uncompressed NARs.
  ⇒ **sha256 of the downloaded file IS the locked NarHash** — verification becomes buck2-native.
- **The gcc layer contains 61 cross-store-path symlinks** — per-path artifacts inherently contain
  symlinks escaping their artifact root. The one open platform question (spike M1).
- narinfo signature fingerprint: `1;<storePath>;<NarHash sha256:base32>;<NarSize>;<comma refs>`;
  pure-python ed25519 verify ≈100 vendored lines, ~10ms/sig (resolve-time only).
- Nix's own sandbox mount set (known-good minimal root for nixpkgs compilers): fresh /proc
  (CLONE_NEWPID + fork), /dev subset (null, zero, urandom, random, tty, shm tmpfs, fd + stdio
  symlinks), fresh tmpfs /tmp, minimal /etc, build dir — nothing else.
- OSS buck2 hard-fails all soft errors; its RE client caches FindMissingBlobs without post-upload
  invalidation (v1 finding). v2 remedy inverted per addendum: see ADR-4.

## Architecture v2 — the native pipeline

```
lock.json/lock.bzl (resolve-time, signed narinfo, committed)
  └─ per-store-path targets  root//nix:<basename>        [macro from lock.bzl PATHS]
       action 1: ctx.actions.download_file(url, sha256=narHash, size_bytes=narSize)
                 — buck2-NATIVE: hash-verified by buck2, CAS-cached, RE-compatible, no interpreter
       action 2: nar-unpack (static C tool, exec_dep)     — RE-able, no network, no hashing needed
  └─ nix_closure(name, packages)   — featureless layer: store = composition of path artifacts,
       facts written at ANALYSIS time (closure known from lock at load time)
  └─ dir_layer(name, features, parent_layer)  — ONE action (category dirlir_layer):
       dirlir-shim --enclose --store <buildtools>/nix/store -- python3 layer.py @argfile
       validate (depgraph logic, runs first) → toposort → assemble → slim facts
       buildtools = nix_closure(["python3","coreutils","strace"])  — bootstrap needs no python itself
  └─ toolchains address tools as /nix/store/<base>/bin/gcc directly (forest mechanism DELETED)
```

Everything is an artifact or a native download ⇒ **zero `local_only` in the dirlir pipeline**
except the bootstrap tool builds. No action touches the network. PYTHON3 host pin deleted.

### The one spike (M1): per-path artifacts vs per-closure trees

- **Variant C (primary)**: `nar-unpack` does NO symlink rewriting (targets stay absolute
  `/nix/store/...`); store composition = `ctx.actions.symlinked_dir({basename: path_artifact})`;
  the shim deref-mounts (realpath each entry before binding; one merged-mount code path).
  Zero-copy layers, per-path unpack dedup. Requires buck2+RE to round-trip artifacts containing
  absolute/escaping symlinks bit-exact.
- **Variant B (designed fallback)**: unpack per closure — one `nar-unpack --manifest` action per
  layer consumes the per-path downloaded NARs into a self-contained tree with v1-proven relative
  rewriting. Downloads stay per-path/deduped; only unpack CPU repeats.
- Spike: S1 real `download_file` against a snix castore URL (redirects? transparent zstd? hash on
  decoded bytes?); S2 hand-built artifact with absolute + escaping symlinks → local build,
  consume, NativeLink round-trip; S3 shim deref-mount POC. Verdict appended to PLAN-v2.md.
- **Acceptance rule for C**: REv2 makes absolute-symlink handling an explicit per-server
  capability (`symlink_absolute_path_strategy`), so C's viability is per-backend BY PROTOCOL
  DESIGN — a verdict on NativeLink evidence alone leaves a Buildbarn landmine, and Buildbarn is
  a v2 deliverable. Therefore: (a) **any ambiguity resolves to B**; (b) S2 gets a cheap
  Buildbarn leg if feasible in M1, else the C verdict is recorded as CONDITIONAL, with the
  symlink round-trip as the Buildbarn lane's FIRST assertion — and that one check is NOT
  allow-failure even while the rest of the lane is; (c) the C→B blast radius is bounded and
  known: swap the composition action + `nar-unpack`'s manifest mode; toolchain addressing is
  unchanged — a late flip is a bounded event, which is what makes deferring the Buildbarn check
  tolerable; (d) S2's fixtures graduate into a permanent `tests/symlink-roundtrip` test rather
  than spike detritus — with the buck2 source pin, every future rev bump automatically re-proves
  the platform assumption C stands on.

### Bootstrap (decided: nix-build action, buck2.nix-style)

`dirlir/bootstrap.bzl`: a ~30-line `nix_flake_tool` rule — a `local_only` action runs
`nix build --no-link --print-out-paths .#<tool>` (pinned by flake.lock) and copies outputs into
buck-out. No binaries in git, zero drift, no CI byte-compare. These are the ONLY local_only
actions left — leaf exec_deps, CAS-cached, never run on RE workers. `nar-unpack.c` joins the shim
in `nix/shim/` (same pkgsStatic pipeline); structural validation (reject `/`, `.`, `..`, dup
names; enforce declared sizes; `--size` cap).

### Buck2 from source, patch-ready (addendum mandate 1)

- `nix/buck2/default.nix`: from-source derivation pinned to an exact upstream rev fetched with
  submodules. **Initial pin = the rev the repo runs today** (`7600cb80…`, buck2 2026-04-14) so M2
  changes one variable — binary provenance, not version; the v1 empirical findings
  (FindMissingBlobs behavior, ttl=0, .buckconfig.local startup semantics) stay interpretable and
  re-demo assertions remain valid. Version bumps are their own commits thereafter. Nightly rust
  per buck2's `rust-toolchain` file (via fenix or rust-overlay), `importCargoLock` from its
  Cargo.lock, protoc via the vendored `protoc-bin-vendored` crate. **`patches = [ ];` by
  default** — the mechanism ships now, patches only on demand. Do NOT use the nixpkgs package
  (it repackages prebuilt release binaries and cannot take source patches).
- **Prelude pairing is CHECKED, not assumed**: the repo loads the `bundled` prelude external
  cell. M2 verifies whether the from-source cargo build actually embeds the prelude submodule
  (release packaging may differ). If yes: matched by construction, record in ADR-1. If no:
  vendor the prelude synced from the derivation's recorded `preludeRev` (sync script) plus a
  one-line CI assertion in lock-check comparing the vendored rev to `preludeRev` in
  `nix/buck2/`. Either way the {buck2, prelude} pair is verifiable, and the stale
  `tools/vendor-prelude.sh` fallback is deleted or becomes the sync script.
- devshell switches to this buck2; flake.lock no longer implicitly determines the buck2 version.
- CI: the derivation is cached keyed on `{rev, hash(patches)}` (nix's own store hashing gives
  this for free; the workflow caches the closure and only rebuilds when the pin or patch set
  changes — a from-source buck2 build is ~20–40 min cold, so this cache is load-bearing).
- **Parsimony-gate conflict, flagged**: this deletes nothing and exceeds 50 lines (~80–120 lines
  of nix). It is included because the addendum mandates the mechanism; the conflict is recorded
  rather than silently resolved (ADR-1).

### Resolve/lock v2

`nix/resolve.py`: caches = `["https://nixos.snix.store"]`; **verify every narinfo ed25519
signature** against pinned trusted keys (vendored `nix/ed25519.py`, RFC 8032 verify only) —
unsigned/invalid aborts resolve. Lock schema per path: `narHash, narSize, references, url`
(DELETE fileHash/fileSize/compression). lock.bzl v2 exports `PACKAGES` + `PATHS` — no PYTHON3,
no SHIM_STORE_PATH. `dirlir/lock_util.bzl`: load-time `closure()` BFS, `store_base()` helpers.
Canonical attr list moves to `tools/resolve.sh`. `lock.json` leaves the build graph (stays
committed for `--check`/audit/liveness).

### Shim v2 — provision/enclose taxonomy (addendum mandate 3)

Binary renamed **`dirlir-shim`** (v3 generic reading; renaming later is churn — ADR-2). Every
flag is classified in `--help` and in source layout (single file, three commented sections;
provision and enclose share only the computed mount plan):

- **provision** (additive): `--store DIR` (merge DIR's entries into the provisioned /nix/store;
  deref binds under variant C). No nix-specific logic outside provision paths.
- **enclose** (subtractive): `--enclose` (minimal pivot_root root: provisioned /nix/store +
  exec root at its absolute path + fresh tmpfs /tmp + /dev subset + fresh /proc via CLONE_NEWPID
  + fork + minimal shim-written /etc), `--map-user N`, `--map-group N`, `--fail-hint STR`
  (the escape-hatch wording in the failure trailer is INJECTED by the caller, generic default —
  the shim never hardcodes buck2 UX, the same coupling class the taxonomy bans for nix;
  `shim_run()` passes the `-c dirlir.isolation=off` wording, `dirlir-run` passes the
  `DIRLIR_ISOLATION=off` wording, so each context's hint is accurate).
- **exec**: `-- PROG ARGS...`, and `@argfile` accepted for the full argv (doubles as v3 D1's
  manifest transport; ~20 lines).

Fast path (bind over /nix/store, full host view — provision without enclose) remains for
`buck2 run`/nix_tool UX. `dirlir/shim.bzl`: one `shim_run()` helper replaces the 5 duplicated
cmd_args constructions (nix_cxx.bzl, nix_haskell.bzl, import.bzl ×2, defs.bzl) and consumes the
isolation knob (below).

### Isolation knob, escape hatches, failure UX (addendum DX doctrine)

One knob: `[dirlir] isolation = off | audit | enforce` (buckconfig, default `enforce`,
documented). **The mode must enter action digests**: a module-level
`read_root_config("dirlir", "isolation", "enforce")` constant in `shim.bzl` (evaluated at LOAD
time — `read_config` is not callable from analysis; a `-c` change → reload → re-analysis → new
cmd_args → new digests, so the substance is identical), consumed by `shim_run()` which puts the
mode in `cmd_args` — so off/audit/enforce runs get distinct digests
and deliberately do NOT share cache entries (an `off` build can never poison an `enforce` cache;
this is a feature). The per-invocation escape hatch is therefore
**`buck2 build -c dirlir.isolation=off <target>`** — no env plumbing into actions (buck2 doesn't
forward client env, and a runtime-env override would share cache keys across modes, reinstating
the exact host-contamination-under-shared-keys vector this design closes). `DIRLIR_ISOLATION`
env remains meaningful ONLY for `dirlir-run` (no cache there; env is fine).
- `off`: provision only (no `--enclose`).
- `audit`: provision only, plus an strace wrapper emitting a one-line summary of **successful**
  opens outside {exec root, /nix/store, /proc, /dev, /tmp} (failed opens behave identically
  under enforce and are noise). Audit is an **over-approximation** — e.g. `/etc/ld.so.cache`
  succeeds on host, ENOENTs benignly under enforce, breaks nothing — so it ships a tiny default
  ignore-list for known tolerated probes, and docs state that the enforce run is ground truth.
  strace lives in the `buildtools` closure (`["python3","coreutils","strace"]`) — but toolchain
  invocations provision the TOOLCHAIN layers, not buildtools, so in audit mode `shim_run()`
  additionally adds the strace path artifact to that action's inputs/stores (harmless: audit
  digests are distinct by construction; and no fallback to host strace, which would reintroduce
  a host dep inside the observability feature).
- `enforce`: provision + `--enclose`.
On any nonzero child exit under enclose, dirlir-shim prints ONE stderr trailer:
`dirlir-shim[enclose]: command failed inside minimal root (visible: /nix/store, <execroot>,
/tmp, /proc, /dev, minimal /etc); <fail-hint>` — where the hint comes from `--fail-hint`
(shim_run injects `rerun with -c dirlir.isolation=off to bypass or -c dirlir.isolation=audit
to compare`; dirlir-run injects `set DIRLIR_ISOLATION=off to bypass`). The M6 demo asserts
this TEXT (not just exit code).
Debugging recipe (documented): re-run the failing action under `-c dirlir.isolation=audit`,
diff the audit summary against the enforce mount list.

### Rung-0 wrapper: `tools/dirlir-run` (addendum mandate 2)

Extract hermetic.sh's enclosure setup (allowlist closure computation + staged store masking)
into a reusable entry point that runs an arbitrary command — including `buck2 build` and the
buckd it spawns — inside the minimal-store namespace derived from the lock:
`dirlir-run [--audit] -- CMD...`. hermetic.sh becomes a thin test calling it (net deletion —
gate-passes). `--audit` = the same strace summary wrapper. This is simultaneously the
zero-integration adoption path and the control for CI machines allowed to write shared caches.

**The pre-existing-buckd hazard (flagship-demo threat, closed two ways).** If a daemon for that
isolation dir is already alive OUTSIDE the namespace, `dirlir-run -- buck2 build` encloses only
the client: every action executes in the unenclosed daemon's context, reachable through the
bound project directory's socket — silent false hermeticity from the zero-integration tool.
(v1's hermetic.sh dodged this by accident via always-fresh isolation dirs; productizing dropped
that safeguard.) Fix:
- **Policy (ADR-7)**: refuse by default when a live daemon exists for the target isolation dir
  (`dirlir-run: refusing: buckd for this isolation dir is running outside the namespace (pid N);
  run 'buck2 kill' or pass --kill-daemon`); `--kill-daemon` kills and proceeds. Chosen over
  forcing a dedicated `--isolation-dir` because killing the daemon keeps the warm buck-out
  cache (cold daemon, warm cache) — a dedicated dir would cold the whole buck-out and undercut
  the "wrap an existing build" pitch.
- **Unconditional invariant**: after spawning the command, locate the daemon pid and compare
  `readlink /proc/<pid>/ns/mnt` against dirlir-run's own; fail loudly on mismatch. The R0
  banner is the OUTPUT of this check, not decoration.
- **Teardown: daemon lifetime = wrapper lifetime** (the inverse hazard: a daemon that OUTLIVES
  dirlir-run stays enclosed while its socket remains reachable from outside — the next plain
  `buck2 build` then fails on host paths with bare ENOENTs and no trailer, silent false
  NON-hermeticity; and consecutive dirlir-run invocations would trip their own refusal check
  forever, making `--kill-daemon` a mandatory nag). Fix: run the enclosure under CLONE_NEWPID so
  the kernel reaps the daemon and everything else on exit (fallback: `trap 'buck2 kill' EXIT`
  inside the namespace).

## User journey (generic OSS buck2 repo)

- **R0 — wrap an existing build, zero repo changes:**
  ```
  $ nix develop -c tools/dirlir-run -- buck2 build //...
  dirlir-run: enclosing: 41 store roots visible (host store: 118k)
  dirlir-run: verified buckd (pid 12345) shares this mount namespace
  BUILD SUCCEEDED
  $ nix develop -c tools/dirlir-run --audit -- buck2 build //...
  dirlir-run[audit]: 3 successful opens outside allowed roots (top: /usr/include/zlib.h ×3) — over-approximation; enforce run is ground truth — see /tmp/dirlir-audit.txt
  ```
  First hermeticity signal for any repo, before adopting anything.
- **R1 — adopt dirlir toolchains; isolation enforced on tool invocations:**
  ```
  # .buckconfig: [dirlir] isolation = enforce   (default; off|audit available)
  $ buck2 build //app:main
  # a leak now fails loudly:
  main.c:1:10: fatal error: /etc/hostname: No such file or directory
  dirlir-shim[enclose]: command failed inside minimal root (visible: /nix/store, <execroot>, /tmp, /proc, /dev, minimal /etc); rerun with -c dirlir.isolation=off to bypass or -c dirlir.isolation=audit to compare
  ```
- **R2 — wrap your own rules' actions:**
  ```
  load("@root//dirlir:shim.bzl", "shim_run")
  cmd = shim_run(ctx, stores = [layer], argv = [tool, args...])   # inherits the knob
  ```
- **R3+ (future work only, not v2)**: prelude-wide per-action manifests (D1), localhost-RE
  per-action sandboxing (D2), upstream local-executor integration (D3), external-cell
  distribution. Users never see drivers, manifests, or the provision/enclose taxonomy — the
  surface is one command (R0) and one knob (R1).

## Deletion inventory (parsimony scorecard)

`nix/cache/` and all file-cache machinery; `nix_store_import` + `import_path.py`; `nar.py`;
materialize.py's fetch/decompress/verify/DIRLIR_CACHE/urllib/lzma/zstd code (+
`rewrite_store_symlinks` under variant C); the separate plan action, plan.json subtarget,
`--lock` plumbing (closure resolution → load time; `lock.json` leaves the build graph);
`NixLayerInfo.lock`; forests (feature arg, builder, collision errors, limitation); PYTHON3 /
SHIM_STORE_PATH / python314 devshell pin; lock fields fileHash/fileSize/compression; `.#`
flake-package support in resolve; all dirlir `local_only` (except bootstrap); PYTHON3
allowlisting in hermetic.sh; hermetic.sh's inline enclosure code (→ dirlir-run); duplicated shim
cmd_args ×5; DESIGN.md limitations that cease to exist (NAR-cache GC, materialize-on-RE, forest
planning, FileHash instability handling).

**Parsimony gate on v3-prep items**: dirlir-run (deletes hermetic.sh duplication ✓);
@argfile (~20 lines ✓); flag taxonomy/rename (~0 net ✓); isolation knob + trailer (~40 lines ✓);
buck2 source pin (**fails the gate; mandated; conflict recorded** — ADR-1).

## Adversarial validation suite

- `tests/unit/`: malformed-NAR corpus vs `nar-unpack` (traversal names, truncation at every
  token, bad padding, size bombs, dup entries) + `test_ed25519.py` (real signed narinfo positive;
  flipped sig/hash/refs negatives).
- `tests/tamper.sh`: flipped narHash in a scratch lock → build fails, no partial artifact.
- `tests/determinism.sh`: double build in two fresh isolation dirs → **type-aware manifest**
  (hash regular files; record symlinks as literal `path -> target` entries; record directory
  structure — a naive `find|sort|sha256sum` follows symlinks and ENOENTs on variant C's absolute
  `/nix/store/...` targets, which never exist outside buck-out on CI hosts) vs committed
  `tests/golden/*` (`--update` on lock bumps). Literal symlink comparison also makes goldens
  stronger than resolution-based hashing.
- `tests/offline.sh`: warm downloads; then bump a salt (`-c dirlir.salt=<value>`) that is
  threaded by `shim_run()` into every wrapped action's `cmd_args` AND directly into
  `nar-unpack`'s `cmd_args` (it is not shim-wrapped; one line in our own rule — otherwise it
  stays cached and the exact action class between downloads and layers is silently exempted).
  Same isolation dir, inside `unshare -rn`. The claim, stated precisely: **all dirlir actions
  re-run offline except native downloads and the bootstrap tool builds** (bootstrap runs
  `nix build` and is allowed network by design).
- `tests/isolate-audit.sh`: strace a real gcc compile under enforce; zero successful opens
  outside the minimal roots. Also validates the `audit` knob output format.
- `tests/re-demo.sh` updated: `dirlir_layer`/`nar_unpack` categories must appear REMOTE; local
  dirlir count = 0 (downloads exempt by construction).
- `tests/symlink-roundtrip/`: permanent home of the S2 fixtures (absolute + escaping symlink
  artifacts, build → consume → RE round-trip) — re-proves variant C's platform assumption on
  every buck2 rev bump and on every backend.
- `tests/re-buildbarn/`: docker-compose bb-storage/scheduler/worker+runner (SHA256, runner
  WITHOUT chroot-into-input-root, privileged for userns) — allow-failure until proven, EXCEPT
  the symlink round-trip assertion, which runs first and is never allow-failure.
- `tests/liveness.py`: HEAD every locked narinfo+NAR on snix (Content-Length == narSize) + full
  GET+sha256 of 3 random paths.
- M6 failure-UX demo: /etc-read compile fails under enforce **with the trailer text asserted**,
  succeeds under `off`.

## CI (GitHub Actions) — PR fast + nightly full

Every job: DetSys nix-installer; `sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`
+ `unshare -rm true` canary (verify exact knob during M8); `actions/cache` for buck-out keyed
`hashFiles('nix/lock.json','flake.lock','nix/buck2/*')`; the from-source buck2 closure cached
keyed on `{rev, hash(patches)}`.

- `ci.yml` (PR/push): unit → lock-check (`resolve.sh --check` + sigs) → build (`buck2 build
  root//...` + depgraph-errors) → hermetic (via dirlir-run) → offline → determinism (C-toolchain
  scope) → re-nativelink. GHC excluded from the PR lane.
- `nightly.yml` (cron): full matrix incl. ghc, re-buildbarn lane, full determinism goldens.
- `liveness.yml` (weekly): `tests/liveness.py` + `resolve.sh --check` (signed narinfos are
  immutable — any change is an alarm).

## Milestones (risk-ordered; each ends green + commit + push)

- **M0**: write this plan as `PLAN-v2.md`, commit, push.
- **M1 — spikes** (½ day): S1 snix download_file; S2 symlink round-trip local+RE; S3 deref POC.
  Exit: C-vs-B verdict appended to PLAN-v2.md.
- **M2 — buck2 source pin**: `nix/buck2/default.nix` (rev+submodules, nightly rust,
  importCargoLock, `patches=[]`), devshell switch, matched-pair doc. Verify: full v1 test suite
  green under the from-source buck2.
- **M3 — tools + shim interface**: `nar-unpack.c` + unit corpus; `nix_flake_tool` bootstrap;
  shim → `dirlir-shim` (taxonomy sections, `@argfile`, `--enclose` rename, `--fail-hint`);
  `shim.bzl` with the isolation knob (off/audit/enforce, `-c dirlir.isolation=` override,
  trailer). Delete `nix/cache/`, `import_path.py`, `nix_store_import`. Verify: build green,
  units, knob smoke tests.
- **M4 — lock v2**: vendored ed25519 + signature verification, snix cache, slim schema, lock.bzl
  v2, resolve deletions, regen lock, `liveness.py`. Verify: `resolve.sh --check`, sig unit tests.
- **M5 — native pipeline**: per-path `nix_path` targets, chosen composition variant,
  `nix_closure`, toolchains/openssl/dir_subpath → store-path addressing, forest deletion.
  Verify: examples build+run, hermetic, re-demo.
- **M6 — dir_layer v2 + enclosure**: buildtools layer, single `layer.py` action via shim-python,
  slim facts, delete legacy python + `local_only`; `--enclose` default-on with escape hatches +
  failure-text demo + isolate-audit. Verify: all proofs green; re-demo shows dirlir actions
  remote; trailer text asserted; **digest separation proven directly** — flip enforce→off and
  assert via `buck2 log what-ran` that wrapped actions re-EXECUTE (not merely behave
  differently).
- **M7 — dirlir-run**: extract from hermetic.sh, `--audit`, daemon policy + mount-ns invariant,
  hermetic.sh becomes thin caller; R0 journey commands verified verbatim. Verify: hermetic green
  through dirlir-run; audit summary on a deliberately-leaky command; **adversarial daemon case:
  start an OUTSIDE daemon first, run dirlir-run, assert refusal/kill and that the ns-mismatch
  check fires; teardown case: after dirlir-run exits, assert no daemon survives and a
  subsequent plain build spawns a fresh one**.
- **M8 — validation + CI**: determinism/tamper/offline tests + goldens, buildbarn lane,
  workflows, DESIGN.md/README v2 rewrite incl. user journey. Verify: full CI green on GitHub.

## ADRs (append verdicts/amendments here during execution)

1. **Buck2 source pin**: from-source nix derivation @ exact rev with submodules; **initial rev =
   the currently-running version (7600cb80…, 2026-04-14)** so provenance and version change
   separately; nightly rust per rust-toolchain; importCargoLock; protoc-bin-vendored;
   `patches=[]` default; CI cache key {rev, hash(patches)}. Prelude pairing is **checked**:
   M2 verifies bundled-prelude embedding in the from-source build; if absent, vendored prelude
   synced from the derivation's `preludeRev` + one-line CI assertion in lock-check. *Recorded
   parsimony-gate conflict: deletes nothing, >50 lines — included as an addendum mandate.*
   Upstreaming patches: out of v2 scope; intent recorded.
2. **Flag taxonomy & names**: binary `dirlir-shim`; classes provision (`--store`), enclose
   (`--enclose`, `--map-user/group`), exec (`--`, `@argfile`); classes named in --help and
   source sections; no nix semantics in enclose paths.
3. **Rung-0 tool name**: `tools/dirlir-run`.
4. **Risk-6 inversion**: PRIMARY remedy for RE-client misbehavior (FindMissingBlobs staleness,
   ttl=0 class) caught by re-demo assertions is a carried `.patch` in `nix/buck2/patches/`;
   FALLBACK is re-pinning `dir_subpath` local.
5. **Audit mechanism**: strace wrapper + summarizer only (in dirlir-run and the `audit` knob);
   no eBPF/fanotify/kernel machinery. Semantics: **successful** opens outside allowed roots,
   with a small default ignore-list for tolerated probes; audit is an over-approximation and
   the enforce run is ground truth. strace lives in the buildtools closure.
6. **Isolation mode is buckconfig entering digests, never runtime env**: module-level
   `read_root_config("dirlir", "isolation", "enforce")` in `shim.bzl` (load time; `-c` change →
   reload → re-analysis → new digests), mode in `cmd_args` ⇒ per-mode action digests; escape
   hatch is `-c dirlir.isolation=off`. `DIRLIR_ISOLATION` env exists only for `dirlir-run`
   (uncached). Same mechanism carries `dirlir.salt` (threaded into shim-wrapped actions AND
   nar-unpack). Failure-trailer escape wording is injected per context via `--fail-hint`.
7. **dirlir-run daemon policy**: refuse by default on a live buckd for the target isolation dir;
   `--kill-daemon` kills and proceeds (keeps the warm buck-out — chosen over forcing a dedicated
   isolation dir, which would cold the cache and undercut the wrap-an-existing-build pitch).
   Unconditional post-spawn invariant: daemon's `/proc/<pid>/ns/mnt` must equal dirlir-run's
   own; the R0 banner is that check's output. **Teardown: daemon lifetime = wrapper lifetime**
   — enclosure runs under CLONE_NEWPID so the kernel reaps the daemon on exit (fallback:
   `trap 'buck2 kill' EXIT` inside the namespace); no enclosed daemon may outlive dirlir-run.

## Explicitly deferred (not designed, not scaffolded)

Standalone helper repo/split and renaming; Landlock backend; non-nix provision sources; D1 for
prelude rules; localhost-RE productization; upstream PRs; external-cell distribution. On spec
formats: **argv+@argfile is the contract for all three planned drivers by design; superseding it
requires an ADR demonstrating a concrete driver need that argv cannot carry** (firm door,
honest hinge — no other serialized format gets designed or scaffolded in v2).

## Risks

1. buck2/RE symlink semantics for per-path artifacts — retired in M1; variant B designed fallback.
2. snix retention/completeness — weekly liveness cron; `caches[]` re-pointable; documented plan-B
   mirror script (`nix store dump-path` raw NARs → any static host); cache.nixos.org cannot
   substitute directly (no uncompressed NARs).
3. `download_file` specifics (redirects, transparent zstd decode) — spike S1.
4. GHA userns restriction — sysctl + canary; verified live in M8.
5. Buildbarn runner chroot vs userns — runner without chroot, privileged container, allow-failure.
6. OSS buck2 RE-client bugs when dirlir actions go remote — **primary remedy: carried patch**
   (ADR-4); fallback: local re-pin.
7. From-source buck2 build cost (~20–40 min cold) — CI closure cache keyed {rev, patches};
   rebuilds only on pin/patch change. **Beyond CI**: a contributor's first `nix develop` eats
   the cold build unless CI populates a public binary cache — remedy: CI pushes the buck2
   closure to cachix (free OSS tier; secret-optional like the buildbarn lane, forks skip the
   push and either pull the public cache or accept the cost — documented either way).
8. Bootstrap layer size (python3 closure) — free under C (symlinks), one-time under B; a
   static-python/rust port is explicitly NOT pursued (parsimony).
9. CI bandwidth for uncompressed NARs — PR lane C-only, caches keyed on lock, nightly full.
10. Trailer noise (printed on every nonzero exit under enforce) — accepted for self-explanatory
    failures (one line, names the off-switch); revisit if it drowns compile errors.

---

## M1 spike verdict (appended per plan)

**Variant C — CONDITIONAL PASS** (per the acceptance rule: conditional because Buildbarn is
untested; the symlink round-trip becomes the Buildbarn lane's first, non-allow-failure
assertion in M8).

- S1 ✅: `ctx.actions.download_file(url, sha256=narHash-hex, size_bytes=narSize)` against a live
  snix castore URL succeeds; buck2 verifies the hash natively. Any transparent content-encoding
  handling is irrelevant to the guarantee: the hash is checked over the bytes delivered, which
  must be the NAR bytes to match.
- S2 ✅: dir artifacts containing (i) an absolute dangling `/nix/store/...` symlink and (ii) a
  relative symlink escaping the artifact root round-trip **bit-exact** through NativeLink CAS in
  BOTH directions (local-produce → remote-read; remote-produce → local-materialize), verified by
  manifest diff and readlink. No canonicalization, no rewriting.
- S3 ✅: a symlinked_dir-style store (entries are symlinks to sibling artifacts) deref-mounts
  correctly: resolve entries pre-masking, bind each resolved dir into the store view (in the
  shell POC: staged tmpfs + final `--rbind`; in the shim: tmpfs at /nix/store + in-place binds,
  all syscalls). `hello` and coreutils execute through the composed store.

Implementation notes carried into M5: shim deref uses realpath-before-unshare (already the shim's
pattern) + per-entry binds; final placement must be recursive-bind semantics where staging is
involved. Spike fixtures live in `spikes/` until they graduate to `tests/symlink-roundtrip` (M8).

---

## Execution ADR amendments (M2–M8)

- **ADR-1 resolved**: the prelude is an in-tree directory of the buck2 repo
  (not a submodule); `app/buck2_external_cells_bundled/build.rs` embeds it
  at cargo build time — matched by construction, verified by the full suite
  under the from-source binary. Upstream ships no Cargo.lock (they build
  buck2 with buck2); ours is generated once per rev and committed.
  `RUSTFLAGS=--cfg tokio_unstable` required (buildRustPackage's vendoring
  shadows upstream's .cargo/config.toml). protoc via nix protobuf env
  override, exactly like upstream's own devshell.
- **ADR-4 executed**: chained remote layers hit the OSS FindMissingBlobs
  stale-cache bug in anger; carried patch 0001 records this client's
  uploads as present. Result: dir_subpath un-pinned, `local dirlir
  actions: 0` in the RE demo.
- **ADR-7 amended**: teardown also removes the daemon RECORD (a reaped
  namespace daemon leaves a pid meaningless outside; the next plain buck2
  would try to kill an unrelated host process). dirlir-run additionally
  self-heals stale records on entry (`buck2 status` reports "no buckd
  running" with rc=0 — probe by text, not exit code).
- **Bootstrap-in-the-mask**: buck2 has no persistent local action cache, so
  a fresh namespaced daemon re-executes the bootstrap; dirlir-run therefore
  allowlists the sanctioned nix infrastructure (nix+git closures, flake
  input sources, the prebuilt tools output) and exports a store-direct PATH
  (/run/current-system symlink chains die under the mask). The bootstrap
  passes explicit `--extra-experimental-features` (host nix.conf resolves
  through masked store paths on NixOS).
- **M1 verdict update**: variant C additionally proven via the graduated
  `tests/symlink-roundtrip` executing THROUGH shim actions on the
  store-less NativeLink worker, both directions, as the RE demo's first
  non-soft assertion. Still CONDITIONAL on the Buildbarn lane
  (tests/re-buildbarn.sh, nightly, allow-failure until proven; hard
  round-trip gate inside).
- **Enclosure findings**: fresh /proc must be mounted BEFORE pivot_root
  (kernel visible-proc rule); fresh /tmp before the exec-root bind (RE
  work dirs live under /tmp); on NixOS /etc/hostname resolves through the
  store, so the mask alone breaks it — mask-vs-enclose probes must use a
  real host file (/etc/machine-id).
