## CHANGED Requirements

### Requirement: HTTP for --update uses in-process Rust stack
The `--update` CLI path SHALL perform all HTTP requests inside the process using the `reqwest` crate. It SHALL NOT spawn `curl` or any other external HTTP tool.

#### Scenario: Fetch update manifest without curl
- **GIVEN** the binary is running as an AppImage (LD_LIBRARY_PATH set by AppImage runtime)
- **WHEN** `tillandsias --update` is invoked
- **THEN** `latest.json` is fetched without spawning any child process for HTTP
- **AND** no `nghttp2` or `libcurl` symbol lookup error occurs

#### Scenario: Download update archive without curl
- **GIVEN** an update is available and the binary is an AppImage
- **WHEN** the update archive is downloaded
- **THEN** the download is performed in-process using `reqwest`
- **AND** the downloaded bytes are written directly to the temp file path without involving a system HTTP client

#### Scenario: Redirects are followed
- **GIVEN** the GitHub releases URL issues an HTTP redirect to the CDN
- **WHEN** the manifest or archive is fetched
- **THEN** redirects are followed automatically (reqwest follows redirects by default)

#### Scenario: Timeout is enforced
- **WHEN** the remote host is unreachable or slow
- **THEN** the request times out within 30 seconds and an error message is printed to stderr

## UNCHANGED Requirements

### Requirement: tar extraction is unchanged
Archive extraction via `Command::new("tar")` is unchanged. `tar` does not link against `libcurl` and is not affected by the AppImage nghttp2 conflict.

### Requirement: Non-AppImage update behavior is unchanged
- **WHEN** `$APPIMAGE` is not set
- **THEN** the version check still runs and the download URL is printed, with no download attempted
