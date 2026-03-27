## 1. OpenSpec

- [x] 1.1 Write proposal.md
- [x] 1.2 Write design.md
- [x] 1.3 Write tasks.md
- [x] 1.4 Write specs/versioned-forge-images/spec.md

## 2. Implementation -- build-image.sh

- [x] 2.1 Add `--tag <tag>` argument parsing to build-image.sh
- [x] 2.2 Use `--tag` value as `IMAGE_TAG` when provided, fall back to `:latest`
- [x] 2.3 Update `--help` output to document `--tag`

## 3. Implementation -- Rust: forge_image_tag() function

- [x] 3.1 Replace `FORGE_IMAGE_TAG` constant with `pub fn forge_image_tag() -> String` in handlers.rs
- [x] 3.2 Update all `FORGE_IMAGE_TAG` references in handlers.rs to `forge_image_tag()`
- [x] 3.3 Update all `handlers::FORGE_IMAGE_TAG` references in main.rs to `handlers::forge_image_tag()`
- [x] 3.4 Replace `FORGE_IMAGE` constant in init.rs with `handlers::forge_image_tag()` call
- [x] 3.5 Update `image_tag()` in runner.rs to use versioned tag for forge images
- [x] 3.6 Update `FORGE_IMAGE_TAG` import in github.rs to use `forge_image_tag()` function

## 4. Implementation -- Build script invocation with --tag

- [x] 4.1 Update `run_build_image_script` in handlers.rs to pass `--tag` argument
- [x] 4.2 Update `run_build_image_script` in runner.rs to pass `--tag` argument
- [x] 4.3 Update `build_forge_image` in init.rs to pass `--tag` argument

## 5. Implementation -- Old image pruning

- [x] 5.1 Add `prune_old_forge_images()` function to handlers.rs
- [x] 5.2 Call prune after successful build in handlers.rs `run_build_image_script`
- [x] 5.3 Call prune after successful build in runner.rs `run_build_image_script`
- [x] 5.4 Call prune after successful build in init.rs `build_forge_image`

## 6. Implementation -- Launch-time messaging

- [x] 6.1 Update launch-time check in main.rs to detect "first time" vs "update" using any `tillandsias-forge:v*` existence check

## 7. Verification

- [x] 7.1 `./build.sh --check` passes
- [x] 7.2 `./build.sh --test` passes
