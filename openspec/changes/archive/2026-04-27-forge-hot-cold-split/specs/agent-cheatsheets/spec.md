## MODIFIED Requirements

### Requirement: Forge image bakes cheatsheets

The forge image SHALL maintain TWO views of the cheatsheets — an image-baked
canonical at `/opt/cheatsheets-image/` and a runtime tmpfs view at
`/opt/cheatsheets/` (8 MB cap). The agent-facing env var
`TILLANDSIAS_CHEATSHEETS=/opt/cheatsheets` is unchanged — agents observe no
behavioral difference.

> Delta: the single `/opt/cheatsheets` bake is replaced by a two-layer model.
> The image-build COPY lands at `/opt/cheatsheets-image/` (immutable lower layer).
> At container start, `populate_hot_paths()` copies the canonical content into
> `/opt/cheatsheets/` (runtime tmpfs, 8 MB cap).

| View | Path | Backing store | Populated by |
|------|------|---------------|--------------|
| Image-baked canonical | `/opt/cheatsheets-image/` | Image overlayfs lower layer (disk) | `COPY cheatsheets/ /opt/cheatsheets-image/` at build time |
| Runtime tmpfs view | `/opt/cheatsheets/` | Kernel tmpfs (RAM), 8 MB cap | `populate_hot_paths()` in every forge entrypoint |

#### Scenario: /opt/cheatsheets/ is the tmpfs view; /opt/cheatsheets-image/ is the immutable lower-layer copy

- **WHEN** a forge container starts and `populate_hot_paths()` completes
- **THEN** `findmnt /opt/cheatsheets -no FSTYPE` returns `tmpfs`
- **AND** `diff -r /opt/cheatsheets-image /opt/cheatsheets` returns exit 0
  (content is identical; the tmpfs is a complete copy of the image-baked layer)
- **AND** `/opt/cheatsheets-image/` is NOT a tmpfs — it is read-only overlayfs
  (image state)

#### Scenario: Environment variable is set to the tmpfs view (unchanged)

- **WHEN** an agent runs `echo $TILLANDSIAS_CHEATSHEETS` inside the forge
- **THEN** the output is `/opt/cheatsheets` — the RAM-backed view
- **AND** no agent code or cheatsheet reference requires updating

#### Scenario: Agent writes to /opt/cheatsheets are lost on container stop

- **WHEN** an agent writes to `/opt/cheatsheets/` (tmpfs is rw by default inside
  the container, though the 8 MB cap limits abuse)
- **THEN** the write is NOT visible in `/opt/cheatsheets-image/` and NOT
  persisted after container stop (tmpfs is ephemeral)
- **AND** the next forge container starts fresh from the image-baked canonical

## Sources of Truth

- `cheatsheets/runtime/forge-hot-cold-split.md` — HOT tier design and the two-layer cheatsheet model
- `cheatsheets/runtime/forge-container.md` — forge container launch model and entrypoint structure
