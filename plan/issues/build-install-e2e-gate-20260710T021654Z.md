# --ci-full --install gate — run 20260710T021654Z — 2026-07-10

- discovered_by: meta-orchestration cycle (linux_mutable, macuahuitl), operator-directed
- agent: linux-macuahuitl-fable5-20260710T0009Z
- commit tested: `39186723` (HEAD relay-advanced to `699a8eed` mid-gate, sanctioned)
- evidence: `target/build-install-smoke-e2e/20260710T021654Z/01-build-install.log`
- installed: `/home/tlatoani/.local/bin/tillandsias` — **Tillandsias v0.3.260710.3** (40M)

## Result: exit 1 with exactly ONE red — everything operator-directed passed

| Surface | Verdict |
|---|---|
| Pre-build suite | 147/147 PASS |
| **rust-clippy-all-features lane (order 266, first run in anger)** | **PASS** |
| Security suite | 17/17 PASS |
| Workspace build + musl launcher + install | PASS (v0.3.260710.3) |
| **litmus:opencode-prompt-e2e-shape (orders 255/262/264)** | **7/7 PASS — first fully-green run in this litmus's history** |
| Post-build e2e suite | 7/8 — sole red below |

The in-forge STEP 3 cycle ran under the new one-packet doctrine: it drained
exactly one packet (order 224, litmus-stdlib research — 8 primitives, 5
prototypes, `16078687`), finished inside the 600s budget, and its push
passed the branch-scoped STEP 6 probe. Orders 262 and 264 exit criteria are
discharged live.

## The one red: inference first-run ollama download fails (product, pre-existing path)

`litmus:inference-deferred-model-pulls` STEP 2 (launch inference container
with wiped model cache, 185s window):

```
[inference] Installing ollama binary (first run)...
[inference] ollama download FAILED — will retry next launch (non-fatal)
/usr/local/bin/entrypoint.sh: line 119: ollama: command not found
[inference] default model qwen2.5:0.5b pull FAILED — will retry next launch (non-fatal)
(container exit 127; litmus run cmd: podman run --userns=host --rm
 --name test-inference-first-run -v ~/.cache/tillandsias/models:... 
 tillandsias-inference:latest)
```

The entrypoint's degradation is designed ("retry next launch, non-fatal"),
so the PRODUCT effect is a delayed-inference first run, not a broken tray.
The litmus, however, is right to demand a working cold path. Unrelated to
this cycle's changes (runner changes are warning-only in legacy mode; the
lane and doctrine don't touch containers). Shaped as order 268. NOTE: this
litmus file is also one of the four YAML-invalid files in order 267's
scope — coordinate edits.

### Work Packet (→ plan/index.yaml order 268)

- id: `smoke-finding/inference-firstrun-ollama-download`
- repro: `rm -rf ~/.cache/tillandsias/models` (and any ollama binary cache),
  then the podman run line above; observe the download failure and exit 127.
- open questions for the packet: does the tarball fetch route through the
  enclave proxy or direct egress in THIS launch shape (no --network flag)?
  is a proxy env leak from the build environment involved? is the download
  URL/checksum stale? why did prior gates pass (warm binary cache)?
