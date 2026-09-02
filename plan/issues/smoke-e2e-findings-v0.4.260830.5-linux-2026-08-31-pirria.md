# Curl-install e2e smoke — v0.4.260830.5 (daily) — linux/pirria — 2026-08-31

RESULT: **PASS with findings.** Install, destructive reset, and pristine init
all clean; forge lane launched and the egress assertion held. Five findings
filed below, none of them install- or init-blocking.

Host regime: Intel N150, 4 cores / 4 threads, 15 GiB RAM, NVMe, Fedora
Silverblue — the fleet's minimum-hardware host. These wall-clock numbers are
the target-audience out-of-box experience, not a fast-host figure.

| step | result | wall |
|---|---|---|
| 1 curl-install (published artifact, `TILLANDSIAS_RELEASE_BASE` pinned) | PASS, exit 0, `--version` asserts `v0.4.260830.5` | 3m12s |
| 2 `podman system reset --force` | PASS, exit 0, store asserted empty (0 containers/volumes/images) | 21s |
| 3 `tillandsias --debug --init` from pristine | PASS, exit 0, zero error/panic/SIGSEGV lines, vault healthy `initialized=true sealed=false v=1.18.5`, 12 policies | 7m27s |
| 4 forge `--opencode` meta-orchestration | ran to completion, exit 0, findings below | 23m48s |
| 4b egress assertion (order 298) | PASS — `tillandsias-proxy` alive alongside the lane container | — |

**Clone-to-enclave on minimum hardware: 10m60s** (install 3m12 + reset 0m21 +
init 7m27). Init pulled 10 images and also recorded 10 build markers.

Sibling heads at run start: main `341ab0010`, linux-next `cd2208635`,
windows-next `00dd6974a`, osx-next `04ca38a4a`.

## Ledger claims

**The release has NO ledger row — that is finding 1 below, not a skip.**
`awk` over `README.md` returned `NO LEDGER ROW for v0.4.260830.5`, and the row
is absent on all four branches (`main`, `linux-next`, `windows-next`,
`osx-next`; newest row anywhere is `v0.4.260826.1`, and `main`'s newest is
older still at `v0.4.260817.1`).

- **EXERCISED** — none attributable. With no row, this run could not direct
  itself at any claim this release makes.
- **NOT APPLICABLE** — none determinable.
- **NOT CHECKED** — *everything this release claims to fix.* This lane
  validated the generic property (it installs, destroys, re-provisions, and
  runs a forge lane) against an artifact nobody described. Two fixes landed
  tonight that this host itself verified out-of-band before the cut — the
  `--extra-substituters` nix-cache repair and the probe capability boundary
  (917-zkge) — but this smoke did not re-verify them through the released
  artifact, and no row asserts they are in it.

## Notes carried, not filed

**900-z3kv reproduced on a third host — appended to that packet, not re-filed.**
Step 2 asserted an empty store, yet step 3's init logged
`recovered Shamir unseal share from host keychain or fallback (v1, base64)` and
`preserving existing data volume (Shamir share present in keychain)`. So
`podman system reset --force` is again shown **not credential-cold** on Linux,
and the vault re-init path this skill's header claims to exercise remains
unexercised here. Consistent with the v0.4.260826.1 stable row, which recorded
the same on yoga and named it a platform property predating that release.

---

### Work Packet: smoke-finding/no-release-ledger-row-260830-5

- id: `smoke-finding/no-release-ledger-row-260830-5`
- owner_host: linux
- capability_tags: [release, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260830.5`
- evidence:
  - `target/smoke-e2e/00-ledger-row.txt:1` — `NO LEDGER ROW for v0.4.260830.5`
  - absent on all four branches; newest row anywhere is `v0.4.260826.1`
- repro:
  - `awk -v tag=v0.4.260830.5 '$0 ~ "^\\| " tag "( |\\()" {found=1} END{if(!found) print "NO LEDGER ROW"}' README.md`
- next_action: >
    Determine whether the release skill's README-append step ran for this tag.
    Either append the row for v0.4.260830.5 describing what it ships, or fix
    the release path so a cut cannot publish an artifact with no ledger row.
    Per SKILL.md §0.2b this is the difference between a smoke that validates a
    generic property and one that can check what the release claims to fix.
- events:
  - type: discovered
    ts: `2026-08-31T02:04:26Z`
    agent_id: `linux-pirria-claude-20260831t020425z`
    host: linux

### Work Packet: smoke-finding/loop-status-append-help-parses-stdin

- id: `smoke-finding/loop-status-append-help-parses-stdin`
- owner_host: any
- capability_tags: [rust, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260830.5`
- evidence:
  - `target/smoke-e2e/04-opencode.log:1464` — `tillandsias-plan loop-status-append --help` returns `error: <loop-status-append>: fragment carries no ` + "`## Cycle`" + ` section`, exit 1
- repro:
  - `tillandsias-plan loop-status-append --help`
- next_action: >
    Make `--help` print usage and exit 0 before any stdin/fragment parsing.
    An agent asking a subcommand how to be called should not get a content
    validation error about input it never supplied; the in-forge agent spent
    several turns guessing the invocation after this.
- events:
  - type: discovered
    ts: `2026-08-31T02:04:26Z`
    agent_id: `linux-pirria-claude-20260831t020425z`
    host: linux

### Work Packet: smoke-finding/forge-agent-repetition-loop

- id: `smoke-finding/forge-agent-repetition-loop`
- owner_host: linux
- capability_tags: [forge, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260830.5`
- evidence:
  - `target/smoke-e2e/04-opencode.log:4682` — `Let me read them now, finally, without further deliberation.Let me read the skill's exit contract and gate invocation sections now — this is a simple file read.`
  - 249 occurrences of `Let me read` across a 4695-line log; the run ended still announcing a read it never performed
- repro:
  - `env TILLANDSIAS_NO_TRAY=1 tillandsias . --opencode --prompt "Use the /meta-orchestration skill"`
- next_action: >
    Investigate why the in-forge agent stalls announcing a file read instead of
    issuing it. Establish whether the trigger is the truncated skill content
    noted at log line 19 (`The skill content was truncated`), which would make
    this a skill-delivery defect rather than an agent-behaviour one, before
    treating it as model behaviour.
- events:
  - type: discovered
    ts: `2026-08-31T02:04:26Z`
    agent_id: `linux-pirria-claude-20260831t020425z`
    host: linux

### Work Packet: smoke-finding/forge-agent-tool-call-leaked-as-text

- id: `smoke-finding/forge-agent-tool-call-leaked-as-text`
- owner_host: linux
- capability_tags: [forge, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260830.5`
- evidence:
  - `target/smoke-e2e/04-opencode.log:4685` — a literal `<invoke name="read">` block with `filePath`/`offset`/`limit` printed as text rather than executed; 4 such raw markup lines in the log
- repro:
  - as above; observed at the tail of the meta-orchestration run
- next_action: >
    Determine whether the forge's opencode harness failed to parse a
    well-formed tool call or the agent emitted malformed markup. Likely the
    same root cause as `smoke-finding/forge-agent-repetition-loop` — the loop
    terminates in exactly this leaked block — so triage them together and
    close one as a duplicate if confirmed.
- events:
  - type: discovered
    ts: `2026-08-31T02:04:26Z`
    agent_id: `linux-pirria-claude-20260831t020425z`
    host: linux

### Work Packet: smoke-finding/forge-plan-binary-lacks-version

- id: `smoke-finding/forge-plan-binary-lacks-version`
- owner_host: linux
- capability_tags: [forge, release]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260830.5`
- evidence:
  - `target/smoke-e2e/04-opencode.log:301` — `error: unknown subcommand '--version' — this tillandsias-plan was built from sources that do not provide it.` for `/home/forge/.local/bin/tillandsias-plan`
- repro:
  - inside the forge lane: `tillandsias-plan --version`
- next_action: >
    Decide whether the released forge image should ship a plan binary that can
    report its own version. The error text is well-built and self-diagnosing —
    it names the rebuild and lists the 50 subcommands the binary does have —
    so this is not a crash; the gap is that an agent in a clean-room forge has
    no way to confirm which plan binary it is running, which is exactly the
    check the smoke wants when validating a published artifact.
- events:
  - type: discovered
    ts: `2026-08-31T02:04:26Z`
    agent_id: `linux-pirria-claude-20260831t020425z`
    host: linux

---

## Addendum 2026-08-31 — truncation ruled OUT as the loop's cause

`smoke-finding/forge-agent-repetition-loop` was filed with a next_action to
rule out skill-delivery truncation before treating the loop as agent
behaviour. That check has now been done, and it comes back negative — the
truncation was handled correctly and is not the cause.

Evidence, `target/smoke-e2e/04-opencode.log`:

- **:18** the skill is invoked BARE — `Skill "meta-orchestration"`, no args —
  and **:39** the agent states so itself: *"The invocation prompt is a bare
  'Use the /meta-orchestration skill'"*. So the args-bearing skill-load defect
  seen elsewhere in the fleet (skill body corrupted at load when args are
  passed) **does not apply to this run**, and the two are not one defect.
- **:19-24** the truncation is ordinary opencode tool-output truncation with a
  pointer to a spill file, and the agent paginated it successfully —
  `offset=400`, then `offset=800`, then `offset=1300`.
- **:37** *"I now have the full meta-orchestration skill. Let me start the
  full-mode cycle."*

The loop then begins thousands of lines later and ends at **:4682-4685**. A
truncation that was resolved at line 37 does not explain a stall at line 4682.

The packet's next_action is therefore superseded: skill delivery is exonerated,
and the remaining candidates are the opencode harness's tool-call handling and
agent behaviour proper. That still should not be filed as model behaviour on
this evidence alone — the run ends with a well-formed `<invoke>` block emitted
as TEXT, which is as consistent with the harness failing to parse a valid call
as with the agent emitting an unparseable one, and this lane cannot distinguish
those two from the outside. Whoever picks this up should start by determining
which side dropped the call.
