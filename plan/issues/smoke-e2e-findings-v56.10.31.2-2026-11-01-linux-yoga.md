# Smoke e2e findings — v56.10.31.2 — linux — yoga

- run_start: 2026-11-01T01:09:46Z
- evidence_dir: target/smoke-e2e   (previous runs archived under _archived-<ts>/)
- forge_lane_outcome: cold-host guard stop (EXPECTED PASS), then the agent died again — the guard answered `blocked:upstream-no-credential` (`04-opencode.log:214`); nothing claimed or committed, `git status` empty, in-forge HEAD == origin/linux-next. About 20 minutes later the agent died at `04-opencode.log:303` on `EPROTO: The TLS handshake failed`, right after a bounded `git push --dry-run`; `opencode_exit=1`, no `MO-FULL:` marker. Second sample of the v56.10.31.1 finding (2 of 2 cold lanes).
- signature_verification: cosign:could-not-run:cosign-absent

**Verdict: PASS (signatures unverified: cosign absent)**, with the
v56.10.31.1 TLS finding REPRODUCED.

Skill: `/smoke-curl-install-and-test-e2e`, destructive clean-room Linux lane,
under the operator's standing wipe approval for yoga (given 2026-10-31 in
this session). Tag pinned exactly (`releases/download/v56.10.31.2`).
Sibling heads at start: main 5c81b9247, linux-next 5c81b9247, windows-next
b38f71052, osx-next 49731c152. No evidence file predates `00-run-start.txt`.

| Step | Result | Evidence |
|---|---|---|
| §1 install | PASS — `install_exit=0`; `--version` = `Tillandsias v56.10.31.2` (bounded match) | `01-install-exit.txt`, `01-version.txt` |
| §1s signature | could-not-run (cosign absent) | `01s-cosign.txt` |
| §2 reset | PASS — `reset_exit=0`, `clear_exit=0` (`ok:clear-vault-credentials`); 0 containers / volumes / images; vault-data absent; probe `credential-cold` | `02-*.txt` |
| §3 `--debug --init` | PASS — `init_exit=0`; 0 panic / `Error:` / cipher lines; 0 `localhost/` images predate run_start | `03-init.log`, `03-images-predating.txt` |
| §3b shutdown | PASS for Tillandsias — `tillandsias-vault` exit=0, 0 s of 10 s grace. `ollama` is the operator's own `ollama-vulkan.service` container; excluded as in the two previous runs. | `3b-shutdown.txt` |
| §4 forge lane | readiness gate PASS (see below); guard stop PASS; then agent died on TLS (finding) | `04-opencode.log:214`, `:303` |
| §4b egress | PASS — `tillandsias-proxy` alive alongside the lane | `04b-containers.txt` |
| §4c health | PASS — vault `"sealed":false`, proxy healthy, version v56.10.31.2 | `05-health.log` |
| image.generate | PASS — inside a `--cloud 8007342/tillandsias --bash` forge on the installed binary, via `/home/forge/.config-overlay/mcp/host-browser.sh`: SDXS-512-0.9, tier I0, backend vulkan, 512×512, `elapsed_s` 3.17, PNG present | `04i-imagegen.out` |

## Ledger claims

Row: README.md line 84 on linux-next, `v56.10.31.2 (daily — fix forward of v56.10.31.1 …)`.

- **EXERCISED**: the readiness gate counts a READY that fired before it
  subscribed (1922-lrdy #770) — the `--bash` maintenance forge launched
  while proxy, router and vault were already up and Ready from the
  `--opencode` lane, and the forge came up and served `image.generate`.
  The `--opencode` lane itself also passed the gate onto a freshly started
  stack. Launcher waiting on the mirror readiness event (1922-unwt #762):
  both lanes reached the forge with mirror=up.
- **NOT APPLICABLE**: macOS Vault credential exchange (1925-cxch), the
  Windows readiness refusal it fixes (verified on Windows only), release CI
  Nix changes, `./build.sh` changes (1925-77h4, 1931-steb; not part of the
  installed artifact).
- **NOT CHECKED**: whether the readiness gate's "already ready" path was
  the one taken (the log does not say which path fired); `--rejoin` and
  sibling cgroup budgets (1911-3dqo); `lua` in the forge (1864-qymj).

## Recurrence: smoke-finding/cold-lane-agent-dies-on-tls-handshake-without-blocked-marker

Filed in `plan/issues/smoke-e2e-findings-v56.10.31.1-2026-10-31-linux-yoga.md`.
Second sample, same host, same lane:
- `target/smoke-e2e/04-opencode.log:303` — `Error: EPROTO: The TLS handshake failed. Does the server speak TLS on this port?`, then `forge session exited … status 1`.
- The last tool calls before it were `git ls-remote origin 'refs/tillandsias/upstream-auth/*'` and `timeout 30 git push --dry-run origin linux-next`, then a git-state echo; on v56.10.31.1 it followed `tillandsias-plan expire-claims --list-live`. The common factor is time (both ~4–20 min into the agent), not one tool call, which points at the agent's model connection rather than a tool.
- The forge's own opencode log is removed with the lane; the next run should copy `/home/forge/.local/share/opencode/log/` out before teardown (the agent watch does this only on its own verdict).
