## Cycle 2026-08-18T08:36Z — the destructive e2e paid off: the enclave could not cold-start, in three independent ways

**Result: with the substrate genuinely empty for the first time,
`orchestrate-enclave.sh` could not start a SINGLE container. Three faults, all
fixed and each verified by watching the next container come up. This is the
return on the nine Step 1 attempts.**

- **406's runtime half — answered, with a caveat that matters.** The literal
  question ("does `tillandsias --init` produce an inference container with
  tier=gpu-cuda and a CUDA runner?") answers **no: `--init` produces no
  inference container at all**; the stack one is lane-scoped. But the GPU
  capability itself is proven on this cold-provisioned host, measured on the
  dev endpoint:

  ```
  inference compute id=0 library=CUDA compute=8.6 name=CUDA0
    description="NVIDIA RTX A5000" libdirs=ollama,cuda_v13 driver=13.3
    type=discrete total="23.5 GiB" available="22.7 GiB"
  ```
  plus `/dev/nvidia0` inside the container, `nvidia-smi -L` resolving the
  A5000, `TILLANDSIAS_INFERENCE_TIER=gpu-cuda`, and
  `accel_class=workstation-gpu accel_gpu=usable`. Left 406 open: its deliverable
  names the stack container, and the stack one is torn down by the script
  seconds after it spawns. Also confirmed live in passing:
  `accel_npu=present-unusable accel_reason=engine-missing` — that is 802-2536.

- **825-uxzu, three cold-start faults**, each invisible on a host that already
  has a stack:
  1. **Static IPs the product forbids.** `IPAM error: 10.0.42.2 already
     allocated`. I first read this as an orphaned lease and nearly filed
     "stale netavark entry survives a reset" — wrong: that container IS vault,
     alive and entitled to .2, because `--init` created it and IPAM handed out
     the first free address. main.rs:18834 asserts `!--ip` for all four stack
     containers with the message *"stack launch must let podman IPAM allocate
     addresses"*, and :17403 forbids the proxy carrying `10.0.42.2` by name.
     The script pinned it anyway.
  2. **A read-only mirror with nowhere to write.** `fatal: cannot mkdir
     /srv/git/tillandsias: Read-only file system`, exit 128 — words nobody had
     ever seen, because `--detach --rm` deleted the container and its logs
     before the readiness probe. The product mounts
     `{mirror_volume}:/srv/git` with a unit test asserting it; the script
     mounted only the CA cert, and pointed `--base-path` at /var/lib/git while
     the image serves /srv/git.
  3. **An image tag guessed from the wrong source.** proxy and git *resolve*
     their image from `podman images`; inference *constructed*
     `tillandsias-inference:v${VERSION}` from the checkout. `--install` bumps
     VERSION and **702-eusw requires reverting it**, so the project's own
     push-isolation rule guarantees that tag is wrong. The only container that
     derives its tag from VERSION is the only one that broke.

  **The pattern**: the shell orchestration has drifted from the product's
  launch path, and in two of three the product asserts the correct behaviour
  in a unit test the script violates. The tests are the spec; nothing checks
  the script against them.

- **A fourth, filed not fixed**: on the git failure the script printed *"Image
  may be incomplete. Rebuild: scripts/build-image.sh git"*. The image was fine —
  1.15 GB, built 36 minutes earlier. The 797-5kqe shape again: a remedy
  asserting a cause it never measured, pointing at the one healthy link. I
  removed `--rm` from the git block so the next failure is autopsiable; the
  message and the other two `--rm` service containers remain.

- **Three of my own errors, all caught by measuring** rather than continuing:
  the orphaned-lease misreading above; a perl edit that left a blank line after
  a backslash continuation (`line 171: --volume: command not found`); and
  resolving CERTS_DIR by `find` when the script simply declares
  `CERTS_DIR=/tmp/tillandsias-ca` (rc=125). Reading the script beat inferring
  from the filesystem.

- **823-u3k9** filed earlier this cycle: `check-mcp-expert-health.sh` starts its
  OWN server from the registration, so it validates the FILE and can never see
  that the session's long-lived MCP process is stale. It said
  `ok:experts-healthy` while the L1 spec expert answered from
  `/mnt/c/Users/bullo/...` — a WSL path, on Linux. 799-j4xd's comment already
  names this host and symptom: *"a fix in a file does not reach a process that
  already read it."*

### For the operator

- **809-w2xy** — still the root blocker for forge writes; unchanged.
- **808-zrzz** — still wants a recorded decision; tonight's e2e finally reached
  §2/§3, so the series-wiring cost is now concrete rather than theoretical.
- **406** — left open deliberately; the GPU tier is proven, the stack-container
  half is not.
- **801-x1nx**, **814-iyu7** — still yours.
