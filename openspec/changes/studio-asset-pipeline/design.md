# Design: studio asset pipeline

## Context

- **What exists.**
  - The light tool `image.generate` runs stable-diffusion.cpp. It has a tier ladder, consent tokens, the licence register and a lane scratch volume.
  - After 1954-gdi6 and 1955-rjv3 it also has one ControlNet, LoRAs, a per-host GPU queue, and degraded reporting.
  - The optional `imagegen-studio` container (1874-zry8) runs ComfyUI v0.40.0 with only ComfyUI-GGUF. It mounts the shared model cache read-only at `/models` and the lane scratch volume at `/out`. No forge-callable tool reaches it.
  - lenovinha owns the `--studio` launch lane (1953-stsk, 1945-sthg).
- **Who it is for.** Two game forges defined the needs on 2026-11-01:
  - demon_attack needs layered ship parts, docks and wear states.
  - kumbia-kombat needs beat-timed character frames rendered from hand-keyed Blender stand-in rigs, per-room pixel finishing, and floor-perspective and side-on cameras.
  - Sibling projects such as cannonball have the same shape: a game or app forge that needs consistent, reproducible, licence-clean art.
- **Their documents:**
  - 8007342/kumbia-kombat, branch work/1830-pipe: `plan/asset-pipeline-requirements.md`, `asset-inventory-contract.md`, `generative-animation-research.md`;
  - demon_attack's `licence-review.md`;
  - the contract record `plan/issues/comfyui-studio-family-contract-v0-2026-11-01.md`.
- **Operator rulings this design obeys (2026-11-01):**
  - consent is a grant with a scope and an expiry, and a granted tier approval holds until expiry is enforced;
  - a standing approval covers free models in the operator's own projects;
  - OpenRAIL counts as permissive, and its use restrictions pass downstream;
  - CorridorKey ships as a proof of concept first, and Corridor sees a demo before any wider release;
  - accepting a licence produces a durable obligations spec in the agreeing project, signed, recorded, never enforced, never restricting the user.

## Goals / Non-Goals

**Goals:**
- A forge agent runs a committed ComfyUI workflow headlessly, in batch, and gets output paths plus provenance back.
- One contract describes every asset family, and a static checker rejects a bad spec before any GPU time is spent.
- Every model a run loads is pinned and licence-admitted, or acknowledged by the user.
- An accepted licence leaves a signed record and an obligations spec in the project.
- GPU jobs from both engines share one queue per host.

**Non-Goals:**
- No enforcement of licence obligations; the project honours its own spec.
- No hosted or paid inference.
- No redistribution of restricted weights: the user's machine fetches them after acknowledgement.
- No custom training UI. LoRA training is P2 and headless.
- No detector-only pose pipeline: control images come from the caller.

## Decisions

### D1. `studio.run_workflow` is a tray-side MCP tool that proxies to the studio's HTTP API

The forge calls the tool on its existing MCP socket, exactly as it calls `image.generate`. The tray validates the request, then submits to ComfyUI at `http://<studio container>:8188/prompt` over the enclave network, follows `/ws` for progress, and collects the outputs. The forge never talks to ComfyUI directly for headless runs. The browser UI stays available through `browser.open` for people.

Request:

```json
{
  "workflow": "tool/art/workflows/character-pose-sdxl.api.json",
  "inputs":   { "pose": "/work/tmp/imagegen/in/gk/left_hand.peak.pose.png" },
  "overrides": { "seed": 930001, "prompt": "...", "negative_prompt": "..." },
  "count": 4,
  "family": "art/families/gatekeeper-v3.json",
  "tier": "I1"
}
```

- `workflow` is a path in the project checkout, read by the tray from the forge's source mount. It must be ComfyUI API format, not the UI graph format.
- `inputs` binds names to files. A `LoadImage` node whose `image` input is the string `"$pose"` receives the file bound to `pose`. Every file must sit under `/work/tmp/imagegen/`.
- `overrides` reach only nodes that carry a `_meta.title` of `$seed`, `$prompt` or `$negative_prompt`. A workflow therefore declares which knobs are open.
- `count` is the batch size, 1 to 16, run as consecutive queue items with seeds `seed`, `seed+1`, and so on.
- `family` is optional. When it is given, the run first passes `studio.validate_family` and is refused on any static failure.

Validation happens before anything is queued:

1. The workflow JSON parses.
2. Every `class_type` is a ComfyUI core node or a node from a pinned custom-node package (D4). Anything else is refused as `node_not_pinned`.
3. Every model filename a loader references (`ckpt_name`, `lora_name`, `control_net_name`, `ipadapter_file`, `vae_name`, and the others) resolves to a row of `models.tsv` that the licence register admits, or that a consent record admits (D6). Anything else is refused as `model_refused`. Admitted files the cache lacks are fetched through the existing `ensure_files` path, with progress.
4. Every input file exists.

The result is shaped like `image.generate` (1871-47ex), with paths and never bytes:

```json
{ "job": "st-<stamp>", "outputs": [ { "path": "/work/tmp/imagegen/studio/st-<stamp>/0000.png",
  "width": 768, "height": 960, "has_alpha": true, "provenance": "…/0000.provenance.json" } ],
  "degraded": null, "elapsed_s": 41.2 }
```

### D2. Files cross through the existing lane scratch volume; it lives as long as the forge

This resolves open decision (a) from 1935-k2ib. The per-forge lane volume is already mounted in the forge at `/work/tmp/imagegen` and in the studio at `/out`.

- Inputs go under `in/`.
- Studio outputs go under `studio/<job>/`.
- `/work/tmp/imagegen/X` in the forge is `/out/X` in the studio.

The volume is destroyed on forge teardown, as already ruled for Q1 (2026-10-25). The forge commits what its owner accepts. No new mount and no host path is exposed.

### D3. One GPU queue per host for both engines

The ticket queue from 1955-rjv3 moves from `imagegen_tool.rs` into a small shared module, `gpu_queue.rs`. Studio jobs take a turn exactly as `image.generate` calls do, report `Queued { position }`, and name the VRAM holders on a VRAM failure. The studio container stays up between jobs, but it holds the turn only while a prompt executes. After a job the tray calls ComfyUI's `/free` endpoint with `unload_models: true` so the next job, of either engine, starts with the device empty. A placement that falls back to the CPU is reported as `degraded`, as in 1955-rjv3.

### D4. Pinned custom nodes and models (P0 set)

These are added to `custom-nodes.toml` with a commit and a lock, and to `models.tsv` and the register with revision, sha256 and licence. Each is verified on its card at pin time.

| Need | Node package | Weights |
|---|---|---|
| ControlNet apply, LoRA | ComfyUI core | xinsir OpenPose SDXL (pinned, 1957-pins); xinsir Union SDXL promax (apache-2.0) for depth and lineart |
| Reference identity | ComfyUI_IPAdapter_plus (GPL-3.0, the same as ComfyUI) | IP-Adapter Plus SDXL, non-FaceID only, plus its CLIP-ViT-H image encoder; no InsightFace |
| Transparent output | ComfyUI-layerdiffuse | layer_xl_transparent_attn and layer_xl_transparent_conv, SDXL only |
| Matte elsewhere | a BiRefNet-only node | BiRefNet (MIT) weights; never RMBG-1.4/2.0 |
| Pixel style | none (LoRA) | nerijs/pixel-art-xl (pinned, 1957-pins) |
| QA embedding | none (tray-side) | facebook/dinov2-small (apache-2.0) |

A node package whose own code pulls weights at runtime from an unpinned URL is patched or refused. Weights come only from the shared cache at `/models`, and the studio has no egress. The Union ControlNet needs a control-type selector, which the pinned core apply node or the Union node provides; the implementer verifies which.

### D5. Provenance: one record per output

`<output>.provenance.json` sits beside each file, and the same object is returned in the result:

```json
{ "schema": "tillandsias.provenance/v1", "pipelineVersion": "<tillandsias version>",
  "engine": { "name": "comfyui", "ref": "v0.40.0", "sha": "3541246…", "nodes": [{"name","commit"}] },
  "workflow": { "path": "...", "sha256": "..." },
  "models": [ { "file": "...", "repo": "...", "revision": "...", "sha256": "...", "licence": "...",
               "consent": null | "<acknowledgement id>" } ],
  "inputs": [ { "name": "pose", "path": "...", "sha256": "..." } ],
  "seed": 930001, "prompt": "...", "negative_prompt": "...", "tier": "I1",
  "placement": "cuda", "family": { "path": "...", "sha256": "...", "contract": "1935-k2ib/v1" } }
```

`image.generate` gains the same record, with engine `sd.cpp` and its tag, so both tools speak one schema. The `pipelineVersion` in a family spec stays `null`, and the tool stamps it here.

### D6. Licence consent: signed acceptance, a project record, an obligations spec, a fetch gate

This implements 1954-dvz9.

- **Acceptance.** The `accept-licence` skill, run in the forge, asks the tray to show the licence:
  - its id, version and hash;
  - the restriction clauses, quoted verbatim from the card or the LICENSE file pinned with the row;
  - the artefact (repo, revision, file, sha256).

  The user approves through os-verified-approval-gates: an SSHSIG over the approval statement by an enrolled per-host key, released by Windows Hello, Touch ID, fingerprint or FIDO (its D1 to D3). The grant carries a scope (`project:<name>` or `operator-projects`) and an expiry (session, a TTL, or `standing`). Under the standing-approvals ruling a grant holds until expiry is enforced.
- **Record.** The skill commits a signed commit to the agreeing project containing:
  - `licences/acknowledgements/<artefact-slug>.yaml`: the statement, the signature, the grantor, the time, the scope and the expiry;
  - `openspec/specs/third-party-licence-<licence-id>/spec.md`: generated from the licence's obligation classes. It reads "This project depends on <artefact> and must now adhere to <obligations>", with one requirement per obligation:
    - attribution (with its exact required text);
    - notice;
    - share-alike;
    - non-commercial;
    - use-restriction passdown, which is the OpenRAIL Attachment A;
    - field-of-use;
    - seat or revenue thresholds;
    - no redistribution.

    The spec states how the project honours each obligation, for example "the credits screen shows 'CorridorKey'". The project adds the how.
- **Gate.** `register_admits` admits a permissive row as today. A non-permissive row lives in `images/models/licence-register-restricted.tsv`, with its obligation classes and its licence text hash. It is admitted only for a request from a project whose checkout holds a matching acknowledgement that the tray can verify. A licence whose terms forbid the use outright stays refused.
- **Never redistribute.** Restricted weights are fetched only on the user's machine, after acknowledgement, into the user's cache. They are never bundled in an image or a release.
- **First record.** The operator's standing approval (acknowledgement #1, 2026-11-01) seeds the operator's projects with a grant of scope `operator-projects`, use non-sale, expiry `standing`. It covers the free models on demon_attack's `licence-review.md` and kumbia-kombat's list, plus the restricted-free ones (non-commercial weights and CorridorKey 2.0). It does not authorise redistribution, or clicking through gated terms (for example FLUX.1-schnell) on the operator's behalf.

### D7. The family contract v1 (rulings on v0)

The contract is the v0 record plus its two revisions, ratified as `1935-k2ib/v1` with these rulings:

- **(a) ACCEPTED.** `qa.static.palette_fails_all_gates` is mandatory for any family that declares `reservedRamps`. `region_mask_colours_declared` is mandatory for any family that declares `regions`.
- **(b) ACCEPTED,** with this refinement:
  - `camera: "floor-perspective" | "side-on"` lives on each `targets[]` entry, because a per-room atlas has one camera;
  - `frame.camera` is a family default that a target may override;
  - `poses[]` carry no camera;
  - `baseline_drift` measures on a projected ground line under `floor-perspective` and on a flat one under `side-on`.
- **Per-room native size:** `frame.native = {"perRoom": true, "<room>": {width, height, pixelScale}}`. Every target names its `room`.
- **`kind` is an open enum.** `character-frames` and `layered-parts` are defined now. A sibling project such as cannonball adds a kind by contributing its schema branch; the checker refuses an unknown kind with the list of known ones.
- **Gate grammar is data, never eval.** A colour matches a ramp when ANY gate has ALL its conditions true. `lhs` is a channel or `{sub:[a,b]}`; `rhs` is a literal or `{mul:[k,channel]}`. RGB is unpremultiplied, in the range 0–1.
- **Paths in a spec are project-relative**, and inputs are copied to the lane volume by the caller.

`studio.validate_family {spec}` is pure: it reads the spec and the PNGs it names and runs no GPU. It returns:
- `ok:family:<name>`, or
- one `refused:<check>:<detail>` line per failure, for checks such as schema, `palette_fails_all_gates` (naming the colour and the gate it passes), `region_mask_colours_declared` (naming the undeclared colour and the file), a missing input file, and an unknown kind.

The JSON Schema ships at `openspec/changes/studio-asset-pipeline/contract/family-spec.v1.schema.json` and moves to `openspec/specs/imagegen-studio/` on archive.

### D8. Project LoRAs (P2)

This resolves open decision (b) from 1935-k2ib.

- A LoRA trained by a project lives in the shared model cache under `models/imagegen/project/<project>/lora/`, never in git, with a provenance sidecar listing:
  - the training images' hashes;
  - the base model and its licence;
  - the trainer and its commit;
  - the seed.
- Its licence is the base model's licence plus the project owner's own rights in the training data.
- The project's acceptance is a consent record of scope `project:<name>` (D6), signed by the owner.
- Training runs headless as a studio job (`studio.train_lora`) in the GPU queue. It is P2 and not needed for the next launches.

### D9. CorridorKey 2.0 proof of concept (P1)

This implements 1954-xy5m.

- It is a studio job (`studio.key_footage {input, outputs:[alpha,fg,cutout], low_vram}`). It runs `infer.py` from a pinned commit in a separate CUDA image, `imagegen-corridorkey`, built only on first use.
- Its weights and its three foundation models come from the restricted register, behind D6. The operator's standing approval admits them for the operator's projects.
- Its acceptance writes the obligations spec: attribution "CorridorKey", share-alike on modifications, the commercial-integration clause, and the seat threshold.
- No automatic wiring ships to other users until Corridor has seen the demo, as the operator ruled.

### D10. Review UI (later)

For the next launches people review in the stock ComfyUI frontend through `browser.open`, and in the project's own tools. A BPM flipbook (onion skin, accept/reject, pivot edit, manifest export) belongs to the web-studio-lanes work and is filed after the P0 set lands.

## Risks / Trade-offs

- **Custom-node supply chain.** Nodes run Python inside the studio. Mitigation: every node is pinned to a commit with a lock, the node directory is read-only, the studio has no egress, and the licence is checked at pin.
- **sd.cpp SDXL ControlNet may not load** (its README names SD1.5 only). Mitigation: the studio path covers SDXL ControlNet natively, and the interim path is tested live on macuahuitl.
- **VRAM thrash between the inference container and the studio.** Mitigation: the shared queue, `/free` after each job, and named holders. A long-term host-wide VRAM broker is out of scope.
- **Generated obligations specs can be wrong about a licence.** Mitigation: the clauses are quoted verbatim, the classes are conservative (an unknown clause is listed as "review"), and the project owner signs the acceptance after reading the quotes.

## Migration Plan

1. P0 (1956-x7xp, 1956-26qh, 1956-bh6j, 1935-svxq) lands on linux-next and is built into the next release.
2. The game forges relaunch on that release. They run `studio.validate_family` on their families, then `studio.run_workflow` with their committed workflows.
3. P1 (1956-ecpb, 1956-ucix) follows. P2 (1956-m8wx, flipbook) after that.

## Open Questions

None blocking. The operator delegated the remaining decisions to this design on 2026-11-02.
