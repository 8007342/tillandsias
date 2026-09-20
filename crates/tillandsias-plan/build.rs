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

// ORDER 1287-h6qn. The SAME file the crate compiles, so the hash embedded here
// and the hash computed at runtime cannot drift.
include!("src/validator_surface.rs");

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

    // ORDER 1287-h6qn — embed the validator surface's CONTENT hash, so the
    // binary can answer "was I built from these bytes" without a stamp file, an
    // mtime, or an operator who knows to run a checker first.
    //
    // RERUN ON EVERY SURFACE INPUT. If a real edit did not force a rebuild, the
    // embedded hash would be stale while claiming currency — this row's own
    // defect wearing its fix's clothes, and lying in the direction that looks
    // healthy. The `src` rerun above already covers the .rs files; these cover
    // the manifest itself, Cargo.toml and Cargo.lock, none of which live there.
    let root = src
        .parent()
        .and_then(|p| p.parent())
        .map(std::path::Path::to_path_buf)
        .unwrap_or_else(|| src.to_path_buf());
    println!(
        "cargo:rerun-if-changed={}/crates/tillandsias-plan/validator-surface.manifest",
        root.display()
    );
    println!("cargo:rerun-if-changed={}/Cargo.lock", root.display());
    let (files, _deps) = validator_surface_inputs(&root);
    for rel in &files {
        println!("cargo:rerun-if-changed={}/{rel}", root.display());
    }
    match validator_surface_hash(&root) {
        Some(h) => println!("cargo:rustc-env=TILLANDSIAS_PLAN_VALIDATOR_SURFACE={h}"),
        // Never fail the build over it, and never fake it: an empty value is
        // read by the runtime as "this binary cannot vouch", which refuses.
        None => println!("cargo:rustc-env=TILLANDSIAS_PLAN_VALIDATOR_SURFACE="),
    }
}
