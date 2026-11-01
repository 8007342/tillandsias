# Smoke e2e findings — v56.10.31.1 — linux — yoga

- run_start: 2026-10-31T19:21:46Z
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-<ts>/)
- forge_lane_outcome: cold-host guard stop (EXPECTED PASS), then the agent died — the `--opencode` lane brought the enclave up and the guard answered `blocked:upstream-no-credential` (`04-opencode.log:243`); nothing claimed or committed, `git status` empty. The agent then kept running read-only plan queries and died at `04-opencode.log:653` on `EPROTO: The TLS handshake failed`, so `opencode_exit=1` and NO `MO-FULL:` marker (neither COMPLETE nor BLOCKED) was emitted. See finding 1.
- signature_verification: cosign:could-not-run:cosign-absent

**Verdict: PASS (signatures unverified: cosign absent)**, with one finding.
Install, reset, init, shutdown, egress, health and in-forge image.generate
all pass; the finding is the agent run ending on a TLS error instead of a
BLOCKED disposition.

Skill: `/smoke-curl-install-and-test-e2e`, destructive clean-room Linux lane,
operator-authorised wipe on yoga 2026-10-31 (asked for this run). Tag pinned
exactly (`releases/download/v56.10.31.1`). Sibling heads at start: main
cec5797c3, linux-next 3aa8272ea, windows-next b38f71052, osx-next 49731c152.
No evidence file predates `00-run-start.txt`.

| Step | Result | Evidence |
|---|---|---|
| §1 install | PASS — `install_exit=0`; `--version` = `Tillandsias v56.10.31.1` (bounded match) | `01-install-exit.txt`, `01-version.txt` |
| §1s signature | could-not-run (cosign absent) | `01s-cosign.txt` |
| §2 reset | PASS — `reset_exit=0`, `clear_exit=0` (`ok:clear-vault-credentials`); 0 containers / volumes / images; vault-data absent; probe `credential-cold` | `02-*.txt` |
| §3 `--debug --init` | PASS — `init_exit=0`; 0 panic / `Error:` / cipher lines; 0 `localhost/` images predate run_start | `03-init.log`, `03-images-predating.txt` |
| §3b shutdown | PASS for Tillandsias — `tillandsias-vault` exit=0, 0 s of 10 s grace. The `ollama` row is the operator's own `ollama-vulkan.service` container, not Tillandsias (same as the v56.10.30.1 run); excluded. | `3b-shutdown.txt` |
| §4 forge lane | guard stop PASS; agent then died on TLS (finding 1) | `04-opencode.log:243`, `:653`, `04a-*.txt` |
| §4b egress | PASS — `tillandsias-proxy` alive alongside the lane | `04b-containers.txt` |
| §4c health | PASS — vault `"sealed":false`, proxy healthy, version v56.10.31.1 | `05-health.log` |
| image.generate | PASS — from inside a `--cloud 8007342/tillandsias --bash` forge on the installed binary, through `/home/forge/.config-overlay/mcp/host-browser.sh`: SDXS-512-0.9, tier I0, backend vulkan, 512×512, `elapsed_s` 2.86, PNG present. | `04i-imagegen.out` |

`head_matches_origin=no` in `04a-cold-host-residue.txt` is the host checkout
sitting on `work/1861-nmpp`, not lane residue.

## Ledger claims

Row: README.md line 84 on linux-next, `v56.10.31.1 (daily — fix forward of v56.10.30.1 …)`.

- **EXERCISED**: a relaunch onto a tray-served lane is not refused
  (1863-eckw #754) — the `--bash` forge launched with the lane's tray
  (pid 852686) still serving it, where v56.10.30.1 refused this exact
  launch. Local image generation carried from v56.10.30.1 (above).
- **NOT APPLICABLE**: the macOS cloud launch (1925-mcld), Windows vault
  delivery (1927-q6fk).
- **NOT CHECKED**: `tillandsias --rejoin` and the sibling cgroup budgets
  (1911-3dqo); `lua` and helpers on the forge PATH (1864-qymj); the web
  launch respawning a vanished tray (1863-eckw); the pre-receive plain-date
  gate (1863-mqiw).

### Work Packet: smoke-finding/cold-lane-agent-dies-on-tls-handshake-without-blocked-marker

- id: `smoke-finding/cold-lane-agent-dies-on-tls-handshake-without-blocked-marker`
- owner_host: linux
- capability_tags: [forge, opencode, proxy, testing]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v56.10.31.1`
- evidence:
  - `target/smoke-e2e/04-opencode.log:243` — `blocked:upstream-no-credential` (guard correct)
  - `target/smoke-e2e/04-opencode.log:653` — `Error: EPROTO: The TLS handshake failed. Does the server speak TLS on this port?`, immediately after a `tillandsias-plan expire-claims --list-live` call, then `forge session exited … status 1`
  - no `MO-FULL:` line at all; on v56.10.30.1 the same lane on the same host ended `opencode_exit=0` with `MO-FULL: BLOCKED`
- repro:
  - §2 + §3 of the skill, then `TILLANDSIAS_NO_TRAY=1 tillandsias --cloud 8007342/tillandsias --opencode --prompt "Use the /meta-orchestration skill"`
- next_action: >
    Find which connection the agent's TLS error came from (model provider
    through the proxy, or an MCP/HTTP endpoint spoken to as https) from the
    forge's opencode log; one sample only, so re-run once before fixing.
- events:
  - type: discovered
    ts: `2026-10-31T19:47:03Z`
    agent_id: `linux-yoga-claude-20261027t070947z`
    host: linux
