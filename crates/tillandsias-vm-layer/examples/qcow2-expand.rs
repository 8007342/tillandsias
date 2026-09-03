//! Expand a qcow2 image to a raw disk with the pure-Rust reader — the same
//! code path first-run provisioning uses, driven from the command line so it
//! can be diffed against `qemu-img convert` (order 980-xcaf).
//!
//! ```bash
//! cargo run -p tillandsias-vm-layer --features download \
//!   --example qcow2-expand -- <src.qcow2> <dest.raw> [final_size_bytes]
//! ```
//!
//! Omit `final_size_bytes` to stop at the image's own virtual size, which is
//! what you want when comparing against `qemu-img convert` — the provisioning
//! path grows the file afterwards, and a grown file will not diff against an
//! ungrown one for reasons that have nothing to do with correctness.

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!(
            "usage: qcow2-expand <src.qcow2> <dest.raw> [final_size_bytes]\n\
             (omit final_size_bytes to stop at the image's virtual size)"
        );
        std::process::exit(2);
    }
    let src = std::path::PathBuf::from(&args[1]);
    let dest = std::path::PathBuf::from(&args[2]);
    let final_size: u64 = args.get(3).and_then(|s| s.parse().ok()).unwrap_or(0);

    let started = std::time::Instant::now();
    let progress = |done: u64, total: u64| {
        if total > 0 && (done == total || done.is_multiple_of(16)) {
            eprint!("\r[qcow2-expand] L1 {done}/{total}");
        }
    };
    match tillandsias_vm_layer::qcow2::expand_to_raw(&src, &dest, final_size, &progress) {
        Ok(virtual_size) => {
            eprintln!();
            println!("virtual_size={virtual_size}");
            println!("elapsed_ms={}", started.elapsed().as_millis());
        }
        Err(e) => {
            eprintln!("\n[qcow2-expand] FAILED: {e}");
            std::process::exit(1);
        }
    }
}
