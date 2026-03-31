fn main() {
    // Embed the full 4-part version from the VERSION file at compile time.
    // CARGO_PKG_VERSION is 3-part (Cargo semver constraint), but we need
    // the full version (e.g., "0.1.97.83") for forge image tags so that
    // every build increment triggers a forge image rebuild.
    let version = std::fs::read_to_string("../VERSION")
        .unwrap_or_else(|_| std::env::var("CARGO_PKG_VERSION").unwrap_or_default());
    println!(
        "cargo:rustc-env=TILLANDSIAS_FULL_VERSION={}",
        version.trim()
    );
    println!("cargo:rerun-if-changed=../VERSION");

    tauri_build::build();
}
