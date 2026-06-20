---
title: Install Go compiler (golang)
gap: Go compiler is missing; GOPATH and GOMODCACHE are exported in lib-common.sh but no Go compiler is installed
category: runtime-tool
status: proposed
proposed_at: 2026-05-29T10:50:00Z
changes:
  - file: images/default/Containerfile
    description: Add `golang` to the microdnf install RUN layer. GOPATH and GOMODCACHE are already exported by lib-common.sh routing Go modules to the per-project cache.
approved_by: null
---

## Gap

The forge image exports `GOPATH` (line 529) and `GOMODCACHE` (line 530) in `lib-common.sh`, routing Go module caches to the per-project cache. The `$GOPATH/bin` directory is added to `$PATH` (line 561). However, the Go compiler (`go`) is not installed in the image.

The forge-completeness-baseline audit has per-language env vars at PROMPT coverage but no actual Go runtime to test.

## Evidence

- `images/default/lib-common.sh` line 529: `export GOPATH="$PROJECT_CACHE/go"`
- `images/default/lib-common.sh` line 530: `export GOMODCACHE="$PROJECT_CACHE/go/pkg/mod"`
- `images/default/lib-common.sh` line 561: `export PATH="...:$GOPATH/bin:$PATH"`
- `images/default/Containerfile` lines 17-24: no golang package

## Safety

- `golang` is a standard Fedora Minimal package — no untrusted downloads.
- GOPATH already points to per-project cache; module downloads will use the designated cache location.
- Fedora golang package is ~150 MB with the standard library.
- No credentials or secrets are involved.
