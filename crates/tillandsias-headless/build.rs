// @trace spec:user-runtime-lifecycle, spec:linux-native-portable-executable, spec:init-command
// ORDER 1916-embd: the embedded runtime assets (images/, skills/, research/,
// observatorium, scripts) moved to crates/tillandsias-embed/build.rs, so a
// cheatsheet edit no longer reruns this build script.
use std::fs;
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap());

    // ── Order 852-dk9z: a probe-code fingerprint the capability cache keys on ──
    //
    // load_or_probe used to invalidate only on parse failure, schema_version, or
    // legacy_tier. None of those move when enumeration LOGIC changes, so a
    // rebuilt binary served its predecessor's document verbatim and the row
    // generator wrapped it into a "fresh" probe. Measured twice: yoga after
    // 850-bif2's AMD enumeration landed, and pirria after 856-fwyh's Intel
    // disposition landed — both published the pre-fix document.
    //
    // Hashing the SOURCE means no human has to remember to bump anything: any
    // edit to the probe changes the identity, which is exactly the property a
    // hand-maintained revision constant fails to provide.
    let probe_src = manifest_dir.join("src").join("accel_probe.rs");
    println!("cargo:rerun-if-changed={}", probe_src.display());
    let probe_bytes =
        fs::read(&probe_src).unwrap_or_else(|e| panic!("read {}: {e}", probe_src.display()));
    let mut probe_hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in &probe_bytes {
        probe_hash ^= *b as u64;
        probe_hash = probe_hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    println!("cargo:rustc-env=TILLANDSIAS_PROBE_REVISION={probe_hash:016x}");
}
