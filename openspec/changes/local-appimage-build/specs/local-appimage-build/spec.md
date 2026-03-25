## NEW Requirements

### Requirement: --appimage flag in build.sh

`./build.sh --appimage` SHALL produce a functional AppImage at `target/release/bundle/appimage/Tillandsias-linux-x86_64.AppImage`.

#### Scenario: First-time AppImage build
- **GIVEN** no cached `appimagetool`
- **WHEN** `./build.sh --appimage` is run
- **THEN** `appimagetool` is downloaded to `~/.cache/tillandsias/appimagetool`
- **AND** a release build is performed
- **AND** an AppDir is assembled from the deb bundle output
- **AND** `appimagetool` packs it into an AppImage
- **AND** the AppImage is placed at `target/release/bundle/appimage/Tillandsias-linux-x86_64.AppImage`

#### Scenario: Subsequent AppImage build
- **GIVEN** `appimagetool` is already cached
- **WHEN** `./build.sh --appimage` is run
- **THEN** the cached `appimagetool` is reused (no download)

#### Scenario: AppImage is functional
- **GIVEN** a locally built AppImage
- **WHEN** `chmod +x` and executed
- **THEN** the Tillandsias tray app launches normally

#### Scenario: No FUSE required
- **GIVEN** a Fedora Silverblue toolbox without FUSE
- **WHEN** `./build.sh --appimage` is run
- **THEN** the build completes successfully (static appimagetool, no FUSE dependency)
