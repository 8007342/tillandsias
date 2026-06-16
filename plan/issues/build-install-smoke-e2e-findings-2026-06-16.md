# Build/install smoke E2E findings - 2026-06-16

Status: pass

Full destructive Linux build/install/reset/init/forge smoke passed on the
integrated `linux-next` head.

## Evidence

- log_dir: `target/build-install-smoke-e2e/20260616T072454Z`
- build/install: `./build.sh --ci-full --install` passed
- installed binary: `Tillandsias v0.3.260616.1`
- litmus: evidence bundle reported 140 passed, 0 failed
- evidence bundle:
  `target/convergence/evidence-bundle-20260616-073151.tar.gz`
- substrate reset: `podman system reset --force` completed and empty
  containers/images/volumes were verified
- pristine init: `tillandsias --init --debug` completed with `init_exit=0`
- prompted forge: `tillandsias . --opencode --prompt "Use the /forge-continuous-enhancement skill"`
  completed with `forge_exit=0`

## Notes

The forge diagnostics pass filed proposal backlog items, not smoke failures.
Critical/high proposal triage is tracked in
`plan/issues/forge-enhancements-run-2026-06-16.md` and surfaced through
`plan/issues/ACTIVE.md`.

---

## Second run (Pass — full E2E) — 20260616T081336Z

A second full E2E pass ran later the same day (paced loop, step 1). Recorded
separately so the convergence record shows the build was re-exercised.

- Discovered by: `/build-install-and-smoke-test-e2e (linux)`
- Host: Linux (`macuahuitl`)
- Branch: `linux-next`
- Commit under test: `591d4dde02f06cf00db9a90d3d963e9ba291844a`
- Installed build: `Tillandsias v0.3.260616.2`
- Evidence: `target/build-install-smoke-e2e/20260616T081336Z/`
- Working tree at start: **dirty** (pre-existing, not modified by this skill) —
  `Cargo.lock`, `VERSION`, four crate `Cargo.toml`s, `TRACES.md`,
  `docs/convergence/centicolon-dashboard.{json,md}`, four `openspec/specs/*/TRACES.md`,
  `plan/metrics-dashboard.md`; untracked `build-proxy.log`. Recorded, left untouched
  per skill rules.
- Passed gates: `./build.sh --ci-full --install` exited 0 (pre-build CI green,
  runtime residual litmus 5/5, evidence bundle generated); installed to
  `~/.local/bin/tillandsias` (`v0.3.260616.2`); `podman system reset --force`
  exited 0 with empty store; `tillandsias --init --debug` exited 0 from pristine
  (all images built, `tillandsias-enclave` network created, Vault healthy
  `initialized=true sealed=false v=1.18.5`, bootstrap complete); forge lane
  exited 0 — in-forge agent ran diagnose-forge (100% completeness, 25/25),
  filed `2026-06-16-install-gradle.md` + `2026-06-16-install-flutter-sdk.md`.
- Outcome: **PASS** end-to-end. Two non-blocking observations:
  - Build auto-bumps `VERSION` (`.1 → .2`) as a side-effect — expected, recorded
    so the dirty-tree version delta is not misread as drift.
    Evidence: `…/20260616T081336Z/00-version.txt` vs `01-installed-version.txt`.
  - Forge entrypoint logs `OpenSpec init failed — /opsx commands may not work`;
    the agent fell back to `Write` and completed (exit 0). Confirm whether
    `/opsx` is expected inside the opencode forge or the warning is benign.
    Evidence: `…/20260616T081336Z/04-forge-continuous-enhancement.log:3`.
