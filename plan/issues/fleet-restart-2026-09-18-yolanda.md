# Fleet restart 2026-09-18 — yolanda (Windows)

Per-host findings. The coordinator owns the main drill; this file is
yolanda's own, per the per-host convention.

## 1. Every restarted host pays a full gate before its FIRST push of any kind

The restart invalidates the `./build.sh --check` stamp. The next push —
**including a plan-only one** — is refused by the pre-push hook with:

    the tree changed since ./build.sh --check last passed

Nothing is wrong with the content and the tree can be perfectly clean. On
this host the remedy cost **4658 seconds of gate phases, about 78 minutes**,
before a two-file plan fragment could land.

**It reads like a credential fault and is not one.**
`scripts/check-credential-channel.sh` independently returned
`ok:gh-keyring-push-verified-hook-refused` and diagnosed the same stale
stamp in its own note. One cause, not two. A host that reads the refusal as
a credential problem will go looking in the wrong place.

## 2. The trunk merge is ALSO a gated push, and the plan-only lane cannot take it

The plan-only lane scopes the **outgoing diff**, and the outgoing diff is
measured against `origin/<this branch>` — not against trunk. A restarted
platform branch is hundreds of commits behind its own remote ref, so
merging trunk into it produces an outgoing diff carrying `crates/`,
`scripts/` and `openspec/`. It is nowhere near plan-only and always needs
the full gate.

Do not tell a restarted host that its merge-plus-claim push will take the
plan lane. It will not. (Linux hosts that fast-forward to
`origin/linux-next` *before* the claim push are the exception — their
outgoing diff really is one fragment.)

## 3. The `.gemini/skills` "deleted" list in the refusal is not dirt

Trunk replaced a five-file directory with a symlink. Relative to the
stamped tree those five paths are gone, so the hook lists them while
explaining what changed. On a Windows checkout `core.symlinks=false`, so
git stores the symlink as a mode-120000 blob holding the target string and
`git status --porcelain` is **empty**.

It reads exactly like the Windows symlink hazard and is not it. Every
restarted Windows host will see this list once, for the same non-reason.

## 4. A ref that lags is not a checkout that lags

Two dispatches sized this host's work from `origin/windows-next` and were
wrong both times — "585 commits behind", then "0 ahead of trunk and 617
behind". The local checkout was 37 behind trunk and then 0 behind, carrying
612 unpushed commits. The ref lagged; the checkout did not.

Ask the host, not the ref.

## 5. HOST vs GUEST memory — this one stopped the host gating entirely

See the measured instance appended to `1256-cqsy`. Short form: WSL2 balloons
under build I/O and does not return memory to Windows, so the **guest**
reads healthy while the **host** crosses the harness's low-memory threshold
and the gate is killed mid-run.

    GUEST  available 6237 MB      <- looks fine
    HOST   free 1783 MB of 15526  <- 11.5 percent, vmmemWSL holding 7311 MB

`build.sh` prints `ok:gate-memory:<N>MB available, floor 1024MB` and that is
the **guest** reading. It passed immediately before both reaps. A green
memory gate blind to the only memory pressure that can stop the build is a
defect that is in the tree today.

Consequence for this restart: yolanda **can measure and write, but cannot
gate**. Two full attempts, both killed at the
`cargo test -p tillandsias-headless --features tray,listen-vsock` phase.
Every `crates/` push needs that gate, so code work must leave this host
through the ungated `salvage/` lane and be gated by a relaying host.

The two levers are the operator's, not a peer's: the harness reaper can only
be disabled by an environment variable set when the agent process starts,
and a `.wslconfig` memory cap is a file in the operator's home directory.

## 6. A killed gate leaves live processes

Both reaps left the work running untracked inside the distro — two
`bash ./build.sh --check` shells and a live `rustc`/`cargo test` still
climbing in RSS. They keep consuming the memory that caused the reap.

**Check for survivors before re-running anything**, or the second attempt
competes with the first for the same `CARGO_TARGET_DIR` and the same RAM.
