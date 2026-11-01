# Smoke e2e findings — v56.11.1.1 — linux — yoga

- run_start: 2026-11-01T08:53:39Z
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-<ts>/)
- forge_lane_outcome: `--bash` maintenance lane only (no agent turn: yoga holds opencode.ai traffic until 2026-11-02T03:00Z)
- signature_verification: cosign:could-not-run:cosign-absent

**Verdict: PASS (signatures unverified: cosign absent)**

Skill: `/smoke-curl-install-and-test-e2e`, destructive clean-room Linux lane,
scoped by macuahuitl-fedora's request: install, reset, init, a `--bash` forge,
one `image.generate` call, stop. Under the operator's standing wipe approval
for yoga. Tag pinned exactly (`releases/download/v56.11.1.1`). Sibling heads
at start: main 05341632f, linux-next 991183d89, windows-next b38f71052,
osx-next 49731c152.

| Step | Result | Evidence |
|---|---|---|
| §1 install | PASS — `install_exit=0`; `--version` = `Tillandsias v56.11.1.1` (bounded match) | `01-install-exit.txt`, `01-version.txt` |
| §1s signature | could-not-run (cosign absent) | `01s-cosign.txt` |
| §2 reset | PASS — `reset_exit=0`, `clear_exit=0` (`ok:clear-vault-credentials`); 0 containers / volumes / images; vault-data absent; probe `credential-cold` | `02-*.txt` |
| §3 `--debug --init` | PASS — `init_exit=0`; 0 panic / `Error:` / cipher lines; 0 `localhost/` images predate run_start | `03-init.log`, `03-images-predating.txt` |
| §3b shutdown | PASS for Tillandsias — `tillandsias-vault` exit=0, 0 s of 10 s grace. `ollama` is the operator's own auto-removed `ollama-vulkan.service` container (inspect after stop has nothing to read); excluded as in previous runs. | `3b-shutdown.txt` |
| §4 forge lane | PASS — `--cloud 8007342/tillandsias --bash` brought up `tillandsias-tillandsias-forge-maintenance`; no agent turn by design | scratchpad typescript |
| §4b egress | PASS — `tillandsias-proxy` alive alongside the lane | `04b-containers.txt` |
| image.generate | PASS — through `/home/forge/.config-overlay/mcp/host-browser.sh`: SDXS-512-0.9, tier I0, backend vulkan, 512×512, `first_use` true, `elapsed_s` 315.87 (wall 317 s, includes the first-use model fetch after the wipe), PNG present in the forge | `04i-imagegen.out` |
| §4c health | PASS — vault `"sealed":false`, proxy healthy, version v56.11.1.1 | `05-health.log` |

## Ledger claims

Row: README.md line 84, `v56.11.1.1 (daily; prerelease, three-platform smoke pending)`.
This lane exercised install, clean-room init and the I0 image path. The
agent-turn claims were not looked at (agent turn withheld).

## Notes

- The 315.87 s `elapsed_s` is a first-use number, not a per-image timing; the
  warm SDXS figure on this host stays 2.86–3.17 s (v56.10.31.1 report).
