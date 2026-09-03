//! The pure-Rust qcow2 reader, pinned against a committed fixture.
//!
//! WHY A FIXTURE AND NOT JUST THE REAL IMAGE (order 980-xcaf). The reader was
//! accepted by expanding the actual Fedora Cloud 44 aarch64 image and getting a
//! byte-identical SHA-256 against `qemu-img convert`. That is the strongest
//! evidence available, and it is also unrepeatable: it needs a 528 MB artifact
//! nobody else has and a `qemu-img` on the host — the very dependency this
//! order removes. So the one-time proof is recorded on the packet, and this
//! fixture is what the next person actually gets to run.
//!
//! The fixture is 448 KB and deliberately mixes all three branches, verified by
//! walking its L2 table: 4 compressed clusters, 1 normal cluster, 8187
//! unallocated. A reader that mishandled compressed clusters would still pass a
//! normal-only fixture while producing an image that is 89% garbage on the real
//! one — which is why the mix is the point.
//!
//! REMEMBER WHAT IS NOT COVERED BY A SHA PIN ELSEWHERE: the manifest pins the
//! qcow2 DOWNLOAD, never the expanded raw. Nothing but this test stands between
//! a one-bit error in a cluster offset and a guest disk that boots far enough
//! to look fine.

#![cfg(feature = "download")]

use sha2::{Digest, Sha256};
use std::io::Read;
use std::os::unix::fs::MetadataExt;

const FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/tests/fixtures/mixed-clusters.qcow2"
);

/// `qemu-img convert -f qcow2 -O raw` of the committed fixture, captured on
/// macOS 26.6 with qemu 11.1.1. If this changes, the reader changed.
const EXPECTED_SHA256: &str = "3a551799e962c822e0ed1e59002e26d1ce8d535d0a19682ac0e77b693834ea09";

const CLUSTER: u64 = 65536;
const VIRTUAL_SIZE: u64 = 524288;

fn expand(final_size: u64) -> (tempfile::TempDir, std::path::PathBuf) {
    let dir = tempfile::tempdir().expect("tempdir");
    let out = dir.path().join("expanded.raw");
    let vs = tillandsias_vm_layer::qcow2::expand_to_raw(
        std::path::Path::new(FIXTURE),
        &out,
        final_size,
        &|_, _| {},
    )
    .expect("expand fixture");
    assert_eq!(vs, VIRTUAL_SIZE, "fixture virtual size");
    (dir, out)
}

/// The whole-image assertion: byte-for-byte agreement with qemu-img.
#[test]
fn expansion_matches_qemu_img_byte_for_byte() {
    let (_d, out) = expand(0);
    let mut f = std::fs::File::open(&out).unwrap();
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = f.read(&mut buf).unwrap();
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    assert_eq!(
        format!("{:x}", h.finalize()),
        EXPECTED_SHA256,
        "expanded fixture must be byte-identical to `qemu-img convert` output"
    );
    assert_eq!(
        std::fs::metadata(&out).unwrap().len(),
        VIRTUAL_SIZE,
        "without a final_size the expansion stops at the image's virtual size"
    );
}

/// Content assertions per cluster kind, so a failure says WHICH branch broke
/// rather than only that a hash moved.
#[test]
fn each_cluster_kind_expands_to_the_right_bytes() {
    let (_d, out) = expand(0);
    let data = std::fs::read(&out).unwrap();
    let cl = |i: u64| &data[(i * CLUSTER) as usize..((i + 1) * CLUSTER) as usize];

    // compressed, highly compressible
    assert!(cl(0).iter().all(|&b| b == 0xAA), "cluster 0 (compressed)");
    // hole
    assert!(cl(1).iter().all(|&b| b == 0), "cluster 1 (unallocated)");
    // compressed, ~incompressible payload — the case where a wrong span length
    // still inflates to *something* and only the bytes reveal it
    assert!(
        cl(2).iter().any(|&b| b != 0) && !cl(2).iter().all(|&b| b == cl(2)[0]),
        "cluster 2 (compressed, incompressible)"
    );
    // written AFTER the compressed convert, so this one is a normal cluster
    assert!(cl(3).iter().all(|&b| b == 0x5A), "cluster 3 (normal)");
    assert!(cl(4).iter().all(|&b| b == 0xBB), "cluster 4 (compressed)");
    // structured 0..255 repeating
    assert_eq!(cl(5)[0], 0, "cluster 5 (compressed, structured)");
    assert_eq!(cl(5)[255], 255, "cluster 5 (compressed, structured)");
    assert!(cl(6).iter().all(|&b| b == 0), "cluster 6 (unallocated)");
    assert!(cl(7).iter().all(|&b| b == 0), "cluster 7 (unallocated)");
}

/// `final_size` grows the raw file the way `qemu-img resize` did, and growing
/// must not disturb the content that precedes it.
///
/// GROWN TO 4 GiB DELIBERATELY. An earlier version of this test grew to 2 MiB
/// and asserted sparseness, which failed on APFS — at that size the filesystem
/// simply allocates the whole file, so the assertion was measuring the
/// filesystem rather than the reader. The provisioning path grows to 250 GiB,
/// where sparseness is the difference between 11 GiB and 250 GiB on disk, so
/// the test grows far enough for the property to mean something. Nothing is
/// read whole here either: this must not pull 4 GiB into memory.
#[test]
fn final_size_grows_the_image_without_changing_its_content() {
    use std::io::{Read, Seek, SeekFrom};
    let grown = 4 * 1024 * 1024 * 1024u64;
    let (_d, out) = expand(grown);
    let meta = std::fs::metadata(&out).unwrap();
    assert_eq!(meta.len(), grown, "final_size must grow the file");

    let mut f = std::fs::File::open(&out).unwrap();
    let mut head = vec![0u8; CLUSTER as usize];
    f.read_exact(&mut head).unwrap();
    assert!(
        head.iter().all(|&b| b == 0xAA),
        "growing must not disturb existing content"
    );

    // Spot-check the grown region rather than reading it.
    for probe in [VIRTUAL_SIZE, VIRTUAL_SIZE + 1, grown / 2, grown - 4096] {
        f.seek(SeekFrom::Start(probe)).unwrap();
        let mut b = [0u8; 4096];
        f.read_exact(&mut b).unwrap();
        assert!(
            b.iter().all(|&x| x == 0),
            "grown region at {probe} must be zeros"
        );
    }

    assert!(
        meta.blocks() * 512 < grown / 2,
        "grown image must stay sparse (allocated {} of {grown})",
        meta.blocks() * 512
    );
}

/// A `final_size` SMALLER than the image must not truncate it — shrinking a
/// guest disk under a filesystem is data loss, and silently honouring it would
/// be worse than refusing.
#[test]
fn final_size_below_virtual_size_does_not_truncate() {
    let (_d, out) = expand(1024);
    assert_eq!(
        std::fs::metadata(&out).unwrap().len(),
        VIRTUAL_SIZE,
        "a smaller final_size must leave the image at its virtual size"
    );
}

/// The one-time acceptance run, kept as executable documentation.
///
/// ```bash
/// TILLANDSIAS_QCOW2_ACCEPTANCE="$HOME/Library/Application Support/Tillandsias/rootfs.qcow2" \
/// TILLANDSIAS_QCOW2_EXPECTED_SHA=<sha of `qemu-img convert -f qcow2 -O raw`> \
///   cargo test -p tillandsias-vm-layer --features download --test qcow2_expand -- --ignored
/// ```
///
/// Recorded result, 2026-09-03, macneo (Fedora Cloud 44 aarch64, 528,154,624
/// bytes): both `qemu-img convert` and this reader produced 5,368,709,120 bytes
/// hashing to
/// `432913a8fa8028d173b865c69874ac68ae6dc0d9f85d67a862eac923c644b12d`.
#[test]
#[ignore = "needs a full Fedora Cloud qcow2 and its qemu-img-derived SHA"]
fn full_image_matches_qemu_img() {
    let Ok(src) = std::env::var("TILLANDSIAS_QCOW2_ACCEPTANCE") else {
        panic!("set TILLANDSIAS_QCOW2_ACCEPTANCE to a qcow2 path");
    };
    let expected = std::env::var("TILLANDSIAS_QCOW2_EXPECTED_SHA")
        .expect("set TILLANDSIAS_QCOW2_EXPECTED_SHA");
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("full.raw");
    tillandsias_vm_layer::qcow2::expand_to_raw(
        std::path::Path::new(&src),
        &out,
        0,
        &|done, total| eprintln!("L1 {done}/{total}"),
    )
    .expect("expand");
    let mut f = std::fs::File::open(&out).unwrap();
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf).unwrap();
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    assert_eq!(format!("{:x}", h.finalize()), expected.trim());
}
