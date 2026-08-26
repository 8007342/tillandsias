## Cycle 2026-08-23T01:15:04Z (macos tlatoanis-macbook-air — meta-orchestration full; operator-directed macOS fleet-rejoin onboarding)

### THIRD HOST KIND JOINED; THE ONBOARDING WAS THE WORK
Operator directive: fix your own onboarding, not drain packets. Six defects
(operator-verified on linux-next 2026-08-22) confirmed against osx-next HEAD
== origin/linux-next `cef7c023b` by an 8-agent verification pass BEFORE any
edit, then fixed with mutation-controlled fixtures; a SEVENTH surfaced when
this cycle's own `./build.sh --check` went red on Darwin. All under order
**851-gpb5** (done); residuals shaped ready as **851-28b5**. Full narrative:
`plan/issues/enhancement/macos-onboarding-defect-sweep-2026-08-23.md`.

### THE HEADLINES
- `pull_merge_cadence.pre_push_gate` is now STATED in the skill (Finalization
  step 6) and ENFORCED in code for the first time: v5 pre-push hook, merge
  gate first in the chain (`scripts/hooks/pre-push-linux-next-merged.sh`).
  The name collision that concealed it is retired — "local gate" now means
  `./build.sh --check` everywhere in the skill.
- `./build.sh --check` is GREEN on the first macOS host, but only after
  fixing derive-host-identity: fixture leaked the real Mac (`apple`) into
  every mocked scenario (no uname shim), the SUT slugify used GNU-sed `\+`
  (BSD-literal), and the fixture's `--help | grep -q` under pipefail was a
  deterministic SIGPIPE false-FAIL on Darwin. 18/18 now, hermetic on every
  host; gate-stamp memoizes on macOS through the new portable digest
  dispatch (byte-identical digests pinned across sha256sum/shasum).
- "Joining the fleet" gained the macOS paragraph (branch + merge gate, build
  path `scripts/build-macos-tray.sh`, bash-3.2/BSD dialect, expert-absent
  first boot, `--seed`). The next Darwin host should need none of this cycle.

### FIRST-BOOT STATE (recorded)
MCP experts down at start (`down:forge-plan`, `degraded(not-built)`) —
cycle-preflight rebuilt the instrument (`source_commit == HEAD`), cycle ran
through the CLI fallback per `mcp_first_read_path`; mcp_outage line carries
it. This checkout had NO git hooks until `scripts/install-hooks.sh` ran here.
Host slug (post-fix): `macos-m5-apple-tlatoanis-macbook-air`. Litmus wiring
lesson: a litmus file is inert until bound in `openspec/litmus-bindings.yaml`
— the 721-77yu gate caught the three new pins unbound on first run.
