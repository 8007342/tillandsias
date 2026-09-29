//! Stream a `.raw.xz` disk image into a SPARSE raw file (exploration branch
//! `exploration/raw-xz-rootfs`, operator request 2026-09-29).
//!
//! Fedora publishes its aarch64 Cloud image as a qcow2 (Generic, 528 MB) and as
//! an xz-compressed RAW disk (AmazonEC2, 514 MB). Decoding the raw.xz needs no
//! image-format parser at all: the decoded bytes ARE the disk. This module
//! decodes the stream into `dest` and keeps it sparse by SEEKING over all-zero
//! chunks instead of writing them. A 5 GiB image with ~1-2 GiB of real data
//! then allocates only the data. The file is then grown to `final_size` with
//! `set_len`, exactly as the qcow2 path resizes.
//!
//! Measured on tlatoanis-macbook-air (M5) 2026-09-29, Fedora-Cloud-Base-
//! AmazonEC2-44-1.7.aarch64.raw.xz (490 MiB -> 5120 MiB, 214 xz blocks):
//! `xz -dc -T1` 16.2 s, `xz -dc -T0` 2.5 s. This decoder is single-threaded
//! (liblzma through xz2).
//!
//! The caller verifies the download's SHA-256 before calling this; xz's own
//! CRC64 per block additionally catches corruption during decoding.

use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom, Write};
use std::path::Path;

/// Chunk size for decode, zero-detection and seeking.
const CHUNK: usize = 1024 * 1024;

/// A reader that counts the COMPRESSED bytes consumed, for progress.
struct Counting<R> {
    inner: R,
    read: std::sync::Arc<std::sync::atomic::AtomicU64>,
}

impl<R: Read> Read for Counting<R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        let n = self.inner.read(buf)?;
        self.read
            .fetch_add(n as u64, std::sync::atomic::Ordering::Relaxed);
        Ok(n)
    }
}

/// Decode `src` (xz) into a sparse raw file at `dest`, then grow it to
/// `final_size` (never shrink below the decoded size). `on_progress(done,
/// total)` reports COMPRESSED bytes consumed out of the compressed file size.
/// Returns the decoded (virtual) size in bytes.
pub fn expand_xz_to_raw(
    src: &Path,
    dest: &Path,
    final_size: u64,
    on_progress: &(dyn Fn(u64, u64) + Send + Sync),
) -> Result<u64, String> {
    let file = File::open(src).map_err(|e| format!("open {}: {e}", src.display()))?;
    let total = file
        .metadata()
        .map_err(|e| format!("stat {}: {e}", src.display()))?
        .len();
    let consumed = std::sync::Arc::new(std::sync::atomic::AtomicU64::new(0));
    let counting = Counting {
        inner: BufReader::with_capacity(CHUNK, file),
        read: consumed.clone(),
    };
    let mut dec = xz2::read::XzDecoder::new_multi_decoder(counting);

    let mut out = File::create(dest).map_err(|e| format!("create {}: {e}", dest.display()))?;
    let mut buf = vec![0u8; CHUNK];
    let mut pos: u64 = 0;
    let mut last_pct = u64::MAX;
    loop {
        // Fill the whole chunk (a decoder read may return less than asked).
        let mut filled = 0;
        while filled < CHUNK {
            let n = dec
                .read(&mut buf[filled..])
                .map_err(|e| format!("xz decode {} at {pos}: {e}", src.display()))?;
            if n == 0 {
                break;
            }
            filled += n;
        }
        if filled == 0 {
            break;
        }
        let chunk = &buf[..filled];
        if chunk.iter().all(|b| *b == 0) {
            out.seek(SeekFrom::Current(filled as i64))
                .map_err(|e| format!("seek {}: {e}", dest.display()))?;
        } else {
            out.write_all(chunk)
                .map_err(|e| format!("write {}: {e}", dest.display()))?;
        }
        pos += filled as u64;
        let done = consumed.load(std::sync::atomic::Ordering::Relaxed);
        if let Some(pct) = (done * 100).checked_div(total)
            && pct != last_pct
        {
            last_pct = pct;
            on_progress(done, total);
        }
    }
    // A trailing zero run was seeked over, not written: set_len materialises
    // the logical size (as a hole) whether or not the target is larger.
    out.set_len(pos.max(final_size))
        .map_err(|e| format!("size {} to {}: {e}", dest.display(), pos.max(final_size)))?;
    out.sync_all()
        .map_err(|e| format!("sync {}: {e}", dest.display()))?;
    Ok(pos)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn scratch(name: &str) -> std::path::PathBuf {
        let d =
            std::env::temp_dir().join(format!("tillandsias-rawxz-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).expect("scratch");
        d
    }

    /// The decoded file is byte-identical to the source, zero runs included,
    /// and grown to the requested size.
    #[test]
    fn decodes_byte_identical_and_grows_to_the_target_size() {
        let d = scratch("roundtrip");
        // 3.5 chunks: data, a full zero chunk, data, a trailing zero tail.
        let mut raw = vec![0u8; CHUNK * 3 + CHUNK / 2];
        raw[..4096].fill(0xA5);
        raw[CHUNK * 2..CHUNK * 2 + 17].copy_from_slice(b"tillandsias-rawxz");
        let src = d.join("img.raw.xz");
        let mut enc = xz2::write::XzEncoder::new(File::create(&src).expect("create"), 1);
        enc.write_all(&raw).expect("encode");
        enc.finish().expect("finish");

        let dest = d.join("img.raw");
        let target = (CHUNK * 8) as u64;
        let seen = std::sync::Mutex::new(Vec::new());
        let n = expand_xz_to_raw(&src, &dest, target, &|done, total| {
            seen.lock().unwrap().push((done, total));
        })
        .expect("expand");
        assert_eq!(n, raw.len() as u64, "reports the decoded size");
        let got = std::fs::read(&dest).expect("read back");
        assert_eq!(got.len() as u64, target, "grown to the target size");
        assert_eq!(&got[..raw.len()], &raw[..], "decoded bytes identical");
        assert!(
            got[raw.len()..].iter().all(|b| *b == 0),
            "growth reads as zeros"
        );
        assert!(!seen.lock().unwrap().is_empty(), "progress was reported");
        let _ = std::fs::remove_dir_all(&d);
    }

    /// A target smaller than the image never truncates decoded data.
    #[test]
    fn never_shrinks_below_the_decoded_size() {
        let d = scratch("noshrink");
        let raw = vec![7u8; CHUNK + 3];
        let src = d.join("img.raw.xz");
        let mut enc = xz2::write::XzEncoder::new(File::create(&src).expect("create"), 1);
        enc.write_all(&raw).expect("encode");
        enc.finish().expect("finish");
        let dest = d.join("img.raw");
        expand_xz_to_raw(&src, &dest, 16, &|_, _| {}).expect("expand");
        assert_eq!(std::fs::read(&dest).expect("read").len(), raw.len());
        let _ = std::fs::remove_dir_all(&d);
    }

    /// Corrupt input is an error naming the file, never a silent short disk.
    #[test]
    fn corrupt_input_is_refused() {
        let d = scratch("corrupt");
        let raw = vec![1u8; CHUNK * 2];
        let src = d.join("img.raw.xz");
        let mut enc = xz2::write::XzEncoder::new(File::create(&src).expect("create"), 1);
        enc.write_all(&raw).expect("encode");
        enc.finish().expect("finish");
        let mut bytes = std::fs::read(&src).expect("read");
        let mid = bytes.len() / 2;
        bytes[mid] ^= 0xFF;
        std::fs::write(&src, &bytes).expect("corrupt");
        let err = expand_xz_to_raw(&src, &d.join("img.raw"), 0, &|_, _| {})
            .expect_err("corrupt xz must fail");
        assert!(err.contains("xz decode"), "{err}");
        let _ = std::fs::remove_dir_all(&d);
    }
}
