## FIXED Requirements

### Requirement: latest.json references the correct Linux artifact
The release workflow SHALL generate a `latest.json` where the `linux-x86_64` platform URL points to the raw `.AppImage` file and whose signature is read from the `.AppImage.sig` file.

#### Scenario: Linux URL uses raw AppImage
- **WHEN** the release workflow executes the "Generate latest.json" step
- **THEN** the `linux-x86_64.url` value ends with `Tillandsias-linux-x86_64.AppImage` (no `.tar.gz` suffix)

#### Scenario: Linux signature read from correct file
- **WHEN** the release workflow executes the "Generate latest.json" step
- **THEN** `LINUX_SIG` is read from `Tillandsias-linux-x86_64.AppImage.sig` (not `.AppImage.tar.gz.sig`)

#### Scenario: macOS artifact format is unchanged
- **WHEN** the release workflow executes the "Generate latest.json" step
- **THEN** the `darwin-aarch64.url` value still ends with `.app.tar.gz` (macOS produces a tarball; this is correct and must not be changed)

### Requirement: Update CLI applies raw AppImage without tar extraction
The `--update` CLI SHALL detect whether the downloaded artifact is a raw `.AppImage` or a `.tar.gz` archive and apply the correct replacement strategy for each.

#### Scenario: Raw AppImage download is applied directly
- **WHEN** the platform URL in `latest.json` ends with `.AppImage`
- **THEN** the downloaded file is treated as the replacement binary directly, the `tar` extraction step is skipped, the file is made executable, and it atomically replaces the running AppImage

#### Scenario: tar.gz download is still extracted (forward-compat)
- **WHEN** the platform URL in `latest.json` ends with `.tar.gz`
- **THEN** the existing tar extraction path runs, finds the `.AppImage` inside the archive, and replaces the running binary as before

#### Scenario: Temporary file naming matches download type
- **WHEN** the download URL ends with `.AppImage`
- **THEN** the temporary file written to disk is named `tillandsias-update.AppImage` (not `tillandsias-update.tar.gz`) to avoid misleading file metadata
