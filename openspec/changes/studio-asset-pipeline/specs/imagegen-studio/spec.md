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
