## 1. Version the hash file

- [x] 1.1 In `build-image.sh`, derive hash file name from IMAGE_TAG instead of IMAGE_NAME
- [x] 1.2 Clean up old unversioned hash files

## 2. Always invoke build script from tray

- [x] 2.1 In handlers.rs launch-time check, always call build script (remove image_exists short-circuit)
- [x] 2.2 Keep the retry logic for image_exists after build completes

## 3. Prune old forge images

- [x] 3.1 Add `prune_old_forge_images()` call after successful forge build in handlers.rs
- [x] 3.2 Ensure prune function removes all tillandsias-forge:v* except current tag
- [x] 3.3 Add prune after init.rs build path too

## 4. Detect newer forge images

- [x] 4.1 Before building, list tillandsias-forge:v* images and find the newest
- [x] 4.2 If a newer version exists, use it and log warning
- [x] 4.3 Skip build when using a newer image

## 5. Verify

- [x] 5.1 cargo check --workspace compiles clean
- [x] 5.2 cargo test --workspace passes
