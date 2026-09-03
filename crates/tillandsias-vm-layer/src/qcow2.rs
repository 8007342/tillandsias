//! Pure-Rust qcow2 -> raw expansion, so provisioning needs no `qemu-img`.
//!
//! WHY THIS EXISTS (order 980-xcaf). `convert_qcow2_to_raw` used to spawn
//! `qemu-img convert` and then `qemu-img resize`. Both were bare `PATH`
//! lookups, and a macOS `.app` started by LaunchServices gets
//! `PATH=/usr/bin:/bin:/usr/sbin:/sbin` — measured with `ps eww` on the live
//! tray of a factory-fresh Mac, not assumed. `qemu-img` is not on that path on
//! any Mac, so first launch died with "missing qemu" and STAYED dead after
//! `brew install qemu`, because Homebrew's prefix was never on the tray's
//! `PATH` to begin with. The CLI `--provision`, run from a shell, worked.
//!
//! Bundling `qemu-img` would trade a `PATH` problem for a GPL-vendoring and
//! notarization problem; resolving it through a login shell would keep a host
//! dependency the product says it does not have. So we read the format.
//!
//! SCOPE IS MEASURED, NOT GUESSED. Every feature refused below was checked
//! against the actual Fedora Cloud 44 aarch64 image this project provisions
//! (528,154,624 bytes) by walking all 81,920 of its L2 entries:
//!
//! ```text
//!   version 3, cluster_bits 16 (64 KiB), virtual size 5.00 GiB
//!   backing file NONE, crypt_method 0, nb_snapshots 0
//!   incompatible_features 0x0, refcount_order 4
//!   unallocated  70,706  86.31%
//!   normal        1,207   1.47%
//!   compressed   10,007  12.22%
//!   zero              0   0.00%
//! ```
//!
//! Compressed clusters carry 89% of the allocated data, so a reader that
//! handled only "normal" clusters would emit an image that is mostly garbage
//! and would still boot far enough to look like it worked. That is the failure
//! shape this module is written against, and it is why every unsupported
//! feature is a hard error rather than a skip.
//!
//! THE SHA PIN DOES NOT COVER THIS STEP. The manifest pins the qcow2 DOWNLOAD,
//! not the expanded raw image, so the conversion has always been unverified —
//! with `qemu-img` that was borrowed trust and here it is ours. Hence the
//! committed fixture in `tests/` and the fail-loud checks.

use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

const QCOW2_MAGIC: u32 = 0x5146_49fb;
/// L2 entry bit 62 — the cluster's bytes are deflate-compressed.
const L2E_COMPRESSED: u64 = 1 << 62;
/// L2 entry bit 0 on a standard cluster — reads as all zeros (qcow2 v3).
const L2E_ZERO: u64 = 1;
/// Standard-cluster host offset lives in bits 9..=55.
const L2E_OFFSET_MASK: u64 = 0x00ff_ffff_ffff_fe00;

/// What a qcow2 header tells us that we actually act on.
#[derive(Debug, Clone, Copy)]
pub struct Qcow2Info {
    pub version: u32,
    pub cluster_bits: u32,
    pub cluster_size: u64,
    pub virtual_size: u64,
    pub l1_size: u32,
    pub l1_table_offset: u64,
}

fn be32(b: &[u8], at: usize) -> u32 {
    u32::from_be_bytes([b[at], b[at + 1], b[at + 2], b[at + 3]])
}
fn be64(b: &[u8], at: usize) -> u64 {
    u64::from_be_bytes([
        b[at],
        b[at + 1],
        b[at + 2],
        b[at + 3],
        b[at + 4],
        b[at + 5],
        b[at + 6],
        b[at + 7],
    ])
}

/// Parse and VET a qcow2 header.
///
/// Every rejection here is a feature the measured Fedora image does not use.
/// Refusing loudly is the point: a future image that switches one on must stop
/// this code rather than silently produce a wrong disk.
pub fn read_header(f: &mut File) -> Result<Qcow2Info, String> {
    let mut h = [0u8; 104];
    f.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    f.read_exact(&mut h)
        .map_err(|e| format!("read qcow2 header: {e}"))?;

    let magic = be32(&h, 0);
    if magic != QCOW2_MAGIC {
        return Err(format!(
            "not a qcow2 image: magic {magic:#010x}, expected {QCOW2_MAGIC:#010x}"
        ));
    }
    let version = be32(&h, 4);
    if version != 2 && version != 3 {
        return Err(format!("unsupported qcow2 version {version} (need 2 or 3)"));
    }

    let backing_file_offset = be64(&h, 8);
    if backing_file_offset != 0 {
        return Err(
            "qcow2 has a backing file; this reader expands self-contained images only".into(),
        );
    }

    let cluster_bits = be32(&h, 20);
    if !(9..=21).contains(&cluster_bits) {
        return Err(format!(
            "qcow2 cluster_bits {cluster_bits} out of range 9..=21"
        ));
    }
    let cluster_size = 1u64 << cluster_bits;
    let virtual_size = be64(&h, 24);

    let crypt_method = be32(&h, 32);
    if crypt_method != 0 {
        return Err(format!(
            "qcow2 is encrypted (crypt_method {crypt_method}); refusing to guess at plaintext"
        ));
    }

    let l1_size = be32(&h, 36);
    let l1_table_offset = be64(&h, 40);
    let nb_snapshots = be32(&h, 60);
    if nb_snapshots != 0 {
        return Err(format!(
            "qcow2 carries {nb_snapshots} snapshot(s); expanding one would pick a state \
             arbitrarily"
        ));
    }

    if version >= 3 {
        let incompatible = be64(&h, 72);
        if incompatible != 0 {
            // bit0 dirty, bit1 corrupt, bit2 external data file, bit3 compression-type.
            return Err(format!(
                "qcow2 sets incompatible_features {incompatible:#x} — refusing rather than \
                 producing a disk this reader cannot claim to understand"
            ));
        }
        let refcount_order = be32(&h, 96);
        if refcount_order != 4 {
            return Err(format!(
                "qcow2 refcount_order {refcount_order} != 4; unexpected for a published cloud \
                 image, so stopping rather than assuming the rest of the header is ordinary"
            ));
        }
    }

    // The L1 table must actually cover the virtual size it claims.
    let l2_entries = cluster_size / 8;
    let covered = (l1_size as u64)
        .saturating_mul(l2_entries)
        .saturating_mul(cluster_size);
    if covered < virtual_size {
        return Err(format!(
            "qcow2 L1 table covers {covered} bytes but virtual size is {virtual_size}"
        ));
    }

    Ok(Qcow2Info {
        version,
        cluster_bits,
        cluster_size,
        virtual_size,
        l1_size,
        l1_table_offset,
    })
}

/// Byte span of a compressed cluster's deflate stream.
///
/// THE COMMON BUG THIS AVOIDS: the descriptor's size field counts *additional
/// 512-byte sectors beyond the sector containing the offset*, and the data may
/// start mid-sector and may share a sector with a neighbouring cluster. So the
/// span is NOT the deflate stream's length — it is an upper bound. We hand the
/// whole span to the decoder and let the stream terminate itself.
///
/// `x = 62 - (cluster_bits - 8)`; offset is bits `0..x`, sector count is bits
/// `x..62`.
fn compressed_span(desc: u64, cluster_bits: u32) -> (u64, usize) {
    let x = 62 - (cluster_bits - 8);
    let offset = desc & ((1u64 << x) - 1);
    let extra_sectors = (desc >> x) & ((1u64 << (62 - x)) - 1);
    let sector_base = offset & !511u64;
    let end = sector_base + (extra_sectors + 1) * 512;
    (offset, (end - offset) as usize)
}

/// Expand `src` (qcow2) into `dest` (raw), then grow `dest` to `final_size`
/// bytes. Returns the image's virtual size.
///
/// The output is SPARSE: unallocated and zero clusters are never written, so
/// the 250 GiB guest disk occupies only what the guest has actually touched.
/// Growing with `set_len` is what `qemu-img resize` did, minus the subprocess.
pub fn expand_to_raw(
    src: &Path,
    dest: &Path,
    final_size: u64,
    on_progress: &(dyn Fn(u64, u64) + Send + Sync),
) -> Result<u64, String> {
    let mut f = File::open(src).map_err(|e| format!("open {}: {e}", src.display()))?;
    let info = read_header(&mut f)?;

    let mut out = File::create(dest).map_err(|e| format!("create {}: {e}", dest.display()))?;
    out.set_len(info.virtual_size)
        .map_err(|e| format!("size {} to {}: {e}", dest.display(), info.virtual_size))?;

    let l2_entries = (info.cluster_size / 8) as usize;
    let mut l1 = vec![0u8; info.l1_size as usize * 8];
    f.seek(SeekFrom::Start(info.l1_table_offset))
        .map_err(|e| format!("seek L1: {e}"))?;
    f.read_exact(&mut l1).map_err(|e| format!("read L1: {e}"))?;

    let mut l2 = vec![0u8; l2_entries * 8];
    let mut cluster = vec![0u8; info.cluster_size as usize];
    let mut last_pct: i64 = -1;

    for l1_index in 0..info.l1_size as usize {
        let l2_offset = be64(&l1, l1_index * 8) & L2E_OFFSET_MASK;
        if l2_offset == 0 {
            continue; // whole L2 table absent: 2 GiB of hole at 64 KiB clusters
        }
        f.seek(SeekFrom::Start(l2_offset))
            .map_err(|e| format!("seek L2 @{l2_offset}: {e}"))?;
        f.read_exact(&mut l2)
            .map_err(|e| format!("read L2 @{l2_offset}: {e}"))?;

        for l2_index in 0..l2_entries {
            let desc = be64(&l2, l2_index * 8);
            if desc == 0 {
                continue; // unallocated -> hole
            }
            let guest_offset =
                (l1_index as u64 * l2_entries as u64 + l2_index as u64) * info.cluster_size;
            if guest_offset >= info.virtual_size {
                continue; // tail padding beyond the declared size
            }

            if desc & L2E_COMPRESSED != 0 {
                let (off, span) = compressed_span(desc, info.cluster_bits);
                let mut raw = vec![0u8; span];
                f.seek(SeekFrom::Start(off))
                    .map_err(|e| format!("seek compressed cluster @{off}: {e}"))?;
                // The final sector may run past EOF on the last cluster.
                let got = read_up_to(&mut f, &mut raw)?;
                raw.truncate(got);
                let mut dec = flate2::read::DeflateDecoder::new(&raw[..]);
                let n = fill(&mut dec, &mut cluster).map_err(|e| {
                    format!("inflate compressed cluster at guest offset {guest_offset}: {e}")
                })?;
                if n == 0 {
                    return Err(format!(
                        "compressed cluster at guest offset {guest_offset} inflated to nothing"
                    ));
                }
                cluster[n..].fill(0);
                write_at(&mut out, guest_offset, &cluster, info.virtual_size)?;
            } else if desc & L2E_ZERO != 0 {
                continue; // reads as zeros; the hole already does that
            } else {
                let host = desc & L2E_OFFSET_MASK;
                if host == 0 {
                    continue;
                }
                f.seek(SeekFrom::Start(host))
                    .map_err(|e| format!("seek cluster @{host}: {e}"))?;
                let got = read_up_to(&mut f, &mut cluster)?;
                if got < cluster.len() {
                    cluster[got..].fill(0);
                }
                write_at(&mut out, guest_offset, &cluster, info.virtual_size)?;
            }
        }

        let pct = ((l1_index as u64 + 1) * 100 / info.l1_size.max(1) as u64) as i64;
        if pct != last_pct {
            last_pct = pct;
            on_progress(l1_index as u64 + 1, info.l1_size as u64);
        }
    }

    out.flush()
        .map_err(|e| format!("flush {}: {e}", dest.display()))?;
    if final_size > info.virtual_size {
        out.set_len(final_size)
            .map_err(|e| format!("grow {} to {final_size}: {e}", dest.display()))?;
    }
    // Drop closes; an error on close would otherwise be discarded silently.
    drop(out);
    Ok(info.virtual_size)
}

/// Write a cluster at `guest_offset`, clipped to the declared virtual size so a
/// final partial cluster cannot extend the image past its own header.
fn write_at(
    out: &mut File,
    guest_offset: u64,
    buf: &[u8],
    virtual_size: u64,
) -> Result<(), String> {
    let room = virtual_size.saturating_sub(guest_offset) as usize;
    let n = room.min(buf.len());
    if n == 0 {
        return Ok(());
    }
    out.seek(SeekFrom::Start(guest_offset))
        .map_err(|e| format!("seek out @{guest_offset}: {e}"))?;
    out.write_all(&buf[..n])
        .map_err(|e| format!("write out @{guest_offset}: {e}"))
}

/// `read` until the buffer is full or EOF. Short reads are normal at EOF and on
/// pipes; treating one as the end of a cluster is a classic silent corruption.
fn read_up_to(f: &mut File, buf: &mut [u8]) -> Result<usize, String> {
    let mut n = 0;
    while n < buf.len() {
        match f.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(format!("read: {e}")),
        }
    }
    Ok(n)
}

/// Same, for the decompressor: a deflate stream legitimately returns short
/// reads, and stopping at the first one truncates the cluster.
fn fill<R: Read>(r: &mut R, buf: &mut [u8]) -> Result<usize, std::io::Error> {
    let mut n = 0;
    while n < buf.len() {
        match r.read(&mut buf[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(ref e) if e.kind() == std::io::ErrorKind::Interrupted => {}
            Err(e) => return Err(e),
        }
    }
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Build a compressed-cluster descriptor the way qemu writes one, for
    /// `cluster_bits = 16` (so `x = 54`). Spelled out as a helper rather than
    /// inline shifts so a zero sector count stays readable as "no additional
    /// sectors" instead of collapsing into an identity operation.
    fn descriptor(offset: u64, extra_sectors: u64) -> u64 {
        L2E_COMPRESSED | (extra_sectors << 54) | offset
    }

    /// The descriptor split is the one piece of arithmetic that silently
    /// produces garbage when wrong, so it is pinned by hand for the 64 KiB
    /// cluster size the Fedora image actually uses (x = 54).
    #[test]
    fn compressed_span_splits_offset_and_sector_count() {
        // offset 0x1234_5678 (mid-sector), 3 additional sectors.
        let desc = descriptor(0x1234_5678, 3);
        let (off, span) = compressed_span(desc, 16);
        assert_eq!(off, 0x1234_5678);
        // sector base is offset & !511; span runs to base + 4*512.
        let base = 0x1234_5678u64 & !511;
        assert_eq!(span as u64, base + 4 * 512 - 0x1234_5678);
    }

    /// A sector-aligned offset with zero extra sectors spans exactly one
    /// sector — the degenerate case an off-by-one would break first.
    #[test]
    fn compressed_span_handles_aligned_single_sector() {
        let desc = descriptor(4096, 0);
        let (off, span) = compressed_span(desc, 16);
        assert_eq!(off, 4096);
        assert_eq!(span, 512);
    }

    #[test]
    fn rejects_non_qcow2() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("junk.img");
        std::fs::write(&p, vec![0u8; 4096]).unwrap();
        let mut f = File::open(&p).unwrap();
        let err = read_header(&mut f).unwrap_err();
        assert!(err.contains("not a qcow2 image"), "{err}");
    }
}
