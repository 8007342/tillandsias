## MODIFIED Requirements

### Requirement: Forge image ships cheatsheets at /opt/cheatsheets-image (image-baked canonical)

The forge image (`images/default/Containerfile`) SHALL bake cheatsheets at
`/opt/cheatsheets-image/` (the immutable lower-layer copy) rather than at
`/opt/cheatsheets/` (which is now a runtime tmpfs mount populated by
`populate_hot_paths()` in every forge entrypoint).

> Delta: the COPY target in the Containerfile moves from `/opt/cheatsheets` to
> `/opt/cheatsheets-image`. The path `/opt/cheatsheets` is now a runtime tmpfs
> mount populated by `populate_hot_paths()` in every forge entrypoint.
> `/opt/cheatsheets-image` is the immutable, image-baked lower-layer copy.

1. `COPY cheatsheets/ /opt/cheatsheets-image/` at image-build time (lower-layer bake).
2. NOT create `/opt/cheatsheets/` at image-build time — that directory is created
   by the tmpfs mount at container start.
3. Export `ENV TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` unchanged (the runtime
   tmpfs view, not the image-baked canonical).

#### Scenario: /opt/cheatsheets/ is tmpfs-backed at runtime; canonical at /opt/cheatsheets-image/

- **WHEN** a forge container starts
- **THEN** `findmnt /opt/cheatsheets -no FSTYPE` returns `tmpfs`
- **AND** `ls /opt/cheatsheets-image/INDEX.md` succeeds (image-baked canonical)
- **AND** `ls /opt/cheatsheets/INDEX.md` succeeds (runtime tmpfs view, populated
  by `populate_hot_paths()`)

#### Scenario: populate_hot_paths copies image-baked content to tmpfs at entrypoint

- **WHEN** the forge entrypoint runs `populate_hot_paths()`
- **THEN** `/opt/cheatsheets/` contains the same files as `/opt/cheatsheets-image/`
- **AND** the copy is a `cp -a` (preserving permissions and timestamps)
- **AND** running `populate_hot_paths()` a second time is idempotent (safe to call
  from multiple entrypoints via `lib-common.sh`)

## Sources of Truth

- `cheatsheets/runtime/forge-hot-cold-split.md` — explains the image-baked vs runtime-tmpfs distinction
- `cheatsheets/runtime/forge-container.md` — forge container launch model and entrypoint structure
