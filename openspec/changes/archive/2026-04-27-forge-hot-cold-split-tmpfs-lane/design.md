## Context

The `forge-hot-cold-split` capability defines two storage tiers: HOT (kernel tmpfs, hard cap, ENOSPC on overflow) and COLD (disk, no cap from this spec). Four paths are HOT; everything else is COLD. The `cheatsheets-license-tiered` design's pull-on-demand cache does not fit cleanly into either tier:

- It needs **fast first-read** for recently-pulled content (tmpfs latency).
- It needs **graceful overflow** because the agent does not know upstream archive sizes a priori (a JDK API HTML pull is hundreds of MB; an RFC text pull is KB).
- It needs **per-project isolation** preserved (per `forge-cache-dual`) — eviction must never cross project boundaries.

Tmpfs with hard cap (HOT semantics) fails the first constraint when the agent pulls something larger than the cap. Disk-only (COLD semantics) fails the second constraint by always going to slow storage. The right pattern is a **tmpfs overlay on top of a COLD root** with LRU eviction across the boundary as a single per-project pool. This pattern preserves the four-HOT-roots invariant (tmpfs-overlay is not a HOT root in the spec sense; it is a COLD root with optional acceleration).

## Goals / Non-Goals

**Goals:**
- Admit the tmpfs-overlay pattern explicitly so `cheatsheets-license-tiered` apply has unambiguous spec coverage.
- Preserve the four-HOT-roots rule unchanged.
- Tie the new pattern to `forge-cache-dual` per-project isolation so eviction semantics are inherited.

**Non-Goals:**
- Generalizing the pattern to non-cache paths (e.g., `/tmp` is still pure HOT; `/var/log/tillandsias/` is still pure COLD).
- Implementing the tmpfs-overlay mechanism in this change — that lands in `cheatsheets-license-tiered` apply.
- Changing the four HOT root caps or adding a fifth HOT root.

## Decisions

### Decision 1 — Naming: "tmpfs-overlay lane" not "fifth HOT root"

The new pattern is named **tmpfs-overlay lane** in the spec. Alternatives considered:

| Alternative | Rejected because |
|---|---|
| "Fifth HOT root" | Would dilute the "HOT means hard cap with ENOSPC" semantic; the new lane has soft cap with auto-spill — opposite behavior on overflow. |
| "Hybrid tier" | Vague; does not signal *direction* of overflow (HOT→COLD vs the reverse). |
| "Tepid tier" | Cute but confusing; reads as "between" HOT and COLD when in fact it IS COLD with optional acceleration. |
| "Cache-overlay tier" | Better but doesn't name the underlying mechanism (tmpfs union over disk). |

**Rationale:** "tmpfs-overlay lane" makes the mechanism explicit. The lane sits on top of a COLD root; the tmpfs is an acceleration layer, not a separate tier. Reading the spec, an implementer immediately knows the storage substrate (disk) and the acceleration mechanism (tmpfs overlay).

### Decision 2 — Where the overlay lives

The tmpfs-overlay lane is rooted at `~/.cache/tillandsias/cheatsheets-pulled/` inside the forge container. This path is:

- Inside the per-project cache mount (per `forge-cache-dual`), so per-project isolation is structural — the host bind-mounts a per-project directory at `~/.cache/tillandsias/`, and the overlay only sees that one project's bytes.
- A subtree of an existing COLD root (the per-project cache), so existing COLD-root semantics (no spec-level size cap) apply.
- Not a child of any HOT root, so the four-HOT-roots invariant is undisturbed.

### Decision 3 — Tier auto-detection

`MemTotal` is read from `/proc/meminfo` once at tray startup. The tray records the host class in its config and passes the resolved cap into the forge container via env var (`TILLANDSIAS_PULL_CACHE_RAM_MB`). The agent does not detect — the cap is given to it.

| `MemTotal` | Tier | Cap | Override knob |
|---|---|---|---|
| < 8 GiB | modest | 64 MB | `forge.pull_cache_ram_mb` |
| 8–32 GiB | normal | 128 MB | same |
| ≥ 32 GiB | plentiful | 1024 MB | same |

**Rationale:** Detect once at tray startup (cheap, accurate enough). Pass via env var (no per-launch reading of `/proc/meminfo` from inside the container). Override knob in user config preserves the convergence-by-intent rule.

### Decision 4 — LRU eviction is per-project, never cross-project

When the tmpfs portion exceeds the cap, the LRU eviction algorithm:
1. Identifies the least-recently-accessed file in the SAME PROJECT'S subtree of the tmpfs portion.
2. Demotes (`mv`s) it to the disk-backed portion of the same project's pull cache.
3. Repeats until the new write fits.

Eviction NEVER touches another project's bytes (would violate `forge-cache-dual`). If a single project's pull cache exceeds available disk, the underlying filesystem returns ENOSPC and the agent handles it like any other disk-full event.

**Rationale:** The simplest possible eviction policy that respects existing isolation invariants. More sophisticated cross-tier policies (e.g., promote-on-second-read) are deferred until the v1 implementation surfaces hotspots.

## Risks / Trade-offs

| Risk | Mitigation |
|---|---|
| Implementer reads "tmpfs-overlay lane" and adds a fifth HOT root by accident | Spec text is explicit: "tmpfs-overlay lane is NOT a HOT root; the four HOT roots remain unchanged" |
| Pattern leaks beyond the pull cache (e.g., implementer applies it to project source) | Spec scopes the pattern to `~/.cache/tillandsias/cheatsheets-pulled/` only; other applications need their own spec change |
| Auto-detection misclassifies a host (e.g., a 16 GB host with constrained swap behaving like an 8 GB host) | `forge.pull_cache_ram_mb` override is the escape hatch; documented in `cheatsheets/runtime/forge-paths-ephemeral-vs-persistent.md` |
| Tmpfs-to-disk demotion loses access metadata (atime) needed for LRU | Eviction tracks access via in-process LRU rather than filesystem atime (atime is unreliable on tmpfs anyway); state is per-session, lost on container stop (acceptable — pull cache is per-project ephemeral) |

## Migration Plan

This is a spec-only change. The actual implementation lands in `cheatsheets-license-tiered` apply. There is no migration; no existing behavior changes.

## Open Questions

None — the design choices above are derived from `cheatsheets-license-tiered` Decision 3 and are deterministic given that change's defaults.
