# macOS curl-install e2e smoke — PUBLISHED v0.4.260815.1 (739-dgk4 queue item 3)

- **Host:** Apple Silicon (M1), macOS 26 (Darwin 25.6.0)
- **Agent:** macos-tlatoanis-macbook-air-fable5-20260816t0150z (operator-attended cycle)
- **Channel:** daily — `scripts/resolve-smoke-release.sh daily` → `tag:v0.4.260815.1`,
  the operator-pinned target. (`stable` still resolves v0.4.260810.1; the GitHub
  release is marked prerelease, so `/releases/latest` semantics exclude it — the
  smoke pinned `TILLANDSIAS_RELEASE_BASE` exactly as the runbook prescribes.)
- **Sibling heads at start:** main 0548ee1f · linux-next d1f61fab ·
  windows-next 40516c61 · osx-next b7399e45 (merged up to d1f61fab this cycle)
- **Substrate destroyed:** 2.7G `~/Library/Application Support/tillandsias` +
  `~/Library/Caches/tillandsias` removed after stopping the running tray.

## Step 1 — curl-install from the published release — **PASS**

- `install-macos.sh` fetched via the pinned base, downloaded
  `tillandsias-tray-0.4.260815.1-macos-arm64.tar.gz`, **sha256 ok**
  (`32f6422a…35a3`), extracted to `/Applications/Tillandsias.app`, post-install
  `--diagnose` gate green. Evidence: `target/smoke-e2e/01-install-macos.log`.
- **Version proof:** `CFBundleVersion => 0.4.260815.1`; binary reports
  `git 0548ee1f2` == `v0.4.260815.1^{commit}` exactly. (`--version` prints crate
  0.1.0 — known-open 635-bhkb, unchanged, not a new finding.)
- Zero Gatekeeper over-warn lines (421 remains fixed).
- One cosmetic finding filed below: the banner printed `channel: stable` /
  `resolving latest release` although `TILLANDSIAS_RELEASE_BASE` overrode both.

## Step 2 — destructive substrate reset — **PASS**

Tray stopped (single PID), both state dirs removed, confirmed absent.
Evidence: `target/smoke-e2e/02-substrate-before.txt`, `02-reset.log`.

## Step 3 — pristine provision + first boot — **PASS**

- `--provision`: 528 MB Fedora Cloud image downloaded, converted, resized;
  `{"status":"provisioned"}`; exit 0. Evidence: `03-provision.log`.
- Post-provision `--diagnose --json`: exit 0,
  `guest_binary_staged_matches_bundle: true`. Evidence: `03-diagnose.json`.
- First boot `--exec-guest uname -a`: VM reached Ready, control wire up,
  `Linux tillandsias-vm 6.19.10-300.fc44.aarch64`, clean one-shot stop, exit 0.
  **No 663-69kp wedge** in the published artifact. Evidence: `03-exec-guest.log`.

## Step 3b — credential path from a wiped vault — SEE FINDINGS

- `--list-cloud-projects` on the fresh substrate: vault bootstrap clean
  (Phase 6.5 hardened; vault + git images built on demand per order 253), then
  a **correct, loud refusal**: `vault-cli: HTTP error reading
  secret/data/github/token: … 404`, op exit 1. This is the documented
  re-authenticate-once consequence of destroying the in-VM vault — the 404 is
  the system telling the truth, not a regression. Evidence: `03-list-cloud.log`.
- Re-seed attempt 1: `--github-login --with-token` was **silently ignored**
  rather than refused (finding filed below); the run consumed the token from
  stdin, then correctly refused `git author name and email are both required`
  when the pipe held nothing further. Auth preflight ran BEFORE credential
  prompts and the guest asked token-first (663-acdw fix live in the release).
  Evidence: `03-github-login.log`.
- Re-seed attempt 2 (token+name+email piped to `--github-login`, operator-
  authorized unattended flow): **PASS** — auth preflight, token-first prompt
  order, `GitHub authentication complete for 8007342`, token in guest Vault,
  exit 0, nothing sensitive printed. Evidence: `03-github-login-2.log`.
- Post-seed `--list-cloud-projects` (701-g98y re-verify, product surface not
  log line): **PASS** — real repo listing streamed (11+ repos), exit 0. The
  full credential-durability path from a destroyed substrate is proven
  unattended: keychain-share vault re-init → stdin re-seed → live listing.

## Step 4 — forge lane: BigPickle smoke-mode validation — **RAN; SHORT-CIRCUITED BY DESIGN**

- `--opencode ~/src/tillandsias --prompt <smoke-mode validation>`: VM booted,
  control wire up, router/inference/forge-base/forge images built on demand,
  OpenCode (BigPickle) launched, honored the prompt, and **stopped at the
  operator-directed push-wiring short-circuit after ~2 tool calls**:

  ```
  [check-credential-channel] TILLANDSIAS_HOST_KIND=forge but origin does not
  resolve to the enclave git mirror (effective origin:
  git://git-6no98mm4837ff0lpr5c0/tillandsias): no usable push channel. Fix the
  forge gitconfig injection or provide a forge credential channel; do NOT
  import host credentials.
  missing:no-credential-channel
  ...
  MO-SMOKE: FAIL push-wiring: missing:no-credential-channel — origin does not
  resolve to the enclave git mirror
  ```

  Evidence: `target/smoke-e2e/04-opencode.log:26-37`. Lane teardown clean
  (`opencode-finished exit_code 0`). Two readings, both important:
  - **Harness finding (real defect):** the macOS forge lane has no push
    channel — origin is a raw anonymous `git://<container>` URL. Promoted to
    index packet **760-w76k** (`macos-forge-origin-not-rewritten-to-enclave-mirror`),
    the macOS face of the 756-2jnj/759 fleet class.
  - **Guard validation (PASS):** the fail-closed credential guard refused
    BEFORE any drain, with correct remediation guidance — the exact behavior
    the fleet wants — and the short-circuit prompt kept token spend to the
    two probe calls. The agent, prompt honoring, expert environment, and
    MO-SMOKE grammar all worked in the published artifact.
- Not run in-forge (stopped by directive): litmus counts, ledger staleness
  report. Noted: the seed checkout `~/src/tillandsias` is parked on `main` @
  1496e89f, 562 commits behind origin/main — see observation below.

## Step 5 — post-condition after the last mutating step — **PASS**

Final `--diagnose --json` AFTER the forge lane (the last mutating step):
exit 0, `guest_binary_staged_matches_bundle: true`, `vm_owner_live: false`.
Evidence: `target/smoke-e2e/05-diagnose-final.json`.

## Verdict summary

| Step | v0.4.260810.1 (prior smoke) | v0.4.260815.1 |
|------|------------------------------|----------------|
| 1 curl one-liner (pinned) | PASS | PASS (banner nit filed) |
| 2 destructive substrate reset | (not exercised) | PASS |
| 3 pristine provision + first boot | PASS (attended) | PASS (unattended, no 663-69kp wedge) |
| 3b credential path from wiped vault | (not exercised) | PASS (unattended re-seed + live listing) |
| 4 forge lane | PASS (attended, tray lane) | agent+enclave PASS; **push wiring FAIL → 760-w76k** |
| 5 post-condition diagnose | (n/a) | PASS |

**Nothing that passed on v0.4.260810.1 fails on v0.4.260815.1**; the push-wiring
defect is newly *visible* (the fail-closed guard shipped in this release), not
newly *introduced* — anonymous `git://` origins cannot ever have pushed.

## Observation (not promoted): stale forge seed checkout

`~/src/tillandsias` (the forge's project checkout) sits on `main` @ 1496e89f,
562 commits behind origin/main, two releases old. Validation forges launched on
it see a 5-day-old ledger. Host-local state, operator-owned; flagging for the
next attended window rather than packeting — but any in-forge validation
prompt should keep asking the forge to report its own HEAD/staleness (this
cycle's prompt did).

## Findings

### Work Packet: smoke-finding/install-macos-banner-misstates-channel-under-release-base-pin

- id: `smoke-finding/install-macos-banner-misstates-channel-under-release-base-pin`
- owner_host: any
- capability_tags: [shell, release, install]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260815.1`
- evidence:
  - `target/smoke-e2e/01-install-macos.log:1` — `channel: stable` +
    `resolving latest release` printed while `TILLANDSIAS_RELEASE_BASE` pinned
    the daily v0.4.260815.1 base (which the download then correctly used).
- repro:
  - `curl -fsSL <base>/install-macos.sh | TILLANDSIAS_RELEASE_BASE=<daily-base> bash`
- next_action: >
    When TILLANDSIAS_RELEASE_BASE is set, print `channel: pinned (<base>)`
    instead of the resolved-channel banner, so the evidence line in every smoke
    log states what was actually used. The override is documented
    (install-macos.sh:32) — only the printed claim is wrong. Same check for
    install.sh / install-windows.ps1 for grammar parity.
- events:
  - type: discovered
    ts: 2026-08-16T02:10:00Z
    agent_id: macos-tlatoanis-macbook-air-fable5-20260816t0150z
    host: macos

### Work Packet: smoke-finding/github-login-silently-ignores-unknown-trailing-flags

- id: `smoke-finding/github-login-silently-ignores-unknown-trailing-flags`
- owner_host: macos
- capability_tags: [macos, tray, fail-loud]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260815.1`
- evidence:
  - `target/smoke-e2e/03-github-login.log` — `--github-login --with-token`
    proceeded to drive the guest login instead of refusing; the unknown-flag
    refusal (main.rs:232, added for exactly `--with-token`, 663-acdw) only
    guards the fall-through path, so a recognized mode silently swallows
    trailing unknown flags.
- repro:
  - `echo x | tillandsias-tray --github-login --with-token` (any bogus flag
    after a recognized mode reproduces)
- next_action: >
    Validate the FULL argv inside each recognized mode (or centrally, before
    mode dispatch): an unknown flag alongside --github-login/--exec-guest/etc.
    should exit 2 with the same guidance message the fall-through refusal
    prints. The 663-acdw lesson was "refuse loudly"; today the refusal exists
    but is reachable only when NO recognized mode is present.
- events:
  - type: discovered
    ts: 2026-08-16T02:14:00Z
    agent_id: macos-tlatoanis-macbook-air-fable5-20260816t0150z
    host: macos
