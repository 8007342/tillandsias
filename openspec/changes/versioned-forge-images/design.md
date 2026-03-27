## Architecture

### Version Source

The version comes from `CARGO_PKG_VERSION`, which is set at compile time from `Cargo.toml`. This is a 3-part semver (e.g., `0.1.72`). The image tag format is `tillandsias-forge:v0.1.72`.

```rust
pub fn forge_image_tag() -> String {
    format!("tillandsias-forge:v{}", env!("CARGO_PKG_VERSION"))
}
```

### Data Flow: App Update Scenario

```
App v0.1.72 running -> User installs v0.1.73
  -> v0.1.73 launches
  -> forge_image_tag() returns "tillandsias-forge:v0.1.73"
  -> image_exists("tillandsias-forge:v0.1.73") -> false
  -> Any tillandsias-forge:v* exists? -> yes (v0.1.72) -> "Building Updated Forge"
  -> build-image.sh forge --tag tillandsias-forge:v0.1.73
  -> Prune: remove tillandsias-forge:v0.1.72
  -> forge_available = true
```

### Data Flow: First Install

```
App v0.1.73 installed fresh
  -> forge_image_tag() returns "tillandsias-forge:v0.1.73"
  -> image_exists("tillandsias-forge:v0.1.73") -> false
  -> Any tillandsias-forge:v* exists? -> no -> "Building Forge"
  -> build-image.sh forge --tag tillandsias-forge:v0.1.73
  -> No old images to prune
  -> forge_available = true
```

### build-image.sh Tag Override

```bash
# Dev mode (no --tag): defaults to :latest
scripts/build-image.sh forge
# -> tillandsias-forge:latest

# Versioned mode (--tag provided by Rust binary)
scripts/build-image.sh forge --tag tillandsias-forge:v0.1.72
# -> tillandsias-forge:v0.1.72
```

The `--tag` argument overrides the default `IMAGE_TAG` variable. Staleness detection still works identically -- it just checks for the overridden tag name instead of `:latest`.

### Pruning Strategy

Pruning happens in the Rust code after a successful build, not in `build-image.sh`. This keeps the shell script simple and gives the Rust code full control over when to clean up.

```
podman images --format '{{.Repository}}:{{.Tag}}'
  | grep 'tillandsias-forge:v'
  | grep -v "<current_tag>"
  | xargs -r podman rmi
```

The pruning is best-effort -- failures are logged but do not block operation.
