# Fleet restart drill — pirria findings

Per-host file (coordinator folds these; the main `fleet-restart-2026-09-12.md`
has one writer). FLAT name deliberately: a `.d/` subdirectory matches the
pre-push lane's `*/*` arm and takes the FULL gate on every note.

## 2026-09-13 — pirria (floor host, CachyOS, 15 GiB / 4 cores)

- **An instrument that asks a narrower question than the product answers will
  report a false PASS, and the floor host is where that costs most.**
  `probe-credential-cold-state.sh` asks the keychain; vault reads keychain OR a
  `~/.cache/tillandsias/fallback_*` file. On pirria the fallback has survived
  since 2026-09-01, so the probe said `credential-cold` in the same run whose
  init log says `preserving existing data volume`. Filed as
  `smoke-finding/credential-cold-probe-reads-keychain-only` (p1). The
  generalisable half: yoga and lenovinha reading `credential-warm` are *safer*
  than pirria reading cold, because a wrong warm is discounted and a wrong cold
  is spent. When adding a verdict to a probe, enumerate every source the
  PRODUCT consults before deciding what the verdict may claim.

- **A good diagnostic pointed at the wrong cause is worse than a terse one.**
  `tillandsias-plan blocked-on` answers "the ARTIFACT is stale — rebuild it or
  relaunch the forge". The binary has `blocked-by` and has never had
  `blocked-on`; the MCP layer advertises `plan_blocked_on`. So the cheapest
  correct action (fix the name) is the one the error rules out, and the
  expensive wrong one (rebuild, relaunch a forge) is the one it prescribes.
  Filed as `smoke-finding/plan-binary-blocked-on-surface-skew` (p3). Rule worth
  keeping: a stale-artifact message should require evidence of staleness — the
  name present in sources and absent from the binary — not infer it from
  "unknown".

- **§4 survived on 15 GiB this time, so the 4a boundary is still a boundary and
  not a threshold.** `setsid nohup` detachment, lane completed in 66 m 39 s,
  `opencode_exit=0`, supervisor intact, no kernel oom-kill. The 2026-09-04 run
  on this same host lost its supervisor at the same memory. Two runs, same host,
  same size, different outcomes — which is the definition of marginal. Do not
  promote 15 GiB to "sufficient" on the strength of this run; record it as the
  second data point on a line that still has no measured crossing. Detaching is
  what made the difference observable, not what made the host adequate.

- **`timing_reap` emitted nothing at §0, which is itself the report.** It means
  no earlier pirria smoke left an orphaned stamp — the 1026-ps4n instrument
  answering "nothing was lost" rather than staying silent for lack of data. Five
  `phase=smoke` records landed this run, all `exit: 0`. The floor host is now
  routinely writing the metrics no cargo-gated emitter could ever produce here.

- **A warm store makes a step's duration incomparable, and the number does not
  say so.** `smoke-curl-install` recorded 7.5 s against the ledger's 175 s for
  the earlier cachyos run, purely because §1 ran with 18 images and a live vault
  already present. Same step, same host, same release, 23x apart. Any reading of
  these records across runs has to carry the store's state or it is comparing
  two different operations that share a name.
