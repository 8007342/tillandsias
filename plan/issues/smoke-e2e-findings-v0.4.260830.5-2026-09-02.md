# Clean-room smoke findings — v0.4.260830.5 on yoga (linux, Fedora Silverblue)

Run 2026-09-02T08:02:04Z via `/smoke-curl-install-and-test-e2e`, daily channel.

## VERDICT: GREEN — yoga blesses v0.4.260830.5 for stable promotion

| step | result |
|---|---|
| 1 curl-install | PASS — installed SHA `7cb17f164dcafcf0` identical to the published asset; `--version` 3/3 reports v0.4.260830.5 |
| 2 destructive reset | PASS — `podman system reset --force` exit 0; containers/volumes/images all empty, asserted |
| 3 pristine init | PASS — exit 0, ZERO Error:/panic/FATAL lines, 30 images rebuilt from an empty store, Vault initialized and healthy with its full policy set |
| 4 forge lane | PASS — exit 0 |
| 4b egress assertion | PASS — `tillandsias-proxy` alive alongside the lane (no order-298 regression); full six-container enclave up |

Neither finding below is a regression in v0.4.260830.5. Both are pre-existing conditions
that this run happened to be positioned to observe, and neither should block
promotion.

## Ledger claims

**Cannot be accounted for.** `README.md` has NO row for v0.4.260830.5 — see finding 1. The
runbook's §5 requires each claim from the release's ledger row to be marked
EXERCISED / NOT APPLICABLE / NOT CHECKED, and with no row there are no claims to
mark. This blessing therefore certifies the generic property (it installs, it
survives destruction, it re-provisions, the forge runs) and NOT that anything
v0.4.260830.5 specifically claims to fix was fixed. That is a narrower green than the
runbook intends and the narrowing is stated rather than hidden.

### Work Packet: smoke-finding/readme-ledger-row-missing-for-daily-releases

- id: `smoke-finding/readme-ledger-row-missing-for-daily-releases`
- owner_host: any
- capability_tags: [release, docs]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260830.5`
- evidence:
  - `target/smoke-e2e/00-ledger-row.txt` — `NO LEDGER ROW for v0.4.260830.5`
  - `README.md:114` — newest row is `v0.4.260826.1`; none of today's dailies (.1 through .5) have rows
- repro:
  - `awk -v tag=v0.4.260830.5 'index($0, "| " tag) == 1' README.md` → no output
- next_action: >
    Backfill the RELEASE/INTENDED FEATURES/BUGFIXES rows for the dailies, and
    make the release skill's append step fail loudly when it does not run — a
    missing row means the fleet is asked to bless an artifact nobody described,
    and it silently disables the runbook's ledger-claims accounting.
- events:
  - type: discovered
    ts: `2026-09-02T08:02:04Z`
    agent_id: `linux-yoga-opus5-20260902t080204z`
    host: linux

### Work Packet: smoke-finding/runtime-inference-container-claims-gpu-rocm-on-cpu

- id: `smoke-finding/runtime-inference-container-claims-gpu-rocm-on-cpu`
- owner_host: linux
- capability_tags: [podman, runtime, accel]
- status: ready
- discovered_by: `/smoke-curl-install-and-test-e2e` on release `v0.4.260830.5`
- evidence:
  - `podman inspect tillandsias-inference` — `TILLANDSIAS_INFERENCE_TIER=gpu-rocm`, `OLLAMA_VULKAN=1`, `OLLAMA_LLM_LIBRARY=vulkan`, and `HostConfig.Devices: []`
  - in-container: `libvulkan.so.1` absent, `/usr/share/vulkan/icd.d/` absent
  - `podman logs tillandsias-inference` — `inference compute id=cpu library=cpu`
- repro:
  - `tillandsias --debug --init` on a gpu-rocm host, then inspect the runtime inference container
- next_action: >
    The RUNTIME container (tillandsias-inference) needs the same two fixes the
    DEV endpoint received on linux-next after this tag was cut: pass /dev/kfd and
    /dev/dri on the gpu-rocm tier, and ship the Vulkan userspace (vulkan-loader +
    mesa-vulkan-drivers) so the already-selected vulkan backend can enumerate.
    Note lenovinha measured that `--init` builds from the release-bundled runtime
    assets, NOT the operator's checkout — so neither fix reaches operators until a
    new release bundles it. Confirmed independently on lenovinha's clean-room
    container: no Vulkan userspace in the shipped daily there either.
- events:
  - type: discovered
    ts: `2026-09-02T08:02:04Z`
    agent_id: `linux-yoga-opus5-20260902t080204z`
    host: linux
