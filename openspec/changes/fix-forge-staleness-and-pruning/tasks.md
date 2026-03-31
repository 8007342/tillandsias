## 1. Version the hash file

- [ ] 1.1 In `build-image.sh`, derive hash file name from IMAGE_TAG instead of IMAGE_NAME
- [ ] 1.2 Clean up old unversioned hash files

## 2. Always invoke build script from tray

- [ ] 2.1 In handlers.rs launch-time check, always call build script (remove image_exists short-circuit)
- [ ] 2.2 Keep the retry logic for image_exists after build completes

## 3. Prune old forge images

- [ ] 3.1 Add `prune_old_forge_images()` call after successful forge build in handlers.rs
- [ ] 3.2 Ensure prune function removes all tillandsias-forge:v* except current tag
- [ ] 3.3 Add prune after init.rs build path too

## 4. Detect newer forge images

- [ ] 4.1 Before building, list tillandsias-forge:v* images and find the newest
- [ ] 4.2 If a newer version exists, use it and log warning
- [ ] 4.3 Skip build when using a newer image

## 5. Verify

- [ ] 5.1 ./build-osx.sh --check compiles clean
- [ ] 5.2 ./build-osx.sh --test passes
