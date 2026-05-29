---
name: build-macos-tray
description: Attempt a cross-platform build of the macos-tray release binary on the local Windows host (expected to fail), file findings in ./plan/ so the macos host can act on them.
---

# /build-macos-tray

A daily probe (scheduled via /loop 24h) that compiles
`tillandsias-macos-tray` from the **windows host**. The crate is cfg-gated:
every macOS-only module is behind `#[cfg(target_os = "macos")]` and the
Apple-only deps (`objc2_virtualization`, `objc2_app_kit`, etc.) live under
`[target.'cfg(target_os = "macos")'.dependencies]` in Cargo.toml, so on
Windows the build **succeeds as a stub** (a tiny `main` that exits 1 with a
pointer to the spec).

The value of this loop is therefore the **inverse of what I first assumed**:
a Windows build SUCCESS = healthy cross-platform discipline; a Windows build
FAILURE = something broke in the cross-platform-shared portion of the crate
(`menu_disabled_v2`, `terminal_attach`, or any shared crate the stub still
pulls in like `tillandsias-host-shell`). That kind of failure is precisely
what the linux dev box's `cargo check --workspace` is supposed to catch
pre-merge — this loop catches it from the **other** host's perspective and
files findings so the macos host sees them too.

## Why this exists

The user explicitly asked for this loop so that:
1. Windows-side build attempts surface in the multi-host plan.
2. Other hosts (notably the macos host) see any issues that might affect them.
3. We capture a clean, reproducible "this is what the build looks like from
   windows today" snapshot in case a future cross-compile path becomes viable
   (e.g. clang-cross, an MSI'd toolchain, GitHub Actions matrix).

Treat this file as the source of truth; tune it between iterations as the
cross-platform story evolves.

## Working dir

`C:/Users/bullo/src/tillandsias`

## Steps

### 1. Sync working tree

```bash
git fetch --all -q
B=$(git branch --show-current)
[ "$B" = "windows-next" ] || { echo "WRONG BRANCH: $B"; exit 1; }
git merge --ff-only origin/linux-next 2>&1 | tail -2
```

### 2. Attempt the build

```powershell
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
cargo build -p tillandsias-macos-tray --release
```

Capture both stdout and the cargo exit code. The build is EXPECTED to fail.

### 3. Classify the outcome

| cargo exit | meaning                              | action                          |
|-----------|--------------------------------------|---------------------------------|
| `0`       | **expected steady state** — stub compiled on Windows; the cfg-gating is intact. | Record as baseline; no escalation. |
| non-zero  | **regression in the cross-platform-shared portion** of macos-tray or one of its non-platform-gated dependency crates. | ESCALATE — find first `error[...]` line; surface it (see Step 5). |

The shared modules + crates whose health this loop transitively pins:
- `tillandsias-macos-tray::menu_disabled_v2`
- `tillandsias-macos-tray::terminal_attach`
- `tillandsias-host-shell` (full crate — pulled by both modules above)
- `tillandsias-control-wire` (pulled by host-shell)

A failure surfaced here means at least one of those broke for everyone, not
just macOS — even though only the macos-tray's daily build is the canary.

### 4. Findings file

Write `plan/diagnostics/build-macos-tray-from-windows-YYYY-MM-DD.md`:

```markdown
# build-macos-tray (from windows host) — YYYY-MM-DD

**Branch:** <branch> @ <short SHA>
**cargo exit:** <N>
**First error line:** <verbatim>
**Classification:** <expected: objc2_virtualization | expected: objc2_app_kit
                    | expected: linker | UNEXPECTED: <category>>
**Shared-crate impact:** <none | crate <name> error: <excerpt>>
**Action needed:**
- If classification is `expected`: none from any host. Recorded as the daily
  baseline.
- If classification is `UNEXPECTED` AND shared-crate-impact is non-none:
  ESCALATE — flag in `plan/issues/tray-convergence-coordination.md` so the
  affected host can act before their next integration cycle.
```

### 5. Conditional cross-host coordination note

If and only if Step 3 surfaced an UNEXPECTED shared-crate error: append a
short entry to `plan/issues/tray-convergence-coordination.md` describing the
error + which crate + the reproducer. Do NOT delete others' notes — append
only.

### 6. Commit + push

```bash
git add plan/diagnostics/build-macos-tray-from-windows-YYYY-MM-DD.md
[ -f plan/issues/tray-convergence-coordination.md ] && \
  git add plan/issues/tray-convergence-coordination.md
git commit -m "diagnostics(windows-next): build-macos-tray-from-windows YYYY-MM-DD"
git push origin windows-next
```

### 7. Report

Print a 4-line summary: cargo exit, first error excerpt, classification,
and whether an escalation note was filed.

## Tuning log

- **2026-05-29:** initial. Documents the expected-failure modes and the single
  case (UNEXPECTED + shared-crate-impact) that warrants escalation. The
  classification list will need refinement as Rust ecosystem changes — e.g.
  if `objc2_virtualization` ever ships a Windows-stub that fails differently.
