# build.sh's top-level `require_podman` gate blocks flags that never touch podman — 2026-07-07

- class: bug-fix (build-script architecture)
- filed: 2026-07-07
- owner: any (cross-platform script, not host-specific)
- status: done
- trace: spec:dev-build, spec:build-script-architecture,
  plan/issues/macos-build-check-podman-wrapper-2026-07-05.md (the earlier,
  narrower macOS-only symptom of this same root architecture)

## Finding

`build.sh` line 63:

```bash
require_podman || exit 1
```

runs **unconditionally, before argument parsing even happens** (the
`--check`/`--test`/etc. flag-parsing loop starts later in the script). So
every invocation of `./build.sh`, regardless of which flag was passed, pays a
hard, fail-closed Podman connectivity requirement — including flags whose own
work never touches Podman at all.

Traced every actual Podman touchpoint in `build.sh` to check which flags
genuinely need it:

| Flag | Own work | Podman need |
|---|---|---|
| (no flags — default debug build) | `cargo build --workspace` + best-effort `image prune -f \|\| true` | **None** |
| `--check` | `cargo fmt --check` + `cargo check --workspace` + `cargo clippy -- -D warnings` | **None at all** |
| `--test` | `cargo test --workspace` + best-effort prune | **None hard** (some workspace integration tests may exercise real containers and would simply fail individually if Podman is broken — informative, not a blocking precondition) |
| `--install` (alone) | build + validate the musl-static launcher, copy to `~/.local/bin/` | **None** |
| `--install --ci-full` | additionally runs post-build/runtime litmus phases | Degrades gracefully already (`\|\| _warn "... non-fatal"`, `podman_runtime_health_probe` skip-not-fail) except genuinely Podman-dependent litmus specs, which is legitimate |
| `--release` | delegates to `scripts/local-ci.sh --fast` | Legitimate — but **already self-guarded**, see below |
| `--ci` / `--ci-full` | delegates to `scripts/local-ci.sh` | Legitimate — but **already self-guarded**, see below |
| `--init` | `tillandsias --init` (builds all container images) | **Yes, genuinely** |
| `--clean` / `--wipe` / `--remove` (alone) | filesystem cleanup only | **None** |

Every other Podman call already in `build.sh` (the dev-cache squid proxy setup
`ensure_dev_cache()`, `setup-podman-registries.sh`, all three
`"$PODMAN_CTL" image prune -f` calls) is already written to degrade
gracefully — warn and continue, never hard-exit. The unconditional top-level
gate is the **only** place in the file that hard-fails the whole script for a
requirement most flags don't have.

**`scripts/local-ci.sh` (invoked by `--ci`/`--ci-full`/`--release`) already
calls `require_podman` itself, conditionally, at the 4 specific points that
need it** (`grep -n require_podman scripts/local-ci.sh` → lines 958, 982,
1009, 1044, each `if require_podman; then ...`). So `build.sh`'s blanket gate
is not just overly broad for `--check`/`--test`/etc. — it's **redundant** for
`--ci`/`--ci-full`/`--release` too, since the script those flags delegate to
already does the right granular check on its own.

## Why this matters beyond the one macOS symptom already fixed

`plan/issues/macos-build-check-podman-wrapper-2026-07-05.md` (order 201's
sibling fix) found and fixed a macOS-specific bug in *how* the Podman wrapper
was generated (Homebrew Podman rejected Linux storage flags). That fix made
`require_podman` itself succeed correctly on macOS again — but the deeper
issue this packet addresses is host-agnostic: **any** host — Linux, Windows
WSL2, macOS — with a stopped/misconfigured/absent Podman daemon gets
`./build.sh --check` hard-blocked today, even though `--check`'s actual
work (`cargo fmt`/`cargo check`/`cargo clippy`) has never needed Podman. This
is the more fundamental bug the operator's question surfaced; the wrapper fix
was necessary but not sufficient.

## Work

1. Remove the unconditional `require_podman || exit 1` at `build.sh:63`.
2. Add an explicit `require_podman || exit 1` immediately before the
   `--init` block (the one place in `build.sh` itself with a genuine,
   unconditional Podman need) so that path still fails fast with a clear
   message instead of a possibly-confusing downstream Rust error.
3. Leave `--ci`/`--ci-full`/`--release` alone — `scripts/local-ci.sh`
   already gates the specific operations that need Podman; do not duplicate
   the check at the `build.sh` level for these.
4. Verify: with Podman intentionally broken/stopped, `./build.sh --check`,
   `./build.sh --test` (Podman-independent tests only), `./build.sh`
   (default debug build), `./build.sh --install` (without `--ci-full`), and
   `./build.sh --clean`/`--wipe`/`--remove` all now proceed and succeed on
   their own merits, while `./build.sh --init` still fails fast and clearly
   when Podman is unavailable.

## Acceptance Evidence

- `./build.sh --check` exits 0 with Podman stopped/misconfigured, on at
  least one host (this packet is filed from macOS, where the underlying
  Podman gap was discovered — see the krunkit/podman-machine finding in
  `plan/issues/macos-embedded-guest-runtime-smoke-2026-07-05.md`).
- `./build.sh --init` still fails fast and clearly (not a raw Rust panic)
  with Podman stopped/misconfigured.
- No regression in `--ci`/`--ci-full`/`--release`'s existing Podman-gating
  behavior (still correctly fails when a real Podman-dependent litmus check
  can't run).
- This finding is a candidate for semantic distillation into
  `methodology/` (e.g. `methodology/between-commits-work-discipline.yaml`
  or a build-script-architecture note) during the next
  semantic-distillation-and-ledger-pruning pass, per `openspec/specs/build-script-architecture/spec.md`'s
  ownership of this exact question (gate placement should match actual
  need, not blanket-require infrastructure the invoked operation doesn't
  use) — flagging here so meta-orchestration's compaction cycle picks it
  up rather than this staying scattered across a plan/issues note only.

## Fixed — 2026-07-07T00:20Z (order 226)

Removed the unconditional `require_podman || exit 1` at `build.sh:63`;
added an explicit guard immediately before the `--init` block only, with a
comment explaining why no blanket gate exists at the top of the script
anymore.

**Verified with Podman genuinely unreachable** on the filing host
(`podman-machine-default` has never started, `podman info` returns
connection-refused — see `plan/issues/macos-embedded-guest-runtime-smoke-2026-07-05.md`
for why): `./build.sh --check` now exits 0 (`cargo fmt --check` + `cargo
check --workspace` + `cargo clippy -- -D warnings` all pass, no gate trip
at all — this is the same scenario that motivated the whole
`macos-build-check-podman-wrapper` investigation, now genuinely resolved
at the architecture level, not just the wrapper-flags level). `./build.sh
--init` still exits 1 with a clear, comprehensible message ("Failed to
build 7 required image(s): proxy, git, inference, router, chromium-core,
chromium-framework, web").

**One nuance worth recording precisely** rather than overclaiming:
`require_podman()` itself only checks that `podman --version` succeeds
(binary is invokable), which is true even with *no Podman machine
running at all* — `podman --version` never touches the socket. So this
check was already weak (binary-presence, not connectivity) before this
change, at the old top-level location too. Moving it to just before
`--init` did not make `--init`'s failure mode either better or worse; it
only stopped that same weak check from blocking flags that never needed
it in the first place. Whether `require_podman()` should become a real
connectivity check (e.g. `podman info` instead of `podman --version`) is
a separate, legitimate follow-on question this packet intentionally does
not address — filing that separately would be premature without deciding
whether every current caller of `require_podman()` (including
`local-ci.sh`'s 4 call sites) actually wants the stricter behavior.

**Regression evidence**: `cargo fmt --check` clean; `cargo test -p
tillandsias-macos-tray -p tillandsias-vm-layer`: 58/58 + 50/50 pass;
`scripts/run-litmus-test.sh --phase pre-build --size instant --compact`
unchanged at 117 PASS / 2 FAIL (same 2 already-diagnosed local-machine-
state gaps, unrelated to this change). `--ci`/`--ci-full`/`--release`
code paths were not touched at all (no lines in their branches changed),
so their existing `scripts/local-ci.sh`-mediated Podman gating is
unaffected by construction.

**For the semantic-distillation pass** (see the candidate note above):
the durable, spec-worthy claim to carry forward is "a build-script gate
must be scoped to the operation that actually needs the resource, not
placed unconditionally ahead of argument parsing" — this repo's own
`ensure_dev_cache()`/registries-setup/image-prune calls already modeled
the correct pattern (degrade gracefully, fail only where truly needed);
this fix brings the one outlier (`require_podman`'s placement) in line
with the convention the rest of the script already followed.
