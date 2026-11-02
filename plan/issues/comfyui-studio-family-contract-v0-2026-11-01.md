# ComfyUI studio shared family contract 1935-k2ib/v0 — 2026-11-01

**Status:** `open`. This is design input for order 1935-k2ib. It is not adopted until that design lands.
**Filed:** 2026-11-01 by calmecacpilli.
**Source:** kumbia-kombat-forge sent it at the coordinator's request (macuahuitl-fedora). demon_attack-forge reviewed it twice. demon_attack's ship.json becomes kind `layered-parts` under the same contract.
**Trace:** order 1935-k2ib (design); order 1954-gdi6 (interim control_image + lora through image.generate).

## Why one contract

Both game forges agreed that ONE contract serves every asset family. It has three parts:
- a family spec JSON;
- a queue/results JSON;
- a provenance schema.

Stages branch on `kind`. `character-frames` uses frame, clips and poses. `layered-parts` uses slots, dock and wear.

## Field semantics

- `contract` and `pipelineVersion` record which rules applied. `pipelineVersion` stays `null` in a spec; the tool stamps it into provenance at run time.
- `frame`:
  - units are `native-px`, meaning pixels from the frame's top-left on the final native grid, and pivots are not normalised;
  - `scale.mode: fixed-per-family` is resolved once from the `referencePose` bounding-box height and stored in provenance;
  - `native: null` is a decision the owner has not made yet;
  - `margin` is a fraction of the generation canvas, and touching the border fails.
- `transparency.byBackend`:
  - SDXL uses LayerDiffuse (layerdiffusion-v1 `layer_xl_*`, creativeml-openrail-m);
  - every other backend uses a BiRefNet matte;
  - alpha is binary;
  - rmbg-1.4 and rmbg-2.0 are never shippable (see the 1935-k2ib row).
- `adapters.enum` lists only approved identity adapters. FLUX Redux is excluded because its licence is dev-only.
- `regions` and `poses[].regionMask`: each pose has a flat-colour ID PNG, rendered from the game's rig and aligned to that pose's control image. The palette snap picks its targets per region. `regionsRender` turns off antialiasing and filtering, so mask colours stay exact.
- `reservedRamps[].gates` are the runtime recolour thresholds, written as structure that is never evaluated as code:
  - a colour matches when ANY gate has ALL of its conditions true;
  - `lhs` is a channel (`r`, `g`, `b`) or `{sub:[a,b]}`;
  - `rhs` is a literal or `{mul:[k,channel]}`;
  - RGB is unpremultiplied, in the range 0–1.
- `clips[]` are timed in beats, through `durationBeats` and `events`, where an accent names its drawing.
- `poses[]` each carry:
  - a control image the CALLER supplies, plus aux images, all rendered from a Blender rig at beat-timed key frames (the tool must accept them, not only run detectors);
  - `supportFoot`;
  - `accent`.
- `qa.static` runs before generation:
  - `palette_fails_all_gates`: the outline and every non-cloth palette entry fail every gate. kumbia-kombat proposes making it MANDATORY for any family that declares `reservedRamps`. The old outline #1A1020 passed the cool gate, which is how this was found.
  - `region_mask_colours_declared`: every colour in a region mask is declared in `regions`.
- `qa.add` lists the per-run checks: `baseline_drift`, `head_size_variance`, `region_gate_agreement` and `identity_similarity` (facebook/dinov2-small, apache-2.0).
- `targets[]` are per-project writers: kumbiaManifest here, and demon_attack adds layeredAtlas. Each sets `requireHumanAcceptance`. `packing.anchorRelativeTo` is `trimmed-rect`.

## The tool asks this contract implies (kumbia-kombat P0)

- Run committed API-format workflows headlessly, with control and region PNGs passed by path on a shared mount.
- Run batches with progress.
- Return output paths plus provenance: the sha256 and licence of every model, LoRA and ControlNet, the seed, the prompts, the input hashes and the engine version.
- Later: a flipbook review at BPM.

## Example: Kumbia's Gatekeeper character-frames spec, compacted

The demon_attack review's six changes are applied:
1. the outline becomes #1A1018;
2. `qa.static` is added;
3. `regionsRender` is added;
4. the margin becomes a fraction of the canvas;
5. `packing.anchorRelativeTo` is set to `trimmed-rect`;
6. `pipelineVersion` stays null.

Strings that start with "…" stand for elided entries of the same shape: 62 of 64 poses, 12 of 14 clips and 2 of 3 gates. The full 37 KB file is on kumbia-kombat branch work/1830-pipe.

```json
{
  "contract": "1935-k2ib/v0",
  "pipelineVersion": null,
  "family": "gatekeeper-v3",
  "version": 1,
  "project": "kumbia-kombat",
  "kind": "character-frames",
  "frame": {
    "units": "native-px",
    "baselineY": null,
    "pivot": {
      "x": null,
      "y": null,
      "normalized": false
    },
    "scale": {
      "mode": "fixed-per-family",
      "referencePose": "groove.down_l",
      "resolved": null
    },
    "native": {
      "width": null,
      "height": null,
      "pixelScale": null
    },
    "margin": {
      "minClear": 0.03,
      "units": "fraction-of-generation-canvas",
      "failOnBorderTouch": true
    },
    "generationCanvas": {
      "width": 768,
      "height": 960
    }
  },
  "transparency": {
    "byBackend": {
      "sdxl": "layerdiffuse",
      "default": "matte"
    },
    "matte": "birefnet",
    "alpha": "binary"
  },
  "outline": "#1A1018",
  "symmetry": "none",
  "adapters": {
    "enum": [
      "ip-adapter-sdxl",
      "qwen-image-edit",
      "img2img"
    ]
  },
  "references": [
    {
      "role": "identity",
      "image": "assets/art/ensemble/gatekeeper-v2.png",
      "crop": "TBD",
      "adapter": "ip-adapter-sdxl",
      "weight": 0.7
    }
  ],
  "regions": {
    "#FF0000": "skin",
    "#00FF00": "hair",
    "#0000FF": "cloth",
    "#FFFF00": "hat",
    "#00FFFF": "shoes",
    "#FF00FF": "accessory"
  },
  "reservedRamps": [
    {
      "id": "kumbia-outfit",
      "appliesToRegions": [
        "cloth"
      ],
      "recolor": false,
      "gates": [
        {
          "id": "plum",
          "all": [
            {
              "lhs": "r",
              "op": ">=",
              "rhs": 0.392157
            },
            {
              "lhs": "r",
              "op": ">=",
              "rhs": {
                "mul": [
                  0.7,
                  "b"
                ]
              }
            },
            {
              "lhs": "b",
              "op": ">=",
              "rhs": {
                "mul": [
                  0.32,
                  "r"
                ]
              }
            },
            {
              "lhs": "g",
              "op": "<=",
              "rhs": {
                "mul": [
                  0.55,
                  "b"
                ]
              }
            },
            {
              "lhs": {
                "sub": [
                  "b",
                  "g"
                ]
              },
              "op": ">=",
              "rhs": 0.047059
            }
          ]
        },
        "…cool, pink"
      ]
    }
  ],
  "palette": {
    "locked": "tool/art/palettes/gatekeeper.json"
  },
  "style_prompt": "pixel art game sprite, full body, single character, warm festive party, crisp clusters, clean dark outline, flat shading, plain background",
  "style_negative": "multiple characters, sprite sheet, grid, text, logo, blur, motion blur, cropped feet, cropped hat, shadow on floor",
  "character_prompt": "cheerful mustached man in a cream panama hat with teal band, purple guayabera shirt with teal embroidery panels, cream trousers, teal shoes",
  "clips": [
    {
      "id": "groove",
      "drawings": 8,
      "view": "front",
      "loop": true,
      "durationBeats": 2.0,
      "events": []
    },
    {
      "id": "left_hand",
      "drawings": 4,
      "view": "front",
      "loop": false,
      "durationBeats": 1.0,
      "events": [
        {
          "beat": 0.25,
          "type": "accent",
          "drawing": "peak"
        }
      ]
    },
    "…12 more"
  ],
  "poses": [
    {
      "id": "left_hand.peak",
      "clip": "left_hand",
      "order": 1,
      "view": "front",
      "control": {
        "type": "openpose",
        "image": "art_runs/inputs/gatekeeper-v3/left_hand.peak.pose.png",
        "aux": [
          {
            "type": "depth",
            "image": "art_runs/inputs/gatekeeper-v3/left_hand.peak.depth.png"
          }
        ],
        "strength": 0.85
      },
      "regionMask": "art_runs/inputs/gatekeeper-v3/left_hand.peak.regions.png",
      "supportFoot": "both",
      "accent": true
    },
    "…63 more"
  ],
  "generation": {
    "count_per_pose": 4,
    "seed_base": 930000,
    "seed_policy": "fixed per pose while tuning",
    "backend": "comfyui-api",
    "workflow": "tool/art/workflows/character-pose-sdxl.api.json",
    "tiers": {
      "I1": {
        "model": "SDXL-Lightning-4step",
        "steps": 4
      },
      "SDXL-base": {
        "model": "SDXL base 1.0",
        "steps": 25
      }
    }
  },
  "qa": {
    "inherit": [
      "coverage",
      "single_object",
      "border_touch",
      "slot_fill"
    ],
    "add": [
      {
        "id": "baseline_drift",
        "maxPx": 1,
        "scope": "consecutive drawings sharing a planted support foot"
      },
      {
        "id": "head_size_variance",
        "maxPct": 4,
        "scope": "family"
      },
      {
        "id": "region_gate_agreement",
        "rule": "non-cloth outside all gates; cloth inside one"
      },
      {
        "id": "identity_similarity",
        "against": "references",
        "threshold": "TBD",
        "embedding": {
          "model": "facebook/dinov2-small",
          "licence": "apache-2.0"
        }
      }
    ],
    "static": [
      {
        "id": "palette_fails_all_gates",
        "rule": "the outline and every non-cloth palette entry fail all reservedRamps gates; checked before generation"
      },
      {
        "id": "region_mask_colours_declared",
        "rule": "every colour in a regionMask PNG is a key of regions"
      }
    ]
  },
  "targets": [
    {
      "type": "kumbiaManifest",
      "atlas": "gatekeeper",
      "out": "assets/art/ensemble/gatekeeper-v3.png",
      "manifest": "assets/art/ensemble/manifest.json",
      "frameId": "{clip}_{drawing}",
      "fields": [
        "rect",
        "anchor",
        "pixelsPerUnit",
        "facing",
        "loop",
        "durationBeats",
        "events",
        "supportFoot",
        "status",
        "provenance"
      ],
      "packing": {
        "gutterPx": 2,
        "trim": true,
        "anchorRelativeTo": "trimmed-rect"
      },
      "requireHumanAcceptance": true
    }
  ],
  "regionsRender": {
    "antialias": false,
    "filtering": "none"
  }
}
```

## Revision 2026-11-01: kumbia-kombat owner decisions (relayed by kumbia-kombat-forge, demon_attack-forge informed)

These supersede the matching fields in the example above.

1. **Native pixel size is per room.** A character that appears in several rooms (Mācron) keeps ONE accepted high-res source set, and the pixel finish runs once per room target.
   - `frame.native` becomes `{"perRoom": true, "<room>": {"width", "height", "pixelScale"}}`.
   - `targets[]` gains a `room` key, one target per room atlas.
2. **Rooms may use different cameras.** Level 4 is side-on: a horizontal ground line, no floor-projection scaling, true profile views.
   - Proposed: `frame` and `targets[]` carry `camera: "floor-perspective" | "side-on"`.
   - QA uses it to know whether `baseline_drift` is measured on a projected ground line or a flat one.
3. **The motion source is hand-keyed Blender stand-in rigs.** The rigs render the control PNGs and region PNGs.
   - `poses[]` therefore stays camera-agnostic.
   - Camera and view are render parameters, not pose fields.
