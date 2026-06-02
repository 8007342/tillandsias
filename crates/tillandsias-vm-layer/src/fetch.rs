//! HTTP fetch + SHA-256 verification for first-run VM provisioning.
//!
//! Shared by the Windows (`WslRuntime`) and macOS (`VzRuntime`) trays so the
//! download / verify / resume discipline lives in exactly one place. Gated
//! behind the `download` feature so trait-only consumers and the Linux
//! cross-build check do not pull `reqwest` + `ring`.
//!
//! The committed `provisioning-manifest.json` (parsed into [`ProvisioningPins`])
//! is the source of truth for *which* rootfs + headless binary to fetch and
//! their expected checksums — NOT the host crate version. The host-shell
//! crate version is a build version, not a release tag, so it cannot address
//! a GitHub release asset on its own.
//!
//! @trace spec:vm-provisioning-lifecycle

use std::path::Path;

use serde::Deserialize;
use sha2::{Digest, Sha256};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

/// Already-rendered error context — mirrors [`crate::VmError`].
pub type FetchError = String;

/// One pinned remote artifact: URL + expected lowercase-hex SHA-256.
#[derive(Debug, Clone, Deserialize)]
pub struct RemoteArtifact {
    pub url: String,
    pub sha256: String,
    /// Optional advertised size, for sanity logging only.
    #[serde(default)]
    pub bytes: Option<u64>,
}

/// Parsed `provisioning-manifest.json`. Committed per release; the pins are
/// the authoritative inputs to first-run provisioning.
///
/// @trace spec:vm-provisioning-lifecycle.provision.first-run-downloads@v1
#[derive(Debug, Clone, Deserialize)]
pub struct ProvisioningPins {
    pub schema: u32,
    /// The GitHub release tag the headless binary was published under
    /// (e.g. `v0.2.260523.6`). Informational; the URL is the operative field.
    pub headless_release_tag: String,
    pub rootfs: RemoteArtifact,
    pub headless_binary: RemoteArtifact,
}

impl ProvisioningPins {
    pub fn from_json(s: &str) -> Result<Self, FetchError> {
        serde_json::from_str(s).map_err(|e| format!("parse provisioning manifest: {e}"))
    }
}

/// True iff `s` is exactly 64 ASCII hex digits.
pub fn is_sha256_hex(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit())
}

/// Decompresses an XZ file to a destination path using pure Rust.
/// @trace spec:vm-provisioning-lifecycle
#[cfg(feature = "download")]
pub async fn decompress_xz(src: &Path, dest: &Path) -> Result<(), FetchError> {
    use std::fs::File;
    use std::io::BufReader;
    let src_file = File::open(src).map_err(|e| format!("open xz source {}: {e}", src.display()))?;
    let mut decoder = xz2::read::XzDecoder::new(BufReader::new(src_file));
    let mut dest_file = File::create(dest).map_err(|e| format!("create xz dest {}: {e}", dest.display()))?;
    std::io::copy(&mut decoder, &mut dest_file).map_err(|e| format!("xz decompression error: {e}"))?;
    Ok(())
}

fn hex_lower(bytes: &[u8]) -> String {
    use std::fmt::Write as _;
    let mut s = String::with_capacity(bytes.len() * 2);
    for b in bytes {
        let _ = write!(s, "{b:02x}");
    }
    s
}

/// Stream a file through SHA-256. Returns `None` if the file is absent.
async fn file_sha256(path: &Path) -> Result<Option<String>, FetchError> {
    let mut f = match tokio::fs::File::open(path).await {
        Ok(f) => f,
        Err(ref e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("open {}: {e}", path.display())),
    };
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f
            .read(&mut buf)
            .await
            .map_err(|e| format!("read {}: {e}", path.display()))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(Some(hex_lower(&hasher.finalize())))
}

/// Download `artifact.url` to `dest`, verifying its SHA-256. Idempotent and
/// resumable:
///
/// - If `dest` already exists and hashes to the expected SHA, returns `Ok`
///   immediately (cache hit — no network).
/// - Otherwise downloads to `<dest>.part`, resuming any existing partial via
///   an HTTP `Range: bytes=<have>-` request, verifies the full-file hash, and
///   atomically renames `.part` → `dest`.
/// - A checksum mismatch deletes the partial and returns an error so a retry
///   starts clean (the import path never sees an unverified artifact).
///
/// `on_progress(downloaded, total)` is invoked as bytes arrive; `total`
/// includes any resumed prefix and is `None` when the server omits a length.
///
/// @trace spec:vm-provisioning-lifecycle.provision.first-run-downloads@v1
pub async fn download_verified(
    artifact: &RemoteArtifact,
    dest: &Path,
    on_progress: &(dyn Fn(u64, Option<u64>) + Send + Sync),
) -> Result<(), FetchError> {
    if !is_sha256_hex(&artifact.sha256) {
        return Err(format!(
            "artifact {} has no pinned SHA-256 (got {:?}); refusing to fetch unverified",
            artifact.url, artifact.sha256
        ));
    }
    let expected = artifact.sha256.to_ascii_lowercase();

    // Cache hit: a fully-downloaded, verified artifact already on disk.
    if let Some(existing) = file_sha256(dest).await?
        && existing == expected
    {
        let len = tokio::fs::metadata(dest)
            .await
            .map(|m| m.len())
            .unwrap_or(0);
        on_progress(len, Some(len));
        return Ok(());
    }

    if let Some(parent) = dest.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| format!("create {}: {e}", parent.display()))?;
    }

    let part = dest.with_extension("part");

    // Seed the hasher from any existing partial so the final whole-file hash
    // can be computed without re-reading the resumed prefix.
    let mut hasher = Sha256::new();
    let mut have: u64 = 0;
    if tokio::fs::try_exists(&part).await.unwrap_or(false) {
        let mut f = tokio::fs::File::open(&part)
            .await
            .map_err(|e| format!("open partial {}: {e}", part.display()))?;
        let mut buf = vec![0u8; 1 << 20];
        loop {
            let n = f
                .read(&mut buf)
                .await
                .map_err(|e| format!("read partial {}: {e}", part.display()))?;
            if n == 0 {
                break;
            }
            hasher.update(&buf[..n]);
            have += n as u64;
        }
    }

    let client = reqwest::Client::builder()
        .build()
        .map_err(|e| format!("build http client: {e}"))?;
    let mut req = client.get(&artifact.url);
    if have > 0 {
        req = req.header(reqwest::header::RANGE, format!("bytes={have}-"));
    }
    let resp = req
        .send()
        .await
        .map_err(|e| format!("GET {}: {e}", artifact.url))?;
    let status = resp.status();

    // If we asked for a range but the server ignored it (200 not 206), the
    // body is the whole file again — discard the partial and restart clean.
    if have > 0 && status != reqwest::StatusCode::PARTIAL_CONTENT {
        hasher = Sha256::new();
        have = 0;
        let _ = tokio::fs::remove_file(&part).await;
    }
    if !status.is_success() {
        return Err(format!("GET {} -> HTTP {}", artifact.url, status));
    }

    let total = resp.content_length().map(|c| c + have);

    let mut file = tokio::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .append(have > 0)
        .truncate(have == 0)
        .open(&part)
        .await
        .map_err(|e| format!("open {} for write: {e}", part.display()))?;

    let mut resp = resp;
    let mut downloaded = have;
    on_progress(downloaded, total);
    while let Some(chunk) = resp
        .chunk()
        .await
        .map_err(|e| format!("download chunk from {}: {e}", artifact.url))?
    {
        file.write_all(&chunk)
            .await
            .map_err(|e| format!("write {}: {e}", part.display()))?;
        hasher.update(&chunk);
        downloaded += chunk.len() as u64;
        on_progress(downloaded, total);
    }
    file.flush()
        .await
        .map_err(|e| format!("flush {}: {e}", part.display()))?;
    drop(file);

    let got = hex_lower(&hasher.finalize());
    if got != expected {
        let _ = tokio::fs::remove_file(&part).await;
        return Err(format!(
            "checksum mismatch for {}: expected {expected}, got {got} (deleted partial)",
            artifact.url
        ));
    }

    tokio::fs::rename(&part, dest)
        .await
        .map_err(|e| format!("rename {} -> {}: {e}", part.display(), dest.display()))?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn noop_progress() -> impl Fn(u64, Option<u64>) + Send + Sync {
        |_, _| {}
    }

    #[test]
    fn sha256_hex_validation() {
        assert!(is_sha256_hex(
            "5734e74f527c346e88c881a02c46ee96c7316c7d03cd00b6d8120b4c578aa159"
        ));
        assert!(!is_sha256_hex("TODO"));
        assert!(!is_sha256_hex("")); // empty
        assert!(!is_sha256_hex("xyz")); // too short / non-hex
        assert!(!is_sha256_hex(&"a".repeat(63))); // off-by-one
        assert!(!is_sha256_hex(&"g".repeat(64))); // non-hex char
    }

    /// A verified file already on disk is a cache hit: `download_verified`
    /// returns Ok without touching the (deliberately invalid) URL.
    #[tokio::test]
    async fn cache_hit_skips_network() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("artifact.bin");
        let content = b"hello tillandsias";
        tokio::fs::write(&dest, content).await.unwrap();
        let mut h = Sha256::new();
        h.update(content);
        let art = RemoteArtifact {
            url: "http://127.0.0.1:1/should-never-be-hit".into(),
            sha256: hex_lower(&h.finalize()),
            bytes: None,
        };
        let prog = noop_progress();
        download_verified(&art, &dest, &prog)
            .await
            .expect("cache hit must not error");
    }

    /// An unpinned SHA (placeholder, empty, malformed) is refused before any
    /// network call — the import path must never see an unverified artifact.
    #[tokio::test]
    async fn unpinned_sha_is_refused() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("x.bin");
        let art = RemoteArtifact {
            url: "http://127.0.0.1:1/x".into(),
            sha256: "TODO-PIN-ME".into(),
            bytes: None,
        };
        let prog = noop_progress();
        let err = download_verified(&art, &dest, &prog).await.unwrap_err();
        assert!(err.contains("no pinned SHA-256"), "unexpected error: {err}");
    }

    #[test]
    fn pins_parse_from_json() {
        let json = r#"{
            "schema": 1,
            "headless_release_tag": "v0.2.260523.6",
            "rootfs": { "url": "https://example/rootfs.oci.tar.xz", "sha256": "75200f5752a74a21a616ca9a75e25beb594e2e117a0195c54f87c0b3e3974d1b", "bytes": 70170200 },
            "headless_binary": { "url": "https://example/tillandsias-linux-x86_64", "sha256": "5734e74f527c346e88c881a02c46ee96c7316c7d03cd00b6d8120b4c578aa159" }
        }"#;
        let pins = ProvisioningPins::from_json(json).expect("parse");
        assert_eq!(pins.schema, 1);
        assert_eq!(pins.headless_release_tag, "v0.2.260523.6");
        assert!(is_sha256_hex(&pins.rootfs.sha256));
        assert!(is_sha256_hex(&pins.headless_binary.sha256));
        assert_eq!(pins.rootfs.bytes, Some(70170200));
    }

    /// Live network test — downloads the real pinned headless binary and
    /// verifies its checksum. Ignored by default (needs network + ~MBs).
    /// Run: `cargo test -p tillandsias-vm-layer --features download -- --ignored`
    #[tokio::test]
    #[ignore = "live network: downloads the real headless release binary"]
    async fn live_headless_binary_downloads_and_verifies() {
        let dir = tempfile::tempdir().unwrap();
        let dest = dir.path().join("tillandsias-linux-x86_64");
        let art = RemoteArtifact {
            url: "https://github.com/8007342/tillandsias/releases/download/v0.2.260523.6/tillandsias-linux-x86_64".into(),
            sha256: "5734e74f527c346e88c881a02c46ee96c7316c7d03cd00b6d8120b4c578aa159".into(),
            bytes: None,
        };
        let prog = noop_progress();
        download_verified(&art, &dest, &prog)
            .await
            .expect("download + verify real headless binary");
        assert!(dest.exists());
    }
}
