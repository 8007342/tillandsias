# Smoke e2e findings — v56.9.25.2 — 2026-09-26 — macOS — macbookair

- run_start: 2026-09-26T01:53:31Z
- evidence_dir: target/smoke-e2e   (previous run archived under _archived-20260926t015331z/)
- forge_lane_outcome: **unfinished at cap, no guard line observed** — stopped by SIGTERM at the 3h cap (etime 03:00:09, 2026-09-26T04:55:20Z, `opencode_exit=143`). NOT a pass, and NOT a cold-host guard stop: no `blocked:upstream-*` line ever appeared.
- signature_verification: cosign:verified:1/1 (tillandsias-tray-56.9.25.2-macos-arm64.tar.gz)

**Verdict: §1–§3 PASS; §4 UNFINISHED (no verdict).** Operator approved the VM wipe for this run
directly (2026-09-25); coordinator GO relayed by macuahuitl with the ledger row at 182033fd7.

Host: tlatoanis-macbook-air, macOS 27.0 arm64, 10 cores / 16 GiB (guest sized 8 vCPU / 8 GiB),
GNU bash 3.2.57, cosign v3.1.3 (installed via brew for this run), jq-1.8.2.
Sibling heads at start: main ce2da1f57, linux-next 182033fd7, windows-next 28ad32365, osx-next 1bf1aad09.

## Steps

| Step | Result | Evidence |
|---|---|---|
| §1 curl-install (tag-pinned `TILLANDSIAS_RELEASE_BASE=…/download/v56.9.25.2`) | PASS: install_exit=0, curl_exit=0, into /Applications (no ~/Applications fallback) | 01-install-macos.log, 01-install-macos-exit.txt |
| §1 version | PASS: `tillandsias-tray 56.9.25.2 (git ce2da1f57, built 2026-09-26T01:19:13Z)` | 01-version.txt |
| §1s signature | PASS: `cosign:verified:1/1` on the tarball the installer consumed | 01s-cosign-verdict.txt |
| §2 destroy | PASS: step2_exit=0; before 1.4G VM dir + 4K cache; residue empty; tray stopped | 02-destroy-before.txt, 02-macos-residue.txt |
| §3 cold `--provision` | PASS: provision_exit=0 (downloaded + converted the Fedora Cloud image); rootfs.img newer than the destruction marker; no error/warn lines in 110 log lines | 03-provision.log |
| §3 `--diagnose --json` (LAST in §3) | PASS: exit 0; provisioned=true; rootfs_present=true; version="56.9.25.2" | 03-diagnose.json |
| §3b guest container shutdown | NOT CHECKED — stated macOS gap (substrate is a VZ VM; the runbook's loop runs in-guest or not at all) | — |
| §4 forge lane | UNFINISHED at the 3h cap; see findings | 04-opencode.log (24 lines), 04-cap.txt, 04-guest-recovery*.log |

§4 was run as `tillandsias-tray --opencode /home/forge/src/tillandsias --prompt "Use the /meta-orchestration skill"`,
detached (`nohup … & disown`), watched by process liveness and VM CPU because the one-shot agent
prints nothing until it exits. Stopped at 3h by agreement with the coordinator.

## Ledger claims (row read in §0.2b)

- **EXERCISED:** the release installs, verifies and provisions on macOS at the published tag;
  the tray reports 56.9.25.2 on both surfaces (`--version`, `--diagnose --json`).
- **NOT APPLICABLE:** Linux `--reset-state` refused on every clean host (1371-a7w2; keyring
  `NoEntry` read as already-absent) — Linux lane; GPU container start names its cause (1248-j6vd) —
  Linux; reset_state env tests serialized (1369-a76a) — test-suite change; release-workflow nix
  `http2 = false` + `fallback = true` (1272-95ng) — CI.
- **NOT CHECKED:** the "known, shipping with it" unstable-URL installer channel default
  (1369-sjbc) — this run pinned the exact tag, as instructed, so it did not exercise the default.

## Findings

### Finding (a) — the forge seeded from branch `main` of a month-old host checkout

Recorded as an event on the existing row **965-rb3v** (tray-launched forge seeded from main, not
the checkout branch), not a new packet.
`04-opencode.log`: `[forge-launch] SEED main from /home/forge/src/tillandsias` and
`seed-staleness: branch=main local=unknown last-fetched-origin=unknown behind=unknown fetch-age-h=unknown verdict=unknown`.
The host `~/src/tillandsias` is on `main` at 341ab0010 (2026-08-25), so the lane exercised
month-old code, not trunk, and the staleness verdict could not say so.

### Work Packet: 1385-h6uz — macOS one-shot `--opencode` lane runs 3h silent with no guard line, and the guest keeps no record of it

- id: `smoke-finding/macos-oneshot-opencode-lane-silent-3h-no-guard-no-record`
- order: 1385-h6uz (filed as a plan fragment beside this report)
- owner_host: macos
- capability_tags: [macos, forge, opencode, observability, smoke]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.9.25.2`
- evidence:
  - `target/smoke-e2e/04-opencode.log:24` — last line `[forge] All changes must be committed to persist.` at 01:57:43Z; nothing after, for 3h.
  - Guest journal of the lane boot (6a6071b5…): FIRST 01:55:11Z, LAST **01:58:01Z** (`04-guest-recovery-3.log`), while the VM ran to 04:55Z at ~1 core and wrote rootfs.img continuously.
  - lenovinha's Linux §4 of the same release hit `blocked:upstream-no-credential` promptly; this lane never did.
- ruled out (measured, not assumed):
  - *stale seed lacked the guard*: `scripts/check-credential-channel.sh` exists at 341ab0010 and the seeded `meta-orchestration` skill calls it (3 references).
  - *SELinux blocked it*: 137 AVC denials in the lane boot, every one `permissive=1` in `vault_container_t` (Vault's healthcheck `curl`, `sh`, and Vault's own data files) — logged, not enforced.
  - *the local model never arrived*: `/root/.cache/tillandsias/models` holds `blobs/`, `manifests/`, `.preloaded`, all written 01:58Z.
- unexplained (recorded as such, not as a flake): what the in-forge agent did from 01:57:43Z to 04:55:20Z, and why the guard was not reached. Candidates to discriminate, not assert: the one-shot agent blocked on a provider or prompt with no output; it ran committable-work-free steps before the guard; the platform path differs from Linux before the skill runs.
- the evidence gap is part of the defect: after a stop, the guest keeps no journal past lane minute 3 and the forge is `--rm`, so a 3h run leaves nothing to read. Linux keeps `podman logs` on the host.
- repro: on macOS after a §2 wipe, `tillandsias-tray --opencode /home/forge/src/tillandsias --prompt "Use the /meta-orchestration skill"`; watch for a `blocked:upstream-*` line.
- next_action: >
    Make the one-shot lane's agent output reach the host while it runs (stream it, or tee it to a
    host-visible share), then re-run and read where it stops. Only then decide the guard question.
- events:
  - type: discovered
    ts: `2026-09-26T05:10:00Z`
    agent_id: `macos-tlatoanis-macbook-air-claude-20260926`
    host: macos

## Side observations (not filed)

- Router `opencode-web-session-otp` logs `Control-socket connection failed … No such file` with exponential backoff (7 lines in the lane boot). Expected for a one-shot lane with no web session; noted in case it is not.
- Vault logs `path is already in use` for approle/ and the ssh signers on a fresh volume; benign re-enable noise.
- Inference: `could not chown … /root/.cache/tillandsias/models` on virtio-fs is expected (804-deux).
- 137 permissive AVC denials in `vault_container_t` are noise today, but they would become real failures if that domain ever went enforcing.
