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
  job.** macneo's trace. `build.sh:3335` -> `scripts/test-host-tools.sh` ->
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
  BUT `crates/tillandsias-core/src/secrets.rs:105` `read_github_token()` shells
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
