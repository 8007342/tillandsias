# linux-immutable curl-install e2e smoke — PUBLISHED v0.4.260815.1 (yoga)

- **Host:** yoga (Fedora Silverblue 44, linux_immutable) — the fleet's primary-methodology host
- **Agent:** linux-yoga-claude-20260816t185912z (yoga meta-orchestration cycle, 2026-08-16)
- **Channel:** daily — `scripts/resolve-smoke-release.sh daily` → `tag:v0.4.260815.1`
  (stable still resolves v0.4.260810.1; the release is a prerelease, pinned via
  `TILLANDSIAS_RELEASE_BASE` exactly as the runbook prescribes)
- **Sibling heads at start:** main 0548ee1f2 · linux-next 35a8ca020 ·
  windows-next e63628484 · osx-next 04ee0711c
- **Substrate destroyed:** full `podman system reset --force` — all containers,
  images, volumes (incl. `tillandsias-mirror-*`, vault data volume), and the
  operator's toolboxes (ruled ephemeral/idempotent; recreated post-smoke)

## Step 1 — curl-install from the published release — **PASS**

- `install.sh` fetched via the pinned base under the smoke lock; `install_exit=0`.
- **Version proof (727-kmks assertions live):** `tillandsias --version` →
  `Tillandsias v0.4.260815.1`, grep-matched against the resolved tag.
- Evidence: `target/smoke-e2e/01-install.log`, `01-version.txt`.

## Step 2 — destructive substrate reset — **PASS**

- `podman system reset --force` under the smoke lock, `reset_exit=0`.
- Post-reset store asserted EMPTY (containers/volumes/images all zero rows).
- Evidence: `target/smoke-e2e/02-reset.log`, `02-empty-store.txt`.

## Step 3 — pristine `--init` — **PASS**

- `tillandsias --debug --init` exit 0 in ~4 minutes on this host (dev proxy
  cache warm): proxy, git, vault, inference, chromium-core, forge images all
  built; enclave network up; Vault initialized, unsealed, and bootstrapped
  (12 policies + AppRole roles provisioned, keychain share captured — no
  738059bc-class brick).
- Notables, none filed as findings: IPv6 probe failed → documented
  `--ipv4-only` pasta self-heal; `podman image failed: status=1` lines are the
  expected pre-build existence probes; chromium dnf `audit log` lines benign.
- Evidence: `target/smoke-e2e/03-init.log` (3862 lines), `03-init-exit.txt`.

## Step 4 — forge lane: BigPickle FULL `/meta-orchestration` cycle

- Launched under the smoke lock with `TILLANDSIAS_NO_TRAY=1
  tillandsias . --opencode --prompt "Use the /meta-orchestration skill"` —
  the FULL prompt per operator directive; `full-meta` rate-limit stamp
  recorded before launch (window 4h).
- Lane bring-up: shared-stack idempotency wipe ran first (order 298 order
  correct), project cloned from the per-project mirror
  (`tillandsias-git-tillandsias` — post-659 identity), agent **big-pickle**
  started and immediately invoked the meta-orchestration skill.

### Step 4b — first-launch egress assertion (order 298) — **PASS**

- With the lane container up: `tillandsias-proxy` alive alongside
  `tillandsias-tillandsias-forge`, `tillandsias-git-tillandsias`,
  `tillandsias-inference`, `tillandsias-router`, `tillandsias-vault`.
- Evidence: `target/smoke-e2e/04b-containers.txt`.

### In-forge cycle outcome — **RAN TO ATTESTED COMPLETION, disposition BLOCKED (by design)**

BigPickle honored the FULL prompt and ran the complete cycle discipline
end-to-end inside the published artifact:

- **Experts:** in-forge plan/project experts registered and answered
  57/57 calls (`answer_rate=100%`), groundtruth `expert_accuracy` 21/21
  (`rate=100%`), `mcp: health=ok`. The forge-local-experts Direction works
  in the released artifact on a pristine substrate.
- **Guards:** preflight `ok:cycle-preflight:rebuilt`, branch
  `ok:linux-next`, expert base ok — then the Credential Channel Guard
  fail-closed on `blocked:upstream-auth-unpublished` (mirror reachable, but
  the container publishes no `refs/tillandsias/upstream-auth/*` verdict ref
  — the v0.4.260815.1 git image predates order 756-2jnj's probe). Worker
  drain, batch triage, and nested e2e correctly refused.
- **Fail-loud done right:** it updated
  `plan/issues/blocker-git-mirror-upstream-auth-denied-2026-08-16.md` with
  the 20:24Z verdict variant, filed
  `plan/issues/optimization/cargo-lock-stale-metrics-podman-dep-2026-08-16.md`
  (a real drift this host's cycle introduced minutes earlier — caught and
  lockfile-synced by the forge), and pushed 3 commits
  (`e1585de6`, `2a9dff4e`, `58365aed`) through the mirror relay with
  upstream `ls-remote` convergence.
- **Key diagnosis (advances the morning blocker):** the sanctioned pushes
  SUCCEEDING proves the mirror→upstream credential is write-authorized NOW —
  the morning's 403 is resolved/transient. The residual defect is only the
  missing verdict-ref publication. Smallest next action (operator): rebuild/
  restart the `tillandsias-git` container so `probe-upstream-auth` publishes
  an `authorized/<epoch>` ref.
- **Attestation:** finalization gates green in-forge (93s `--check`,
  boundary verified, `check-forge-findings-persisted.sh ok`, 53 ledger
  markers verified) and the terminal marker emitted + ledgered:
  `MO-FULL: BLOCKED 58365aed... linux-next 58365aed...` — a
  guard-blocked cycle with a valid attestation is the loud, correct shape.
- Evidence: `target/smoke-e2e/04-opencode.log` (1392 lines);
  `plan/loop_status.d/20260816t202700z-380389fb-forge.md`;
  `plan/mo-full-attestations.d/` forge ledger.

No harness findings: the lane launched, honored the prompt, tore down clean
(exit 0), and every issue it hit was filed by the in-forge agent itself and
pushed durably — the exact behavior order 741-3y48 exists to guarantee.

## Verdict summary

| Step | v0.4.260815.1 on yoga |
|------|------------------------|
| 1 curl one-liner (pinned, version-asserted) | PASS |
| 2 destructive reset (empty-store asserted) | PASS |
| 3 pristine init (images + vault from nothing) | PASS |
| 4 forge lane launch + agent + prompt honored | PASS |
| 4b egress invariant | PASS |
| in-forge full-meta cycle | RAN + ATTESTED (BLOCKED at credential guard, by design; blocker advanced with push-works evidence) |

**PASS entry:** release v0.4.260815.1 — install clean, reset clean, init
clean, forge lane clean; the only red is the known operator-owned mirror
verdict-publication gap, which this run narrowed from "403 denied" to
"publication missing, credential proven good".
