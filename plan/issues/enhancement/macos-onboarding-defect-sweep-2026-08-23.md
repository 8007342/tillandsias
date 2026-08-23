# macOS onboarding defect sweep — first Darwin host joins the fleet

Date: 2026-08-23 (UTC). Host: `macos-m5-apple-tlatoanis-macbook-air`
(macOS 26.x, Darwin 25.6.0, system bash 3.2). Branch: `osx-next`,
fast-forwarded to `origin/linux-next` @ `cef7c023b` at cycle start.
Ledger: orders **851-gpb5** (the sweep, done) and **851-28b5** (residuals,
ready). Operator directive: fix your own onboarding, not drain packets.

## What was fixed (851-gpb5)

Six operator-verified defects plus one found live when this cycle's own
`./build.sh --check` went red. Every fix carries a fixture with an embedded
mutation-control arm (cmp-verified mutants, exactly the bound assertion goes
red); details and file list live in the 851-gpb5 packet. Highlights that are
lessons, not just fixes:

1. **A stated-but-unenforced rule hid behind an enforced namesake.**
   `pull_merge_cadence.pre_push_gate` (merge `origin/linux-next` before EVERY
   platform push) was in methodology, CLAUDE.md and two script comments —
   and in no code. The skill meanwhile used "pre-push gate" to mean
   `./build.sh --check`, so every reader who went looking found a healthy
   gate of the same name and stopped. Now: the skill says "local gate" for
   `--check`, states the methodology rule in Finalization step 6, and the v5
   pre-push hook enforces the merge half
   (`scripts/hooks/pre-push-linux-next-merged.sh`, first in the chain).
2. **The gate could not pass on the platform being onboarded.**
   `derive-host-identity`'s fixture pinned lspci/nvidia-smi/hostname but not
   `uname`, so the real Mac leaked `apple` into every mocked-Linux scenario
   (10/17 red); the SUT's slugify used GNU-sed `\+` (literal on BSD sed —
   `Yoga_ThinkPad` stayed `yoga_thinkpad`, two identities for one host); and
   the fixture's own `--help | grep -q` under pipefail died of SIGPIPE
   deterministically on Darwin — the exact shape the
   sigpipe-verdict-pipelines family forbids in gates. Fixtures are not
   exempt from the repo's own portability and SIGPIPE rules.
3. **Memoization loss on old Macs is silent.** gate-stamp's bare `sha256sum`
   (absent before macOS 13) fails into a swallowed stderr and a hook that
   forever demands a re-run whose stamp can never be written. The portable
   dispatch is pinned by a fixture proving digests are BYTE-IDENTICAL across
   `sha256sum`/`shasum`, so existing stamps stay valid across hosts.

## First-boot observations (recorded, remedied where possible)

- MCP experts DOWN on first boot (`down:forge-plan`, `degraded(not-built)`);
  `scripts/cycle-preflight.sh` built `./target/release/tillandsias-plan`
  (serving `source_commit == HEAD`) and the cycle ran through it by path per
  `mcp_first_read_path`. The health probe recorded the outage.
- This checkout had NO git hooks installed until this cycle ran
  `scripts/install-hooks.sh` — a fresh clone pushes with no VERSION guard and
  no local gate until someone remembers. The new fleet paragraph makes it a
  named first step for Darwin hosts; consider wiring hook installation into
  first-run tooling (residual, 851-28b5 adjacent).
- `plan/mo-full-attestations.d/tlatoanis-macbook-air.md` already exists from
  pre-reduction cycles, so 848-bx2q's new-host first-attestation trap was not
  expected to fire here.

## Residuals

Split into **851-28b5** (ready, any host): remaining bare `sha256sum` sites,
`uninstall.sh`'s genuinely-empty-input `xargs -r`, the build-gate sense of
"pre-push gate" in prose outside the skill, and methodology
`lane_exclusion`'s reference to a `lane-exit.sh` that exists nowhere — a
second stated-but-unenforced clause of the same rule this sweep mechanized.
