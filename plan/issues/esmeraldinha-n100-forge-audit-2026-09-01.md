# The N100 forge audit — one night, eleven findings, four self-corrections

First working night of esmeraldinha (Windows host, N100/4-core/7.8Gi, WSL2 →
podman → Fedora forge guest; the fleet's lower-bound user-runtime hardware),
2026-08-31/09-01, coordinated from macuahuitl. Operator mandate: what is
invisible on a fat host is loud here; find and file exactly those so future
forge containers ship without them. Everything below is measured in that
guest unless marked otherwise; regimes are stated per finding in the message
log (coordinator session) and summarized here.

## Verdict on stable v56.8.31.3: NO CONFIRMED CONTENT DEFECT

Every candidate fell to mechanism-level adjudication: six suites (versioning-
shape included) to the global-hooksPath defect below; shipped-diagnostic-
tool-dispatch to a guard that greps the comment documenting its own fix's
removal (born red ~a0ea1f169 2026-08-25 — CONFIRM from a free host);
freshness-inventory to a 0.1s budget margin (15.1s vs 15s). Open: hook-
install-portability step 4/5 (generated post-commit content assertion), and
daily-maintenance-day-boundary (bare `fail:` with NO ARM NAMED — run at a
non-boundary hour to split bug from boundary flake). A release cleared by
mechanism beats one cleared by pass rate.

## Fixed already (macuahuitl, with pre-banked verification)

- **Global hooks fire in foreign repos and BLOCK COMMITS** — every /tmp
  fixture and scratch repo on a forge guest; six litmus suites collateral;
  `build.sh --check` dead at 877-mynm; `git commit` impossible outside the
  checkout. Single-variable proof: 6/5 → 11/0 with only the global hook
  removed. Fixed: foreign-repo guard in HOOK_PREAMBLE (install-hooks.sh,
  markers v3/v7/v5). Consider follow-up: scope hooksPath per-repo via
  `includeIf gitdir:` instead of globally.
- **scripts/tillandsias-podman compiled a full dependency tree to learn a
  guaranteed negative** — 105s once per fresh volume, 18ms after (cargo run
  builds as a side effect); only debug/ was ever probed while the forge
  builds --release. Fixed: absent-podman short-circuit + release/ probe.
- **Retired with its lane**: the opencode curl installer (see packet
  opencode-curl-install-never-populates-its-cache — completed).

## The first-launch tax (packet: forge-first-launch-tax)

The expert bootstrap (`ensure_forge_experts`) is the guest's heaviest job and
runs CONCURRENTLY with the whole rest of forge startup. Three-point bracket:
cold+idle 233s (39% of the 600s cap, peak load 2.73) vs stale+contended 516s
(86%, load 7.94) — cold is FASTER than contended by 2.2x, so cache state was
never the risk; SELF-CONTENTION is. Third point (brand-new volume, no
registry) un-measured — it measures the proxy, not this CPU. The 781-6gys
warm path structurally protects only the 2nd..Nth launch at a commit — a
user's fresh install is always a 1st launch. The 2026-08-16 FORGE_EXIT=124
prior art re-reads as probable contention. Fixes, in packet: PRIMARY prebake
tillandsias-plan at image build (publish logic exists, runs one stage late);
SECOND do not run the expert build concurrently with startup (the forge
violates the fleet's own settle rule against itself); timeout bump RETIRED
(61% idle headroom). Positive verification worth keeping: the 781-6gys
copy-out DESIGN HELD — 13G of target/ deleted under a live session and
forge-plan MCP never blinked.

## Forge identity is missing, with two starving consumers (packet: forge-stable-identity)

TILLANDSIAS_WORKSTATION unset; every fallback reports the per-launch
container id. Consequences: (1) `build.sh --check` refused by the
capability-row truth gate (889-ewvt — whose diagnostic is the night's
POSITIVE EXEMPLAR: names condition, sources tried, why publishing would be
wrong, exact remedy); (2) timing telemetry writes host=unknown in 322/337
records — the instrument built to compare hosts discards the host. One fix:
launcher exports the host's fleet name into the guest env. Until it lands, a
forge guest can neither pass its own gate nor attribute its own measurements.

## Forge image/launch hygiene (packet: forge-guest-hygiene)

- `/home/forge/.config/gh` is root:root 0700 — the SINGULAR outlier in an
  otherwise forge:forge config tree; gh dies before argv. Every gh-based
  skill fails closed in guests.
- Launch-time opsx/openspec re-materialization: installed CLI (1.11.0)
  rewrites 22 repo files 11s after clone — SEMANTIC drift (real behavioral
  agent instructions), newer than the commit the checkout reports. No guest
  runs pristine stable; clean-tree gates start dirty. Fix: pin the CLI to
  the repo generation at image build, or commit the regeneration.
- The forge gitconfig latches "THE ORIGIN COULD NOT BE RESOLVED... is a
  FAULT" from a PRE-CLONE transient ("not a git work tree" — false by the
  time anyone reads it): startup ordering race, silently disables the mirror
  redirect for the session.
- Litmus mutates the GLOBAL hooks dir mid-run (hook-install-portability's
  installer step writes into live core.hooksPath): test contamination of
  shared state; needs a sandboxed HOME/hooksPath.

## Litmus instrument findings (packet: litmus-low-end-instrument)

- Precondition gating EXISTS (183/472 skipped — an earlier zero-SKIP claim
  was an instrument error, corrected) but has HOLES: host-browser-mcp-lane
  executed and FAILed on an absence the harness independently confirmed.
- STARVATION is a third verdict category beside infra-absence and content:
  the runner's kill-time saturated/not-saturated adjudication was correct on
  every stamp (4→0 timeouts on idle). Contention multiplier 2.05x
  (5.26 s/suite contended vs 2.56 idle). Scheduling rule: nothing runs on a
  low-end guest until expert state reads ready.
- `--size instant` is not instant on low-end hardware (>900s contended,
  740s idle for the full instant tier): a size label calibrated on fat
  hardware is a scheduling hazard.
- Wasteful-step top five = 33% of all litmus wall in 5 tests, led by
  forge-policy-binary-discoverability at 118.3s, PASSING. Two of three
  over-budget steps are macOS-floor checks paying full price on a Linux
  guest — platform-floor assertions should gate on the platform lane.
- A multi-arm step that fails without naming its arm is unadjudicable by
  construction (daily-maintenance-day-boundary's bare `fail:`). Opposite
  exemplar: 889-ewvt's diagnostic.

## Method lines added to the fleet cheatsheet by this audit

- Subtract yourself before attributing a signal to the environment (five
  instances, two hosts, one night: pgrep self-match ×2, zsh word-splitting,
  retry-cadence-as-periodicity, forensic shim self-catch).
- Confirmation is when the instrument gets the least scrutiny and needs the
  most — re-read the instrument once more when the result agrees with you.
- A RED that does not name its instrument can be false and expensive; a
  green that does not name its artifact can be true and useless.

## Guest provenance gap (small packet: guest-states-own-provenance)

`tillandsias` is not on PATH inside the guest; a guest cannot state which
release binary produced it. Awkward for exactly the reporting the mandate
requires.
