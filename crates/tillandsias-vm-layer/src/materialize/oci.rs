//! OCI image flattener — `vm-recipe-provisioning` §Phase 2b.
//!
//! Converts an OCI image archive (as published by Fedora or produced by
//! `podman save --format oci-archive`) into a flat rootfs tarball suitable
//! for `wsl --import` or VFR disk imaging.
//!
//! Pure Rust — no buildah, no skopeo, no helper VM. Enables non-Linux hosts
//! to pivot to official Fedora-owned OCI archives without hosting giant
//! flattened blobs.
//!
//! @trace spec:vm-provisioning-lifecycle

use std::fs::File;
use std::io::{self, BufReader, Read};
use std::path::Path;

use serde::Deserialize;
use tar::Archive;
use tempfile::TempDir;
use thiserror::Error;

/// Error taxonomy for OCI flattening.
#[derive(Debug, Error)]
pub enum OciError {
    #[error("IO error: {0}")]
    Io(#[from] io::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("OCI index.json not found")]
    MissingIndex,
    #[error("OCI manifest not found: {0}")]
    MissingManifest(String),
    #[error("OCI layer not found: {0}")]
    MissingLayer(String),
    #[error("Unsupported OCI archive format (missing index.json)")]
    UnsupportedFormat,
}

#[derive(Debug, Deserialize)]
struct OciIndex {
    manifests: Vec<OciDescriptor>,
}

#[derive(Debug, Deserialize)]
struct OciDescriptor {
    digest: String,
}

#[derive(Debug, Deserialize)]
struct OciManifest {
    layers: Vec<OciDescriptor>,
}

/// Flattens an OCI image archive into a rootfs tarball.
///
/// `oci_archive` can be a `.tar` or `.tar.xz`. If it's `.tar.xz`, it must be
/// decompressed before calling this function, or the reader must handle it.
pub fn flatten_to_tar<R: Read>(oci_reader: R, output_tar: &Path) -> Result<(), OciError> {
    let mut archive = Archive::new(oci_reader);
    let scratch = TempDir::new()?;
    let rootfs_dir = scratch.path().join("rootfs");
    std::fs::create_dir_all(&rootfs_dir)?;

    // 1. Extract the OCI archive into the scratch space to access metadata and blobs.
    // In a more memory-efficient version we would stream, but OCI archives are
    // non-linear (index.json is often at the end).
    archive.unpack(&scratch)?;

    // 2. Read index.json to find the manifest.
    let index_path = scratch.path().join("index.json");
    if !index_path.exists() {
        return Err(OciError::MissingIndex);
    }
    let index: OciIndex = serde_json::from_reader(BufReader::new(File::open(index_path)?))?;

    let manifest_digest = index
        .manifests
        .first()
        .ok_or_else(|| OciError::MissingManifest("empty index".into()))?
        .digest
        .strip_prefix("sha256:")
        .unwrap_or(&index.manifests[0].digest);

    // 3. Read the manifest to find the layers.
    let manifest_path = scratch.path().join("blobs/sha256").join(manifest_digest);
    if !manifest_path.exists() {
        return Err(OciError::MissingManifest(manifest_digest.to_string()));
    }
    let manifest: OciManifest =
        serde_json::from_reader(BufReader::new(File::open(manifest_path)?))?;

    // Fedora Container Base is a single gzip-compressed layer. Preserve that
    // layer's tar metadata verbatim instead of unpacking it onto the host
    // filesystem, where Windows would lose Unix modes, ownership, and symlinks.
    if manifest.layers.len() == 1 {
        let layer_digest = manifest.layers[0]
            .digest
            .strip_prefix("sha256:")
            .unwrap_or(&manifest.layers[0].digest);
        let layer_path = scratch.path().join("blobs/sha256").join(layer_digest);
        if !layer_path.exists() {
            return Err(OciError::MissingLayer(layer_digest.to_string()));
        }
        let mut layer = flate2::read::GzDecoder::new(File::open(layer_path)?);
        let mut output = File::create(output_tar)?;
        io::copy(&mut layer, &mut output)?;
        return Ok(());
    }

    // 4. Extract each layer into the rootfs directory in order.
    // Layers are ordered from base to top.
    for layer in manifest.layers {
        let layer_digest = layer
            .digest
            .strip_prefix("sha256:")
            .unwrap_or(&layer.digest);
        let layer_path = scratch.path().join("blobs/sha256").join(layer_digest);
        if !layer_path.exists() {
            return Err(OciError::MissingLayer(layer_digest.to_string()));
        }

        // Layers in OCI archives are often gzipped tars.
        let f = File::open(layer_path)?;
        let mut layer_archive = Archive::new(flate2::read::GzDecoder::new(f));

        // Unpack the layer, handling whiteouts.
        for entry in layer_archive.entries()? {
            let mut entry = entry?;
            let path = entry.path()?.to_path_buf();

            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                if name.starts_with(".wh.") {
                    // Whiteout file: remove the target file/dir.
                    let target_name = &name[4..];
                    let mut target_path = rootfs_dir.clone();
                    if let Some(parent) = path.parent() {
                        target_path.push(parent);
                    }
                    target_path.push(target_name);
                    if target_path.exists() {
                        if target_path.is_dir() {
                            std::fs::remove_dir_all(target_path)?;
                        } else {
                            std::fs::remove_file(target_path)?;
                        }
                    }
                    continue;
                }
            }

            entry.unpack_in(&rootfs_dir)?;
        }
    }

    // 5. Create the final flattened tarball.
    let out_file = File::create(output_tar)?;
    let mut builder = tar::Builder::new(out_file);
    builder.append_dir_all(".", &rootfs_dir)?;
    builder.finish()?;

    Ok(())
}

/// Decompresses an XZ-encoded OCI archive and flattens it.
/// Helper for macOS/Windows first-run paths.
pub fn flatten_oci_xz(xz_path: &Path, output_tar: &Path) -> Result<(), OciError> {
    let f = File::open(xz_path)?;
    let xz_decoder = xz2::read::XzDecoder::new(BufReader::new(f));
    flatten_to_tar(xz_decoder, output_tar)
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::Compression;
    use flate2::write::GzEncoder;

    fn create_mock_layer(files: &[(&str, &[u8])]) -> Vec<u8> {
        let mut buf = Vec::new();
        {
            let mut gz = GzEncoder::new(&mut buf, Compression::default());
            let mut tar = tar::Builder::new(&mut gz);
            for (name, content) in files {
                let mut header = tar::Header::new_gnu();
                header.set_size(content.len() as u64);
                header.set_path(name).unwrap();
                header.set_cksum();
                tar.append(&header, *content).unwrap();
            }
            tar.finish().unwrap();
        }
        buf
    }

    #[test]
    fn test_flatten_mock_oci() {
        let tmp = tempfile::tempdir().unwrap();
        let oci_path = tmp.path().join("mock.oci.tar");
        let output_path = tmp.path().join("rootfs.tar");

        // Create mock layers
        let layer1 = create_mock_layer(&[("etc/fedora-release", b"Fedora 44")]);
        let layer2 = create_mock_layer(&[
            ("usr/local/bin/tillandsias", b"binary"),
            ("etc/fedora-release", b"Fedora 44 modified"),
        ]);

        let layer1_digest = "sha256:layer1";
        let layer2_digest = "sha256:layer2";
        let manifest_digest = "sha256:manifest";

        // Create OCI structure
        {
            let f = File::create(&oci_path).unwrap();
            let mut tar = tar::Builder::new(f);

            // index.json
            let index = serde_json::json!({
                "manifests": [{"digest": manifest_digest}]
            });
            let index_bytes = serde_json::to_vec(&index).unwrap();
            let mut header = tar::Header::new_gnu();
            header.set_size(index_bytes.len() as u64);
            header.set_path("index.json").unwrap();
            header.set_cksum();
            tar.append(&header, &index_bytes[..]).unwrap();

            // manifest
            let manifest = serde_json::json!({
                "layers": [
                    {"digest": layer1_digest},
                    {"digest": layer2_digest}
                ]
            });
            let manifest_bytes = serde_json::to_vec(&manifest).unwrap();
            let mut header = tar::Header::new_gnu();
            header.set_size(manifest_bytes.len() as u64);
            header.set_path("blobs/sha256/manifest").unwrap();
            header.set_cksum();
            tar.append(&header, &manifest_bytes[..]).unwrap();

            // layer 1
            let mut header = tar::Header::new_gnu();
            header.set_size(layer1.len() as u64);
            header.set_path("blobs/sha256/layer1").unwrap();
            header.set_cksum();
            tar.append(&header, &layer1[..]).unwrap();

            // layer 2
            let mut header = tar::Header::new_gnu();
            header.set_size(layer2.len() as u64);
            header.set_path("blobs/sha256/layer2").unwrap();
            header.set_cksum();
            tar.append(&header, &layer2[..]).unwrap();

            tar.finish().unwrap();
        }

        // Run flattener
        flatten_to_tar(File::open(&oci_path).unwrap(), &output_path).expect("flatten");

        // Verify output
        let mut out_tar = Archive::new(File::open(&output_path).unwrap());
        let entries: Vec<_> = out_tar
            .entries()
            .unwrap()
            .map(|e| e.unwrap().path().unwrap().to_path_buf())
            .collect();

        assert!(entries.iter().any(|p| p == Path::new("etc/fedora-release")));
        assert!(
            entries
                .iter()
                .any(|p| p == Path::new("usr/local/bin/tillandsias"))
        );

        // Verify content (layer 2 should overwrite layer 1)
        let mut out_tar = Archive::new(File::open(&output_path).unwrap());
        for entry in out_tar.entries().unwrap() {
            let mut entry = entry.unwrap();
            if entry.path().unwrap() == Path::new("etc/fedora-release") {
                let mut s = String::new();
                entry.read_to_string(&mut s).unwrap();
                assert_eq!(s, "Fedora 44 modified");
            }
        }
    }
}
