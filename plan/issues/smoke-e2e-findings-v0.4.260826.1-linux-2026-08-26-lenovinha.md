# Linux (Silverblue) curl-install e2e — v0.4.260826.1 — independent second leg

discovered_by: `/smoke-curl-install-and-test-e2e` (linux_immutable), meta-orchestration
cycle lenovinha-opus5-20260826t025500z.
Host: **lenovinha** (Fedora Silverblue, `linux_immutable`), branch `linux-next`,
channel **daily**, resolved `channel:daily tag:v0.4.260826.1`.
Evidence: `target/smoke-e2e/` (host-local). Forge clone seed: `linux-next` at
`59ac801d98e1`, `behind=0`, `verdict=fresh`.

Deliberately **not** coordinated with yoga's Linux leg. Two independent
instruments on one platform answer a question one cannot.

## Run 2026-08-26T02:58Z→03:33Z — **PASS** (tag v0.4.260826.1, commit 341ab0010)

- **Step 1 curl-install**: `install_exit=0`. **Version assertion PASS** —
  `tillandsias --version` → `Tillandsias v0.4.260826.1`, containing the resolved
  tag, so the artifact under test is provably the published one (727-kmks).
  Installed to `~/.local/bin/tillandsias`.
- **Step 2 destructive reset**: `reset_exit=0`. **Empty-store assertion PASS** —
  containers, volumes and images all empty after `podman system reset --force`.
- **Step 3 cold init**: `init_exit=0`, 02:59:21Z→03:06:58Z (**~7m37s** from a
  wiped store). Every enclave image rebuilt at `v0.4.260826.1`; Vault
  bootstrapped with all twelve policies and every AppRole; `tillandsias-vault`
  `Up (healthy)`. No panics, no `Error:` lines, no short-name prompts, no
  non-zero container exits. The only matches on an error scan were HEALTHCHECK
  *definitions* (which contain `|| exit 1`) and chromium's own
  `Failed to connect to audit log, ignoring` — both benign.
- **Step 4 forge lane**: launched, ran healthy for the full 25 minutes.
  **Prompt honored** — the in-forge agent ran `/meta-orchestration` (17 matches),
  and the **MCP experts answered inside the forge**
  (`forge-plan_plan_next`, `forge-plan_plan_status`,
  `forge-plan_expert_capability`), which is the order-531 signal: experts that
  are *ready* and also *answering*.
- **Step 4b egress assertion (order 298)**: **PASS** — `tillandsias-proxy` alive
  alongside the lane container. Full stack up: vault, router, proxy,
  git-tillandsias, inference, tillandsias-forge.

### `opencode_exit=124` is MY bound, not a lane failure

The lane was cut off by my own `timeout 1500`, mid-work, while cargo tests were
passing. It is not a failure signal and must not be read as one.

---

## FINDING (confirms yoga's, and promotes it from host fact to platform fact)

### Work Packet: smoke-finding/podman-reset-does-not-reach-the-host-keychain

- id: `smoke-finding/podman-reset-does-not-reach-the-host-keychain`
- owner_host: linux
- capability_tags: [podman, vault, testing, release, linux]
- status: ready
- discovered_by: yoga on `v0.4.260826.1`; **independently reproduced here on a
  second Linux host with different keychain dates**
- evidence:
  - `target/smoke-e2e/02-empty-store.txt` — containers/volumes/images all empty
    after `podman system reset --force`
  - `target/smoke-e2e/03-init.log:3848` — `recovered Shamir unseal share from
    host keychain or fallback (v1, base64)`
  - `target/smoke-e2e/03-init.log:3850` — **`preserving existing data volume
    (Shamir share present in keychain)`**
  - keychain metadata, read via `busctl` Created/Modified properties only —
    **the secret value was never materialised** (`secret-tool search --all`
    prints it inline; two hosts learned that the hard way):
    `vault-shamir-share-v1` created **2026-07-08**, modified **2026-08-14**
- repro: `podman system reset --force && tillandsias --debug --init`
- next_action: >
    Decide which is true and make the other match. Either `--init` genuinely
    re-initializes Vault on Linux (and the keychain must be cleared as part of
    the reset, as Windows does under 804-ckst), or it legitimately preserves and
    `skills/smoke-curl-install-and-test-e2e/SKILL.md:52-53` must stop claiming
    the resync path "is part of what this smoke exercises". Today the runbook
    asserts the opposite of what the code does.

**WHY THE SECOND HOST MATTERS.** yoga saw a share created 2026-06-15 / modified
2026-07-16; this host's is created 2026-07-08 / modified 2026-08-14. Different
ages, different hosts, **same behaviour** — so this is a **platform property of
Linux, not a quirk of yoga's machine**. One data point could not have separated
those, which is exactly why the second leg was worth running after the gate was
already satisfied.

**LIMIT ON THIS LEG, volunteered:** like yoga's, this run was **not
credential-cold**. Linux has no equivalent of Windows' 804-ckst credential
purge, so the keychain↔volume resync brick remains **unexercised on Linux** by
either leg.

---

## FINDING (harness, new)

### Work Packet: smoke-finding/in-forge-agent-cannot-record-ledger-events

- id: `smoke-finding/in-forge-agent-cannot-record-ledger-events`
- owner_host: any
- capability_tags: [forge, plan, tooling]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260826.1`
- evidence:
  - `target/smoke-e2e/04-opencode.log:1150` — `error: ledger event has no
    --agent and TILLANDSIAS_AGENT_ID is unset — refusing to record agent_id
    'unknown'. Derive the id from scripts/agent-identity.sh (order 756-hn3a)`
- repro: launch the forge lane and have the in-forge agent append a ledger event
- next_action: >
    The forge does not export `TILLANDSIAS_AGENT_ID`, so an in-forge agent's
    first ledger write is refused. The refusal is correct and well-worded — it
    names the remedy — but every in-forge cycle pays the same discovery. Export
    it at forge launch (derived via `scripts/agent-identity.sh`), or have the
    forge startup context state it. Note the interaction with §"THIS CHECKOUT IS
    EPHEMERAL": an agent that cannot record events is one teardown from losing
    them.

---

## NOT FINDINGS — two apparent failures, correctly attributed

Both were the **in-forge agent's own work-in-progress**, interrupted by my
timeout. Recording them so nobody re-files them as release or trunk defects.

- `04-opencode.log:2127` — `tray::tests::unobserved_login_renders_disabled_checking_row`
  panicked at `tray/mod.rs:6187` <!-- cite-ok: the DIVERGENCE between two line numbers IS the evidence; the symbol is named below and is identical in both trees, so a symbol-only citation cannot express it -->
  — the symbol is `fn unobserved_login_renders_disabled_checking_row`, which on
  trunk sits at a *different* line. **Measured here on the same commit
  (`59ac801d9`), clean tree: `cargo test -p tillandsias-headless --bin
  tillandsias` → 420 passed, 0 failed.** What proves the in-forge tree was
  edited is that the same symbol reports a different line there than here —
  precisely the thing a symbol-only citation cannot say, because the symbol is
  what did *not* change.

- `04-opencode.log:2678` — `E0063: missing field 'full_name' in initializer of
  ProjectEntry`. **`full_name` does not exist on trunk's `ProjectEntry`** — the
  agent added it and had not finished updating initializers when the bound hit.
- `04-opencode.log:1896` — `build.rs` panic, `required runtime asset missing:
  images/router/tillandsias-router-sidecar`. This is **fail-loud working as
  designed** (710-w9kc): the message states it is a build artifact, never
  committed, absent from a fresh clone, and names `scripts/build-sidecar.sh`.
  Not a defect; noted because every in-forge cycle on a fresh clone meets it.

## PASS entry

`v0.4.260826.1` — Linux (Silverblue, linux_immutable) curl-install PASS:
install_exit=0, version assertion PASS, destructive reset clean with empty-store
assertion, cold init clean in ~7m37s, forge lane healthy with prompt honored and
in-forge MCP experts answering, order-298 egress assertion PASS. Two findings
filed; two apparent failures attributed to in-forge agent WIP and not filed.
Not credential-cold — see the limit above.
