# Active Work — 2026-06-28T09:20Z

## Latest Release

**v0.3.260628.1** — released 2026-06-28 via PR #56
- Linux musl x86_64 + aarch64, macOS arm64 tray, Windows x64 tray
- No `tillandsias-zeroclaw` binary (removed, order 114); single `tillandsias` binary
- Completes the four-P0 credential-path saga (build proxy / exec env / no_proxy / proxy-not-started); verified end-to-end (login + 23 repos)
- https://github.com/8007342/tillandsias/releases/tag/v0.3.260628.1

## In Progress

| Order | Packet ID | Host | Status | Notes |
|-------|-----------|------|--------|-------|
| 122 | container-dependency-graph-impl | linux | in_progress | Slice 1 done (container_deps graph + acyclic tests). Slices 2–5: ensure()/typestate Up<S>/liveness/drift-litmus remain |
| 104 | hardcoded-ip-eradication | linux | in_progress | Sub-task `remove-port-publish` still blocked (vault init unseal still uses HTTP :8201) |

## Blocked

| Task | Blocker | Owner |
|------|---------|-------|
| osx-next macOS integration | rustfmt drift in osx-owned `vm-layer/src/vz.rs` fails shared `--check`; flagged in `coord-osx-vz-fmt-drift-2026-06-28.md` | osx terminal (run `cargo fmt`) |
| hardcoded-ip/remove-port-publish | Vault init still uses HTTP port 8201 for unseal/root-token ops; steady-state reads use podman exec | linux |

## Initiative: Host↔Guest Transport Normalization (orders 123–128)

Operator-mandated: stop the per-platform drift on "connect host→guest". Normalize
vsock to two primitives (InteractiveStream, ExecOneShot) behind one facade, one
protocol, one nomenclature, with **1:1 tray feature/UX parity**. Coordination:
`host-guest-normalization-coordination-2026-06-28.md`. **Release held until macOS
completes current work.**

| Order | Packet | Owner | Status |
|---|---|---|---|
| 123 | normalization research (verdict) | linux | ready |
| 124 | normalization spec + facade | linux | pending (→123) |
| 125 | Linux backend conform + collapse 5 exec variants | linux | pending (→124) |
| 126 | macOS VZ virtio-vsock conform | **osx** | pending (→124) |
| 127 | Windows WSL/hvsock conform | **windows** | pending (→124) |
| 128 | tray parity matrix + litmus | linux | ready |

## Queue Summary

Linux `ready`: **order 123** (transport research) and **order 128** (parity matrix) —
both authorable now and they unblock the rest. Order 122 `in_progress` (slices 2–5).
macОС/Windows: orders 126/127 assigned, blocked on the order-124 facade.

## Recent Completions

- 2026-06-28 order 122 (slice 1): container dependency graph module + acyclic/topo tests
- 2026-06-28 order 121: compile-time container dependency model design verdict (Option C)
- 2026-06-28 order 117: remove orphaned zeroclaw image + dead tray launch path
- 2026-06-28 order 115: --init auto-configures podman dns_servers on loopback-resolver hosts
- 2026-06-27 orders 116/118/119/120: four-P0 credential-path fixes (build proxy / exec env / no_proxy / proxy-not-started)
- 2026-06-27 order 114: remove unauthorized tillandsias-zeroclaw binary from releases
- 2026-06-27 order 113: Eliminate raw credential reads from host tray process
- 2026-06-27 order 112 (slice 1): ProviderId enum + forge container API key injection
- 2026-06-27 order 111: ZeroClaw release packaging
- 2026-06-27 order 110: Vault credential persistence (keyring unseal)
- 2026-06-27 order 109: Proxy env centralization
