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
| 123 | normalization research (verdict) | linux | ✅ completed |
| 124 | normalization spec + facade | linux | in_progress (contract + spec landed) |
| 125 | Linux backend conform + collapse 5 exec variants | linux | ready (facade exists) |
| 126 | macOS VZ virtio-vsock conform | **osx** | **ready** (facade landed) |
| 127 | Windows WSL/hvsock conform | **windows** | **ready** (facade landed) |
| 128 | tray parity matrix + litmus | linux | ready |

**Unblock delivered:** `tillandsias-control-wire::guest_transport` facade
(`GuestTransport` trait + `GuestEndpoint` + `ExecRequest`/`ExecOutput`) + the
`host-guest-transport` openspec spec are landed and compile on all targets, so
126 (osx) and 127 (windows) have a concrete interface — both flipped to `ready`.

## Queue Summary

Linux `ready`: **125** (Linux backend migration + collapse 5 exec→2), **128**
(parity matrix). Order 124 `in_progress` (litmus + conformance harness remain).
Order 122 `in_progress` (slices 2–5).
macОС/Windows: 126/127 ready for their terminals.

## osx integration (action required by osx terminal)

osx-next (0604acff) has **diverged** — a coordinator merge now hits a main.rs
conflict + 8 plan/index.yaml regions + add/add plan files. **Do not force.** osx
must merge linux-next into osx-next first (linux authoritative for shared+ledger,
osx for macos-owned files, `cargo fmt` in the same pass). Steps in
`coord-osx-vz-fmt-drift-2026-06-28.md`. This also hands osx the facade for 126.

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
