# Smoke e2e findings — v56.9.12.2, 2026-09-13, linux/pirria

Runbook: `/smoke-curl-install-and-test-e2e` §0–§5, daily channel.
Host: pirria (CachyOS, kernel 7.2.4-3-cachyos, 15 GiB, 4 cores) — the floor host.
Release under test: `v56.9.12.2` (newest including prereleases; also the stable
`Latest` — both channels carried the same tag on this date).
Destructive reset authorized by this host's operator for this run.

## Result

PASS end-to-end. Install clean, reset clean, init clean, forge run clean.
Two findings, one of them a false-PASS in an instrument rather than a product
defect. Neither halted the run.

| Step | Verdict | Evidence |
|---|---|---|
| §1 curl-install | PASS | `install_exit=0`; `--version` = `Tillandsias v56.9.12.2` (asserted, not commented) |
| §2 destructive reset | PASS | `reset_exit=0`; store zeroed — containers/volumes/images all empty |
| §3 pristine init | PASS | `init_exit=0`, 442.7 s, 15 images rebuilt, vault healthy; 0 panic/`Error:`/SIGSEGV lines |
| §3b shutdown | **FINDING** (known: 1134-u934) | `tillandsias-vault elapsed=11s grace=10s exit=137 oom=false` |
| §4 forge lane | PASS | `opencode_exit=0`, 3 999 114 ms (66 m 39 s); supervisor survived |
| §4b egress | PASS | proxy alive alongside 6 lane containers |
| §4c final health | PASS | `"sealed":false`, proxy up, `--version` correct |

Timing records landed in `.cache/metrics/tillandsias-timing.jsonl`, five of
them, all `exit: 0` — `smoke-curl-install` 7 504 ms, `smoke-destructive-reset`
12 218 ms, `smoke-init-pristine` 442 734 ms, `smoke-forge-lane` 3 999 114 ms,
`smoke-health-check` 247 ms. `timing_reap` at §0 emitted nothing, so no
previous run on this host lost its supervisor. The floor host can write these;
that was the point of 1013-qv7c and it is holding.

Note on `smoke-curl-install` = 7.5 s against the ledger's 175 s for the earlier
cachyos run: this §1 ran against a WARM store (4 containers, 18 images present,
vault already unsealed), so the installer's init was a no-op. The 175 s figure
is the colder path. Not a regression, and not comparable.

## Ledger claims

Row read at §0.2b (`target/smoke-e2e/00-ledger-row.txt`).

**EXERCISED**

- The release installs and self-identifies from a clean curl-install — `--version`
  asserted equal to the tag, not merely non-empty.
- Linux full §1–§3 from a zeroed podman store: this run reproduces the row's own
  cachyos §1–§3 claim independently (install 7.5 s warm, reset to 0/0/0, init
  442.7 s with 15 images and a healthy vault).
- The order-298 egress property: proxy alive alongside a running lane, asserted
  concurrently rather than grepped for the teardown trace. The trace DID appear
  and carried its `keeping application-lifetime: tillandsias-vault,
  tillandsias-proxy, tillandsias-router, tillandsias-nix-cache` clause — the fix
  working, not regressing, exactly as the runbook's note warns a grepper would
  misread.
- `1134-u934`, the defect the row itself says was "found one step past §3 by the
  same run ... routed to pirria". Reproduced here on the PUBLISHED artifact —
  see the finding below.
- The plan-only push lane refusing what it cannot fold (1124-7f3u): exercised
  incidentally by this report's own land.

**NOT APPLICABLE**

- All macOS claims (1084-x8ya macOS arm, `build-macos-tray.sh` dual digests, the
  KNOWN DEFECT SHIPPING note about a malformed embedded digest on macOS, guest
  metrics at 38 s on macbookair) — this is the Linux lane.
- All Windows claims (1084-x8ya Windows arm and `build.rs` digest, 1129-3yv7
  Windows gate as root, 1127-apa8 / 1128-4ffr / 1129-xm5z Windows-lane defects,
  `wsl --unregister` consent, the pristine-host Windows provision the row lists
  as "not run").
- `test-gate-stamp` fixture portability to BSD sed — a build-gate property, and
  this host does not run the cargo gate.

**NOT CHECKED** — this lane could have reached these and did not

- The host↔guest control-wire PSK keying itself (1084-x8ya), which is the row's
  headline change. The forge lane came up and the wire worked, so the keyed path
  is not broken, but this run asserted nothing about the DIGEST — it did not
  check that the PSK is keyed to the guest binary's own self-hash rather than a
  build-time digest, and did not exercise the mismatch arm that is supposed to go
  red on equal digests. A lane that merely launches cannot distinguish a correctly
  keyed wire from an unkeyed one that happens to work.
- The unkeyed entry point's named-cause refusal on release — not provoked.
- The guard auditor searching the canonical `skills/` tree (7b9b58e55).
- The gate memo running ledger guards on plan-only changes (1127-waxf).
- `d15aaf3d4` (ripgrep path operand / piped stdin), `1096-p3tn` (metrics split
  guard), `1131-iax2` (land-script bounded push). A ripgrep IO error DID appear
  in the lane log, but from an in-forge agent's own shell with an empty `$f`
  operand, which is a different condition from the piped-stdin hang that claim
  describes — so it is not evidence either way and is recorded, not counted.

## Findings

### Work Packet: smoke-finding/credential-cold-probe-reads-keychain-only

- id: `smoke-finding/credential-cold-probe-reads-keychain-only`
- owner_host: linux
- capability_tags: [testing, vault, release, linux]
- status: ready
- priority: p1
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.12.2`
- related: `900-z3kv` (criterion 2's instrument), `804-ckst` (the Windows analogue)

`scripts/probe-credential-cold-state.sh --format=md` reported **`credential-cold`**
on this host, and the verdict is WRONG. The product read a surviving share in the
same run.

The probe asks the host keychain and nothing else. The product reads
**keychain OR a file fallback**, and the fallback lives outside everything
`podman system reset --force` touches:

```
/home/lapto/.cache/tillandsias/fallback_vault-root-token-v1    size=28 mode=600 mtime=2026-09-01
/home/lapto/.cache/tillandsias/fallback_vault-shamir-share-v1  size=44 mode=600 mtime=2026-09-01
```

Twelve days old, through this reset and every earlier one. `grep -n 'fallback\|\.cache'
scripts/probe-credential-cold-state.sh` matches only a comment; the script has no
arm for these paths.

The consequence is visible in the product's own log, in the run the probe called
cold:

- `target/smoke-e2e/03-init.log:3908` — `[tillandsias-vault] recovered Shamir unseal share from host keychain or fallback (v1, base64)`
- `target/smoke-e2e/03-init.log:3910` — `[tillandsias-vault] preserving existing data volume (Shamir share present in keychain)`

So the keychain↔volume resync path was **not exercised**, which is precisely the
900-z3kv condition — while the instrument built to detect that condition reported
its opposite. Note the product's own message says "present in keychain" when the
share came from the fallback, which is how the gap stays invisible to a reader.

**Why this is worse than yoga's and lenovinha's warm readings, not better.** Those
hosts report `credential-warm` and are believed; a reader discounts their runs
correctly. pirria reports cold, so a reader credits this lane with coverage it does
not have — and pirria is the floor host whose runs are cited when the fleet wants a
cheap clean-room result. A false cold propagates; an honest warm does not.

- repro:
  - `scripts/probe-credential-cold-state.sh --format=md`  → `credential-cold`
  - `ls -l ~/.cache/tillandsias/fallback_vault-shamir-share-v1`  → present
  - `podman system reset --force && tillandsias --debug --init`  → log says `preserving existing data volume`
- next_action: >
    Give the probe a fallback-file arm so its three verdicts mean what they say:
    warm if EITHER the keychain entry OR a `~/.cache/tillandsias/fallback_*`
    share is present, cold only when neither is, could-not-run when either
    question cannot be asked. Metadata only — never read the file contents, the
    same rule that kept `secret-tool search --all` out of it. That is criterion
    2's instrument being made correct and does not touch criterion 1's open
    (a)/(b) decision about whether the reset SHOULD clear the share; this packet
    deliberately does not settle that and the files were left in place.
    Separately worth raising: the vault log line should say "keychain or
    fallback" where it currently asserts "in keychain", since that wording is
    what makes the substitution unreadable from the log.
- events:
  - type: discovered
    ts: `2026-09-13T09:35:00Z`
    agent_id: `pirria-cachyos`
    host: linux

### Work Packet: smoke-finding/plan-binary-blocked-on-surface-skew

- id: `smoke-finding/plan-binary-blocked-on-surface-skew`
- owner_host: any
- capability_tags: [rust, plan, testing]
- status: ready
- priority: p3
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.12.2` (§4 harness stream)

Inside the forge lane, an agent's `blocked-on` call failed:

- `target/smoke-e2e/04-opencode.log:264` — `error: unknown subcommand 'blocked-on' — this tillandsias-plan was built from sources that do not provide it.`

The binary's diagnostic is good — it lists its 60-odd real subcommands and tells
the reader to rebuild or relaunch. But **its attribution is wrong here**, and that
is the finding. It says the artifact is stale relative to the checkout; the binary
in fact provides `blocked-by`, and `blocked-on` has no counterpart at all. This is
not staleness, it is a NAME that never existed on the CLI — while the MCP layer
advertises both `plan_blocked_by` and `plan_blocked_on` as tools. An agent reading
the MCP surface reasonably reaches for `blocked-on`, gets told its binary is stale,
and rebuilds or relaunches a forge to fix something a rebuild cannot fix.

A second instance of the same class, one screen up:

- `target/smoke-e2e/04-opencode.log:163` — `error: unknown query constraint: --capability-tags`

- repro:
  - inside a forge (or against a release-built `tillandsias-plan`): `tillandsias-plan blocked-on <row>`
  - `tillandsias-plan query --capability-tags <tag>`
- next_action: >
    Decide which surface is canonical and make the other match: either add
    `blocked-on` as an alias for `blocked-by` (and `--capability-tags` to
    `query`), or stop advertising `plan_blocked_on` at the MCP layer. Whichever
    way it goes, narrow the stale-artifact diagnostic so it fires only when the
    name is absent from the BINARY yet present in the checkout's sources — an
    unknown name that exists nowhere should say "no such subcommand", not send
    the reader to rebuild.
- events:
  - type: discovered
    ts: `2026-09-13T09:35:00Z`
    agent_id: `pirria-cachyos`
    host: linux

### Known defect confirmed on the published artifact: 1134-u934

Not a new packet — a confirmation event on the existing row, per the
de-duplicate rule.

§3b reproduced it exactly as the packet predicted, on the release rather than on
a working tree:

```
tillandsias-vault elapsed=11s grace=10s exit=137 oom=false
```

and the process tree read before the stop is the tree the packet names as the
discriminator:

```
1 bash
10 vault
11 tee
52 sh
```

PID 1 is a shell that traps nothing; the pid it would hand a naive trap is
`tee`'s, not vault's. `exit=137` with `elapsed >= grace` is the SIGKILL after the
full grace expired, and `oom=false` rules out memory pressure.

The fix (`0b606fde7`, "forward SIGTERM to vault, and stop reporting clean on the
way out") landed 2026-09-12 16:24 PDT; v56.9.12.2 was cut from `8a45bd522` at
02:29 the same day. `git merge-base --is-ancestor 0b606fde7 v56.9.12.2` → not an
ancestor. So the release ships the defect, as expected — this run confirms the
repro is real on a published artifact and is not an artifact of a dirty tree.

The §3b step itself was routed to pirria by the row and has now been run. Only
`tillandsias-vault` was up at §3b (a bare `--init` leaves the rest down), so this
exercised the one container the packet is about and says nothing about the others.

## Forge-internal stream

The in-forge agent ran `/meta-orchestration` to completion and pushed its own
work (`f156b1fb5`, `1c181f233` and others on `linux-next`), including filing
`plan/issues/low-end-tier-structural-drain-gap-2026-09-13.md` for the
`refused:no-tier-work` condition it hit — so that one is already filed and is not
duplicated here. It also repaired
`cheatsheets/runtime/local-inference.md`, which had a YAML scan error at line 21
(`04-opencode.log:741`) — self-healed within the same lane, recorded rather than
filed.
