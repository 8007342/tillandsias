# Smoke e2e findings — v56.10.30.1 — linux — yoga

- run_start: 2026-10-31T01:04:24Z
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-<ts>/)
- forge_lane_outcome: cold-host guard stop (EXPECTED PASS) — the `--opencode` lane brought the enclave up and stopped at the Credential Channel Guard (`blocked:upstream-*`); nothing claimed or committed, `git status` empty, HEAD == origin/linux-next, `MO-FULL: BLOCKED` present and `MO-FULL: COMPLETE` absent, both correct.
- signature_verification: cosign:could-not-run:cosign-absent

**Verdict: PASS (signatures unverified: cosign absent)**, with two findings
filed below. Neither blocks the clean-room path; finding 1 breaks a relaunch
after the tray has adopted a lane.

Skill: `/smoke-curl-install-and-test-e2e`, destructive clean-room Linux lane,
operator-authorised wipe on yoga 2026-10-30. Tag pinned exactly
(`TILLANDSIAS_VERSION=v56.10.30.1`, release base
`releases/download/v56.10.30.1`), not latest. Sibling heads at start: main
cec5797c3, linux-next aae7f8606, windows-next b38f71052, osx-next 49731c152.
No evidence file predates `00-run-start.txt`.

| Step | Result | Evidence |
|---|---|---|
| §1 install | PASS — `install_exit=0`; `tillandsias --version` = `Tillandsias v56.10.30.1` (bounded match) | `01-install-exit.txt`, `01-version.txt` |
| §1s signature | could-not-run (cosign absent) | `01s-cosign.txt` |
| §2 reset | PASS — `reset_exit=0`, `clear_exit=0` (`ok:clear-vault-credentials`); 0 containers / volumes / images; vault-data dir absent; probe `credential-cold` | `02-*.txt`, `02-credential-cold-post.md` |
| §3 `--debug --init` | PASS — `init_exit=0`; 0 panic / `Error:` / cipher lines; 0 `localhost/` images predate run_start | `03-init.log`, `03-images-predating.txt` |
| §3b shutdown | PASS for Tillandsias — `tillandsias-vault` exit=0 elapsed 0 s of 10 s grace. The flagged `ollama` row is NOT Tillandsias: `docker.io/ollama/ollama:latest` run by the operator's user unit `ollama-vulkan.service`; systemd recreated it mid-check, so inspect read blank. Excluded. | `3b-shutdown.txt` |
| §4 forge lane | PASS — cold-host guard stop (see above); `opencode_exit=0` is not the pass condition | `04-opencode.log`, `04a-*.txt` |
| §4b egress | PASS — `tillandsias-proxy` alive alongside the lane | `04b-containers.txt` |
| §4c health | PASS — vault `"sealed":false`, proxy up, version v56.10.30.1 | `05-health.log` |
| image.generate (headline) | PASS — from INSIDE the forge through `/home/forge/.config-overlay/mcp/host-browser.sh`: SDXS-512-0.9, tier I0, backend vulkan, 512×512, `elapsed_s` 3.7, PNG present at `/work/tmp/imagegen/…` in the forge. `first_use=false`: the Linux reset does not touch `cache_root()/models` (documented). | `04i-imagegen.out` |

The image.generate leg ran in a `--cloud 8007342/tillandsias --bash`
maintenance forge on the installed binary, because the `--opencode` lane's
forge is removed as soon as it stops at the guard. A step-up was not
exercised: yoga's ceiling is I0 (designed, per the coordinator).

## Ledger claims

Row: README.md line 84, `v56.10.30.1 (daily — local image generation …)`.

- **EXERCISED**: `image.generate` on the lane MCP socket at the exact
  requested size with files in `/work/tmp/imagegen` (1874-kkrc) — 512×512
  returned, PNG present in the forge. GPU placement (1874-b9tg) — `backend:
  vulkan` on the 840M. Smallest-tier start (1874-p8w7) — I0 chosen with no
  `tier` argument.
- **NOT APPLICABLE**: macOS / Windows claims in the row.
- **NOT CHECKED**: the single-use consent-token step-up (1874-p8w7) — yoga's
  ceiling is I0, so no higher tier is offerable here; progress-as-events
  (the probe did not read `notifications/progress`); first-use model fetch
  through the proxy with sha256 pinning (the cache survived the reset, so the
  fetch path did not run); first-use image build of the imagegen engine.

### Work Packet: smoke-finding/relaunch-onto-tray-served-lane-refused

- id: `smoke-finding/relaunch-onto-tray-served-lane-refused`
- owner_host: linux
- capability_tags: [rust, mcp, tray, forge]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.10.30.1`
- evidence:
  - `target/smoke-e2e/04j-first-attempt.log` — `Error: runtime_unavailable: per-lane MCP listener failed: mcp socket already has a live owner; refusing to unlink: /run/user/1000/tillandsias/mcp/tillandsias-default/mcp.sock`
  - at that moment `ss -xlp` showed the listener owned by the installed tray (`tillandsias --tray`, the one this launch started), and the lane dir carried a `tray-owned` marker
- repro:
  - with a `tray-owned` marker in the lane dir and the tray serving it, run `tillandsias --cloud 8007342/tillandsias --bash`
- next_action: >
    Already fixed on work/1863-eckw-relaunch (d106a2ad1): in
    start_mcp_socket_server_for_lane a live listener on a tray-marked lane is
    the tray serving it, so the launch proceeds; pinned by
    a_relaunch_onto_a_tray_served_lane_is_not_refused (red on trunk first).
    Land it and re-run this repro. Belongs to 1863-eckw.
- events:
  - type: discovered
    ts: `2026-10-31T02:01:00Z`
    agent_id: `linux-yoga-claude-20261027t070947z`
    host: linux

### Work Packet: smoke-finding/reset-leaves-lane-markers-in-runtime-dir

- id: `smoke-finding/reset-leaves-lane-markers-in-runtime-dir`
- owner_host: linux
- capability_tags: [podman, runtime, mcp, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.10.30.1`
- evidence:
  - the `tray-owned` marker in `/run/user/1000/tillandsias/mcp/tillandsias-default/` was dated 17:18 local (2026-10-31T00:18Z), BEFORE run_start 01:04:24Z, and survived §2 — `podman system reset --force` plus `scripts/clear-vault-host-credentials.sh` never touch `$XDG_RUNTIME_DIR/tillandsias/`
  - that surviving marker is what the post-reset tray adopted, which led to the refusal in the packet above
  - disclosure: the marker was written by this agent's own 1863-eckw live testing earlier that day, not by an operator session; the defect is that the reset does not remove it. The image.generate leg ran after this agent stopped the tray by PID and removed that one marker by hand.
- repro:
  - `touch` a marker in a lane dir, run §2 of the skill, `ls $XDG_RUNTIME_DIR/tillandsias/mcp/*/`
- next_action: >
    Decide whether the clean-room reset owns $XDG_RUNTIME_DIR/tillandsias
    (lane sockets + tray-owned markers) and, if so, clear it in the reset
    step with an assertion like the vault-data-dir one. A marker that
    outlives its tray is runtime state, not installation state.
- events:
  - type: discovered
    ts: `2026-10-31T02:01:00Z`
    agent_id: `linux-yoga-claude-20261027t070947z`
    host: linux
