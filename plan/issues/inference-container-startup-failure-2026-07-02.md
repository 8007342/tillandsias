# Inference (Ollama) container dies ~30s after launch and self-removes

- **Date**: 2026-07-02
- **Host**: windows (windows-next), during the first interactive forge sessions
- **Status**: investigation open — order 159

## Symptom

Both forge launches (mcp-test, tillandsias) started `tillandsias-inference`; podman events show
`create → init → start → died (+~32s) → remove`. Because the service runs with `--rm`, the logs
vanish with it — both in-forge agent diagnostics could only report
`inference:11434 UNREACHABLE`.

## Findings so far (2026-07-02, windows)

- Rerunning the image detached WITHOUT `--rm`: the entrypoint immediately starts **pulling a
  ~2.0 GB Ollama model at ~65 MB/s** — i.e. every fresh container re-downloads the model
  (no volume mounts `/root/.ollama`, the model store dies with the container).
- 2.0 GB at 65 MB/s ≈ 30s — the observed ~32s death lines up with pull-completion +
  model-load, pointing at **OOM during model load** (the WSL2 VM has 7.3 GiB total, ~4.5 free;
  agent runtimes + enclave already resident) or an entrypoint that exits nonzero right after
  the pull.
- The debug container was still healthy mid-pull at +35s, so the pull path itself works.

## Fix directions for the packet

1. Capture the actual death: run once without `--rm` to completion; check `podman inspect`
   OOMKilled flag + last logs; check `dmesg` for oom-kill.
2. Persist the model store: named volume for `/root/.ollama` so restarts don't re-pull 2 GB
   (also removes a 30s+ window where inference is guaranteed unavailable — both agent
   diagnostics hit exactly this window).
3. Right-size or defer the model: pick a model that fits the VM memory budget alongside a
   forge session, or lazy-pull on first inference request instead of at container start.
4. Stop using bare `--rm` for long-lived service containers — post-mortem logs must survive
   (same lesson as the 22h squid corpse, see race-safeguards R-inventory).
5. Consider raising the WSL2 VM memory cap (.wslconfig) if the chosen model needs it.

## Exit criteria

- Death cause captured and fixed; `inference:11434` answers from a fresh forge.
- Model store survives container recreation (no 2 GB re-pull per launch).
- Service containers keep post-mortem logs.
- Forge diagnostics report inference ✅ on a fresh launch.
