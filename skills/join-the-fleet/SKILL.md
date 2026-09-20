---
name: join-the-fleet
description: Idempotent onboarding for a worker agent, on bare metal or inside a forge — the requirements to join the Tillandsias fleet, the scheduled work, the attestation rules, and how to join the work session. Verified by scripts/check-fleet-membership.sh, which reports what is left and never installs.
license: MIT
metadata:
  author: tillandsias
  version: "1.0"
  invokedBy: /join-the-fleet
  trace: "order:1311-ajpm, spec:methodology-accountability"
---

# Join the Fleet

Run this once per session on any worker, bare metal or in-forge. Every command
is ensure-shaped: a second run changes nothing and reports the same verdict.
The skill DOES; the checker only SAYS WHAT IS LEFT:

```bash
scripts/check-fleet-membership.sh     # ok:join-the-fleet:<host>:<regime>:ran=<n> skipped=<m>  → you are in
                                      # todo:join-the-fleet:<host>:<regime>:todos=<k> …        → do the todo: lines, re-run
```

Every `skip:` is named with its reason. A green that does not say what it did
not run is not a green; the verdict carries the counts for that reason.

**Authority.** This page is a view. The rules it repeats live in
`methodology.yaml` and `methodology/` (`multi_host_development`,
`loop_cadence`, `development_environment_lifecycle`, `agent_identity_contract`)
and in the skills it names. When a rule changes, change methodology first and
this page second; never the other way round (CLAUDE.md, Authority).

## 0 — Classify the host, name the session

| Regime | Detected by | Session name | Checkpoints to |
|---|---|---|---|
| forge | `TILLANDSIAS_HOST_KIND=forge` or `.forge-startup-context.md` | `<host>-<project>-forge` | the branch it was seeded from |
| linux-immutable | `/run/ostree-booted` or `rpm-ostree` on PATH | `<host>-silverblue` | `linux-next` |
| linux-mutable | Linux without the marker | `<host>-<os id>` (e.g. `macuahuitl-fedora`) | `linux-next` |
| macos | `$OSTYPE` darwin | `<host>-macos` | `osx-next` |
| windows | msys / cygwin / mingw | `<host>-windows` | `windows-next` |

The checker prints `note:join-the-fleet:session-name:<name>`; use that name as
the cross-session address. Identity for ledger writes comes from
`scripts/agent-identity.sh id <backend>` (756-hn3a), never hand-composed.
Tiers (operator, 2026-09-14): esme and macneo are floor tier and take
tier-relevant work; yolanda and macbookair take platform fixes; interchangeable
Linux work goes to lenovinha first, then yoga; macuahuitl is the operator's
desktop and the coordinator, not labour.

## 1 — Requirements per regime

Bare metal (all three OSes):

1. **Platform branch checked out** (table above). `git fetch origin` first;
   record the sibling heads of `main`, `linux-next`, `windows-next`, `osx-next`.
2. **Hooks installed**: `scripts/install-hooks.sh` (idempotent). The pre-push
   hook is the local gate; a checkout without it can push what the gate would
   refuse.
3. **Builder toolbox** (Linux): `scripts/with-tillandsias-builder.sh true`
   creates or reuses `tillandsias-builder` (methodology `toolbox_first_scripts`).
   macOS and Windows hosts have no toolbox; the checker skips this by name.
4. **A runnable, current plan binary**: `scripts/cycle-preflight.sh` resolves
   or rebuilds it; `scripts/check-plan-binary-current.sh` must answer with the
   literal `ok:validator-surface:<hash>` lane (1287-h6qn). A stale binary mints
   orders the fold never allocated.
5. **Credential channel**: `scripts/check-credential-channel.sh` (982-sguu).
   `blocked:*` means STOP AND REPORT to the coordinator; do not start
   committable work you cannot land. Never `gh auth login` or `gh auth refresh`
   (1025-a896: a re-auth on one host evicts the operator's token on every
   other host); the operator provides tokens (`tillandsias --github-login
   --with-token`, stdin), never an agent.
6. **Start-of-day maintenance**: `scripts/check-daily-maintenance.sh check`;
   on `due:*` run the Start Of Day gate in skills/meta-orchestration once.
7. **Experts answer**: `scripts/check-mcp-expert-health.sh`; if not,
   `scripts/dev-host-experts.sh`. Reads go through the experts first
   (`plan_next`, `plan_status`, `methodology_ask`); the filesystem is the named
   fallback (CLAUDE.md, Bootstrap).

In a forge:

- Steps 3, 6 and the substrate are named skips (no toolbox, no podman, no
  vault; the daily gate exempts forges itself).
- `CARGO_TARGET_DIR` is exported: never resolve a binary from a hardcoded
  `target/` path (721-nyev); use `scripts/plan-binary-probe.sh`.
- The credential channel is a REPORT for verification-only work (818-cgpn)
  and a GATE for anything that commits.
- A broken git mirror is a HARD STOP: "upgrade tillandsias, rebuild the forge",
  never a warning retried against (1310-rec6). A forge cannot repair the host
  that runs it.

## 2 — Substrate (bare-metal Linux)

The enclave and this host's own per-project git mirror are brought up,
rebuilt and troubleshot by the standalone skill
**/initialize-bare-metal-host** (1312-i6da; `skills/initialize-bare-metal-host`).
This page never duplicates it. Its checker,
`scripts/check-bare-metal-host-initialized.sh`, is what the fleet-membership
checker calls for the substrate line. It never seeds a token: the GitHub
credential is the operator's per-host act.

macOS and Windows hosts provision through the installed tray (`--provision`,
`--reset-state` per 1286-4437); the checker skips the substrate line by name
there.

## 3 — Scheduled work

- **Cadence** (methodology/multi-host-development.yaml `loop_cadence`, operator
  ruling): fleet loops run every 2 hours, staggered by the slot table there; a
  host arms its OWN slot; floor forges and the operator's own forge have no
  slot and are driven one-off by the coordinator. The full e2e lane is rate
  limited to one full cycle per 4 hours per host
  (`scripts/forge-e2e-rate-limit.sh`).
- **A cycle** is `/meta-orchestration` (full mode) on the host's own branch:
  Start Of Day gate, credential preflight, claim, work, gate, land, handoff.
- **Claims are by order, through the plan lane**: `tillandsias-plan set-field
  <order> status in_progress --host <host> --reason …`, pushed, then
  `tillandsias-plan next <role> | grep -c <order>` → 0. A hand-off by message
  separates nobody; the claim on trunk does (1140-d6ni).
- **Before calling a packet unclaimed**, fold the sibling branches:
  `scripts/check-claims-across-branches.sh --batch <order>…` (1034-whsp).
- **Platform branches**: macOS and Windows commit to their own branch; the
  coordinator relays to `linux-next`. Before every push of a non-linux-next
  branch, merge `origin/linux-next` into it (methodology `pre_push_gate`).
- **Salvage before you refuse** (872-c9nd): a dirty tree you cannot land goes
  to `scripts/salvage-dirty-worktree.sh <slug>` → `salvage/<host>/<date>-<slug>`
  on origin. Prose about a diff is not a copy of it.
- **A thing not on trunk is not a thing.** Before "filed", "closed" or
  "landed" leaves the host: `git ls-remote origin refs/heads/<branch>` against
  `git rev-parse origin/<branch>`, and `git log origin/<branch>..HEAD --oneline`
  must be empty. A host whose pushes are silently not arriving is
  indistinguishable from a quiet one until someone runs status on the other
  end (2026-09-20, five commits).

## 4 — Attestation

- **Full-mode marker**: `scripts/mo-full-attest.sh self` prints the verified
  `MO-FULL:` line; `record` appends it to `plan/mo-full-attestations.d/<host>.md`.
  Never type a SHA (651-2x5s).
- **Stage before the gate**: the gate stamp reads each path's mode from the
  index, so a new executable file staged AFTER `./build.sh --check` moves the
  digest with no content change and the push is refused (1276-mugq, macneo).
  `git add` every new file first.
- **Every handoff** (`tillandsias-plan loop-status-append --file …`) carries
  the verbatim `scripts/cycle-metrics.sh` block and a `tokens:` line
  (1119-6wn6); `subagent_tokens=0 agents=0` when nothing was spawned.
- **Timestamps come from the clock, never from memory**: the tool's writes
  read it; a hand-written fragment `ts:` more than 900 s in the future is an
  invented time (pirria, 2026-09-20).
- **A first-ever host** adds its capabilities row to `plan/index.yaml`
  directly, not as a fragment (846-idhn: a first row as a fragment is dropped
  at fold time and the pre-push hook refuses `plan-ledger-incomplete`).

## 5 — Join the work session

1. Run the checker; make every `todo:` line ok.
2. Message the coordinator with: the session name, the checker's verdict line,
   the credential verdict, and the sibling heads you recorded. Name the
   packet you are taking, claimed by order (step 3 above), or ask for one.
3. Read the Direction and the open work through the experts:
   `plan_next`, `plan_status <order>`, `methodology_ask`. Fall back to files for
   exactly three reasons and name the one that applies: unavailable,
   verification, not exposed (CLAUDE.md, Bootstrap).
4. Report by comparing trees, not by narrating: paste the artifact (the
   verdict line, the ls-remote line), never "I verified that".

## 6 — Verify

```bash
scripts/check-fleet-membership.sh            # the verdict, with counts
scripts/test-join-the-fleet-idempotent.sh    # ok:join-the-fleet-idempotent:3/3
```

The fixture pins: two runs print the same verdict and leave `git status`
untouched; in a forge every host-only step is a named skip and `skipped=`
equals the number of skip lines; a missing pre-push hook yields
`todo:join-the-fleet:hooks:scripts/install-hooks.sh` with a non-zero exit.
Bound as `litmus:join-the-fleet-idempotent` (spec methodology-accountability).
