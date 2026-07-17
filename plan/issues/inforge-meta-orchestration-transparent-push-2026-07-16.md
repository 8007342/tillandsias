# GOAL: BigPickle/Hy3 runs /meta-orchestration inside the forge with a transparent push (Windows lane)

- Date: 2026-07-16
- Filed by: windows-bullo-fable5-20260716T0731Z (operator session goal)
- Operator directive: "We want a successful /meta-orchestration happening inside
  the forge, able to transparently push to remote." Linux builder is active
  ~2026-07-16T07:30Z→12:30Z (5 h) on 45-minute /meta-orchestration cycles and
  will pick up any linux-owned packet filed here.
- Related: order 350 (windows forge parity gate), order 382 (root-owned staged
  gitdir), order 318 DONE (mirror verified-ack relay), provisional
  windows-260715-4 (maintenance-session name collision), order 334
  (stable-milestone-v1), `git-mirror-push-false-success-not-relayed-2026-07-12.md`,
  `forge-credential-guard-push-channel-gap-2026-07-08.md`.

## Agent identities

- **BigPickle** — the opencode-harness in-forge agent (plan.yaml
  `big_pickle_template`; first full Windows in-forge cycle 2026-07-13).
- **Hy3** — BigPickle's big brother: the larger free Zen sibling model
  (operator, 2026-07-17), selected for heavier in-forge work. Field
  evidence: orders 374/382 (correct MO-SMOKE grammar, criterion-1 demo).
  More Zen models may be trialed; fleet roadmap:
  `agent-fleet-and-zeroclaw-roadmap-2026-07-17.md`.

## Root cause chain, as measured on this host (Yolanda, Windows 11 + WSL2)

1. **Mirror false-success (P1)** — FIXED: order 318 landed synchronous
   pre-receive relay with verified acks (`aeebb939`, in v0.3.260715.6 guest
   images running here). A forge push now relays durably or fails loud.
2. **"Wire-lane insteadOf injection gap" — ROOT CAUSE FOUND (this cycle)**:
   `read_host_project_origin_url` (crates/tillandsias-headless/src/main.rs)
   shells out to `git`, but the WSL2/VZ guest OS ships NO git binary (git
   exists only inside forge containers). The launcher therefore got
   `None` and `write_forge_gitconfig` silently omitted the GitHub→mirror
   `url.insteadOf` rewrite on every wire lane. It was never a lane-launch
   injection wiring gap: the structural gitconfig injection engaged fine
   (order-350 crit-2a PASS on 2026-07-15); only the rewrite section was
   dropped, and the 2026-07-15 crit-2b FAIL was additionally masked by a
   no-origin parity fixture. FIX (windows-next, this cycle): fall back to
   parsing `.git/config` directly when the git binary is absent/fails
   (`parse_gitdir_origin_url`, 3 unit pins). PLEASE REVIEW: linux — shared
   code, also hardens git-less Linux/macOS hosts.
3. **Order 382 root-owned staged gitdir (P1)** — OPEN, linux pickup, ready.
   On this host the current `/home/forge/src/tillandsias` clone is
   forge-owned (Hy3's chown workaround was applied this morning), so the
   demonstration proceeds; unattended fresh installs still hit it.
4. **Maintenance-session name collision (windows-260715-4)** — OPEN, linux
   pickup, ready. Breaks lane RELAUNCH (125); a 45-minute recurring in-forge
   cadence hits it on every cycle after the first unless the stale
   maintenance container is removed. Workaround used here: `podman rm` the
   stale `tillandsias-<project>-forge-maintenance` between lanes.
5. **Stable-channel staleness (observation)** — the operator's 2026-07-16
   morning curl-install yielded tray `0.3.260712.1 (38d33cd8)` while
   v0.3.260716.1 exists; if the installer's default channel is the stable
   label, none of fixes 1-4 reach operators until a new stable is promoted
   (exactly order 334 stable-milestone-v1). Linux coordinator: confirm
   channel semantics and fold this goal's chain into the 334 burndown.

## Requests to the linux builder (5 h window)

- [ ] Review+merge the windows-next origin-url fallback commit (this cycle;
      shared headless code).
- [ ] Order 382: land the staged-gitdir ownership fix (P1, ready, shaped in
      packet; kills the manual chown).
- [ ] windows-260715-4: maintenance-session `--replace` fix (order-314 class;
      required for RECURRING in-forge cycles).
- [ ] Order 334: pull this chain into the stable-release burndown so the
      curl-install stable channel gains the working forge push path.

## Live evidence (2026-07-16, this cycle)

Probe protocol + full table: order-350 evidence doc, 2026-07-16 addendum.
Guest headless hot-swapped to current-checkout v0.3.260716.5; registered
runtime preserved (no re-provision; vault + operator GitHub auth intact).

1. **Wire-lane probes GREEN** (project `tillandsias`, HAS origin):
   insteadOf injected; `tillandsias-git-tillandsias` mirror container UP
   with DNS (first time on Windows); in-forge `git rev-parse` works;
   credential guard `ok:forge-git-mirror`; fetch through the mirror
   served live upstream deltas; push dry-run accepted.
2. **BigPickle full in-forge /meta-orchestration cycle ran**
   (`--cloud tillandsias --opencode --prompt "Use the /meta-orchestration
   skill"`): took its boundary snapshot, pulled linux-next THROUGH THE
   MIRROR transparently (zero manual git config), selected order-374
   discoverability work, added a spec tool-surface requirement + NEW
   `litmus-mcp-discoverability-shape.yaml` (8/8 steps PASS in-lane),
   updated plan ledger files, committed `e8b29bac
   checkpoint(order-374)`.
3. **Push: REJECTED LOUDLY — the order-318 verified-ack mirror working
   as designed.** `[relay] HTTPS upstream credential is unavailable` →
   `[pre-receive] Push rejected: configured upstream did not durably
   accept the ref transaction` → `! [remote rejected]`. No false
   success, no silent loss (contrast: the 07-12/07-13 P1 incidents).
   The commit stayed durable in the guest checkout refs (the facade
   bind-mount design), where the host tier recovered it.
4. **NEW P1 (the LAST blocker, filed windows-260716-2)**: the mirror
   container was created with NO `/run/secrets/vault-token` mount —
   `mint_git_mirror_vault_token` mints AppRole tokens (3 secrets exist
   from earlier bring-ups: …-6385, …-23077, …-18365) but the ensure
   created the final container without any secret arg, and the failure
   is SILENT (mint returns None → fail-open credential-less mirror).
   relay-refs.sh then has no token for `secret/github/token` and
   correctly fail-closes. Same silent-None disease class as the facade
   abort this cycle fixed.
5. **Host-tier recovery**: `e8b29bac` fetched from the guest checkout
   over UNC, rebased onto the meanwhile-advanced linux-next
   (`2f8d53f1`, coordinator heartbeat), relayed to GitHub by the host
   session. Work preserved; transparency criterion stays OPEN on
   windows-260716-2.

**Goal status (2026-07-16)**: in-forge cycle ✓, mirror-transparent fetch ✓,
honest verified-ack push channel ✓, commit durability ✓, ZERO manual git
config in-forge ✓; transparent RELAY blocked by exactly one
linux-owned bug (windows-260716-2). Recurring cadence additionally
needs windows-260715-4 (collision) + order-382 index materialization.

---

## 2026-07-17 — rerun on the fully-fixed stack: blocker moved one layer
deeper (mirror-credential path CONFIRMED fixed; now vault token/policy
skew = order 383)

Overnight the whole chain landed: macOS reused this doc's
`parse_gitdir_origin_url` fallback, and windows-260716-2 was fixed by
making the git-mirror relay credential mandatory + Vault a structural
forge-lane prerequisite (`35253356`); the collision became order 378
(`--replace` idempotency, `6ef71659`); order 382's chown landed
(`dd34cd8a`). I merged all of it (fast-forward to `834c513b`), rebuilt
the guest to **v0.3.260716.7**, and relaunched BigPickle.

**What worked (real forward progress):**
- Fresh-tag stack bring-up: all six images (`…:v0.3.260716.7`) rebuilt
  on-demand from embedded assets (FRESHNESS working end to end).
- **windows-260716-2 is FIXED, confirmed by the failure MODE**: the lane
  reached the git-mirror vault write and failed with
  `Error: write_policy git-mirror-policy: vault unauthorized:
  permission denied / invalid token` — i.e. the mirror credential path
  is now mandatory and LOUD, exactly as designed. No silent
  credential-less mirror.

**The new (and deeper) blocker — order 383 vault root-token skew:**
- The headless vault bootstrap wrote a root token that storage rejects
  (`permission denied` on `token lookup-self`). This is order 383's
  stale-root-token skew, third live repro, now on the Windows lane with
  real operator secrets.
- Manual heal to characterize + restore (the vault was ALREADY wedged
  before I touched it): `vault operator generate-root` with the intact
  Shamir share (`fallback_vault-shamir-share-v1`, 44B, untouched) minted
  a fresh token — `token lookup` → policies:[root], `vault policy list`
  succeeds. **But the same root-policy token still 403s on
  `list auth/approle/role` and `kv get secret/github`.** generate-root
  alone did NOT restore mount/KV access — the skew is deeper than the
  root token. Recorded as an order-383 exit-criterion extension.
- **Operator github token is NOT lost**: KV data lives in the intact
  `vault-data` volume; generate-root never touches it. It is currently
  unreadable pending order 383's proper heal or an attended
  storage-preserving re-init.
- Self-inflicted note: an early botched manual attempt truncated the
  root-token cache file to 0B (`podman exec -i` stole nested-shell
  stdin); regenerated and restored. The recovery-critical Shamir share
  was never touched.

**Updated goal status**: in-forge cycle ✓, mirror-transparent fetch ✓,
verified-ack push ✓, mirror-credential path ✓ (windows-260716-2 fixed),
git-less origin/facade ✓, order-382 chown ✓. Transparent RELAY now
blocked SOLELY by vault token/policy reliability = **order 383**
(linux-owned, ready, estimate bumped 5→7h for the approle/KV wrinkle).
Not retried again this session: re-running the lane just re-hits the
vault wall and its bootstrap re-skews the token — the durable fix is
383's code path or an attended re-init (operator-gated). The blocker has
moved from "the push channel is broken" to "one known vault-reliability
bug stands between us and a clean transparent push" — which is exactly
the reliability bar the EXPERTS/zeroclaw sequencing depends on too.
