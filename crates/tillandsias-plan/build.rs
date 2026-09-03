// @trace order:984-i4k2, spec:meta-orchestration
//
// Bake the revision of the sources being compiled into the binary, so a
// RUNNING tillandsias-plan can say which code it is rather than only which
// subcommands it has.
//
// ORDER 984-i4k2. The expert-capability skew line compares SUBCOMMAND SETS:
// `now` (what the running binary supports) against `after_relaunch` (what the
// checkout's capabilities.txt declares). Both come from the same file read at
// two times, so a subcommand that exists in both versions is invisible to it
// however much its BEHAVIOUR changed. Measured on 2026-09-03: forges whose
// binaries predated 823e3ac0d kept writing `append-event` output straight into
// plan/index.yaml instead of a fragment, on four hosts, while the skew line
// truthfully reported `skew=none`. A capability set cannot see behaviour.
include!("src/source_revision.rs");

fn main() {
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets CARGO_MANIFEST_DIR");
    let src = std::path::Path::new(&crate_dir);
    // Re-run when any hashed input changes, or the baked revision goes stale
    // and the binary starts lying about which code it is — which would be this
    // order's own defect wearing its fix's clothes.
    println!("cargo:rerun-if-changed={crate_dir}/src");
    println!("cargo:rerun-if-changed={crate_dir}/capabilities.txt");
    println!(
        "cargo:rustc-env=TILLANDSIAS_PLAN_REVISION={}",
        source_revision(src)
    );
}
