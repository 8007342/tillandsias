<!--
FILENAME COLLISION, resolved by macneo-macos 2026-09-12 as a UNION.

Two hosts independently created this same path for DIFFERENT reports of the
same release: the macOS-lane smoke (osx-next) and yoga-silverblue's
curl-install smoke (linux-next). Neither is a revision of the other and
neither was dropped; both are reproduced below verbatim, in full, under
their own original titles.

The collision itself is worth a packet: one filename per release per day is
not unique enough when several hosts smoke the same release on the same UTC
day. A host segment in the name (…-v56.9.11.1-<host>-2026-09-12.md) would
have avoided this. Filed as an observation rather than silently renaming,
because renaming here would diverge from the path trunk already carries.
-->

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

---

# Smoke E2E — release `v56.9.11.1`, macOS lane, 2026-09-12

PASS — `v56.9.11.1` on darwin 25.6.0, Apple Silicon (host `tlatoanis-macbook-air`,
bare-metal macOS workstation, branch `osx-next` at `cffa03101`): curl-install
clean, substrate destroyed with zero residue, `--provision` from pristine clean,
`--diagnose --json` green. No findings.

This is the first curl-install smoke of the published macOS artifacts since
2026-09-06. The `v56.9.11.1` ledger row itself records "no macOS/Windows host
smoke, both hosts down since 2026-09-06", so this run closes exactly the gap
that row names — for macOS only. Windows remains unsmoked and that release has
no Windows tray at all (1122-xi2f).

## Regime

- host_id `tlatoanis-macbook-air`, macos, bare-metal, kernel 25.6.0, Apple Silicon
- installed from the published release, NOT a local `target/` build
- artifacts exercised: `install-macos.sh`, `tillandsias-tray-56.9.11.1-macos-arm64.tar.gz`
- `Tillandsias.dmg` is PUBLISHED and was verified present on the release, but
  this lane installs via `install-macos.sh`, which takes the tarball. The DMG
  was NOT opened, mounted, or installed from. See NOT CHECKED below — the
  assignment named the DMG, and "published" is not "tested".

## Destructive-step authorization

This host is an operator workstation, not a dedicated smoke host. The substrate
destroyed by §2 held 13 GB of VM state (`rootfs.img`, a live guest, nvram) plus
a 1.6 GB model cache. Per the skill's own rule, the coordinator's instruction to
run the procedure was NOT treated as consent to destroy this machine; the
operator was asked directly and authorized the destruction for this run before
§2 executed.

## Steps

| Step | Result | Evidence |
|---|---|---|
| §0 ledger row | FOUND (exact row, not a distilled span) | `README.md:114` |
| §1 curl-install | PASS `install_exit=0` | `target/smoke-e2e/01-install-macos.log` |
| §1 sha256 | PASS `25f2ef9ec14a1639c3d55cb7673030c32aefe75062a488e2f1f99e543540724c` | same |
| §1 install path | PASS `/Applications`, no `~/Applications` fallback | same |
| §1 exact tag | PASS `tillandsias-tray 56.9.11.1 (git f1f7c01bc, built 2026-09-11T22:16:43Z)` | `01-version.txt` |
| §2 destruction | PASS, zero residue | `02-macos-residue.txt` |
| §3 provision | PASS `provision_exit=0` | `03-provision.log` |
| §3 freshness | PASS `rootfs.img` postdates the destruction marker — fresh, not a survivor | `03-destruction-marker` |
| §3 diagnose | PASS `diagnose_exit=0`; `provisioned==true`, `rootfs_present==true`, `version=="56.9.11.1"` | `03-diagnose.json` |
| §4 forge lane | NOT APPLICABLE — the `--opencode` forge lane is Linux/Podman | — |

The install re-downloaded and re-converted the 528 MB Fedora Cloud image from
nothing, so this was a genuinely cold provision. `guest_binary_staged_matches_bundle`
is `true`: the staged guest binary matches the bundle.

## Ledger claims

The `v56.9.11.1` row's claims, each under exactly one heading.

### EXERCISED

- **`635-bhkb` version truthfulness** (implicit in every row since): the tray
  reports `56.9.11.1`, not the frozen `0.1.0`, on BOTH surfaces — `--version`
  and the `.version` field of `--diagnose --json`. This is what makes every
  other assertion in this report attributable to a specific artifact.
- **`1109-t8kw` committable-branch fixture sets its own git identity**:
  `scripts/check-committable-branch.sh` ran green (`ok:branch-osx-next`) on this
  release's tree during the landing cycle that preceded this smoke.
- **`1116-vps5` `+x` restored on `finalize-cycle.sh`**: verified present in this
  tree — `-rwxr-xr-x scripts/finalize-cycle.sh`.
- **macOS install path and artifact integrity**: SHA256 verified by the
  installer against `SHA256SUMS-macos`; extraction to `/Applications` confirmed
  by assertion rather than assumption.

### NOT APPLICABLE

- **`1122-xi2f` Windows release placeholder / Windows job FAILED** — Windows lane.
- **forge `/home/forge/src` tmpfs mode 0777** (440cde994) — Linux forge container.
- **`1120-s3e5` three fixtures red in-gate only** — Linux gate lane.
- **`1119-w2rj` cloud-mode Observatorium leaf / `is_cloud` inference** — cloud lane.
- **`776-jcf3` host-checkout elimination for cloud launches** — cloud launch path;
  this lane performs no cloud launch.

### NOT CHECKED

These this lane could have reached and did not. Naming them is the point.

- **`Tillandsias.dmg`**. Verified present on the release; never mounted or
  installed from. The DMG is a SEPARATE install path from the tarball that
  `install-macos.sh` consumes, and a working tarball is not evidence for it.
  The assignment named the DMG explicitly, so this is the largest gap in the run.
- **`1122-6sqz` the release gate reinstalls the launcher on the host that runs
  it**. The gate log for this cycle carries only an ADVISORY naming the packet
  (`.git/tillandsias-land-gate-attempt-1.log:4096`), not a reproduction. This
  smoke reinstalled `/Applications/Tillandsias.app` by design, so a
  gate-caused launcher overwrite is not separable from the smoke's own install
  on this run. Reproducing it needs a cycle that gates WITHOUT installing.
- **`1074-96z9` memo-hit observability**, **`1105-h8vr` answer-rate fixture cost
  fix**, **`1114-p2ht` capability-manifest fixture isolation**, **`1025-a896`
  OAuth 10-token-cap**, **`1119-6wn6` sub-agent and token budget rules**,
  **`889` fragment ledger compaction**, **ephemeral-guarantee spec**,
  **`1080-4deb` ARM 1 ledger-write reachability gate step**. All are gate- or
  plan-layer claims checkable from this checkout; this lane exercised the
  release BINARY and did not run the gate suite against them.
- **Guest liveness**. `--diagnose` alone reports `guest_version: null` and
  `metrics_status: unsupported:no-live-wire-handle` BY DESIGN — those need
  `--with-metrics`, which boots the VM and is a mutating step, so the runbook
  puts it out of scope for the LAST health check. This run therefore proves the
  guest was PROVISIONED, not that it BOOTS AND REACHES READY. Given that
  `1084-x8ya` is open on exactly "provisioning completes but never reaches
  Ready", that distinction matters and this report does not claim otherwise.

## Observations (not findings)

- `kernel_present: false` / `initrd_present: false` in the diagnose report,
  alongside `rootfs_present: true` and `provisioned: true`. Expected for the
  qcow2 boot path (`release_tag: fedora-44`, `manifest_pin_aarch64_qcow2:
  55c60a3b80d3`); recorded so a future reader does not re-derive it.
- The DESTROYED substrate contained a `crashloop.state` dated 2026-09-11 18:44
  next to a heartbeat at 18:51. It was pre-existing state from before this run
  and was deleted by §2 before being read, so its contents are unrecoverable and
  no claim is made about them. Noted only because `1084-x8ya` concerns a guest
  that provisions but never reaches Ready; if that packet's investigation wants
  macOS crashloop evidence, this host no longer has any and a future run should
  read that file BEFORE §2.
