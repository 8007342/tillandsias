## Why

The forge container's `entrypoint.sh` is placed at `/home/forge/entrypoint.sh` — directly inside the user's home directory. When a user browses their home with `ls ~`, a file manager, or any shell, they see a stray `entrypoint.sh` file that has nothing to do with their work. This is confusing and pollutes the home directory.

System-level files like entrypoints belong in system locations, not in user home. The `forge-welcome.sh` script already follows the correct convention by living at `/usr/local/share/tillandsias/forge-welcome.sh`.

## What Changes

- **`flake.nix` — entrypoint placement**: Copy `entrypoint.sh` to `/usr/local/bin/tillandsias-entrypoint.sh` instead of `/home/forge/entrypoint.sh`. Update the `chmod` and the container `Entrypoint` config to match.

## Capabilities

### New Capabilities
(none)

### Modified Capabilities
- `forge-image`: Entrypoint is placed at a system path (`/usr/local/bin/`) rather than user home, keeping `~/` clean.

## Impact

- **Modified files**: `flake.nix`
- **Image rebuild required**: The entrypoint path changes inside the image layer.
- **No behavioral change**: The entrypoint script itself is unchanged; only its location moves.
