# Studio asset pipeline: a forge-callable ComfyUI studio, one family contract, and durable licence consent

## Why

On 2026-11-01 two game forges ran the image tools in earnest: demon_attack (a shooter with layered ship parts) and kumbia-kombat (a rhythm dance game with a robot hero and human opponents). They found these gaps:

- **No headless studio.** The `imagegen-studio` container (1874-zry8) runs ComfyUI, but a forge agent cannot call it. The agent can only open its web UI. Asset pipelines need batch, reproducible runs from committed workflows.
- **No reference, pose, transparency or identity tools.** The studio ships only ComfyUI-GGUF, so it has no IP-Adapter, no LayerDiffuse and no BiRefNet matte. The rig-rendered control images the games produce have nowhere to go except the single-ControlNet interim path in `image.generate` (1954-gdi6).
- **No provenance.** Outputs do not record which models, hashes, seeds and inputs made them, so an accepted asset cannot be reproduced or audited.
- **No shared contract.** Each game invented its own sprite and part spec. The two forges converged on one contract by hand (`plan/issues/comfyui-studio-family-contract-v0-2026-11-01.md`), but nothing in Tillandsias reads or checks it.
- **Licences are refused rather than acknowledged.** The operator ruled that users may accept restricted licences when the acceptance is recorded durably, and that every accepted licence becomes a spec in the agreeing project naming the obligations it must honour. Tillandsias records consent and does not enforce it.
- **Live faults:**
  - parallel `image.generate` calls crashed the engine (fixed by 1955-rjv3);
  - the preview at `:18443` closes connections for a project named with an underscore (1935-svxq).

These users are the design target, together with sibling projects of the same shape (cannonball and any other game or app forge that makes art).

## What Changes

1. **`studio.run_workflow`**, a new MCP tool on the forge's tool socket. It takes:
   - an API-format ComfyUI workflow JSON committed in the project;
   - named input files under the lane scratch folder;
   - seed and prompt overrides;
   - a batch size.

   It runs the workflow in the studio container, queued with every other GPU job on the host, and returns output paths plus a provenance record per output. Every model a workflow loads must pass the licence register.
2. **The family contract, v1**, ratified here from v0 with the rulings below. It ships with:
   - a JSON Schema;
   - a pure static checker exposed as `studio.validate_family`, which runs no GPU.
3. **Pinned studio custom nodes and models** for:
   - reference conditioning (IP-Adapter Plus, non-FaceID);
   - transparent output (LayerDiffuse on SDXL; BiRefNet matte elsewhere);
   - the core ControlNet and LoRA nodes.

   Every node and weight is pinned to a commit and a sha256, under a licence the register admits.
4. **Durable third-party licence consent.** When a user accepts a licence:
   - the acceptance is signed through the os-verified-approval-gates mechanism;
   - it is recorded in the agreeing project;
   - the skill writes an OpenSpec obligations spec into that project ("This project depends on X and must now adhere to Y").

   The fetch gate admits a non-permissive artefact only when such a record exists. Nothing is enforced beyond recording.
5. **Follow-ons, designed here and built after the P0 set:**
   - CorridorKey 2.0 as a proof-of-concept studio job, under the per-user standing approval;
   - project LoRA training and storage;
   - a BPM flipbook review UI.

## Capabilities

### New Capabilities
- `third-party-licence-consent`: signed acceptance of a third-party licence, the per-project acknowledgement record, the generated obligations spec, and the fetch gate that reads the record.

### Modified Capabilities
- `imagegen-studio`: the forge-callable workflow tool, the family contract and its checker, the pinned nodes and models, provenance, and the shared GPU queue.

## Impact

- `crates/tillandsias-headless`: new modules `studio_tool.rs` (run_workflow), `studio_contract.rs` (schema checker) and `licence_consent.rs`; registration in `mcp_socket.rs`; the GPU queue from 1955-rjv3 shared with studio jobs.
- `images/imagegen-studio`: `custom-nodes.toml` and its locks, and `extra_model_paths.yaml`.
- `images/imagegen/models.tsv` and `images/models/licence-register.tsv`: new pinned rows.
- A new skill, `accept-licence`, built on os-verified-approval-gates.
- Plan orders:
  - P0, needed for the next launches: 1956-x7xp, 1956-26qh, 1956-bh6j, 1935-svxq.
  - P1: 1956-ecpb (implements 1954-dvz9), 1956-ucix (implements 1954-xy5m).
  - P2: 1956-m8wx.
