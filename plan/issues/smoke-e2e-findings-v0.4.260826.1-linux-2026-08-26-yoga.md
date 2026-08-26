# Linux (Silverblue) curl-install e2e — v0.4.260826.1

## Run 2026-08-26T02:55Z→03:25Z — **PASS** (tag v0.4.260826.1, commit 341ab0010)

- **Host:** yoga — Fedora Silverblue 44, `linux_immutable`, AMD Ryzen AI 5 340, 14 GiB, btrfs
- **Channel:** daily (prerelease) · `scripts/resolve-smoke-release.sh daily` → `tag:v0.4.260826.1`
- **Artifact:** `tillandsias-linux-x86_64`, curl-installed from the published release. **No local build used at any point.**
- **Skill:** `/smoke-curl-install-and-test-e2e` (the only e2e install skill permitted on immutable Linux)
- **Falsifiers pre-registered in git at `9fbe0e935`, BEFORE the tag existed.**

**PASS covers:** install, destructive reset, cold `--init`, forge lane launch, first-launch egress.
**PASS does not cover:** anything requiring a second host, the promoted stable channel, or the
version-skew warning path (see falsifier 6 — NOT ruled out).

## Lane results, raw

| step | command | exit | evidence |
| --- | --- | ---: | --- |
| 1 install | `curl … install.sh \| … bash` | **0** | `01-install-exit.txt`, `01-version.txt` |
| 1 version | `tillandsias --version` | 0 | `Tillandsias v0.4.260826.1` — exact-tag match |
| 2 reset | `podman system reset --force` | **0** | `02-reset-exit.txt`, `02-empty-store.txt` |
| 3 init | `tillandsias --debug --init` | **0** | `03-init.log` (3882 lines, 7m30s) |
| 4 forge | `tillandsias . --opencode --prompt …` | **0** | `04-opencode.log` |
| 4b egress | proxy alive alongside lane | ok | `04b-containers.txt` |

Substrate, measured either side of the reset:

```
pre-reset   containers=2  images=16  volumes=3   (8.335 GB)
post-reset  containers=0  images=0   volumes=0
post-init   containers=1  images=15  volumes=2   vault healthy (initialized=true sealed=false v=1.18.5)
```

`--init` scan: **0** panic lines, **0** `Error:` lines, **0** non-zero container exits.

## Falsifier results — all six, including the one I could not rule out

1. **A `--version` assertion that cannot fail** — RULED OUT. Asserted the exact tag `0.4.260826.1`,
   and separately asserted the version *changed* from the pre-install `v0.4.260823.1` recorded in
   the pre-registration. A no-op install would have failed the second check.
2. **Destruction that removed nothing** — RULED OUT. Pre-reset store was non-empty
   (2 containers / 16 images / 3 volumes / 8.3 GB) and post-reset was 0/0/0. The pre-commitment
   was to report idempotence UNPROVEN had the store been empty; it was not, so the claim stands.
3. **`--init` exiting 0 without provisioning** — RULED OUT by positive post-conditions: 15 images
   built from an empty store, Vault container running and healthy.
4. **A health check predating the last mutating step** — RULED OUT, **and it fired.** See F2 below.
   The earlier reading (all containers up) was stale within minutes.
5. **A `curl | bash` that half-failed** — RULED OUT. `${PIPESTATUS[0]}` captured at every stage;
   `install_exit=0` recorded separately from the pipeline.
6. **A guest/tray version skew that no longer warns** — **NOT RULED OUT.** A single-version install
   produces no skew, so the warning path was never exercised. Recording this as unruled-out rather
   than omitting it; it needs a deliberately skewed guest to test.

## Findings

### Work Packet: smoke-finding/linux-clean-room-keeps-host-keychain-share

- id: `smoke-finding/linux-clean-room-keeps-host-keychain-share`
- owner_host: linux
- capability_tags: [vault, podman, testing, release]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260826.1`
- evidence:
  - `target/smoke-e2e/03-init.log:3834` — `recovered Shamir unseal share from host keychain or fallback (v1, base64)`
  - `target/smoke-e2e/03-init.log:3836` — `preserving existing data volume (Shamir share present in keychain)`
  - host secret-service entry `vault-shamir-share-v1@tillandsias:default` — **created 2026-06-15, modified 2026-07-16** (secret value redacted, not recorded)
- summary: >
    The Linux lane's "clean room" is not cold. `podman system reset --force` destroys the podman
    store including `tillandsias-vault-data`, but the HOST keychain is untouched, so vault
    bootstrap recovers a Shamir share that on this host was over a month old and re-uses it.
    This is the Linux analogue of 804-ckst, which added exactly this step to the Windows branch
    (`cmdkey /delete` for `vault-shamir-share-v1` and `vault-root-token-v1`). The Linux branch of
    the runbook has no equivalent.
- and the runbook asserts the opposite: >
    SKILL.md:52-53 states "A fresh `--init` re-initializes Vault and re-captures the keychain-held
    unseal share, so the keychain-volume resync brick is part of what this smoke exercises."
    Measured: it did not re-initialize, it RECOVERED and PRESERVED. The stated rationale for the
    Linux lane is false, so the resync path this smoke claims to cover has never been covered here.
- repro: >
    `secret-tool search --all service tillandsias` after `podman system reset --force` — the share
    survives. Then `tillandsias --debug --init` and grep the log for "recovered Shamir unseal share".
- next_action: >
    Add a keychain-clearing step to the Linux branch of Step 2, mirroring the Windows block, and
    correct the SKILL.md:52-53 claim. Decide deliberately whether `vault-unseal-v1` /
    `vault-shamir-share-v1` should be cleared (cold-room fidelity) or preserved (install-anchored,
    the reason Windows keeps `tillandsias-vm-uuid`) — the answer may differ per key.

### Work Packet: smoke-finding/status-check-kills-the-container-it-says-it-keeps

- id: `smoke-finding/status-check-kills-the-container-it-says-it-keeps`
- owner_host: linux
- capability_tags: [rust, podman, vault, fail-loud]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260826.1`
- evidence:
  - `target/smoke-e2e/05-status-post.txt:1` — `cleaning project + shared stack … keeping application-lifetime: tillandsias-vault, tillandsias-proxy, tillandsias-router, tillandsias-nix-cache`
  - `target/smoke-e2e/05-status-post.txt:2` — `WARNING: status-check mirror service-identity provisioning skipped: Vault container is not running`
  - `podman ps -a` one second later — `tillandsias-vault  Exited (137)`; `tillandsias-router` absent entirely
  - `status_check_rc=0`
- summary: >
    `tillandsias --status-check` logs that it is KEEPING `tillandsias-vault` and
    `tillandsias-router` as application-lifetime containers, then vault exits 137 (SIGKILL) and
    router disappears. In the same run it warns that Vault is not running — so it observes the
    consequence of its own teardown and still exits 0. A health check that reports success on an
    end state it just broke.
- why it matters: >
    Found only because the e2e pre-registered "re-run the health check after the LAST mutating
    step" (the 2026-08-10 lesson). The reading taken minutes earlier showed all containers up. Any
    operator running `--status-check` to confirm health leaves the enclave in a worse state than
    they found it, and is told everything completed.
- repro: `tillandsias --status-check; podman ps -a --format '{{.Names}}\t{{.Status}}'`
- next_action: >
    Determine whether the application-lifetime keep-list is being computed and then not honoured,
    or honoured against a stale container set. Then make `--status-check` exit non-zero when it
    emits a Vault-not-running warning — the warning and the exit code currently disagree.

### Work Packet: smoke-finding/forge-agent-launches-in-read-only-plan-mode

- id: `smoke-finding/forge-agent-launches-in-read-only-plan-mode`
- owner_host: linux
- capability_tags: [forge, opencode, harness]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260826.1`
- evidence:
  - `target/smoke-e2e/04-opencode.log:221` — `**I am in READ-ONLY / Plan Mode** — I cannot execute any of these steps`
  - `target/smoke-e2e/04-opencode.log:233` — `To execute this cycle, exit Plan Mode and re-invoke the skill.`
- summary: >
    The forge lane launched, the prompt was honoured and the agent invoked `/meta-orchestration` —
    then reported it was in read-only/plan mode and executed nothing. Step 4's stated purpose is a
    continuous-enhancement run inside the forge; it produced a plan instead. The step exits 0, so
    a smoke that only checks exit codes records this as a successful forge run.
- repro: `tillandsias . --opencode --prompt "Use the /meta-orchestration skill"` and read the tail.
- next_action: >
    Determine whether plan mode is the forge harness default or was inherited from the launching
    context, then either launch the in-forge agent in execute mode or assert on the log that work
    occurred, so a plan-only run cannot pass as a forge run.

### Work Packet: smoke-finding/diagnostics-flag-hangs-instead-of-refusing

- id: `smoke-finding/diagnostics-flag-hangs-instead-of-refusing`
- owner_host: linux
- capability_tags: [rust, cli, fail-loud]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260826.1`
- evidence:
  - `tillandsias --diagnose` → `Unsupported option: --diagnose`, exit 2, immediate (correct behaviour)
  - `tillandsias --diagnostics` standalone → no output, **still running at 600s**, killed by timeout
  - `tillandsias --help` shows `--diagnostics` only as a modifier: `--opencode <project> [--debug|--diagnostics]`
- summary: >
    `--diagnostics` is a lane modifier, not a standalone command. Invoked standalone it HANGS
    silently instead of refusing. Its sibling `--diagnose` refuses correctly in milliseconds. An
    operator reaching for the wrong health flag — as this run did — waits indefinitely with no
    output rather than being told the flag needs a lane.
- repro: `timeout 30 tillandsias --diagnostics; echo $?`
- next_action: >
    Refuse standalone `--diagnostics` with the same shape as `--diagnose` (named error, exit 2,
    pointer to `--status-check`).

## Observations, not findings

- **Cold `--init` took 7m30s** on this host (empty store → 15 images, Vault bootstrapped). Useful
  as a floor figure for immutable Linux; not a defect.
- **The release build took ~36 min** for the Linux job versus ~15 min for v0.4.260817.1
  (reported by the coordinator, not measured here). Consistent with a Nix cache miss across the
  commit range. Recorded as an observation about the release path.
- **This run destroyed `tillandsias-builder`**, the toolbox `./build.sh` re-execs into on
  Silverblue, as predicted in the pre-registration. That is the reset working, not a defect, but it
  means an immutable-Linux host cannot gate or push for ~2.5 min after this smoke.

## Provenance note

Before this run the host carried `v0.4.260823.1` — **a version published as no release**, whose
provenance was an unrecorded local install. It was recorded in the pre-registration as
provenance-less and was NOT counted as coverage. The install asserted the version changed away
from it, which is the only role it played.

This report inherits nothing. It names one tag, one platform, one host, and one run.
