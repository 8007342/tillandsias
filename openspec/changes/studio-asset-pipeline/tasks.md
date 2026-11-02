## 1. P0: needed for the next game-forge launches

- [x] 1.1 Order 1956-26qh: family contract v1 JSON Schema, `studio_contract.rs` static checker, and the `studio.validate_family` tool (D7)
- [ ] 1.2 Order 1956-bh6j: pin the IP-Adapter Plus (non-FaceID), LayerDiffuse and BiRefNet nodes, plus their weights and the Union ControlNet, in custom-nodes.toml, models.tsv and the register (D4)
- [ ] 1.3 Order 1956-x7xp: `studio.run_workflow` with validation, file crossing, the shared GPU queue, `/free` after each job, and provenance v1, which `image.generate` adopts too (D1, D2, D3, D5)
- [ ] 1.4 Order 1935-svxq: the preview on :18443 serves an underscore-named project to the browser and to in-forge curl

## 2. P1

- [x] 2.1 Order 1956-ecpb (implements 1954-dvz9): the `accept-licence` skill, the restricted register, acknowledgement records, generated obligations specs, the gate, and seeding the operator's standing approval (D6)
- [x] 2.2 Order 1956-ucix (implements 1954-xy5m): the CorridorKey 2.0 proof-of-concept studio job (D9)

## 3. P2

- [ ] 3.1 Order 1956-m8wx: project LoRA training and storage (D8)
- [ ] 3.2 The BPM flipbook review UI, filed after the P0 set lands (D10)

## 4. E: img2img, inpaint, layout mask, pixel finish, contact sheet (order 1959-xsy5)

- [ ] 4.1 `image.generate` gains `init_image`, `mask`, `strength` and `layout`, passed as `--init-img`, `--mask`, `--strength`; the build reads `sd-cli -h` of the pinned tag and fails on a missing flag; kept pixels are composited back; provenance gains `init`, `mask`, `strength`, `layout` (D11)
- [ ] 4.2 `studio.run_workflow` binds the same keys to `$init_image`, `$mask`, `$layout_mask` and `$strength`, and refuses `workflow_has_no_input:<name>` before queueing (D11)
- [ ] 4.3 Family contract: `layout.reserved[]`, the `reserved_regions_empty` check, the `finish` block, the `palette_contains_outline` check, and the `tillandsias.palette/v1` file; the example gains `finish` (D11, D12)
- [ ] 4.4 `studio.finish_pixels` in the tray: alpha, grid snap, quantise, fixed encoder, `.finish.json`; a cargo test runs it twice and against a golden sha256 (D12)
- [ ] 4.5 `studio.contact_sheet` with the embedded bitmap font and `.contact.json`; `contact_sheet: true` on both generators (D13)
