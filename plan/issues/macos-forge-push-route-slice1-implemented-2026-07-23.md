# IMPLEMENTED (Slice 1): macOS forge push route via the already-running git:// mirror

- **Date:** 2026-07-23
- **Class:** implementation (fix) — closes a slice of the P1 in `macos-forge-no-push-route-lane-decision-2026-07-23.md` (Option B)
- **Area:** forge source-routing (SRC-ISOLATION lane) / git-mirror push relay
- **Status:** code implemented + compiles (`cargo check -p tillandsias-headless` clean; `bash -n lib-common.sh` clean). **PENDING e2e push verification** (guest rebuild + forge relaunch + real push test).
- **Owner:** macOS (osx-next); Linux/forge to review for parity.

## What was implemented (Slice 1 / Variant 1b — env-signal hybrid)

Verified pivotal fact (Plan trace): the `tillandsias-git` mirror is **already started, seeded, and Vault-credentialed** on the macOS `--opencode` launch path (`run_opencode_mode`, `main.rs:8842-8886`, unconditional — not gated by `forge_src_isolation_requested()`). The mirror sits on `tillandsias-enclave`, reachable from the forge, and its relay forwards to GitHub with the Vault token (`relay-refs.sh:62-97`). Push failed only because the SRC-ISOLATION lane never told the guest the mirror exists, so `clone_project_from_mirror` hit "no push route (non-bare staged source)".

Two edits (keep the fast local filesystem clone; add a push route):

1. **`crates/tillandsias-headless/src/main.rs`** (SRC-ISOLATION branch, after the `TILLANDSIAS_GIT_MIRROR_PATH` env): also pass `--env TILLANDSIAS_GIT_SERVICE=tillandsias-git`. Safe because the filesystem clone branch (`lib-common.sh:516`) runs first and `return`s at `:575`, so the network-clone branch (`:584`) is never reached; the new env only feeds the push-URL redirect. `TILLANDSIAS_GIT_SERVICE` has no other image consumer.
2. **`images/default/lib-common.sh`** (the non-bare staged-source `else`, formerly "no push route"): when `TILLANDSIAS_GIT_SERVICE` is set, `git remote set-url --push origin "git://${TILLANDSIAS_GIT_SERVICE}/${TILLANDSIAS_PROJECT}"` — the same transport the network lane already uses (precedent `:639`). Setting `pushurl` bypasses the fragile `insteadOf` string-match entirely.

Net: origin still *presents* the GitHub URL (fetch/UX), but `git push` routes to the enclave mirror, which relays to GitHub with the Vault token. Isolation (order 342, read-only staged clone) is preserved.

## Verifiable success test (the loop's exit condition)

Launch a fresh macOS forge → make a trivial commit in the forge → `git push` → assert all of: (1) push exits 0; (2) the commit SHA appears on GitHub on the target branch; (3) `git remote -v` inside the forge shows the push URL as `git://tillandsias-git/<project>`; (4) the mirror container's `git-push.log` shows `[relay] Atomic push … succeeded`.

## Follow-up findings (from the Plan trace — file/track separately)

1. **`run_opencode_mode` starts the mirror but never gates on `wait_for_git_mirror_ready`** (`main.rs:8871-8886` vs the gate at `:10441`). Benign for Slice 1 (the guest push carries full history from the local clone, so a mid-seed mirror can still relay a fast-forward — `relay-refs.sh:151-161` reconciles), but it is a **hard prerequisite for the Approach A convergence** (clone-from-mirror), where a cold GitHub seed takes minutes and the guest backstop waits only ~42-60s.
2. **A GitHub→mirror `insteadOf` is already injected for all lanes** (`write_forge_gitconfig`, `main.rs:7439-7454`) yet push still failed — so "no push route" was subtler than "no redirect." Likely an origin-string mismatch (`sed`-strip at `lib-common.sh:551` vs `sanitize_forge_origin_url` at `:7406`) or an unresolved origin (`resolve_host_project_origin` no-git fallback). Slice 1's explicit `pushurl` makes it moot; worth a short packet if convergence (Approach A) removes the local clone.

## Deferred (Slice 2+)

- **Approach A (converge to `GIT_SERVICE`):** drop `TILLANDSIAS_FORGE_SRC_ISOLATION=clone` (`diagnose.rs:1200`) so macOS clones AND pushes from the mirror — strictly better isolation, but requires follow-up #1's seed gate and starts from GitHub HEAD (loses the operator's local unpushed commits the staged clone preserves).
- **Local-seed optimization:** seed the mirror from the local virtiofs staged checkout (net-new) so Approach A is fast + local-commit-preserving.
- **Ramdisk (tmpfs) checkout:** separately scoped (`forge-enclave-isolation-uniform-principle-2026-07-23.md` §4).

## Cross-references

- `plan/issues/macos-forge-no-push-route-lane-decision-2026-07-23.md` — the P1 + Option B this closes a slice of.
- `plan/issues/forge-enclave-isolation-uniform-principle-2026-07-23.md` — the uniform-isolation principle / convergence target.
- `plan/issues/macos-clone-lane-push-remote-misalignment-2026-07-16.md` — the original "no push route (non-bare staged source)" diagnosis.
