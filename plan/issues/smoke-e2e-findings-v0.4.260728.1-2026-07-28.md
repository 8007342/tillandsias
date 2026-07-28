# Curl-install e2e smoke — v0.4.260728.1 (Linux) — 2026-07-28

- **Verdict**: **PASS** — full clean-room chain green end to end on the
  published artifact.
- **Host**: mutable Linux (macuahuitl), branch `linux-next`
- **Channel/tag**: `daily` → `v0.4.260728.1` (the v0.4 series opener,
  published ~1h before this smoke)
- **Discovered by**: `/smoke-curl-install-and-test-e2e`
- **Sibling heads at start**: main=ffe85a23, linux-next=d7b6a512,
  windows-next=91ab1f8f, osx-next=89cade75
- **Evidence**: `target/smoke-e2e/` (00-release, 01-install, 02-reset,
  03-init, 04-opencode logs)

## Gate results

| Gate | Result | Evidence |
|---|---|---|
| 1 curl-install | PASS — installer via `TILLANDSIAS_RELEASE_BASE` pin; `tillandsias --version` == v0.4.260728.1 | `01-install.log`, `01-version.txt` |
| 2 destructive reset | PASS — `podman system reset --force`; store verified empty (no containers/volumes/images) | `02-reset.log` |
| 3 cold init | PASS — exit 0; all enclave images rebuilt from scratch (proxy/git/inference/forge; `podman image exists` status=1 probes are the expected pristine-store rebuild triggers); IPv6-check fallback injected `--ipv4-only` (curated path); Vault initialized + unsealed from nothing, 12 policies + AppRoles provisioned, container healthy | `03-init.log` (zero Error/panic/FATAL) |
| 4 forge lane | PASS — `--opencode --prompt "/meta-orchestration"` exit 0. In-forge agent ran a FULL cycle: credential guard `ok:forge-git-mirror`, drained order 485 (plan.yaml duplicate-note housekeeping + methodology/events/ fork deletion), freshness audit refreshed, `./build.sh --check` PASS in-forge, committed `52347333` and PUSHED through the enclave mirror relay — verified durably on origin/linux-next from the host. Boundary verified clean; teardown ran only after lane exit ("no active lane containers" line post-exit, order-298-safe ordering) | `04-opencode.log` |

## v0.4 charter significance

This is the first smoke of the v0.4 series opener and it exercises the exact
charter loop shipped by the release: pristine substrate → published binary →
enclave bring-up → in-forge agent work → durable mirror push, with no
crashloop, no work loss, and no forge/mirror corruption. Order-455's Linux
column now has its dated PASS naming the v0.4 build.

## Observations (process, not product)

- **4b egress snapshot missed**: the host-side proxy-alive-alongside-lane
  probe waited on container names `^tillandsias-(forge|opencode)` which never
  matched the actual lane container name, so the direct `podman ps` snapshot
  was not captured before teardown. Functional egress evidence is stronger
  anyway: the in-forge cycle fetched, built, and pushed through the mirror —
  impossible without live proxy/git during the lane — and the shared-stack
  teardown line appears only after lane exit. Next smoke should grep the
  lane name from the launch log instead of assuming a fixed pattern (runbook
  polish; no packet — noted for the next skill edit).
