# Forge tool availability gaps — next forge run should have these

- date: 2026-08-01
- class: enhancement/
- found by: forge cycle 2026-08-01T00:26Z (order-553 groundtruth reconciliation; operator
  "NEXT FORGE RUN WILL BE BETTER" directive)
- host: forge (TILLANDSIAS_HOST_KIND=forge), branch linux-next
- owner: linux (forge base image + litmus runner)

## What

Three tools the forge runbook assumes are available are NOT discoverable on PATH in a
forge container, or the tooling around them mis-fires. None blocks the work this cycle
did (the graded-binary steps were verified directly), but each slows or mis-reports
future forge cycles:

### 1. `ruby` absent — sanctioned YAML-validation fallback and plan-archive tooling dead

- `ruby -ryaml -e "YAML.load_file(...)"` is the approved validator fallback in the
  meta-orchestration finalization (methodology.yaml / meta-orchestration skill), used
  when the `tillandsias-policy validate-yaml` binary is not built. The forge base image
  (images/default/Containerfile.base microdnf list) does NOT install `ruby` at all, and
  nothing installs it at first-run — so a forge cycle that needs to validate touched
  YAML with the fallback has NO tool. Grep: `grep -c ruby images/default/Containerfile.base` = 0.
- `scripts/archive-plan-packets.sh` also `exec`s `ruby scripts/archive-plan-packets.rb`
  (and `archive-plan-packets-check.rb`) — dead in a forge too.
- Fix candidates: add `ruby` (+ `ruby-libs`/yaml binding) to Containerfile.base's
  microdnf list, or make first-run provisioning (lib-common.sh) install it, or replace
  the ruby fallback with a rust/shell validator that ships in the base.

### 2. `tillandsias-policy` binary not discoverable — `validate-yaml` approved validator unreachable

- `tillandsias-policy validate-yaml <files>` is THE approved validator. In the forge the
  crate builds (cargo build -p tillandsias-policy, ~seconds) but lands in
  `$CARGO_TARGET_DIR/debug/tillandsias-policy`
  (/home/forge/.cache/tillandsias-project/cargo/target/debug/…), NOT in
  `target/debug/` next to the checkout and NOT on PATH.
- Several scripts assume the binary sits at `target/debug/tillandsias-policy`
  (e.g. scripts/check-no-python-scripts.sh:8, check-cheatsheet-sources.sh:45,
  audit-cheatsheet-sources.sh:33, check-cheatsheet-tiers.sh:61,
  test-pre-receive-yaml-gate.sh, distill-forge-diagnostics.sh, fetch-cheatsheet-source.sh,
  regenerate-cheatsheet-index.sh) and `scripts/tillandsias-podman` also probes
  `target/debug/tillandsias-podman-cli` before falling back to cargo run. With
  CARGO_TARGET_DIR redirected in the forge, `exec target/debug/…` fails with
  `No such file or directory`. This is a discoverability gap, not a build gap.
- Fix candidates: (a) make those scripts resolve via `cargo metadata`/`$CARGO_TARGET_DIR`
  or a `scripts/run-policy.sh` wrapper that builds-then-execs from the real target dir;
  (b) install `tillandsias-policy` to `$HOME/.local/bin` at first-run beside the
  `tillandsias-plan` expert binary (ensure_forge_experts pattern).

### 3. litmus runner podman preflight ENV-FAILs a forge on a NON-podman test

- scripts/run-litmus-test.sh preflight (lines ~630-637) fires when:
  `grep -qE '^[[:space:]]*command:.*(^|[ ;|&(])podman[[:space:]]'` matches the test FILE.
  The order-394d groundtruth harness (litmus-expert-groundtruth-harness.yaml) triggers it
  NOT because any step runs podman but because one STEP's *query payload text* contains
  the words "how do I run podman rootless" (the `plan.answer` unregistered-corpus probe,
  step line ~182). Then `command -v podman` succeeds because the runner itself put a
  podman shim on PATH ($LITMUS_RUNTIME_DIR/bin/podman, line 88-139), and `timeout 5
  podman ps` delegates to a REAL podman that does not exist in the forge → ENV-FAIL
  "podman unresponsive" before any step runs. Result: a green-reconciled fixture is
  reported as ENV-FAIL/FAIL by the runner.
- Observed: `litmus:expert-groundtruth-harness` → `[ENV-FAIL] podman unresponsive (>5s)`
  in this forge, while 11 sibling litmuses in the same spec PASSed (they do not mention
  the word podman).
- Fix candidates: (a) scope the preflight trigger to commands that INVOKE podman at the
  start of a word (e.g. `command:.*(^|[ ;&|])podman (run|ps|create|rmi|…)`) rather than
  any occurrence including inside quoted payloads; (b) check `$REAL_PODMAN_BIN` (captured
  at line 85 BEFORE the shim) instead of `command -v podman` (which sees the shim); (c)
  skip when the shim's real podman is absent (forge has no podman by design — it's
  host-side) instead of ENV-FAILing. Preserve the real intent: catch a STALLED host
  podman, don't flag its absence in a forge.

## Why it matters

Every forge cycle runs finalization (validate touched YAML), and many run litmus gates.
Cycle 2026-08-01 lost time to: no ruby fallback (had to build tillandsias-policy from
cargo and point the graded binary directly), no on-PATH tillandsias-policy, and a
misleading ENV-FAIL on the groundtruth litmus. The "next forge run will be better" bar:
ruby present (or fallback replaced), tillandsias-policy reachable from scripts, and the
podman preflight not false-positive on payload text / absent-podman forges.

## Smallest next action

Split into three ready packets (orders 560-562) with named verifiable closures, then
drain on a capable host:

- 560: ruby in the forge base (or a shell/rust YAML validator replacing the ruby
  fallback), proven by `ruby -ryaml -e 'puts "ok"'` at launch / a first-run probe.
- 561: tillandsias-policy reachable for the scripts that assume target/debug/…
  (CARGO_TARGET_DIR-aware resolution or install-to-PATH), proven by
  `scripts/check-no-python-scripts.sh` exiting clean from a CARGO_TARGET_DIR-redirected
  forge.
- 562: litmus podman preflight re-scoped (payload text + absent-podman-safe), proven by
  `litmus:expert-groundtruth-harness` running its real steps in this forge.
