# GitHub E2E Interactive Run Findings — 2026-06-21

**Filed:** 2026-06-21T14:55Z
**Agent:** linux-tlatoani-big-pickle-20260621T1455Z
**Host:** linux_mutable (Fedora Linux)
**Trace:** order 68, github-e2e-lifecycle-interactive

## Run Summary

Performed partial interactive lifecycle run on big-pickle. Tests 1-2 completed; tests 3-5 partially attempted with observable findings.

## Results

### Test 1: `tillandsias --list-cloud-projects` — PASS

```
fetched 23 remote project(s) in 1.97s
```

Vault token read, `gh` helper launched, projects listed. All 23 repos returned with descriptions.

**Finding G1 — Duplicate vault provisioning**: Each `--list-cloud-projects` run triggers 3-4 identical vault policy-writing + AppRole-provisioning cycles (`writing policy git-mirror-policy`, `provisioning AppRole role git-mirror -> git-mirror-policy`) before the actual `gh` invocation. The vault bootstrap path is called redundantly. No correctness impact but noisy and adds startup latency. Trace: crates/tillandsias-headless/src/main.rs vault bootstrap calls in `list_cloud_projects` path.

### Test 2: `tillandsias . --bash` — PASS

Forge welcome shell launched successfully: welcome banner, project info, services (proxy/git/inference), mounts all correct. Shell entered fish at project root.

### Test 3: `tillandsias . --opencode --prompt "..."` — FAIL

Forge container launch failed with:
```
Error: creating build container: unable to copy from source docker://localhost/tillandsias-forge-base:latest:
pinging container registry localhost: dial tcp [::1]:80: connect: connection refused
```

**Finding G2 — Confusing forge-base-missing error**: When `tillandsias-forge-base:latest` is not built, the forge launch path attempts to pull it from a Docker registry at `localhost:80` (which doesn't exist) instead of building it or offering a clear `run tillandsias --init` message. The forge build path needs to detect missing base image and either:
  a) Build forge-base on demand as a dependency, or
  b) Emit a clear actionable error: "forge-base image not found. Run `tillandsias --init` to build required images."

### Test 4: `tillandsias --init --debug` — PASS (partial)

forge-base built successfully (549 RPMs, all checksum-verified cargo tools, pip installs via `PIP_DEFAULT_TIMEOUT=120`). The pyright download that failed on immutable Linux (order 70) succeeded here at 51.6 MB/s. Forge image was SKIP (digest present). This confirms the PIP_DEFAULT_TIMEOUT=120 fix works for the mutable Linux case as well.

### Test 5: In-forge git operations — NOT TESTED

After --init completed most images, the command timed out. Forge interactive git push testing requires a running forge session with manual command injection.

## Glitch Inventory

| ID | Severity | Area | Description |
|----|----------|------|-------------|
| G1 | Low | vault/redundancy | Duplicate vault policy provisioning on every headless command |
| G2 | Medium | forge/ux | Cryptic "connection refused" when forge-base is missing instead of actionable error |

## Plan

- G1: File as low-priority optimization packet `github-e2e/redundant-vault-bootstrap`
- G2: File as medium-priority enhancement packet `github-e2e/forge-base-missing-ux`
- The remaining inside-forge git operations (clone/commit/push) are deferred to a follow-up interactive run after a forge session is available
