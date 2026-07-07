# Bug: MacOS DMG installed app icon is old "T" letter, local build has the new asset

## Observation
- The remotely built `.dmg` installed app has the old "T" letter icon.
- A local build of the tray app using `scripts/build-macos-tray.sh` successfully produces the `.app` with the correct, new icon asset.

## Hypothesis
- The new `icon.icns` asset might be uncommitted/gitignored.
- The CI pipeline might be caching the old `icon.icns` or pulling a different branch.
- The `build-macos-dmg.sh` script might be packaging an old `Tillandsias.app` from a dirty `dist/` directory, or stripping the icon.

## Work
- [ ] Verify `crates/tillandsias-macos-tray/assets/icon.icns` is checked into version control.
- [ ] Ensure `dist/` is properly cleaned on CI before packaging.
- [ ] Investigate if `create-dmg` (or `hdiutil`) is stripping the `.VolumeIcon.icns` or if the inner `.app` is losing its `AppIcon.icns`.
