//! Generate the mixed-cluster qcow2 fixture at test time (order 1006-jfwv).
//!
//! WHY THIS EXISTS. Order 980-xcaf committed a 448 KB `mixed-clusters.qcow2`
//! under `tests/fixtures/`, and `litmus:no-tracked-binaries-shape` has been red
//! on every branch since — unseen for a day because `./build.sh --check` runs
//! no litmus (748-tkjx). A tracked binary poisons every clone and cannot be
//! reviewed; a fixture the vm-layer's raw-image tests genuinely need is a
//! legitimate requirement with an illegitimate home.
//!
//! WHAT I EXPECTED TO LOSE, AND DID NOT. The tracked fixture's expansion was
//! pinned by a SHA-256 captured once from `qemu-img convert`. I wrote this
//! module expecting to trade that independent cross-check for a self-generated
//! round-trip, and said so. The cross-check arm then FAILED on the first run —
//! qemu refused the fixture outright, "Image does not contain a reference count
//! table", because this reader ignores refcounts and I had omitted them. Adding
//! them made the image genuinely valid, and qemu's expansion now agrees with
//! `expected_raw()` byte for byte.
//!
//! So the independent opinion is not lost — it is STRONGER than before. It used
//! to be a constant captured on one host on one day; it is now re-derived on
//! every run on any host that has qemu-img. And the one-time proof against the
//! REAL Fedora Cloud 44 image (528 MB, byte-identical SHA-256) is recorded on
//! packet 980-xcaf and is untouched by this change.
//!
//! The generalisable bit: a generator validated only against the reader it
//! feeds proves the two agree, not that either is right. The arm I nearly wrote
//! off as a nice-to-have is the only reason this fixture is a real qcow2.
//!
//! WHAT IS PRESERVED. The mix is the point and it is reproduced exactly: four
//! compressed clusters, one normal cluster, the rest unallocated. A reader that
//! mishandled compressed clusters would still pass a normal-only fixture while
//! producing an image that is 89% garbage on the real one. The four compressed
//! clusters deliberately span the compressibility range — a constant fill, an
//! incompressible pseudo-random block, another constant, and a structured
//! 0..255 ramp — because a wrong span length still inflates to *something* and
//! only the bytes reveal it.

#![allow(dead_code)]

use std::io::Write as _;

pub const CLUSTER: u64 = 65536;
pub const CLUSTER_BITS: u32 = 16;
pub const VIRTUAL_SIZE: u64 = 524288; // 8 clusters
pub const L2_ENTRIES: usize = (CLUSTER / 8) as usize; // 8192

const L2E_COMPRESSED: u64 = 1 << 62;

// File layout, one cluster each: header, L1, L2, refcount table, refcount
// block, then the data area.
//
// THE REFCOUNT STRUCTURES ARE NOT OPTIONAL, and the cross-check arm is what
// proved it. Our reader ignores refcounts entirely — it only expands — so a
// fixture without them read back perfectly here while `qemu-img convert`
// refused the same file outright: "Image does not contain a reference count
// table". A generator validated only against the reader it feeds would have
// shipped an invalid qcow2 that every test called good.
const OFF_L1: u64 = CLUSTER;
const OFF_L2: u64 = 2 * CLUSTER;
const OFF_REFTABLE: u64 = 3 * CLUSTER;
const OFF_REFBLOCK: u64 = 4 * CLUSTER;
const OFF_DATA: u64 = 5 * CLUSTER;

/// The guest image this fixture encodes: `None` is an unallocated hole.
///
/// The indices and contents are load-bearing — `qcow2_expand.rs` asserts each
/// cluster by kind, so a change here must be a deliberate change there.
pub fn guest_clusters() -> Vec<Option<Vec<u8>>> {
    let n = CLUSTER as usize;
    vec![
        Some(vec![0xAA; n]),     // 0 compressed, highly compressible
        None,                    // 1 hole
        Some(incompressible(n)), // 2 compressed, ~incompressible
        Some(vec![0x5A; n]),     // 3 NORMAL (uncompressed) cluster
        Some(vec![0xBB; n]),     // 4 compressed
        Some(structured(n)),     // 5 compressed, structured 0..255
        None,                    // 6 hole
        None,                    // 7 hole
    ]
}

/// Deterministic pseudo-random bytes: a plain LCG, so the "incompressible"
/// cluster is byte-identical on every host and every run without pulling in an
/// RNG dependency for four kilobytes of entropy.
fn incompressible(n: usize) -> Vec<u8> {
    let mut v = Vec::with_capacity(n);
    let mut s: u32 = 0x1234_5678;
    for _ in 0..n {
        s = s.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
        v.push((s >> 24) as u8);
    }
    v
}

fn structured(n: usize) -> Vec<u8> {
    (0..n).map(|i| (i % 256) as u8).collect()
}

/// The raw image the expansion must produce, built from the same source of
/// truth as the qcow2 itself.
pub fn expected_raw() -> Vec<u8> {
    let mut out = vec![0u8; VIRTUAL_SIZE as usize];
    for (i, c) in guest_clusters().iter().enumerate() {
        if let Some(bytes) = c {
            let at = i * CLUSTER as usize;
            out[at..at + bytes.len()].copy_from_slice(bytes);
        }
    }
    out
}

fn deflate(raw: &[u8]) -> Vec<u8> {
    let mut e = flate2::write::DeflateEncoder::new(Vec::new(), flate2::Compression::default());
    e.write_all(raw).expect("deflate fixture cluster");
    e.finish().expect("finish deflate")
}

fn put32(buf: &mut [u8], at: usize, v: u32) {
    buf[at..at + 4].copy_from_slice(&v.to_be_bytes());
}
fn put64(buf: &mut [u8], at: usize, v: u64) {
    buf[at..at + 8].copy_from_slice(&v.to_be_bytes());
}

/// Write the fixture to `path`. Returns its byte length.
pub fn write_qcow2(path: &std::path::Path) -> u64 {
    let clusters = guest_clusters();

    // ── data area: compressed streams packed back to back, normal clusters
    //    cluster-aligned (the format requires it for standard clusters).
    let mut data: Vec<u8> = Vec::new();
    let mut l2 = vec![0u8; CLUSTER as usize];

    // Pass 1: compressed clusters, packed without alignment — which is the
    // interesting case, because a compressed stream may start mid-sector and
    // share a sector with its neighbour. Packing them tightly is what exercises
    // `compressed_span`'s sector arithmetic rather than sidestepping it.
    for (i, c) in clusters.iter().enumerate() {
        let Some(bytes) = c else { continue };
        if i == 3 {
            continue; // the normal cluster, placed in pass 2
        }
        let stream = deflate(bytes);
        let off = OFF_DATA + data.len() as u64;
        data.extend_from_slice(&stream);

        // Descriptor: bit 62 set, offset in bits 0..x, ADDITIONAL sectors in
        // bits x..62, where x = 62 - (cluster_bits - 8).
        let x = 62 - (CLUSTER_BITS - 8);
        let sector_base = off & !511u64;
        let end = off + stream.len() as u64;
        let sectors_spanned = end.div_ceil(512) * 512 - sector_base;
        let extra = sectors_spanned / 512 - 1;
        let desc = L2E_COMPRESSED | (extra << x) | off;
        put64(&mut l2, i * 8, desc);
    }

    // Pass 2: the normal cluster must start on a cluster boundary.
    let pad = (CLUSTER - ((OFF_DATA + data.len() as u64) % CLUSTER)) % CLUSTER;
    data.extend(std::iter::repeat_n(0u8, pad as usize));
    let normal_off = OFF_DATA + data.len() as u64;
    data.extend_from_slice(clusters[3].as_ref().expect("cluster 3 is the normal one"));
    put64(&mut l2, 3 * 8, normal_off); // no flags: a plain host offset

    // ── L1: one entry, pointing at the single L2 table. Bit 63 (COPIED) is
    //    refcount bookkeeping this reader ignores and qemu-img tolerates.
    let mut l1 = vec![0u8; CLUSTER as usize];
    put64(&mut l1, 0, OFF_L2);

    // ── header (v3).
    let mut h = vec![0u8; CLUSTER as usize];
    put32(&mut h, 0, 0x5146_49fb); // magic
    put32(&mut h, 4, 3); // version
    put64(&mut h, 8, 0); // backing_file_offset
    put32(&mut h, 16, 0); // backing_file_size
    put32(&mut h, 20, CLUSTER_BITS);
    put64(&mut h, 24, VIRTUAL_SIZE);
    put32(&mut h, 32, 0); // crypt_method
    put32(&mut h, 36, 1); // l1_size
    put64(&mut h, 40, OFF_L1);
    put64(&mut h, 48, OFF_REFTABLE);
    put32(&mut h, 56, 1); // refcount_table_clusters
    put32(&mut h, 60, 0); // nb_snapshots
    put64(&mut h, 64, 0); // snapshots_offset
    put64(&mut h, 72, 0); // incompatible_features — must be 0 or the reader refuses
    put64(&mut h, 80, 0); // compatible_features
    put64(&mut h, 88, 0); // autoclear_features
    put32(&mut h, 96, 4); // refcount_order — the reader requires exactly 4
    put32(&mut h, 100, 104); // header_length

    // Refcount structures. Every cluster the file actually occupies gets a
    // refcount of 1; qemu refuses the image outright without them.
    let total_clusters = (OFF_DATA + data.len() as u64).div_ceil(CLUSTER);
    let mut reftable = vec![0u8; CLUSTER as usize];
    put64(&mut reftable, 0, OFF_REFBLOCK);
    let mut refblock = vec![0u8; CLUSTER as usize];
    for c in 0..total_clusters as usize {
        // refcount_order 4 => 16-bit entries, big-endian.
        refblock[c * 2..c * 2 + 2].copy_from_slice(&1u16.to_be_bytes());
    }

    let mut f = std::fs::File::create(path).expect("create fixture");
    f.write_all(&h).expect("write header");
    f.write_all(&l1).expect("write L1");
    f.write_all(&l2).expect("write L2");
    f.write_all(&reftable).expect("write refcount table");
    f.write_all(&refblock).expect("write refcount block");
    f.write_all(&data).expect("write data");
    f.sync_all().expect("sync fixture");
    OFF_DATA + data.len() as u64
}

/// Write the fixture into a fresh temp dir and hand back both, so callers keep
/// the dir alive for the lifetime of the path.
pub fn staged() -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().expect("fixture tempdir");
    let p = dir.path().join("mixed-clusters.qcow2");
    write_qcow2(&p);
    (dir, p)
}
