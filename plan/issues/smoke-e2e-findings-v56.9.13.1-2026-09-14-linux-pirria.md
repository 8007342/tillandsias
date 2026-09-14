# Smoke e2e findings — v56.9.13.1 — 2026-09-14 — linux / pirria

- release under test: `v56.9.13.1` (daily channel; asserted newest including
  prereleases at resolve time — `gh api .../releases | .[0]` returned
  `v56.9.13.1 prerelease=true`)
- release base: `https://github.com/8007342/tillandsias/releases/download/v56.9.13.1`
- host: pirria (mutable Linux, CachyOS, kernel 7.2.4-3, 15 GiB / 4 cores, Podman rootless)
- branch: `linux-next`
- skill: `/smoke-curl-install-and-test-e2e`
- agent: `linux-pirria-opus5-20260914t192603z`
- authorization: operator authorized this run's destructive reset (relayed by the
  macuahuitl coordinator in the operator's words, 2026-09-14: "Yes I've authorized
  pirria to run system reset as per your directions"), and the operator's own
  standing instruction to this session at start. pirria is an operator workstation,
  not a dedicated smoke host, so per-run consent was required (1004-vsh2) and obtained.

## Sibling heads at run start

```
main           6b8342f3f
linux-next     4b5593c4e
windows-next   0fbc3ba95
osx-next       996b97c00
```

## Result: PASS with three findings

v56.9.13.1 curl-installs, resets, and re-initializes from a genuinely cold room
on this host. `init_exit=0`, Vault re-initialized rather than recovering a stale
share, the §3b shutdown assertion is green, the forge lane came up and exited 0,
and the final health check passes. Three findings below. The first had to be
worked around by hand for the run to be a valid clean-room test at all; the third
bounds what the §4 lane can honestly claim to have covered.

The one-line PASS for the convergence record: **v56.9.13.1 — curl-install clean,
cold-room init clean, forge lane clean, health check clean on linux/pirria.**

## Step record

| step | outcome |
|---|---|
| §0 credential preflight | `ok:gh-keyring-push-verified` |
| §0.2b ledger row | present for `v56.9.13.1` (README.md:114), not a distilled span |
| §1 curl install | `install_exit=0`; `tillandsias --version` → `Tillandsias v56.9.13.1`, bounded match PASS |
| §2 podman system reset --force | `reset_exit=0`; containers/volumes/images all empty |
| §2 clear-vault-host-credentials.sh | `clear_exit=0` but **`warn:clear-vault-credentials:partial`** — see finding 1 |
| §2 cold-state probe | pre-reset `credential-warm`; post-reset + manual fix `credential-cold` |
| §3 init from pristine | `init_exit=0`; Vault `initialized=true sealed=false v=1.18.5` |
| §3b shutdown | 1 container, `tillandsias-vault elapsed=1s grace=10s exit=0 oom=false` — 0 unclean |
| §4b egress assertion | proxy alive alongside lane (6 containers up at 2026-09-14T19:44:49Z) |
| §4 forge lane | `opencode_exit=0`; in-forge agent reached a correct fail-loud stop — see finding 3 |
| §4c health check | rc=0; `sealed=false` PASS, proxy up PASS; `Tillandsias v56.9.13.1` |

Health check taken LAST, after every mutating step, per the 2026-08-10 rule.
Application-lifetime set up (`tillandsias-vault`, `tillandsias-proxy`,
`tillandsias-router`, all Up 13 minutes, vault and proxy healthy); lane-scoped
set (`tillandsias-inference`, `tillandsias-git-tillandsias`,
`tillandsias-tillandsias-forge`) gone, which is the pass, not a finding. Vault
reported `{"initialized":true,"sealed":false,"standby":false,...,"version":"1.18.5"}`.

## Timing records emitted (phase=smoke, host=pirria, all exit=0)

| step | duration |
|---|---|
| `smoke-curl-install` | 262.6s |
| `smoke-destructive-reset` | 20.8s |
| `smoke-init-pristine` | 439.9s |
| `smoke-forge-lane` | 822.9s (13m43s) |
| `smoke-health-check` | 0.2s |

`timing_reap` at §0 emitted no `-supervisor-lost` record, so the previous run on
this host did not leave an orphaned stamp. The lane was run detached with
`setsid nohup` per §4a, on the 15 GiB / 4-core host that section names as the
measured boundary; the supervisor survived this time, and the lane's 13m43s is
well under the 71m30s recorded on the same host on 2026-09-04 — the substrate
was already warm from §3's build, which is the difference.

`TILLANDSIAS_RESET_KEEP_MODELS` was unset and is a documented no-op on Linux —
the podman reset and the credential clearer never touch
`~/.cache/tillandsias/models`. Recorded and moved past, per the runbook.

## Ledger claims

The row for `v56.9.13.1` is a large one; it is accounted for here in three
headings, and the NOT CHECKED list is the point of the section.

### EXERCISED

- **900-z3kv — "the documented Linux reset now clears the host-held Vault
  credentials so the clean room is credential-cold for the first time since
  June."** This is the claim this lane exists to check, and it is the one claim
  on the row that this lane can check better than any other host. Result:
  **the end state works and the mechanism is incomplete.** Pre-reset the probe
  read `credential-warm` (no keychain entry, but
  `~/.cache/tillandsias/fallback_vault-shamir-share-v1` dated 2026-09-01 — the
  exact 1149-vgn2 shape this host was the original witness for). The clearer
  removed both fallback files and could not remove `vault-data/`; after the
  manual removal in finding 1 the probe read `credential-cold`, and `--init`
  then logged `Shamir share not found; deriving first-boot dummy key K`,
  `fresh-init handover present; capturing root token + Shamir share into
  keychain`, `vault healthy (initialized=true sealed=false)`. So the resync
  path was genuinely exercised here — the first time on this host — but only
  after a hand fix. See finding 1.
- **1149-vgn2 — the cold probe now checks the fallback share, not the keychain
  alone.** Verified working from both sides on the host that motivated it: the
  pre-reset verdict named the fallback file and its date and refused to certify
  cold; the post-clear verdict named everything it checked. A keychain-only
  probe would have called this host cold at both points.

### NOT APPLICABLE

- Windows claims: 1172-dyvd (yolanda's capability row, Radeon 860M/NPU),
  1171-ccf2 (the Windows zip missing `tillandsias-headless.exe`), the Windows
  probe's staleness-by-vocabulary refusal.
- macOS claims: 1135-z8gn (`clamp-ca-material.sh` inert on BSD stat),
  1137-rgfm (accel probe `name_source`).
- Silverblue claims: 1165-g6wx (akmods depsolve skew probe) — pirria is CachyOS,
  a mutable host, and cannot exhibit the immutable-host condition.
- Coordination/ledger-tooling claims that are not properties of a published
  artifact and cannot be observed from an install-and-run lane: 1164-cftu
  (land-tool push retry), 1119-6wn6 (loop token counter), 1144-jfr5 (stale-ready
  reconciliation), 1141-vf9w / 1150-q462 (competing-gate detector), 829-dkuc
  (de-slop sweep), 1156-eif4 / 1157-ghmi / 1158-y3ad (compaction), 1146-z8ux,
  1146-8j7i, 1148-3439, 1161-42pc, 1118-bscs, 1166-99mk…1169-zw44, 1076-kft9,
  1140-d6ni.

### NOT CHECKED

These this lane could have reached and did not. Naming them is what keeps the
PASS above narrow and true.

- **1139-xe5m** — the capability envelope naming whether a value was measured or
  served. Reachable from inside the forge via the expert/capability surface; the
  lane brought the forge up and did not query it.
- **1154-8ywc / 1165-xkjh** — the capability-row guard no longer failing open on
  age, and `stale:capability-row-expired` appearing where
  `ok:capability-row-reported` used to. Checkable on this host by running the
  capability-row probe; not run.
- **1118-dwgx** — browser enclave host-network default. The chromium images
  built during `--init` (`tillandsias-chromium-core`,
  `tillandsias-chromium-framework`) and the setting was never inspected.
- **1159-g96c** — known-and-unfixed on the row (`due:no-capability-row` from a
  third context on a two-locus host). Not probed here; pirria's context count
  was not established.
- **1175-wuwr** — `litmus:ensure-toolbox-include-shape` step 5, the check that
  went red during this release's own gate and was fixed forward. Not re-run on
  this host, and this host lacks `yq` (see the note below), so a re-run here
  would carry that caveat anyway.

## Note on yq, carried from the same host's 1187-iij8 measurement

`yq` is not on PATH on pirria and cannot be provisioned here: the
`with-tillandsias-builder.sh` toolbox route is Silverblue-only and passes
through on CachyOS, and a package install needs a sudo password this session
does not hold. It does not affect any assertion in this report — no step of
this runbook shells out to `yq` — but any litmus count taken on this host
carries `warn:litmus-degraded-no-yq` and should say so.

---

### Work Packet: smoke-finding/clear-vault-credentials-cannot-remove-subuid-owned-vault-data

- id: `smoke-finding/clear-vault-credentials-cannot-remove-subuid-owned-vault-data`
- owner_host: linux
- capability_tags: [vault, podman, release, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.13.1`
- summary: >
    `scripts/clear-vault-host-credentials.sh` cannot remove
    `~/.cache/tillandsias/vault-data` on a rootless-Podman host — the directory is
    written from inside the container under a subuid and a rootless `rm -rf` is
    refused — so it prints `warn:clear-vault-credentials:partial` and exits 0. The
    remedy that does work, `podman unshare rm -rf`, is available on the same host
    and the script does not attempt it. Without a hand fix the room is not cold and
    900-z3kv's claim is not exercised, while every exit code in the run reads clean.
- evidence:
  - `target/smoke-e2e/02-reset.log` — `WARNING: could not remove vault-data/ (it is written from inside a container under a subuid; a rootless rm may be refused)`
  - `target/smoke-e2e/02-reset.log` — `warn:clear-vault-credentials:partial (cleared: file:fallback_vault-shamir-share-v1 file:fallback_vault-root-token-v1 failed: dir:vault-data) — the room is NOT cold; a partial clear is the state that looks clean and is not`
  - `target/smoke-e2e/02-clear-exit.txt` — `clear_exit=0`
  - `target/smoke-e2e/02-vault-data-dir.txt` — the surviving tree, `drwxr-xr-x 1 100100 lapto` (subuid-owned), with `audit/ auth/ core/ logical/ sys/` intact
  - `target/smoke-e2e/02-empty-store.txt` — containers, volumes and images all empty in the same breath, which is the shape that makes this invisible
- repro:
  - `podman system reset --force && scripts/clear-vault-host-credentials.sh && ls -la ~/.cache/tillandsias/vault-data`
  - on a rootless host the directory survives and the script still exits 0
- verified_remedy:
  - `podman unshare rm -rf ~/.cache/tillandsias/vault-data` removed it cleanly
    (rc=0) and `scripts/probe-credential-cold-state.sh` flipped from
    `credential-warm` to `credential-cold` immediately afterwards
- next_action: >
    In `scripts/clear-vault-host-credentials.sh`, retry the `vault-data` removal
    through `podman unshare rm -rf` when the direct `rm -rf` is refused and podman
    is available, then re-test the path before declaring success. Keep the
    `warn:…:partial` line for the case where both fail. Consider whether exit 0 is
    right for a partial clear at all — the runbook already has to tell readers not
    to trust the exit code here, which is a sign the exit code is wrong rather than
    a sign readers need more instructions. Note that the three `test -z` store
    assertions all pass while this is broken, so the guard has to be the clearer's
    own last line or an explicit `test ! -e` on the directory.
- events:
  - type: discovered
    ts: `2026-09-14T19:34:30Z`
    agent_id: `linux-pirria-opus5-20260914t192603z`
    host: linux

### Work Packet: smoke-finding/smoke-evidence-dir-is-never-cleared-between-runs

- id: `smoke-finding/smoke-evidence-dir-is-never-cleared-between-runs`
- owner_host: any
- capability_tags: [testing, release, fail-loud]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.13.1`
- summary: >
    §0.4 of the runbook creates `target/smoke-e2e` with `mkdir -p` and nothing ever
    clears it, so a run inherits every evidence file from every previous run. A step
    that does not reach its write leaves the PREVIOUS run's file in place under the
    exact name the report and any out-of-band check will read — a stale PASS that
    cannot be distinguished from a fresh one by name, and can only be caught by
    looking at mtimes, which nothing instructs anyone to do.
- evidence:
  - `target/smoke-e2e/_stale-pre-2026-09-14/03-init-exit.txt` — contained `init_exit=0` dated 2026-09-13 01:24 while this run's `--init` was still building the proxy image; read as this run's result until the mtime was checked
  - 14 files from the 2026-09-12/13 runs were still present at the start of this run and are archived under `target/smoke-e2e/_stale-pre-2026-09-14/`, including `04-opencode-exit.txt`, `05-health.log`, `3b-verdict.txt` — one file per step whose absence is supposed to mean "this step did not run"
- repro:
  - run the skill twice, interrupting the second run before §3 writes its exit file
  - `cat target/smoke-e2e/03-init-exit.txt` returns the FIRST run's result
- next_action: >
    Have §0.4 move any existing `target/smoke-e2e/*` aside to a timestamped
    subdirectory (not delete — prior evidence is worth keeping) before the run
    starts, and have the report record the run's own start time so a reader can
    check any file against it. The in-block assertions are not affected because they
    capture status in the same shell; what is affected is every out-of-band read —
    the §5 report, an orchestrator polling for completion, and a human scanning the
    directory afterwards.
- events:
  - type: discovered
    ts: `2026-09-14T19:40:00Z`
    agent_id: `linux-pirria-opus5-20260914t192603z`
    host: linux

### Work Packet: smoke-finding/cold-room-smoke-lane-can-never-reach-committable-work

- id: `smoke-finding/cold-room-smoke-lane-can-never-reach-committable-work`
- owner_host: linux
- capability_tags: [vault, forge, release, testing, fail-loud]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.13.1`
- filed_on_behalf_of: the in-forge meta-orchestration agent, which asked for
  exactly this — "the blocker is reported here in full so the launching host
  files it durably" — and correctly refused to file it from inside the enclave,
  because a local-only commit in a container about to be destroyed is the very
  failure the guard exists to prevent
- summary: >
    §2 of this runbook wipes Vault so the clean room is cold; a cold Vault holds no
    GitHub token; the forge's mirror therefore publishes `no-credential` and the
    meta-orchestration Credential Channel Guard hard-stops the cycle before any
    committable work. That chain is deterministic, so §4's forge lane can NEVER
    exercise claim/drain/commit/push on a correctly-cold host — it exercises
    bring-up and the guard, and nothing past them. The lane still exits 0, so the
    ceiling is invisible in the result.
- evidence:
  - `target/smoke-e2e/04-opencode.log:848` — `scripts/check-credential-channel.sh` → `blocked:upstream-no-credential` (exit 1)
  - `target/smoke-e2e/04-opencode.log:851` — mirror publishes `refs/tillandsias/upstream-auth/no-credential/1789415320`, epoch 2026-09-14T19:48:40Z, ~2 min old, fresh; `no-credential` means the mirror's Vault answers but holds no GitHub token
  - `target/smoke-e2e/04-opencode.log:856` — "I therefore claimed nothing, drained nothing, filed nothing, and committed nothing"
  - `target/smoke-e2e/04-opencode.log:862` — state assurance: `git status` empty, HEAD == `origin/linux-next`, `ok:no-findings`, no lock, no marker
  - `target/smoke-e2e/04-opencode-exit.txt` — `opencode_exit=0`
  - `target/smoke-e2e/00-credential-channel.txt` — `ok:gh-keyring-push-verified` on the HOST at the same time, which is the asymmetry: the host can push, the forge cannot
- repro:
  - run §2 (reset + credential clear) then §4 on any Linux host; the guard fires every time
- next_action: >
    Decide what §4 is FOR on a cold host, then make the runbook say it. Either (a)
    state plainly that on a post-reset host the lane's pass condition is "brings the
    enclave up and stops correctly at the credential guard", and assert the
    `blocked:upstream-no-credential` stop as the EXPECTED outcome rather than
    reading exit 0 as a full cycle — which is what this report had to do by hand; or
    (b) give the lane a scoped, revocable token after §3 so the committable path is
    exercised too, which is a real change in what the smoke covers and needs an
    operator ruling on credential handling in a clean room. Do not leave it implicit:
    today a reader sees `opencode_exit=0` and reasonably concludes the forge did a
    cycle's worth of work, and on a correctly-cold host it structurally cannot.
    Note the in-forge agent's handling was CORRECT throughout and is not what needs
    fixing — the guard fired, it stopped before committable work, it left the tree
    pristine, and it deliberately emitted no MO-FULL marker so the absence would be
    loud. This packet is about what the LANE can claim to cover, not about a defect
    in the product.
- events:
  - type: discovered
    ts: `2026-09-14T19:58:10Z`
    agent_id: `linux-pirria-opus5-20260914t192603z`
    host: linux

---

## Green observations worth keeping

- **1134-u934 is fixed in this release, and this lane can say so from a
  measurement rather than from a changelog.** The vault container's process tree
  at §3b was still `1 bash / 10 vault / 11 tee` — the exact shape the packet
  describes — and it stopped in **1s with exit 0** against a 10s grace. The packet's
  pre-fix state was a full 30s grace burned and `Exited (137)`. The row for
  v56.9.13.1 does not claim 1134-u934, so this is a repair the release ledger
  does not take credit for.
- The order-298 egress assertion passed the way §4b says it must — proxy liveness
  taken by a concurrent watcher while the lane was up, not a grep for the
  teardown trace.
