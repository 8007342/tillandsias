# macbookair — drill findings, 2026-09-12

Per-host file (coordinator convention, 2026-09-12): hosts write here, the
coordinator folds these into `fleet-restart-2026-09-12.md` and is that file's
only writer. Created on first use after the main file took two append
conflicts in one cycle.

FLAT top-level name, not a `fleet-restart-2026-09-12.d/` directory: a nested
`plan/issues/` path outside the four class directories takes the FULL gate
under the pre-push plan-only lane, so the `.d/` shape would have taxed every
note with a `./build.sh --check`. Corrected by the coordinator before this
file's first land.

Host: `tlatoanis-macbook-air`, Apple M5, macOS 25.6.0, 10c/10t, 16 GiB.
Branch `osx-next`. Drill: tree clean, `ok:salvage-not-needed`.

## Landed

- **2026-09-12 — 803-r8u4 + 803-rbqf, one story, landed `6d5f14de9`**
  (`01962efc0`, `b8df64e1d` verified ancestors of `origin/osx-next` after a
  fresh fetch, not from the script's exit status). The macOS arms of
  `accel_probe.rs` stopped defaulting: RAM via `sysctl hw.memsize`, battery via
  `pmset` keyed on the hardware marker, `is_battery_present` retyped
  `Option<bool>`, the Metal device given `unified` memory and a named lane
  obstruction. Also 1090-8nh4's missing `title` (cleared one of three
  schema-drift advisories), a note on 657-zm2n, and two packets filed
  (1137-rgfm, 1138-qvjf). Full evidence is on the packets; not repeated here.

## Findings other hosts should not re-derive

- **`is_battery_present` was WRONG on every non-Linux host, not merely absent.**
  A bare `bool` only the Linux power-supply scan ever wrote, so everyone else
  serialised the `false` initializer as a confident denial. The proof was
  already in our ledger: macneo's first macOS row (relayed onto 657-zm2n
  2026-09-04) reads `is_battery_present false` from a MacBook. Reaches
  behaviour — `inference-policy-router` ADAPT-2 throttles background work on
  battery, so a laptop reporting `false` because nobody probed it never gets
  throttled. **`scripts/windows-host-capability-probe.sh` hardcodes
  `is_battery_present: true`** — a Windows host should check whether theirs is
  measured or asserted.

- **Stale-artifact trap, applies to every host.**
  `scripts/host-capability-probe.sh` resolves `./target/release/tillandsias`.
  A cycle whose builds were all debug will publish a capability row from the
  OLD binary under a FRESH timestamp — writing the defect back over its own fix
  while looking current. Measured here: the first `--fragment` run printed
  `hardware_fingerprint hw2-5ce200f625e69d05` with the pre-fix nulls; after
  `cargo build --release` it read `hw2-d1ec0bba772d4bda`, matching what the
  debug binary had reported all along. **Rule: after touching
  `accel_probe.rs`, build `--release` before publishing a row, and compare the
  fragment's fingerprint against your own binary's. Two fingerprints from one
  host in one cycle is a stale artifact, not hardware variance.**

- **`check-capability-row.sh` cannot see host facts.** It answered
  `ok:capability-row-current` while the committed row still held the stale
  nulls, because it compares only the schedulable `(device_class, lane,
  engine)` triples. So a fleet-wide correction to HOST FACTS triggers a
  republish on nobody. Not filed: the fix needs a ruling on which fields are
  identity-bearing (comparing whole documents makes every timestamp a drift),
  and that is 850-bif2's owner's call. Recorded as a note on 803-r8u4.

- **`check-host-tools.sh` reports the OPERATOR'S PATH as the HOST'S inventory.**
  macneo's discovery; reproduced here as a second host, same tree, same minute,
  nothing installed or removed, only `PATH` changed:
  full agent PATH -> `tray-build:6 present`;
  `PATH=/usr/bin:/bin:/usr/sbin:/sbin` -> `tray-build:4 present, missing
  aarch64-unknown-linux-musl,x86_64-unknown-linux-musl`,
  while `rustup target list --installed` was unchanged throughout.
  Mechanism: `check-host-tools.sh` resolves rustup with a bare `command -v`, so
  the rustup-target probe never benefits from 1004-x9ua's
  `TILLANDSIAS_HOST_TOOL_PREFIXES` fix. The remedy it prints is confidently
  wrong — `rustup target add <triple>` on a host where the triple is installed.
  The same run's own prose says *"A command -v could not have seen either"*:
  the blindness that fix removed at the target level reappeared one level up,
  at the tool that enumerates targets. **Packet is macneo's to file.**

- **The gh keychain dialog is a FIXTURE, not the credential guard doing its
  job.** macneo's trace. `build.sh`'s host-tools step -> `scripts/test-host-tools.sh` ->
  the prover table row runs the REAL `check-credential-channel.sh` as an
  unconditional 1004-x9ua control run, reaching `gh auth status` ->
  `security find-generic-password -s gh:github.com -w` -> decrypt -> ACL. So a
  build ends up depending on the operator's GitHub login state, which nothing
  in the credential guard's design intended. On macbookair the arm runs for
  real and returns silently (gate log line: `ok   without timeout,
  check-credential-channel.sh reports blocked:gh-cli-only`, no SKIP anywhere);
  on macneo it prompts. Ruled out as differentiators by measurement: git
  provenance (BOTH hosts are `/usr/bin/git`, Apple Git-157) and binary
  replacement (macbookair's `gh` binary is 23 days newer than its keychain
  item's `mdat` and still does not prompt). Remaining explanation is the item's
  ACL. **Packet is macneo's to file.**
  Do NOT reach for `TILLANDSIAS_CRED_SKIP_GH=1`: per 860-g798 the `gh` call is
  only a precondition, and the flag skips the whole arm including the
  `git push --dry-run` that is the actual proof this checkout can push.
  `TILLANDSIAS_CRED_PROBE_CMD` is the seam that does not disable the arm.

- **A `gh auth token` call sits one wire-up away from the shipped artifact.**
  Asked by macneo's operator, answered from the tray lane. The shipped tray
  touches the keychain only in its own namespace (`installation_uuid.rs`,
  service `tillandsias`, accounts `tillandsias-vm-uuid` and
  `vault-shamir-share-v1`); it never names `gh:github.com` and invokes no `gh`,
  and neither does `build-macos-tray.sh`. That matches
  `host-shell-architecture.security.no-host-credentials@v1` (MUST, measurable).
  BUT `crates/tillandsias-core/src/secrets.rs` `read_github_token()` shells
  out to `gh auth token`. It is unreachable today — its only caller,
  `check_and_refresh_github_token()`, has zero callers repo-wide — yet that
  function's doc comment reads *"This should be called at application
  startup."* An instruction to wire it in, in a shipped library, one call from
  violating a MUST-modality spec, with no guard on the symbol. **Unowned; not
  filed.** Offered to macneo, otherwise macbookair takes it after 1137-rgfm.

## Method note, three instances in one cycle

An ABSENT result and a NEGATIVE result render identically, and all three of
these initially read as success:

1. `cargo test -p X "a|b"` takes a SUBSTRING, not a regex. It selected zero
   tests and printed `test result: ok`. Two falsification mutations were
   recorded as proven when nothing had run. Report counts as
   **"N selected, M filtered out"** so a zero cannot hide.
2. The capability probe resolving the stale release binary (above) — a fresh
   timestamp over old data looks exactly like current data.
3. `env PATH=/usr/bin:/bin bash scripts/check-host-tools.sh` wrapped as
   `env PATH=... timeout 120 bash ...`: `timeout` is itself a brew coreutils
   binary, so under the narrowed PATH `env` could not resolve it, the script
   never ran, and the grep came back empty — which read as "no missing targets
   found". Resolve the bound OUTSIDE the narrowed environment.

A check that cannot distinguish *"I looked and found nothing"* from *"I never
looked"* will eventually be read as the former.

## 2026-09-13 — the darwin unblock, and a collision one layer down

- **Two hosts fixed the same shared script within an hour, and neither knew.**
  macbookair and yoga. `origin/linux-next` was red on every macOS host at
  c6d191d39 (`FAIL: dispatch reap 7/9`, 1141-vf9w), reproduced in a pristine
  detached worktree so it was trunk and not either tree. Both hosts then wrote
  the SAME caller fix into `scripts/with-tillandsias-builder.sh`: yoga's
  `_tb_on_signal` landed on trunk first (936d22364), macbookair's
  `_tb_reap_and_report` landed on `osx-next` (ba0fb4fd5). The coordinator kept
  trunk's for both hunks and macbookair took trunk's copy wholesale on the next
  merge (`git checkout origin/linux-next -- scripts/with-tillandsias-builder.sh`),
  verified the trap names `_tb_on_signal` with no dangling reference, and
  re-ran the fixture.

  **THIS IS THE DUPLICATE-FILING GAP ONE LAYER DOWN.** 814-iyu7 is two hosts
  implementing one PACKET; the claim mechanism separates that. Nothing
  separates two hosts editing one shared FILE from two different packets — the
  claim was on 1141-vf9w in both cases, and claiming it twice was not the
  error. `scripts/` is cross-host shared scope and the skill says to coordinate
  via the ledger first; both hosts were acting on the coordinator's own
  instruction and still collided. **A heads-up on a shared file beats a
  merge-time choice** — say which shared path you are about to write, before
  writing it, not when git asks.

  Taking trunk's was right on the merits and not only as a tie-break: yoga's
  version names the token in the warning, prints the exact `ps` line to find
  the survivor, and records that SIGTERM is measured inert so SIGKILL is
  needed. Mine said less.

- **An absent result and a negative result render identically — state it as a
  rule, not as anecdotes.** Four instances in two cycles on this host, each of
  which first read as success:
  1. `cargo test -p X "a|b"` — the filter is a SUBSTRING, not a regex. Selected
     zero tests, printed `test result: ok`. Two falsification mutations were
     nearly recorded as proven having run nothing.
  2. `scripts/host-capability-probe.sh` resolves `./target/release/tillandsias`.
     A debug-only cycle republishes the OLD values under a FRESH timestamp.
  3. `env PATH=/usr/bin:/bin ... timeout 120 bash script.sh` — `timeout` is
     itself a brew coreutils binary, so under the narrowed PATH `env` could not
     resolve it, the script never ran, and the grep came back empty.
  4. `bash fixture.sh | tail -4; echo "exit=$?"` reports TAIL's status. It
     printed 0 for a script that exits 2 — and the script in question was the
     one whose whole purpose is to stop a skip being read as a pass.

  **THE RULE: capture the status of the thing you are measuring, unpiped, and
  quote the count of what actually ran.** "N selected, M filtered out" beats
  "ok". Instance 4 is the sharpest because `scripts/land-on-platform-branch.sh`
  documents this exact trap in its own header (`git push | tee LOG | tail -3`
  tests tail, and a rejected push read as LANDED) and it was still repeated by
  a host that had read that header the same night.

- **A gate step that COULD NOT RUN must not report what the check would have
  FOUND, and the reverse is equally true.** The 1141-vf9w fixture's honest
  inability to look was collapsing into the step's content verdict — an answer
  about a reaper the host never exercised — and refused every macOS land on an
  otherwise green trunk. `STEP_SKIP_EXIT` (1087-h2z9) is the fix. But a skip is
  NOT coverage: macOS still has no working reaper, `tillandsias_reap_marked`
  now returns `unsupported:dispatch-reap:no-proc` rather than a quiet 0, and
  the darwin design is filed as 1145-iigx. Both the fixture header and the step
  say so in as many words, because the next reader's danger is the opposite of
  the last one's.

- **Ninth idiom class for 1135-z8gn: ABSENT-ON-DARWIN PRIMITIVES.** `/proc` and
  `setsid` are not GNU-vs-BSD flag differences — they do not exist on macOS at
  all, so there is no flag to normalise and a flag-shaped advisory returns
  clean on the file. Worth noting that `lib-dispatch-reap.sh`'s own header is
  ABOUT darwin portability: it chooses `read -r -d ''` over `mapfile` because
  macOS ships bash 3.2, and records that check-bash-dialect refused it once and
  "earned its keep". All true. The dialect guard checks the SHELL and had
  nothing to say about a FILESYSTEM absent on the target.

## 2026-09-13 — a cfg-split file, and the check darwin CAN run

- **I added a struct field and fixed only the initializers my compiler could
  see.** `name_source` on `DeviceRecord` (1137-rgfm). `cargo build` on macOS
  reported exactly TWO missing-field errors and I fixed those two; eight more
  sites sat behind `#[cfg(target_os = ...)]` and were invisible to a darwin
  build — six Linux arms (nvidia via nvidia-smi, three lspci-named GPU arms,
  the WSL2 /dev/dxg arm, the accel NPU arm) and two Windows arms
  (Win32_VideoController GPU, PnP NPU). Green-on-one-regime on the cfg axis,
  committed in the same cycle I landed a fix for that same class one axis over
  (the darwin reaper). Caught by macuahuitl's relay gate, fixed forward by them
  so trunk never carried it.

- **THE CHECK DARWIN CAN RUN: `cargo zigbuild`, and it catches this.** Measured
  on the pre-fix tree:

      cargo zigbuild -p tillandsias-headless --target x86_64-unknown-linux-musl
      -> rc=101, 6 x error[E0063] "missing field `name_source`"
      -> accel_probe.rs 2716, 2767, 2792, 2819, 2856, 3151

  Exactly the six Linux arms. The tool is already a hard requirement of this
  lane — `scripts/build-macos-tray.sh` dies without zig and cargo-zigbuild and
  cross-builds the guest for both musl triples with it — so this costs nothing
  new. **RULE: zigbuild the guest target before landing a change to a
  cfg-split file.**

  **BOTH ARMS NOW EXIST, which is what makes it a rule rather than an
  anecdote.** Same command, same host, two trees:

      pre-fix  (osx-next 2ccd051f1)      rc=101, 6 x E0063, the six arms named
      post-fix (trunk 95d98bde7 merged)  rc=0,   0 errors

  The green-after arm was the one neither host had; macuahuitl landed the fix
  and this host took the confirming run. A check with only a red arm proves it
  can fail; a check with only a green arm proves nothing at all.

  **BOUNDARY, so nobody over-trusts it.** This covers the SIX LINUX arms only.
  `rustup target list --installed` on this host is aarch64-apple-darwin plus
  the two linux-musl triples — no Windows target — so the two Windows arms are
  still invisible from macOS and need a Windows host. Six of eight, not eight
  of eight.

  **THE ALTERNATIVE THAT DOES NOT WORK, recorded so nobody retries it:** plain
  `cargo check -p tillandsias-headless --target x86_64-unknown-linux-musl`
  fails in `ring`'s build script for want of a cross C toolchain and never
  reaches the crate. zigbuild supplies that toolchain; that is the entire
  difference between the two commands.

- **Fifth instance of the absent-vs-negative trap, caught before it left the
  host.** I read `grep -c E0063` off that zigbuild's log and got 0 — because
  the build was still compiling dependencies and had not reached the crate.
  Three minutes from reporting "the Linux arms compile clean" about a build
  that had not compiled them. The tell was that the log had no `rc=` line: the
  command writes its own exit status as the last line precisely so a reader can
  distinguish finished-and-clean from not-finished. **Check for the terminator
  before reading the count.**

- **Two hosts, one file, second occurrence — and this time the rule held.**
  osx-next carried the cfg break, trunk carried neither the field nor the break
  (2ccd051f1 was not yet relayed), and macuahuitl had a fix in flight on their
  branch. Rather than fix it myself on my own branch, I measured the state,
  reported it, and ASKED who lands it. They did; I did not touch the file. That
  is the heads-up-before-writing rule from this morning's collision, applied
  four hours later to the same class of situation. The measurement that made
  the question precise: `git show origin/linux-next:...accel_probe.rs | grep -c
  name_source` = 0 against origin/osx-next = 18.

- **A verification the fleet cannot produce is not a pending verification.**
  1137-rgfm's title claimed every Apple silicon Mac emits byte-identical
  fingerprint strings. Demonstrating that needs two Macs in the SAME
  core-count class with different chips. macneo is a different hardware class
  as a measured fact (Apple A18 Pro, Mac17,5, 2P+4E, 8 GiB — the fleet's
  low-end host) against this host's M5 10c10t, so under the old code the two
  strings differed at the core count and the pair never collided. Closed on
  the narrowed claim instead: THE PLACEHOLDER DISCRIMINATED NOTHING WITHIN A
  CORE-COUNT CLASS, with the cross-platform provenance guard as closure
  evidence and macneo's inputs as second-machine confirmation that a real
  brand_string exists to read. A smaller true claim beats a row that never
  closes.

- **The hash channel is untrustworthy across hosts, and it would have produced
  a false negative.** The original verification asked macneo to compare
  fingerprints with mine. Two components move for reasons unrelated to the
  chip: `ram_class` is IN the hash (8 GiB vs 16 GiB differs on identical
  silicon), and binary vintage changes it too — 803-r8u4 added `system_ram_gb`
  to the macOS arm, and before it the `ram:` component was ABSENT ENTIRELY.
  Measured by accident on ONE machine in one minute: stale release binary
  `hw2-5ce200f625e69d05`, fresh binary `hw2-d1ec0bba772d4bda`, same hardware.
  And macneo's stored row carries `system_ram_gb: null` — the same vintage
  evidenced from the LEDGER rather than from my accident. Both confounds were
  live in the only pair available. **Compare the INPUTS across hosts
  (brand_string, core counts, memsize); compare hashes only within one host and
  one binary.**

- 2026-09-14 (cycle, 1183-j9dk): claimed the p1 blocking 804-deux (a). The
  scorable half landed (2d1e3661f): the inference entrypoint's bindir `mkdir`
  failure is now fatal where it happens, naming the container uid and the
  mount's owner, instead of surfacing four lines later as a tar error behind
  "will retry next launch (non-fatal)" — a retry that could never succeed.
  Guarded by scripts/test-inference-mkdir-fatal-1183-j9dk.sh, 7 arms with a
  mutation control, falsified 0 passed / 5 failed against the unfixed file.
- 2026-09-14: CORRECTED MY OWN PACKET. 1183-j9dk asserted "ordinary Unix
  semantics then forbid it". Measured against an empty cache: denied at mode
  0777, `chown` inside the share exits 0 WITHOUT APPLYING, and
  `--security-opt label=disable` makes the write succeed on an Enforcing
  guest. It is SELinux confinement, not permissions and not uid — so all
  three candidate fixes I wrote target the wrong layer, and shape 1 is
  impossible outright (VZSharedDirectory has no ownership parameter).
  A defect whose stated mechanism is wrong costs the next taker a wrong fix.
- 2026-09-14: `ausearch -m avc` HANGS reading stdin under --exec-guest; it
  stalled two probes into hard kills before it was isolated. Run it
  `</dev/null`. The dmesg fallback was written `... | tail -5 || echo`, where
  `tail` always exits 0, so its negative branch could never print — the AVC is
  UNCAPTURED, not absent. Third instance of the pipeline-status trap this lane
  has hit, and a waiter also matched its own echoed command line.
- 2026-09-14 (1153-j2nm, macuahuitl's ask): the fragment relay refuses EVERY
  host. `_trunk_fold_check` builds its tree from trunk's index.yaml + index.d
  only, omitting plan/archive/, so depends_on edges into archived packets
  cannot resolve — 96 phantom violations. Proven by rebuilding the tree with
  and without the archive: violation vs "ok: 944 packets ... sound". Reported
  with a one-line remedy; not edited, the script is macuahuitl's.

- 2026-09-14 (cycle, 1063-nraf): bound scripts/test-inference-mkdir-fatal-1183-j9dk.sh
  to scripts/gate-steps.d/345-1183-j9dk.step. It had been landed with 7 arms and
  a mutation control and referenced by NOTHING — green and meaningless. Landed
  bddf183c1; the gate log shows the step executing. Binding also forced a fix:
  its uid-0 path called bad(), so a root gate would have refused every land with
  a content verdict about a guard it never ran (the 1141-vf9w shape). Now
  STEP_SKIP_EXIT=2, verified across four regimes with an `id` shim.
- 2026-09-14: 1183-j9dk corrected THREE TIMES IN ONE DAY, all mine — Unix
  permissions, then SELinux, then "does not reproduce". The third was the worst:
  I ran the packet's own reproduce command, got 4/4 success, and announced a
  retraction that the orchestrator propagated. The command does a SINGLE-level
  mkdir; the product does `mkdir -p ${OLLAMA_MODELS}.tools/ollama`, TWO levels,
  and fails on the second. The probe and the product were never the same
  operation.
- 2026-09-14, the rule I keep relearning: RE-RUN THE BARE FAILURE IN THE FORM
  THE PRODUCT PERFORMS IT before naming any mechanism. Every one of the three
  wrong calls came from explaining a result instead of first reproducing it
  faithfully. A reproduce command in a packet is not evidence that it reproduces
  the defect — it is a claim, and it needs falsifying like any other.

- 2026-09-14 (cycle, 830-xsk2): settled the in-guest hop's open device question
  by measurement rather than assumption, as the prior claimant asked. Four arms:
  the container profile alone refuses AF_VSOCK socket creation (EPERM); adding
  --device /dev/vsock does NOT help (still EPERM); relaxing seccomp WITHOUT the
  device works. So seccomp is the sole blocker and the device is irrelevant —
  neither of the two routes the packet framed. The container route costs one
  narrow seccomp allowance on a dedicated forwarder container, leaving every
  other consumer on the default filter, which removes the "touches every
  consumer" objection that made --add-host look comparable.
- 2026-09-14: recorded explicitly that seccomp=unconfined is the ISOLATION
  instrument and not the fix. A blunt flag that makes the symptom go away is the
  easiest thing to ship and the hardest to walk back once a consumer depends on
  it.
- 2026-09-14: ETIMEDOUT from the forwarder under --exec-guest is EXPECTED, per
  this packet's own 2026-08-29 constraint (VZ retains guest connects until the
  host pumps CFRunLoop). Noted on next_action so the next claimant does not read
  the correct result as a broken forwarder — the failure mode that constraint
  was written down to prevent.

- 2026-09-15 (cycle, 690-w94k item 1): the discarded CFRunLoopRunInMode result
  was NOT benign, as the packet suspected. Measured on a bare thread: a single
  call returned kCFRunLoopRunFinished in 43.3us instead of the 250ms requested,
  and the loop ran 3,471,102 iterations in 250ms — a saturated core across nine
  call sites including the boot waits. Fixed to 34 iterations, wall clock
  intact. Guard counts CFRunLoopRunInMode ENTRIES, because wall-clock cannot
  distinguish park from spin: the loop honours its deadline either way.
- 2026-09-15: macneo found this packet's line citations stale 3 of 3 (881-29me).
  :870 and :1238 are inside the embedded provisioning SHELL script, and :1238
  sits four lines from the provision.state write 1084-x8ya depends on. I reached
  item 1's real site by grepping the symbol, so I missed the trap BY HABIT, not
  by design. A line number is a claim about a file that has since moved.
- 2026-09-15 (1193-yw6u): TRUNK IS RED ON macOS and no Linux host can see it.
  b3a93780b (1189-2ra5) reds test-host-tools.sh; the prover row is macOS-scoped
  so the arm never ran in the gate that landed it. Bisected in pristine
  worktrees. Both macOS hosts blocked from landing any code.
- 2026-09-15, THE PROCESS ERROR: I ran the pre-land gates BEFORE filing the new
  packet, so check-scorable-obligation-added answered skip:no-new-packets and
  the real refusal surfaced only at push. Run the gates AFTER the last ledger
  write, not before.
- 2026-09-15: three refusals in a chain worth knowing — the pre-push stamp
  cannot be refreshed by a macOS host while trunk is red (split the plan half
  onto a clean tree; salvage branch holds the code, no --no-verify); "plan
  binary is STALE" is a validator-surface HASH not an mtime, cleared by
  check-plan-binary-current.sh after a rebuild; and a verifiable_closure
  beginning with a BACKTICK matches nothing because the accept patterns are
  anchored to the first character. The last is documented in the checker's own
  comments and I walked into it anyway.
- 2026-09-15: `tillandsias-plan status <order>` reads the LOCAL FOLD, not the
  fetched remote ref. I queried 1194-davi, got "no packet matches", and reported
  it as possibly-misfiled — it was on trunk the whole time, 23 seconds after my
  own duplicate. Absent and negative render identically AGAIN, this time inside
  the ledger tooling. To ask whether a packet exists on trunk:
  `git grep -l <order> origin/linux-next -- plan/index.d/` WITH A CONTROL search
  that must return nothing. macneo hit the identical shape on 1145-iigx this
  week; on a wedged host nobody's fold is current, because integrating is the
  thing that cannot be done.
- 2026-09-15: I generalised "plan-only pushes and the relay work" from THIS host
  to all macOS hosts. False — macneo was wedged out of the plan lane entirely in
  the same hour. Two hosts, one trunk, opposite outcomes. Correction recorded in
  1195-m9vi's context rather than left in a message.
- 2026-09-15: 690-w94k item 1 LANDED (e43b3d06f) after trunk went green — the
  parked fix was restored from the salvage branch and re-verified (guard + Linux
  zigbuild) rather than trusted in its parked state. Trunk's return to green was
  re-measured here in a pristine worktree rather than accepted on report: the
  host that called it red is the right host to confirm it fixed.
- 2026-09-15 (1196-5hva, yoga/lenovinha): filing a blocker as a LEDGER PACKET —
  what the work loop teaches — makes it INVISIBLE to fleet-heartbeat.sh, which
  reaches its blocked bucket only via plan/issues/*<host>*.md greps and reads
  plan/index.d/ solely for liveness timestamps. So both macOS hosts read WEDGED
  all cycle while a correctly-filed p1 sat on trunk, and WEDGED prescribes
  "adjudicate its worktree" — pointing away from a trunk-wide red. My cycle is
  the evidence in that row. A channel reporting NOTHING is indistinguishable
  from one reporting FINE, and this is the most expensive instance of it today.
- 2026-09-15: I FILED A WRONG HEADLINE ON MACNEO'S BEHALF and retracted it the
  same night. 1195-m9vi claimed the plan-lane closed loop was INDEPENDENT of the
  credential guard. It was not: the stamp horn bites only while the stamp cannot
  be REFRESHED, and it could not be refreshed because ./build.sh --check was red
  — i.e. because of 1193-yw6u. The inference was "neither gate mentions
  credentials, therefore independent", and a gate does not have to MENTION a
  defect to be disabled by it. macneo caught their own error; I had published it.
  Row narrowed to the one unreproduced refusal and dropped p1 -> p3.
- 2026-09-15, the lesson from carrying someone else's report: relaying a blocked
  host's findings is right and it got a p1 fixed inside an hour — but I restated
  their INFERENCE as the packet's headline with my own framing, which made a
  wrong premise more persuasive than it arrived. Carry the MEASUREMENTS
  faithfully; mark the inferences as theirs and unverified, especially when the
  host that made them cannot re-measure.
- 2026-09-15: the smaller true fact the wrong framing hid — two macOS hosts,
  same trunk, same hour, opposite outcomes, because macbookair held a green
  stamp from a land PREDATING b3a93780b and macneo did not. That is why my
  "plan-only pushes work" generalisation was false one host over.

- 2026-09-15 (cycle, 1084-x8ya step b): LANDED 5ba5e30ea. The behaviour was
  already right — headless_service_line splits `inactive` on the timestamp, and
  anything else falls to "NOT a failure by itself" — but NOTHING PINNED IT.
  Measured with a control so the zero was real: `activating` 0 occurrences
  against `headless_service_state` 13. Five arms, including a POSITIVE CONTROL
  requiring a genuinely failed unit to still say FAILED; without it a mutation
  making everything read benign would pass while destroying the report.
  Falsified red by collapsing the mid-boot arm into the failed wording.
- 2026-09-15: took 1084-x8ya despite the skip list, because the reason for the
  skip ("owned elsewhere, macneo") had lapsed — macneo released it explicitly
  and I verified status ready + no cross-branch claim BEFORE claiming, rather
  than acting on the message. A skip list entry states a reason; when the reason
  is gone, check the reason rather than obeying or ignoring the entry.
- 2026-09-15: step (a) of that row advertised work already landed end to end —
  the third stale next_action in two days (mine on 1183-j9dk, macneo's fix of
  it, now this). Reading the row is not reading the tree.
- 2026-09-15, macneo's lesson and the sharpest of the week: A CONTROL ON THE
  WRONG QUESTION STILL ONLY VALIDATES THE WRONG QUESTION. They grepped the tray
  for HandshakeFailure/downcast_ref, got zero, ran a positive control proving
  the probe worked, and reported "the classification never reaches the poll
  line" about their own complete commit. The tray prints {e}; Display does the
  work. A flawless probe answering a different question. Discriminator: trace
  the VALUE, not the NAME — one cargo test printing the rendered error settles
  what three greps could not.
- 2026-09-15: the peer_frame trap, measured in (a)'s own fixture. A plaintext
  refusal of REALISTIC LENGTH reaches the AEAD check, so snow reports Decrypt
  and the classification alone cannot be told from a real PSK mismatch — only a
  very short blob reads as Input. peer_frame is the discriminator, not the
  class. Anyone taking (c) on the class alone chases a PSK question that is
  actually the guest's order-137 Unauthorized notice.
- 2026-09-15 (1197-y6g6): TRUNK RED AGAIN, second in two cycles.
  test-pre-push-honours-a-live-freeze.sh ARM 3b fails on macOS — a plan-only
  push with NO stamp is refused instead of admitted. 18/19, freeze logic fine.
  Reproduced on a pristine worktree of origin/linux-next. Blocks this cycle's
  attestation; the WORK landed before the finalize (5ba5e30ea).
  Different shape from 1193-yw6u: that was a macOS-SCOPED prover row, this is a
  generic script whose assumption fails on a clean macOS checkout, so
  1194-davi's platform-scoped inventory would not catch it.
  The arm is the executable statement that the plan-only lane is a STAMP-FREE
  ESCAPE HATCH — the property 1195-m9vi turns on.
- 2026-09-15, MY OWN ERROR worth recording: I wrote that fragment with an
  UNQUOTED heredoc, so the shell evaluated the backticks and $() inside the
  YAML and corrupted it — strict-fragments caught it immediately
  ("1 fragment(s) could not be read"). Removed and rewrote with <<'YML' plus a
  sed for the order token. Earlier fragments survived only because they happened
  to contain no backticks. Use a QUOTED heredoc for ledger YAML, always.
- 2026-09-15 (1197-y6g6 resolved): NOT A macOS DEFECT. The owner reproduced it
  on LINUX by removing tillandsias-plan from PATH — 18/19, identical refusal.
  The scratch has no target/, so resolve_plan_binary falls through to
  `command -v`, which succeeds only on a host with an installed copy. That is
  1172-dyvd axis 14 (a fixture must shadow or declare every path the code under
  test consults), not the platform-scoping class — 1194-davi correctly keeps its
  scope, because widening it would hand it an inventory it cannot derive.
- 2026-09-15, I PROPAGATED AN OVER-CLAIM. ARM 3b's name asserted the plan-only
  lane is a "stamp-free escape hatch". The real contract is STAMP-FREE BUT NOT
  VALIDATOR-FREE (1124-7f3u fails it closed without one, by design). I repeated
  the arm's claim as the PREMISE of an argument about 1195-m9vi before checking
  it against the code. A test's NAME is an assertion like any other and deserves
  the same scepticism as its body — this one was wrong and travelled two rows.
- 2026-09-15: that also explains macneo's refusal 3
  (refused:fragments-to-trunk:no-validator) — not a defect, the lane failing
  CLOSED in a checkout with nothing built. An escape hatch with an undocumented
  precondition is indistinguishable from a broken one from inside the host that
  needs it; both render as "I cannot write to the ledger". The arm's name was
  exactly where that precondition could have been learned, and it said the
  opposite.

- 2026-09-15 (1201-t6ms): LANDED c04b5c002 after the first land refused on the
  mandated-merge guard — trunk moved during a multi-minute gate, so osx-next no
  longer contained origin/linux-next. The guard was right. I declined the
  offered work/<order> relay-ref escape: that exists for a host that CANNOT
  satisfy the merge policy, and mine can. Worth noting as a lane property: the
  longer the gate runs, the likelier trunk moves beneath it, so a slow gate
  makes its own push refusal more probable.
- 2026-09-15 (920-pxg6 task 4.5, darwin half): a passing test can ride a CACHED
  build and answer a different question than the one asked. mlua is `vendored`,
  so portability is about compiling Lua's C source HERE — my first measurement
  used a cached mlua and would have been reported as portability evidence.
  Destroyed the cache and re-measured: 32 C objects, liblua5.4.a at ARM64,
  7/7 runtime tests including both sandbox arms.
- 2026-09-15, AND THE CLEAN NEEDED ITS OWN CONTROL: I printed "cleaned" from my
  own echo after a `cargo clean -p mlua-sys 2>/dev/null` whose failure would
  have been invisible. The 11s rebuild that never mentioned mlua was the tell.
  A second clean reported "Removed 60 files, 7.6MiB" — THAT is the evidence the
  clean applied. Never suppress the stderr of a command whose silence you are
  about to treat as success.
- 2026-09-15: pushed the 920-pxg6 claim flip ALONE and FIRST, plan-only, before
  starting work — the rule taken from macuahuitl's status ask. Batching a claim
  into the same commit as code hands it to a gate, and for the whole duration of
  a build trunk cannot distinguish the claim from an idle host.
- 2026-09-15: searching trunk for "920-pxg6" found ZERO while the claim fragment
  WAS there — set-field fragments reference a packet by its packet_id SLUG, not
  its order token. Caught by a positive control on a fragment I knew had landed.
  Another probe asking the wrong question and answering it faithfully.
- 2026-09-15 [CAUSE CORRECTED BELOW]: I LEFT FINISHED WORK READING `ready`. My
  lane's instruction says "RELEASE THE CLAIM AT CYCLE END, unconditionally" and
  I applied it literally,
  flipping in_progress -> ready on 1201-t6ms after its fix had landed. RELEASING
  A CLAIM AND CLOSING A ROW ARE DIFFERENT OPERATIONS: the instruction exists so a
  claim is never stranded across cycles, not so a completed row advertises itself
  as available. Effect: landed work sat in the ledger as unfinished and
  plan_next kept offering it. 1155-jurn mirrored — esme's finished work read
  in_progress, mine read ready. Closed as completed with the closure evidence
  RE-RUN on the trunk-merged tree rather than cited from the landing cycle.
- 2026-09-15: `set-field status completed` REFUSES without --evidence (650-dq6u,
  a commit SHA plus a named check result). A good refusal — it makes a closure
  cite something, and it is why macuahuitl declined to close my row from their
  host: they had no run to cite, and a closure written by someone who did not
  run the tests is what that gate exists to refuse.
- 2026-09-15, CORRECTING THE ENTRY ABOVE — the cause was not my literal
  reading. macuahuitl read the shared text instead of accepting my account, and
  the rule was never wrong: skills/advance-work-from-plan/SKILL.md §4's body
  says "Completed work moves to its terminal status (§7.2). Work you did NOT
  finish goes back to `ready`". Its HEADING says "Release on exit,
  unconditionally". The bolded imperative beat the qualifier one line below it.
  I verified that in the file rather than taking it on report.
  THIRD REINFORCEMENT I then found: the step's only CODE BLOCK shows the `ready`
  form. Three surfaces — heading, prose, example — and the two you skim are the
  wrong ones for finished work. Being careful does not help when the careless
  reading is the one the layout teaches.
  THE SHAPE, macuahuitl's words and the durable half: this is the MIRROR of
  641-e2qa, which left 21 packets in_progress and hidden from ready and
  burndown. "A rule written from one failure mode reads as absolute about the
  other." Fixed in the shared skill so every host gets it, not in my lane.
  AND NOTE WHAT THIS ENTRY IS: my file carried the wrong cause after the right
  one existed in someone else's — a record true when written and stale by the
  time it mattered, which is the thing this drill keeps re-learning.

- 2026-09-15 (690-w94k criterion 4): the tray leaked a ZOMBIE PER NOTIFICATION —
  three .spawn() sites dropped the Child, which on Unix does not detach it. The
  comment at the first site was the defect's best disguise: "Detached — let it
  complete in the background. macOS notifications fire near-instantly so we
  don't need to await the child." The second clause is TRUE and is what makes
  the first sound reasoned; a reviewer checking whether the author had thought
  about it would find evidence that they had.
- 2026-09-15: so the test COUNTS ZOMBIES (/bin/ps filtered to our own pid; no
  /proc on darwin) rather than grepping for .wait(). A source-level test would
  have passed on the broken code the moment that comment was written. It carries
  a built-in control that first spawns raw children and REQUIRES zombies to
  appear, so it cannot pass vacuously if the platform ever auto-reaps.
  Falsified at 8 of 8.
- 2026-09-15, A LANE PROPERTY I HAD BEEN MISREADING AS BAD LUCK: two consecutive
  code lands refused on the mandated-merge guard. MEASURED: trunk took 18
  commits in 3h and 9 in the last hour — one every ~6.7 min — against a gate
  that runs longer than that here. A macOS code land cannot reliably win that
  race by re-landing; it is arithmetic. That is the documented "policy your host
  cannot satisfy" case, so work/690-w94k is the compliant path, not a way round
  the guard. I declined the same hatch twice earlier today when the host COULD
  satisfy it — the numbers changed the answer, not the inconvenience.
- 2026-09-15: the refusal says "not a lost race, so retrying cannot help". True
  of retrying the PUSH, false of what the tool already does — re-running it
  merges trunk at attempt start. Taken at face value it sends you to hand-merge,
  twice, before you think to measure. Reported to macuahuitl as wording rather
  than filed as a defect: nothing incorrect landed and the guard is right.

- 2026-09-15 (1207-n96g): the eligibility litmus arm asserted an oracle 723-fndi
  RETIRED. podman was removed from the Darwin path deliberately because its
  verdict printed skip:live-runtime-present with nothing running AND with a live
  VM — a constant is not a probe. So the more thoroughly the arm stubbed podman,
  the more certainly it failed. Scope measured: exactly ONE step, the
  neighbouring wiring step passing at count=3.
- 2026-09-15: THE REMEDY ALREADY EXISTED — scripts/e2e-preflight.sh's `fixture`
  subcommand is green 4/4 on Darwin and already holds an override image open to
  get a genuine verdict. The gap was that the litmus did not USE it. Third
  instance this week of a remedy with nothing pointing at it (the others: a
  next_action advertising landed work, and a symbol search asking whether a
  consumer NAMES a type when it only prints its Display).
- 2026-09-15, A NEAR-MISS ON MY OWN FALSIFICATION worth keeping: my first
  mutation set holder=$$, so the step killed its own shell and reded by TIMEOUT.
  It WAS red, and I could have banked it. But a mutation that reds a step for an
  unrelated reason proves only that a step CAN fail — almost any step in the
  suite would red the same way. Re-ran surgically (removing ONLY `exec 9<`,
  keeping the process, sleep, kill and wait): output=eligible against
  expected=skip:live-runtime-present. THE MUTATION MUST BREAK THE PROPERTY, NOT
  THE STEP.
- 2026-09-15: instrumented the land and found THIS ARM DOES NOT EXECUTE IN
  ./build.sh --check. "The gate does not run litmus" would be FALSE and I nearly
  wrote it — the log mentions litmus 122 times, but they are the META tier (YAML
  parse gate, bindings reconciliation, coverage query, kill-time adjudicator),
  not any spec's tests. So the gate validates that an arm PARSES and BINDS, and
  never evaluates its assertion. Yoga's cross-tier finding, on my own change.
- 2026-09-15: macuahuitl's refusal-wording fix is live — "retrying THIS PUSH
  cannot help (not a lost race); merge trunk and re-gate". Fifth consecutive
  lost race, and this time I went straight to the relay instead of re-running,
  which is what the measurements argued for.

- 2026-09-16 (1032-62rx): took the site inventory, which blocks the closure's
  ten-site deletion mutation. THE ROW'S COUNT IS RIGHT AND I NEARLY REPORTED IT
  AS DRIFTED: my first probe searched only `wire_version != WIRE_VERSION` and
  found 8 across 5 crates. TWO sites use the EQUALITY form `wire_version == WIRE_VERSION` — one in
  vsock_exec and one in router-sidecar's main — making it ten across six
  exactly as filed. A
  faithful search of an incomplete pattern, one step from publishing a false
  correction to a row that was correct.
- 2026-09-16: coverage measured at 2 of 10. `WIRE_VERSION + 1` appears in
  exactly two files tree-wide: vsock_client (this row's own test) and
  vsock_server (my 1201-t6ms). The TITLE is stale — "untested on both sides" was
  true when filed, both named sides are now covered, and the real remainder is
  the other eight sites, which the title hides. A reader trusting the title
  would either close the row wrongly or re-do the two tests that exist.
- 2026-09-16: the remaining eight split across THREE platforms (vsock_exec x5
  and pty_vsock_bridge here; hvsocket needs Windows; router-sidecar needs the
  Linux container lane) while pickup_role holds one value — the 920-pxg6 task
  4.5 limitation again, now on a second row.
- 2026-09-16: salvage fired at cycle start (`ok:salvaged-commits`, not
  not-needed). The salvaged commits read NOT-on-trunk by SHA and ARE on trunk by
  FILE — because relaying via cherry-pick onto a fresh branch makes new SHAs.
  macneo's rule held: the relay moves FRAGMENTS, not commits. Checking by SHA
  would have reported lost work.
- 2026-09-16 (690-w94k criterion 3): bounded the three `security` keychain
  spawns (10s, sized against the 30s status path), sync signatures preserved
  because those fns have 34 callers. THE TEST ASSERTS THE PROCESS TABLE, not
  elapsed time: macneo measured a timeout that killed the PARENT while the
  `security` grandchild survived at PPID 1 holding an undismissable prompt —
  one per call, a SecurityAgent alive 21h45m, cleared only by a restart. A test
  checking "returned inside budget" passes on exactly that. Falsified by
  removing ONLY child.kill() and keeping the timeout, error and reap.
- 2026-09-16, I FIXED A DEFECT I SHIPPED LAST CYCLE. The criterion-4 zombie test
  used `waitpid(-1)`, which reaps ANY child — in a parallel test binary,
  including other tests'. It stole the `security` child of
  keychain_persists_credentials_across_calls, whose wait failed ECHILD "No child
  processes". Each test passed ALONE and the suite failed, and the failure
  pointed at the innocent test. Now reaps by captured pid. I only found it
  because I ran the FULL suite this time — last cycle I ran my own test before
  and after and called that the selftest rule satisfied.
- 2026-09-16: the citation gate caught me writing `main.rs:150` into this drill <!-- cite-ok: the line number IS the evidence — this entry is about being caught writing that exact citation, so rewriting it to a symbol would delete what the entry records -->
  one hour after my own evidence event said "line numbers are a snapshot; the
  FORMS are the durable handle". Fixed by citing the form. Knowing a rule and
  applying it are different acts — macuahuitl's sentence, now mine.
- 2026-09-16, A LANE CONSTRAINT WORTH KNOWING: two integration tests
  (exec_guest_stdin) require exclusive VM ownership and refuse when a tray is
  running — correctly, and loudly, rather than passing vacuously. The operator's
  freshly installed tray is live, so ./build.sh --check CANNOT go green on this
  host right now. Proven environmental: both fail identically on the pre-change
  tree. So this crate's work is committed and UNLANDED until the tray is down;
  I am not quitting the operator's running application to land a commit.
- 2026-09-16 (1224-zpek): filed the live-tray gate blocker. exec_guest_stdin's
  two tests ASSERT on the live-tray refusal while their own message says "this
  test proved nothing" — a failure claims the stdin path is broken; the truth is
  it was never exercised. 1141-vf9w's shape, already settled: an honest "I could
  not look" must not collapse into a content verdict. NOT an oversight about
  vacuity — the guard's comment shows PASS-vacuously vs FAIL was weighed and
  FAIL correctly chosen; SKIP-by-name is the third option nobody had.
- 2026-09-16: this is the THIRD distinct cause for these same two tests. They
  were blamed on gate concurrency (asserted PROVEN on a solo green that was
  lucky link order, not a control), then correctly traced to 1043-kvvn's
  duplicate [[bin]] name. The recorded method error was "never opened the
  transcript to read WHY the test failed". I read it: the stderr names the
  live-tray refusal in plain text, one tray process, and both fail identically
  with my change stashed — environmental, not a regression.
- 2026-09-16, A BOOTSTRAP PROPERTY: the fix for "a live tray reds the gate"
  cannot be LANDED from a host whose tray is redding its gate, because landing
  needs that gate. It wants a host with no tray, an operator quitting theirs
  once, or another host landing a relay ref.
- 2026-09-16: hit the anchored-pattern trap AGAIN. check-scorable-obligation
  matches the FIRST characters (scripts/*.sh*, litmus:*, cargo test*), and my
  closure opened "With a tray RUNNING, cargo test ..." so it matched nothing.
  Two days ago the same checker refused a closure opening with a BACKTICK. I
  recorded that in memory and still wrote the variant.
- 2026-09-16: used the citation gate's `cite-ok` escape for the first time, and
  legitimately — the bullet ABOVE quotes the drifted citation AS the evidence,
  so replacing it with a symbol would erase the finding. That is the case the
  escape documents, not a way around the rule.
- 2026-09-16, THE LESSON I PAID FOR TWICE: I concluded criterion 3 was
  UNLANDABLE and macuahuitl confirmed the relay ref does not escape either — and
  all the while 872-c9nd's salvage net had ALREADY PUSHED
  salvage/tlatoanis-macbook-air/20260916-restart-20260916-115025 to origin,
  reachable by any host with a working gate. It landed from there (2263daf85).
  Both of us reasoned about escape routes while the work sat on a ref neither
  queried. BEFORE CONCLUDING WORK IS UNREACHABLE, LIST THE SALVAGE REFS —
  `git ls-remote --heads origin 'refs/heads/salvage/<host>*'`; this host has 3.
- 2026-09-16: `cargo test -p tillandsias-macos-tray --bins` runs the crate's 135
  tests WITH A TRAY UP, because --bins selects binary targets only and never
  builds tests/exec_guest_stdin.rs. So 1224-zpek blocks ./build.sh --check and
  does NOT block verifying macOS-only sources. Attested from that transcript:
  ok:sources-attested:macos-only:7, verdict now ok:sources-verified:macos-only:7.
  A blocker that stops one thing is not a blocker on everything downstream of
  it, and I had been treating it as one.
- 2026-09-16: macuahuitl corrected their own claim that a Linux gate compiles
  this crate — per 739-6r6n it is FULLY cfg-gated and Linux compiles STUBS, so
  those seven modules land UNVERIFIED and only a macOS host can attest them.
  That is why the attestation above is worth a cycle rather than bookkeeping.
- 2026-09-16: trunk's copy of installation_uuid.rs differed from mine by ONE
  line — `use super::{SECURITY_CALL_BUDGET, spawn_bounded}` versus my reversed
  order — a rustfmt difference between hosts, not a logic change. Took trunk's
  on merge. Worth knowing before the next relay: my fmt and macuahuitl's
  (1.9.0-stable, 48a229ceae) disagree on import ordering.

- 2026-09-17 — Operator ruling on guest VM memory, filed 1235-kjdf and gated
  green: 8 GiB ceiling regardless of host RAM, 4 GiB of guest on an 8 GiB host.
  Implemented as two constants (`GUEST_MAX_MEMORY_BYTES`,
  `HOST_RESERVED_MEMORY_BYTES`) so both of the operator's numbers fall out of
  the existing derivation in `guest_sizing` rather than being special-cased.
  It partially reverses 978-juw4 and the constant's doc comment says so; the
  reserve was revalued rather than deleted, so that order's structure — reserve
  authoritative, no lower clamp, loud refusal on a too-small host — survives.
- 2026-09-17 — Ephemerality asked for by the ruling turned out to need NO code,
  and I verified that rather than asserting it: `guest_sizing` has exactly one
  production call site, inside `VzRuntime::start`, feeding the boot spec's
  `setMemorySize`; `VzBootConfig` has no serde derive and its `defaults()` is
  reached only from tests. Nothing about RAM is persisted, so latest-config-wins
  already holds by construction.
- 2026-09-17 — I put a clippy hard error on trunk (`useless_format`, via
  macuahuitl's 690-w94k relay) and it was red for every macOS build for hours.
  Filed 1235-rfub. The lesson is not "run clippy" but WHERE the blindness is:
  the relaying Linux gate compiles stubs for the cfg-gated tray modules, and my
  own two checks were blind in the same direction — `--bins` runs no lints,
  `zigbuild --target x86_64-unknown-linux-musl` compiles the other side. On a
  cfg-gated crate, lint natively with `--all-targets` before any relay.
- 2026-09-17 — Land lost the mandated-merge race and I stopped at two attempts
  BY ARITHMETIC rather than by feel: trunk's median inter-commit interval
  measured 177 s against a multi-minute gate, matching macneo's ~3 min vs
  ~17 min figure. Took the relay ref the land script names. Measuring the
  branch being pushed would have said "quiet, spend the gate" — the ref that
  matters is the one the refusal names.

- 2026-09-17 — Filed 1238-b825 after the operator found a CalVer build stamping
  a date four days stale (`56.9.13.1` built on 2026-09-17). The encoding makes
  the date load-bearing: `bump-version.sh` documents
  `<years_since_epoch>.<month>.<day>.<build>`, so 56 = 2026 and the version
  literally names 2026-09-13.
- 2026-09-17 — I then published a FALSE universal negative in that row — "NO
  release path invokes bump-version.sh" — and put it in a message telling
  macuahuitl to check before cutting. The release runbook invokes it twice.
  Corrected at e756a912c; the released artifact was always fine and the row is
  not a cut blocker.
- 2026-09-17 — THE CAUSE IS AN INSTRUMENT DEFECT AND IT IS INVISIBLE: `grep`
  here wraps ugrep 7.8.4, whose `-r` does not follow symlinks, and the
  `.claude/skills/` directories ARE symlinks. `grep -rln ... .claude/skills/`
  returns 0 hits with EXIT CODE 0 — it reports success having descended into
  nothing. `-R` finds it. There is no error to suppress or un-suppress, so
  re-running "more carefully" changes nothing. Use `-R` for anything crossing
  `.claude/`, and run a positive control inside the target tree before trusting
  a recursive negative.
- 2026-09-17 — Second time in one evening I matched a PATTERN and concluded
  about a THING: earlier the `pgrep` for a live tray matched a `--github-login`
  one-shot sharing the binary path, voiding a 1224-zpek measurement I had
  already called decisive. Both were caught by someone checking, not by me.
