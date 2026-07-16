# Order 350 — Windows current-build forge live config/mirror/TLS parity evidence (2026-07-15)

- run_by: `windows-bullo-fable5-20260715T2315Z` (Linux coordinator remote-control
  directive: evidence tonight), Windows 11 Home 26200, WSL 2.7.10
- verdict: **PARTIAL PARITY — TLS + gitconfig-path GREEN; GitHub→mirror URL
  rewrite ABSENT in the Windows wire lane (known push-channel gap, now
  current-build-confirmed through the public path); packet blocked on that
  linux-owned injection gap**

## Identity evidence (exit criterion 1) — recorded BEFORE behavior probes

| Surface | Identity |
|---|---|
| Checkout under test | windows-next `a283f8ce` (= HEAD; VERSION 0.3.260715.6) |
| Installed tray | `tillandsias-tray 0.3.260715.6 (a283f8ce)` — embedded SHA == HEAD |
| Guest binary | current-checkout musl build v0.3.260715.6, **built on this Windows host via the wsl2 wrapper** (x86_64 + aarch64, `build-guest-binaries.sh --verify` PASS) |
| Guest injection | tray log `Injecting embedded tillandsias-headless binary arch=x86_64` — NO release-fetch fallback, no version skew |
| Runtime | refreshed: `wsl --unregister` then cold `--provision-once` → `VM Ready — control wire up ✓` wire v2 attempt=1; diagnose exit 0, `wsl_platform: ok` |
| Lane path | PUBLIC argv (host-shell `launch_spec`): `/bin/bash -l -c "exec tillandsias-headless --cloud 'parity-fixture' --bash"` via `wsl.exe` — same argv the tray menu spawns |
| Fixture | `/home/forge/src/parity-fixture` local project (fresh guest vault has no GitHub token; order-325 blocks non-interactive `--github-login`, so a cloud clone was not attemptable unattended) |

Pre-stage parity (source+unit half of
`scripts/test-forge-config-trust-cross-platform-parity.sh`) ran through the
wsl2 wrapper: source pins + 4 unit suites PASS; the two podman-bound
sub-scripts were correctly out of wrapper scope (methodology
`wsl2_hybrid_work` boundary) and are superseded by the live lane below.

## Live in-forge probe results (probe-results.txt, 2026-07-15T23:49:53Z)

| Probe | Result | Detail |
|---|---|---|
| whoami / pwd | forge / `/home/forge/src/parity-fixture` | lane attached to the project forge |
| gitconfig-origin (crit 2a) | **PASS** | `git config --global --show-origin` → `file:/home/forge/.gitconfig` (safe.directory, credential.helper, core.hookspath all from it) |
| mirror-rewrite (crit 2b) | **FAIL** | `url.*insteadOf` rewrite-config EMPTY; `git ls-remote --get-url https://github.com/8007342/tillandsias` resolves to github.com, NOT the mirror |
| mirror-fetch (crit 3a) | PASS | `git ls-remote` against github.com succeeds through the enclave (spliced TLS, system store) |
| mirror-push-dryrun (crit 3b) | SKIP | fixture worktree had no origin; a meaningful mirror push needs the rewrite (blocked by 2b) |
| no-ca-override ×5 (crit 3c pre) | **PASS** | GIT_SSL_CAINFO / SSL_CERT_FILE / REQUESTS_CA_BUNDLE / NODE_EXTRA_CA_CERTS / CURL_CA_BUNDLE all unset |
| tls-curl (crit 3c) | **PASS** | `curl https://github.com` clean |
| tls-node (crit 3c) | **PASS** | node https.get → 200 (no extra CA config) |
| tls-python (crit 3c) | **PASS** | python3 urllib https → clean |

## Findings

1. **Mirror-rewrite gap current-build-confirmed on the Windows wire lane
   (crit 2b FAIL)**: the forge gitconfig carries safe.directory /
   credential-helper / hookspath but NO GitHub→mirror `insteadOf` rewrite.
   This is the already-filed wire-lane gitconfig/mirror-injection gap
   (forge-credential-guard-push-channel-gap-2026-07-08; first Windows repro
   2026-07-13) — now reproduced at a283f8ce through the fully-public lane
   path with a current-checkout guest. The fix is linux-owned (headless
   lane-launch gitconfig injection); order 350 stays open/blocked on it.
2. **NEW: maintenance-session container name collision on lane relaunch**
   (order-314 class, different surface): second `--cloud <p> --bash` lane
   fails `creating container storage: the container name
   "tillandsias-parity-fixture-forge-maintenance" is already in use` →
   status 125. The order-314 fix (`podman run --replace` in the dependency
   ensure) never reached the maintenance-session launcher. Packet filed
   (provisional windows-260715-4, linux pickup — headless launch path).
3. **Corroboration**: ncurses bottle attestation failure during lane
   bootstrap (`brew install direnv failed`) — order-359's exact repro; on
   this fresh guest the vault has no GitHub token, so the 359 host-side
   HOMEBREW_GITHUB_API_TOKEN injection had nothing to inject. Same
   credential-channel root as finding 1; no new packet.
4. Probe-harness notes for future lane evidence: PTY echo makes inline
   stdin capture unusable — stage the probe script into the bind-mounted
   worktree and write results to a file there; MSYS path conversion must
   be disabled (`MSYS_NO_PATHCONV=1`) for `wsl -- /bin/bash ...` argv.

## Residuals / next actions

- Criterion 2b + the push half of 3b: land the wire-lane gitconfig mirror
  injection (linux; the push-channel gap issue), then re-run THIS probe set
  (staged script + file capture; ~5 min warm) to flip the verdict.
- 326 criterion-2 (real cloud clone) remains gated on non-interactive
  GitHub login (order 325) or an attended session.

---

## 2026-07-16 — ROOT CAUSE FOUND + FIXED; crit-2b/3a/3b re-probed GREEN

- run_by: `windows-bullo-fable5-20260716T0731Z`; runtime = the same
  registered guest (NOT re-provisioned; vault + operator GitHub auth
  preserved), guest headless hot-swapped to current-checkout
  v0.3.260716.5 (musl, wsl2-wrapper build), host tray = stable 0712.1
  (uninvolved: lanes launched via the public wsl.exe argv).

### Root cause (one bug, three symptoms)

The 2026-07-15 verdict ("linux-owned lane-launch injection gap") was WRONG
in mechanism: the injection engages fine. The launcher-side helpers shell
out to `git`, and the WSL2/VZ **guest OS ships no git binary** (git exists
only inside forge containers):

1. `read_host_project_origin_url` → `None` → `write_forge_gitconfig` omits
   the `url.insteadOf` rewrite (yesterday's crit-2b FAIL; additionally
   masked by the no-origin parity fixture).
2. Same `None` → `build_git_run_args` never learns the upstream → the
   per-project mirror container is absent from lanes (2026-07-13
   observation "no tillandsias-git-tillandsias observable").
3. `write_forge_repo_gitdir` (git_config_set / write_forge_index) aborts →
   `append_forge_repo_gitdir_mount_args` falls back to the fail-closed
   EMPTY `--tmpfs …mode=0700` mask over `.git` → "root-owned mode 700
   .git" as seen by Hy3 (order 382's field evidence — same root cause).

### Fix (windows-next, this cycle; PLEASE REVIEW: linux — shared code)

- `.git/config` direct-parse fallback for the origin URL
  (`parse_gitdir_origin_url`, 3 unit pins).
- Facade staging git-less: local config written directly; index deferred
  with a loud log when git is absent; staged facade chown'd to the forge
  container uid (1000) so in-container `git read-tree HEAD` can
  materialize the index (root launcher + keep-id made a root-owned facade
  unwritable — the read-tree EACCES → empty-index all-deleted status).

### Live probe results (same protocol, project WITH origin: `tillandsias`)

| Probe | 2026-07-15 | 2026-07-16 |
|---|---|---|
| gitconfig-origin (2a) | PASS | PASS (`file:/home/forge/.gitconfig`) |
| mirror-rewrite (2b) | FAIL (empty) | **PASS** — `url.git://tillandsias-git/tillandsias.insteadOf=https://github.com/8007342/tillandsias.git`; ls-remote --get-url resolves to the mirror |
| mirror container | absent | **UP** (`tillandsias-git-tillandsias`, DNS 10.0.42.x) |
| repo readability (382) | n/a (root-owned mask) | **PASS** — `git rev-parse HEAD` = 9b217958 in-forge |
| credential guard | missing:no-credential-channel | **ok:forge-git-mirror** |
| mirror fetch (3a) | (github direct) | **PASS through mirror** — live upstream deltas served (linux-next 37602c0c..e37711f0) |
| mirror push dry-run (3b) | SKIP (no origin) | **PASS** — `To git://tillandsias-git/tillandsias  * [new branch] HEAD -> probe-350-noop` |

### Remaining for full packet closure

- Crit-1 identity formality: locally built CURRENT tray + refreshed cold
  provision. A re-provision wipes the vault (operator re-login is
  attended) — deliberately NOT done this cycle to preserve the goal
  demonstration; schedule with the operator.
- The end-to-end transparent push proof rides the goal packet
  (windows-260716-1): in-forge agent cycle push verified on GitHub
  out-of-band.
