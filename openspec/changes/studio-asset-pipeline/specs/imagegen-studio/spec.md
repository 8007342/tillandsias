## ADDED Requirements

### Requirement: A forge runs a committed studio workflow headlessly

The tool socket SHALL offer `studio.run_workflow`. It runs an API-format ComfyUI workflow from the project checkout in the studio container, with named input files from the lane scratch folder, seed and prompt overrides limited to nodes the workflow marks as open, and a batch count. It SHALL return output paths and a provenance record per output, never image bytes.

#### Scenario: A pinned workflow runs and returns provenance
- **WHEN** a forge calls `studio.run_workflow` with a workflow whose nodes and models are all pinned and admitted, and with input files under `/work/tmp/imagegen/`
- **THEN** each output is written under `/work/tmp/imagegen/studio/<job>/`, with a `.provenance.json` beside it naming the engine, the workflow sha256, every model's sha256 and licence, the inputs' sha256s, the seed and the prompts

#### Scenario: An unpinned node or model is refused before anything runs
- **WHEN** a workflow names a node class that no pinned package provides, or a model file that neither the licence register nor a consent record admits
- **THEN** the call returns `node_not_pinned` or `model_refused`, naming it, and nothing is queued or fetched

### Requirement: One GPU queue per host for every image engine

Image jobs from `image.generate` and from the studio SHALL take turns on the host's GPU in arrival order. A waiting job reports its queue position. A job is never refused for being concurrent.

#### Scenario: Concurrent calls never overlap on the device
- **WHEN** several image jobs arrive at once from either engine
- **THEN** exactly one runs on the device at a time, and each waiting call receives progress naming how many jobs are ahead

### Requirement: Asset families are checked statically against one contract

The tool socket SHALL offer `studio.validate_family`. It checks a family spec against the family contract v1 schema and its mandatory static checks, without using the GPU. A family that declares `reservedRamps` MUST pass `palette_fails_all_gates`, and a family that declares `regions` MUST pass `region_mask_colours_declared`.

#### Scenario: An outline colour inside a recolour gate is refused
- **WHEN** a family's outline colour satisfies every condition of one of its reserved-ramp gates
- **THEN** `studio.validate_family` returns `refused:palette_fails_all_gates`, naming the colour and the gate, and `studio.run_workflow` with that family queues nothing

### Requirement: Image-to-image, inpaint and a layout mask work at every tier

`image.generate` and `studio.run_workflow` SHALL accept `init_image`, `mask`, `strength` and `layout`. The mask convention is one for both engines: white is repainted, black is kept. On the sd.cpp tiers the tray SHALL pass `--init-img`, `--mask` and `--strength`. A pixel under a fully black mask, or inside a reserved region of the family's `layout`, MUST be byte-identical to the input after the run. A family that declares `layout` MUST pass `reserved_regions_empty` on every finished output.

#### Scenario: A kept region is returned unchanged on an sd.cpp tier
- **WHEN** a forge calls `image.generate` with `tier: "I1"`, an `init_image`, a `mask` whose left half is black, and `strength: 0.6`
- **THEN** the engine runs with `--init-img`, `--mask` and `--strength 0.6`, every output pixel under the black half equals the init image's pixel, and the provenance record carries the init and mask sha256s and the strength

#### Scenario: A reserved centre lane stays empty whichever engine drew the part
- **WHEN** a family declares `layout.reserved` with a `centre-lane` rect and `fill: "transparent"`, and a part is generated through either engine
- **THEN** every finished output has alpha 0 at every pixel inside the rect, and a run whose output does not is reported `refused:reserved_regions_empty`, naming the region and the first offending pixel

#### Scenario: A workflow that does not open the knob is refused before it queues
- **WHEN** `studio.run_workflow` receives `mask` for a workflow with no `LoadImage` node whose `image` is `"$mask"`
- **THEN** the call returns `workflow_has_no_input:mask` and nothing is queued

### Requirement: The pixel finish is a pure, byte-reproducible post-process

The tool socket SHALL offer `studio.finish_pixels`. It runs in the tray, uses no GPU and no container, and applies alpha, nearest-neighbour grid snap to the room's native size, quantisation to the family's locked palette, and a fixed PNG encoder, in that order and in integer arithmetic. The palette file SHALL be `tillandsias.palette/v1`: an ordered list of 1 to 256 `#RRGGBB` colours and a `transparent` entry or `null`. The same inputs MUST produce the same bytes on every host.

#### Scenario: Two runs give one sha256
- **WHEN** `studio.finish_pixels` runs twice on the same input, matte, family and room
- **THEN** both outputs have the same sha256, and the `.finish.json` sidecar names the sha256 of the input, the matte, the palette file and the family spec

#### Scenario: Every opaque pixel is a palette colour at native size
- **WHEN** a 768×960 frame is finished for a room whose native size is 96×128
- **THEN** the output is 96×128, every pixel with alpha 255 is one of the palette's colours, and every other pixel has alpha 0

#### Scenario: An outline missing from the palette is refused statically
- **WHEN** a family's `outline` colour is not in its `palette.locked` file
- **THEN** `studio.validate_family` returns `refused:palette_contains_outline`, naming the colour and the file, and no finish runs

### Requirement: A contact sheet shows outputs across tiers and seeds with provenance

The tool socket SHALL offer `studio.contact_sheet`. It lays the given outputs on a labelled grid, scaled nearest-neighbour, with each cell naming its row, its column, the model's short name and the first eight hex characters of the output's sha256, and writes a `.contact.json` that maps every cell to its output and provenance paths. `image.generate` and `studio.run_workflow` SHALL produce one per job when called with `contact_sheet: true`, tiers on rows and seeds across columns. It uses no GPU and depends on no host font.

#### Scenario: One job, one sheet, every cell resolvable
- **WHEN** `studio.run_workflow` runs with `count: 4` and `contact_sheet: true`
- **THEN** the job folder holds one sheet with four labelled cells in one row, and its `.contact.json` names, for each cell, the seed, the output path and the provenance path

#### Scenario: Pixel art stays crisp on the sheet
- **WHEN** a 96×128 finished frame is placed in a 256-pixel cell
- **THEN** the cell contains only colours of the frame and the checkerboard, with no blended intermediate colour
