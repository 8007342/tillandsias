# Reverted: mirrored networking was the wrong fix — the ambiguity was a redundant ollama I had installed, and the Vulkan lane is unreachable from the sanctioned runtimes anyway

- classification: optimization
- filed: 2026-08-17 (windows/ESMERALDINHA, cycle 7)
- status: **reverted and removed**; supersedes the recommendation in
  `wslconfig-mirrored-resolves-endpoint-ambiguity-2026-08-17.md`
- related: **718-nkm2** (wsl2-inference-substrate-decision — already settled by
  `scripts/dev-inference-ensure.sh`, which I had not read),
  `plan/issues/research/loopback-endpoint-is-ambiguous-across-wsl2-2026-08-17.md`,
  482b (vulkan llama-server image variant)

## Operator decision (2026-08-17)

- **who**: The Tlatoāni
- **what**: Do **not** adopt `networkingMode=mirrored`. The sibling windows host
  assessed it as a **lower security boundary** than the current configuration.
  **Keep the enclave network isolated.** Remove the redundant bare-metal Windows
  ollama instead of writing code or config around it.
- **framing given**: the in-WSL2 ollama is the **DEVELOPMENT RUNTIME**, which is
  a different thing from the **END-USER RUNTIME**; both must have inference
  available on a low-powered device, and on every other host.

## What I got wrong

Cycle 3 measured that `http://127.0.0.1:11434` designated two different ollama
servers across the WSL2 boundary and that both answered. That measurement was
correct. **The diagnosis was not: the ambiguity existed only because I had
installed a second, redundant ollama on Windows during bring-up.** The designed
configuration has exactly one endpoint and no ambiguity at all.

Cycle 4 then "fixed" it by collapsing the network boundary — treating a symptom
I had created, at the cost of a security property that was never mine to trade.

`scripts/dev-inference-ensure.sh` had already settled this, and its header says
so plainly. I did not read it before acting:

> **THIS IS NOT THE END-USER RUNTIME.** The in-VM `tillandsias` distro, its
> podman enclave and its `tillandsias-inference` container are the product;
> they are fully wired, ephemeral and none of this touches them. This is the
> separate question of how the AGENT running on bare metal reaches an
> inference endpoint for its own expert system.
>
> **WHY IN THE BUILD DISTRO AND NOT ON WINDOWS** ...
> * ollama on Windows -> the distro must use the host GATEWAY ip, which moves
>   across reboots ... It would work until the next reboot and then silently
>   return None.
> * ollama in the distro -> 127.0.0.1:11434 on the servers' own loopback.
>   **Nothing to discover, nothing to break on reboot.**

That script is invoked by `cycle-preflight.sh`, so the sanctioned endpoint had
been coming up correctly on this host **the entire time** — every cycle's
`ok:cycle-preflight:rebuilt:ok:dev-inference-ready:...` was it working. The
Windows install was never load-bearing.

**Process lesson, which is the durable part**: the loop's own bootstrap rule is
*ask, don't read* — and when the expert is unavailable, fall back and **name the
reason**. The experts were down on this host all week (a known, filed condition),
so every read fell back to the filesystem, and I read the files I thought to look
for. `dev-inference-ensure.sh` answered the exact question I spent two cycles
measuring, and I never opened it. **A degraded expert path does not just slow
retrieval down; it silently narrows what you think to ask.**

## Actions taken

1. `%USERPROFILE%\.wslconfig` — `networkingMode=mirrored` **removed**; default
   NAT restored, enclave boundary intact. `memory=8GB`, `processors=4` and
   `[experimental] autoMemoryReclaim=gradual` retained (those are unrelated to
   the boundary and independently justified). The file now carries the operator
   decision inline so the next reader does not re-add it.
2. `winget uninstall Ollama.Ollama` — the redundant Windows install removed.
   `OLLAMA_IGPU_ENABLE` cleared from the user environment. Disk 120.3 -> 123.7 GB.
3. Verified afterwards, with the Windows install gone and NAT restored:
   - nothing serves Windows `127.0.0.1:11434`
   - `scripts/cycle-preflight.sh` returns
     `ok:cycle-preflight:rebuilt:ok:dev-inference-started:qwen2.5:0.5b:nomic-embed-text`
     — it brought the endpoint up itself
   - the endpoint is in-distro at `127.0.0.1:11434`, ollama 0.32.14, with
     `nomic-embed-text` + `qwen2.5:0.5b` present

## Consequence worth recording: the Vulkan lane is unreachable here

> **CORRECTED 2026-08-17 (cycle 9): the conclusion in this section is WRONG.**
> `/dev/dri` is indeed absent and always will be — that part stands — but it was
> never the only route. WSL2 exposes `/dev/dxg`, and Mesa's `dzn` driver maps
> Vulkan onto D3D12 over it. Yolanda had already measured that path on AMD the
> previous day (793-zumy); reproduced here on Intel, the iGPU binds at 100%
> offload from inside `tillandsias-build` and delivers **2.16x prefill** over
> CPU. The enablement is three Fedora packages, not "separate, unbuilt work".
> This section inferred "unreachable" from one missing device node instead of
> asking what the present one affords — **absence of the expected interface is
> not absence of the capability.** Full measurement:
> `plan/issues/research/intel-igpu-dzn-in-wsl2-measured-2026-08-17.md`.
> The rest of this file (the revert, the removal, the operator decision) stands.

`/dev/dri` is **ABSENT** in the WSL2 distro (confirmed again this cycle). WSL2
exposes the GPU as `/dev/dxg` with D3D12 libraries, not as a DRI device, and no
Mesa `dzn` (Vulkan-on-D3D12) driver is installed.

So with the bare-metal Windows install gone, **the Intel iGPU is not reachable
from either sanctioned runtime on this host** — not the development runtime (the
build distro) and not the end-user runtime (the podman enclave in the
`tillandsias` distro).

This does **not** invalidate the lane measurements filed in cycles 1, 5 and 6 —
they remain the project's only non-CUDA engine-lane data, and they are what
orders 410/481/482 were waiting for. But their applicability should be stated
honestly:

- **Valid and useful for**: any host that reaches a Vulkan device directly —
  a Linux host with `/dev/dri`, or the 482b Vulkan llama-server image variant
  running where the device is passed through.
- **Not currently reachable on ESMERALDINHA** in either sanctioned runtime.
  Realising the measured ~3.3x prefill win here would require GPU passthrough
  into WSL2 (Mesa `dzn` or equivalent), which is separate, unbuilt work and is
  **not** proposed as part of this.

The measured numbers therefore describe a lane the fleet can use, on hosts that
can reach it — and this host's contribution is the numbers, not the deployment.

## Superseded

`plan/issues/optimization/wslconfig-mirrored-resolves-endpoint-ambiguity-2026-08-17.md`
records a correct measurement (mirrored does remove the ambiguity) attached to a
recommendation that is now **withdrawn on operator decision**. Its cgroup-v2
correction stands and is unaffected.
