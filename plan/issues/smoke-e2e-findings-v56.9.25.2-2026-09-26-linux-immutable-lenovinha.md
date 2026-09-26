# Smoke: curl-install v56.9.25.2 — Linux (immutable), lenovinha — 2026-09-26

- run_start: 2026-09-26T02:13:30Z
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-<ts>/)
- forge_lane_outcome: cold-host guard stop (EXPECTED PASS) — the lane brought the enclave up and stopped at the Credential Channel Guard with `blocked:upstream-no-credential`; NOT a completed cycle. The in-forge agent nevertheless made LOCAL commits after the stop (finding 2); none reached upstream.
- signature_verification: cosign:could-not-run:cosign-absent

**Verdict: PASS (signatures unverified: cosign absent on this host)**, with two findings filed below. Channel: `unstable`, installed with `--channel unstable` explicitly (1369-sjbc is not in this build). Operator authorized the destructive reset for this run.

## 1371-a7w2 — real-host closure evidence (the headline claim)

Precondition: the keyring held `vault-shamir-share-v1` before the run (`credential-warm`). The two entries were pre-cleared with `scripts/clear-vault-host-credentials.sh`. `scripts/probe-credential-cold-state.sh` then answered `credential-cold` ("no `vault-shamir-share-v1` entry for service `tillandsias` in the host keychain, and no fallback share on disk"). §1 then ran the curl installer, which calls `--reset-state` itself.

`target/smoke-e2e/01-install.log:41-42`, verbatim:

```
[tillandsias] cleared: keychain:vault-shamir-share-v1 (already absent) keychain:vault-root-token-v1 (already absent) file:fallback_vault-shamir-share-v1 (already absent) file:fallback_vault-root-token-v1 (already absent) dir:vault-data (already absent)
[tillandsias] --reset-state: cleared keychain:vault-shamir-share-v1 (already absent) keychain:vault-root-token-v1 (already absent) file:fallback_vault-shamir-share-v1 (already absent) file:fallback_vault-root-token-v1 (already absent) dir:vault-data (already absent)
```

The install then reprovisioned (images rebuilt, ending `tillandsias --tray` guidance) with **`install_exit=0`**. A second, independent observation after §2's `podman system reset --force`: an explicit `tillandsias --reset-state` printed the same line (`02b-reset-state.log:14`) with **`reset_state_exit=0`**, reprovisioning every image between 02:21Z and 02:26Z. An absent keychain entry is now read as already-absent, not as a failure, on a real host.

## Steps

| step | result |
|---|---|
| §0 ledger row | present: `\| v56.9.25.2 (daily) \|` (README.md:114) |
| §1 install | `install_exit=0`; `tillandsias --version` → `Tillandsias v56.9.25.2` |
| §1s signature | `cosign:could-not-run:cosign-absent` |
| §2 reset | `reset_exit=0`; `clear_exit=0` (`ok:clear-vault-credentials:nothing-to-clear (preserved: keychain:installation-uuid-v1)`); store empty (0 containers / volumes / images); `vault-data/` absent |
| §2b `--reset-state` | `reset_state_exit=0`; the rebuild of every image happened HERE |
| §3 `--init` | `init_exit=0` in ~5 s: the images were already fresh from §2b, so init only bootstrapped Vault (12 policies, `bootstrap complete`). 0 `localhost/` images predate run_start. |
| §3b shutdown | vault `exit=0` in 0 s; **dev-inference `exit=137` after the full 10 s grace** (finding 1) |
| §4 forge lane | `opencode_exit=0`; `blocked:upstream-no-credential` at 04-opencode.log:157 and :180 |
| §4a residue | `git_status_empty=yes` (host checkout), `mo_full_complete_present=no`, `mo_full_blocked_present=no`. `head_matches_origin=no` compares the HOST checkout with a trunk that moved during the run; it is not forge residue. |
| §4b egress | `egress assertion: proxy alive alongside lane` |
| §4c health | vault `"sealed":false` (v1.18.5); vault, proxy, router, and dev-inference Up; forge, git, and inference torn down by design; version `Tillandsias v56.9.25.2` |

Host notes: the operator's `tillandsias --tray` and a `--cloud … --antigravity` window were running at the start; the reset took their containers, with consent.

## Ledger claims (v56.9.25.2 row)

- **EXERCISED — 1371-a7w2** (Linux `--reset-state` refused on every clean host): see the section above, observed twice, both exit 0.
- **EXERCISED — the publish fix-forward of v56.9.25.1**: the unstable channel served v56.9.25.2, and the Linux asset installed and verified by SHA256 (the installer's own check).
- **NOT APPLICABLE — 1272-95ng** (nix `http2 = false` / `fallback = true` in the release workflow): a CI-side property; the published asset existing is its only observable here.
- **NOT CHECKED — 1248-j6vd** (GPU container start names its cause): this host's inference ran; no GPU start failure occurred to be named.
- **NOT CHECKED — 1369-a76a** (reset_state env tests serialized): a test-suite property, not visible to a curl-install.
- **Known, confirmed**: the unstable-URL installer defaults to STABLE (1369-sjbc); this run passed `--channel unstable` explicitly, as the row instructs.
- **Authenticity NOT established**: cosign is absent here, so no `.cosign.bundle` was verified (1273-4mak).

### Work Packet: smoke-finding/dev-inference-ignores-sigterm-exits-137-after-grace

- id: `smoke-finding/dev-inference-ignores-sigterm-exits-137-after-grace`
- owner_host: linux
- capability_tags: [podman, inference, containers, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.25.2`
- evidence:
  - `target/smoke-e2e/3b-shutdown.txt` — `tillandsias-dev-inference elapsed=10s grace=10s exit=137 oom=false`, beside `tillandsias-vault elapsed=0s grace=10s exit=0`
- repro:
  - `podman stop -t "$(podman inspect tillandsias-dev-inference --format '{{.Config.StopTimeout}}')" tillandsias-dev-inference; podman inspect tillandsias-dev-inference --format '{{.State.ExitCode}}'` → 137
- next_action: >
    Read the container's process tree BEFORE the stop (§3b's
    `podman exec … /proc/*/comm` loop) to see which pid is PID 1 and whether it
    forwards SIGTERM to the server. It is the same shape as 1134-u934 (vault:
    a PID-1 shell that trapped nothing, and `$!` naming the last stage of a
    backgrounded pipeline). Add a standing fixture like
    scripts/test-vault-shutdown-forwards-sigterm.sh for dev-inference.
- events:
  - type: discovered
    ts: `2026-09-26T02:26:16Z`
    host: linux

### Work Packet: smoke-finding/forge-agent-commits-after-the-credential-guard-stop

- id: `smoke-finding/forge-agent-commits-after-the-credential-guard-stop`
- owner_host: linux
- capability_tags: [forge, meta-orchestration, credentials, skills]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.25.2`
- evidence:
  - `target/smoke-e2e/04-opencode.log:157,180` — `blocked:upstream-no-credential` (the guard said stop before worker drain)
  - in-forge repo afterwards: `## linux-next...origin/linux-next [ahead 2]`, commits `e683e2d79 chore(opsx): sync generated openspec commands and skills` and the merge `dcf4369e2`, plus a ref `salvage/forge-tillandsias/20260926-opsx-sync-credential-blocked`
  - mirror `/tmp/git-push.log`: `2026-09-26T03:11:53Z [relay] HTTPS upstream credential is unavailable; run GitHub Login before pushing` / `[pre-receive] Push rejected`. Neither object exists on GitHub (`git cat-file -t e683e2d79` → not a valid object after a fetch), so upstream stayed clean.
  - unexplained, recorded rather than guessed at: the FORGE's own `~/.cache/tillandsias/git-push.log` line 1 reads `2026-09-26T02:59:22Z [pre-receive] Relay verified: upstream durably accepted the ref transaction`, which the mirror's log does not carry.
- repro:
  - a post-reset Linux host (Vault cold), `TILLANDSIAS_NO_TRAY=1 tillandsias . --opencode --prompt "Use the /meta-orchestration skill"`
- next_action: >
    The guard stop is supposed to precede ANY committable work (§4a-cold:
    "claimed nothing, drained nothing, filed nothing, committed nothing", measured
    on pirria 2026-09-14). This run's agent committed an opsx regeneration and
    tried to salvage it. Decide whether the skill should forbid local commits after
    a guard stop, or whether a salvage attempt is the sanctioned response. Then
    make §4a's residue check look INSIDE the forge (it currently checks only the
    host checkout, so this run's `git_status_empty=yes` was true and blind to it).
    Separately, attribute the 02:59:22Z "Relay verified" line.
- events:
  - type: discovered
    ts: `2026-09-26T03:13:43Z`
    host: linux
