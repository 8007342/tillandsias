# Curl-install smoke — v56.9.11.1 — yoga-silverblue (Fedora Silverblue, immutable; Vulkan gfx1152 GPU lane, NPU blocked)

RESULT: **PASS through §4b** on the published Linux artifact. Steps 1, 2, 3 and
4b all green with assertions, not observations. §4 (forge lane) launched
correctly and ran; this host could not supervise it to completion — that is a
host-resource limit, recorded below and on 1026-ps4n, and **not** a defect in
the release.

- release under test: `v56.9.11.1` (daily channel)
- artifact: `https://github.com/8007342/tillandsias/releases/download/v56.9.11.1/tillandsias-linux-x86_64`
- host: yoga, Fedora Silverblue 7.2.4-200.fc44.x86_64, 14 GiB, immutable /usr
- regime: `linux_immutable`, locus bare-metal, legacy_tier gpu-rocm
- branch: linux-next; sibling heads at start — main f1f7c01bc, linux-next 7f0b2cd0f, windows-next 8831f561a, osx-next cffa03101
- operator authorization for the destructive reset: obtained for THIS run
  specifically (yoga is an operator workstation, not a dedicated smoke host —
  skill §DESTRUCTIVE / order 1004-vsh2). A future run needs it again.

## Step results

| step | verdict | evidence |
|---|---|---|
| §1 curl-install | PASS | `install_exit=0`; `tillandsias --version` -> `Tillandsias v56.9.11.1`, asserted against `$SMOKE_TAG` |
| §2 destructive reset | PASS | `reset_exit=0`; `podman ps -aq` / `volume ls -q` / `images -q` all EMPTY — clean room proven, not assumed |
| §3 init from pristine | PASS | `init_exit=0` on the detached relaunch; vault bootstrapped, 12 policies, AppRoles provisioned, `tillandsias-vault` healthy |
| §4 forge lane | LAUNCHED, UNSUPERVISED | six enclave containers up + healthy; in-forge agent honored the prompt (`Skill "meta-orchestration"`, then `forge-quick-intro`) |
| §4b egress (order 298) | PASS | `tillandsias-proxy` alive alongside the lane — non-regression confirmed by liveness, not by grepping the teardown trace |
| §4c final health | NOT TAKEN | deliberately withheld: §4c must be LAST after every mutating step, and the lane was still mutating. A health check taken mid-mutation is the 2026-08-10 incident. |

## Ledger claims (order 380)

Row read at `README.md:114`.

**EXERCISED**
- the release installs and self-identifies from a published artifact — §1, exact-tag assertion.
- a pristine `--init` reaches a healthy enclave — §3, from a provably empty store.
- forge `/home/forge/src` tmpfs 0777 so the forge clone no longer fails (440cde994) — §4: the forge container came up and the in-forge agent read the checkout and ran skills, which is the clone path working.
- order-298 proxy survival across lane bring-up — §4b.

**NOT APPLICABLE**
- Windows tray / 1122-xi2f: this release shipped no Windows tray (the Windows job failed); not reachable from Linux.
- macOS lane claims: covered by macbookair-macos and macneo-macos this cycle, not here.

**NOT CHECKED** — could have been reached from this lane and was not:
- cloud-mode Observatorium leaf + `is_cloud` inference (1119-w2rj, p1, shipped known-broken).
- credential guard's 401 remedy re-minting tokens (1119-9yjk).
- the three in-gate-only red fixtures (1120-s3e5).
- 1122-6sqz, the release gate reinstalling this host's launcher — relevant to this host and not probed.
- ledger-write reachability gate step / 1080-4deb arm 1.

## Findings

### Work Packet: smoke-finding/floor-host-cannot-supervise-any-attached-shell

- id: `smoke-finding/floor-host-cannot-supervise-any-attached-shell`
- owner_host: any
- capability_tags: [testing, podman, metrics]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.11.1`
- evidence:
  - four consecutive supervising shells killed for memory on this host while the
    enclave was up: (1) the original foreground `tillandsias --debug --init`,
    (2) a waiter running `podman ps` every 30s, (3) a waiter doing only
    `sleep 120`, (4) a waiter doing only `sleep 300`.
  - discriminators each time: `podman ps` -> containers UP (after §4) or EMPTY
    (during §3); `journalctl | grep -iE 'oom-kill|Killed process'` -> NO kernel
    oom-kill in every case; `free -g` -> 14 total / 7 available / 0 free with
    the lane up.
- repro:
  - on a 14 GiB host, run this skill's §4 forge lane and attach ANY supervising
    shell to it.
- next_action: >
    Record on 1026-ps4n that the floor limit is not about the supervisor's
    workload. That packet frames the loss as the smoke's WRAPPER being
    collateral, which invites "make the wrapper lighter" as a remedy; on yoga a
    shell doing nothing but sleep(300) was killed just as reliably as the one
    running the lane. The only thing that worked was `setsid` detachment, which
    rescued §3 on the first retry. The practical consequence for this runbook is
    that on a floor host §4 CANNOT be observed by a harness-tracked task at all,
    so `timing_begin`/`timing_reap` (order 1026-ps4n) is the only mechanism that
    can ever capture it — which is an argument for that design, measured.
- events:
  - type: discovered
    ts: `2026-09-12T02:14:34Z`
    agent_id: `linux-yoga-claude-20260912t013000z`
    host: yoga

### Work Packet: smoke-finding/4a-discriminator-returns-no-verdict-when-lane-dies-with-supervisor

- id: `smoke-finding/4a-discriminator-returns-no-verdict-when-lane-dies-with-supervisor`
- owner_host: any
- capability_tags: [testing, documentation]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.11.1`
- evidence:
  - skill §4a states: "Containers up **and** no kernel oom-kill means the
    supervisor was killed by the agent harness, not the product."
  - measured on yoga during §3: containers EMPTY and no kernel oom-kill. The
    rule's antecedent is false, so it yields no verdict for this state.
- repro:
  - kill the supervising shell of `tillandsias --debug --init` (not §4) on a
    memory-constrained host, then apply §4a's discriminator.
- next_action: >
    Add the second shape to §4a: "both gone, no kernel oom-kill" is also a
    host-resource event and also means unfinished-not-red. As written, a reader
    who finds an empty container list has no sanctioned reading and the obvious
    wrong one — that the release failed to bring the enclave up — is exactly
    what §4a exists to prevent. Note also that §4a is filed under §4 while this
    occurred at §3, so the runbook should say the floor can lose a supervisor at
    the pristine rebuild too, not only at the forge lane.
- events:
  - type: discovered
    ts: `2026-09-12T02:14:34Z`
    agent_id: `linux-yoga-claude-20260912t013000z`
    host: yoga

## Note on what this run does NOT establish

§4c was not taken, so this report does not claim a final clean health state; it
claims the enclave was healthy at §4b while the lane was up. The forge lane's
own findings (forge-internal stream) are not captured here because the lane was
still running when this report was written — `target/smoke-e2e/04-opencode.log`
is the record and any findings in it belong to a follow-up.

The GPU lane needs its inference image rebuilt before it will place again on
this host: `podman system reset --force` destroyed the Vulkan/gfx1152 image.
