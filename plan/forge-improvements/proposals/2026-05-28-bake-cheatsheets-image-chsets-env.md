---
title: Bake cheatsheets at /opt/cheatsheets-image/ and export TILLANDSIAS_CHEATSHEETS env var
gap: Cheatsheets are not baked into the forge image at /opt/cheatsheets-image/ and TILLANDSIAS_CHEATSHEETS env var is not exported
category: env-var
status: implemented
proposed_at: 2026-05-28T22:03:00Z
implemented_at: 2026-05-29T08:24:56Z
evidence: Added COPY cheatsheets/ /opt/cheatsheets-image/ and ENV TILLANDSIAS_CHEATSHEETS to Containerfile
changes:
  - file: images/default/Containerfile
    description: Add COPY cheatsheets/ /opt/cheatsheets-image/ near the end of the build and ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets. Do NOT create /opt/cheatsheets/ at build time — that's a runtime tmpfs mount.
approved_by: orchestrator
---

## Gap

The `default-image` spec (`openspec/specs/default-image/spec.md`, lines 245-261, 278-310) requires:

> **Requirement: Forge image bakes the cheatsheets directory at /opt/cheatsheets-image/**
>
> The forge image (`images/default/Containerfile`) SHALL `COPY cheatsheets/ /opt/cheatsheets/` near the end of the build and SHALL set `ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` so agent runtimes can discover the path.
>
> **Requirement: Forge image ships cheatsheets at /opt/cheatsheets-image (image-baked canonical)**
>
> The forge image (`images/default/Containerfile`) SHALL bake cheatsheets at `/opt/cheatsheets-image/` (the immutable lower-layer copy) rather than at `/opt/cheatsheets/` (which is now a runtime tmpfs mount populated by `populate_hot_paths()`).

The current Containerfile does NOT:
1. COPY the cheatsheets/ directory into the image
2. Export TILLANDSIAS_CHEATSHEETS env var
3. Create /opt/cheatsheets-image/ as the immutable source

## Evidence

- `openspec/specs/default-image/spec.md` lines 245-261 — first cheatsheets requirement
- `openspec/specs/default-image/spec.md` lines 278-310 — delta spec for /opt/cheatsheets-image/ path
- `images/default/Containerfile` — no COPY cheatsheets command, no ENV TILLANDSIAS_CHEATSHEETS
- `images/default/lib-common.sh` line 674-680 — `populate_hot_paths()` expects `/opt/cheatsheets-image/` as the source to copy from
- `images/default/entrypoint-forge-opencode.sh` line 21 — calls `populate_hot_paths()`, which is a no-op because cheatsheets-image doesn't exist

## Impact

Without baked cheatsheets:
- `populate_hot_paths()` in every entrypoint silently no-ops (the /opt/cheatsheets-image/ directory does not exist)
- Agents have NO cheatsheets available at runtime — no forge-discovery, cache-discipline, methodology, or language/build cheatsheets
- `TILLANDSIAS_CHEATSHEETS` is unset, so agent tooling that reads this variable gets an empty path
- The welcome banner cannot show the cheatsheet location
- The forge-completeness-baseline-2026-05-27.md rates this as PROMPT-level but it's currently NONE

## Proposed Change

Add near the end of Containerfile (before the locale files COPY):

```dockerfile
# ── Cheatsheets (image-baked, RO lower layer) ───────────────
# @trace spec:default-image, spec:forge-hot-cold-split
COPY cheatsheets/ /opt/cheatsheets-image/
ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets
# DO NOT create /opt/cheatsheets/ here — that's a runtime tmpfs mount
```

## Safety

- `/opt/cheatsheets-image/` is world-readable, root-owned — forge user can read but not modify
- Runtime `/opt/cheatsheets/` tmpfs is populated by `populate_hot_paths()` in the entrypoint, copying from the image-baked source
- No credentials or secrets in the cheatsheets directory — pure reference documentation
- The `cheatsheets/` directory already exists in the repo at 52 KB
