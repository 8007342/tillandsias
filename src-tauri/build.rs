// @trace spec:host-chromium-on-demand
// Build script: emits TILLANDSIAS_FULL_VERSION (from ../VERSION) and the
// pinned Chromium version + per-platform SHA-256 digests parsed from
// scripts/install.sh. Both surfaces share one source of truth — the
// install script — so the tray binary's `--install-chromium` subcommand
// downloads the same pinned version (with the same expected digests)
// that the curl installer would have fetched.

use std::path::Path;

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

    // @trace spec:host-chromium-on-demand
    // Embed the pinned Chromium version + per-platform SHA-256 digests
    // by parsing scripts/install.sh. The script is the single source of
    // truth (per the `refresh-chromium-pin.sh is the sole authoring path`
    // requirement). If install.sh cannot be read (e.g. the tray crate is
    // built outside the workspace), fall back to empty placeholders —
    // the runtime install path will then fail with a clear error before
    // attempting any download.
    let install_sh_path = Path::new("../scripts/install.sh");
    println!("cargo:rerun-if-changed=../scripts/install.sh");
    let install_sh = std::fs::read_to_string(install_sh_path).unwrap_or_default();

    let pin = parse_chromium_pin(&install_sh);
    println!("cargo:rustc-env=TILLANDSIAS_CHROMIUM_VERSION={}", pin.version);
    println!(
        "cargo:rustc-env=TILLANDSIAS_CHROMIUM_SHA256_LINUX64={}",
        pin.linux64
    );
    println!(
        "cargo:rustc-env=TILLANDSIAS_CHROMIUM_SHA256_MAC_ARM64={}",
        pin.mac_arm64
    );
    println!(
        "cargo:rustc-env=TILLANDSIAS_CHROMIUM_SHA256_MAC_X64={}",
        pin.mac_x64
    );
    println!(
        "cargo:rustc-env=TILLANDSIAS_CHROMIUM_SHA256_WIN64={}",
        pin.win64
    );

    tauri_build::build();
}

/// Pin block parsed out of install.sh.
struct ChromiumPin {
    version: String,
    linux64: String,
    mac_arm64: String,
    mac_x64: String,
    win64: String,
}

/// Parse `CHROMIUM_VERSION="..."` and the four `CHROMIUM_SHA256_*="..."`
/// shell variable assignments out of the install script. Tolerates
/// surrounding whitespace and either single or double quotes; leaves any
/// unset value as the empty string so the runtime can detect the gap.
fn parse_chromium_pin(install_sh: &str) -> ChromiumPin {
    fn extract(install_sh: &str, key: &str) -> String {
        for line in install_sh.lines() {
            let trimmed = line.trim_start();
            if let Some(rest) = trimmed.strip_prefix(key)
                && let Some(after_eq) = rest.strip_prefix('=')
            {
                let value = after_eq.trim();
                let unquoted = value
                    .strip_prefix('"')
                    .and_then(|v| v.strip_suffix('"'))
                    .or_else(|| value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
                    .unwrap_or(value);
                return unquoted.to_string();
            }
        }
        String::new()
    }

    ChromiumPin {
        version: extract(install_sh, "CHROMIUM_VERSION"),
        linux64: extract(install_sh, "CHROMIUM_SHA256_LINUX64"),
        mac_arm64: extract(install_sh, "CHROMIUM_SHA256_MAC_ARM64"),
        mac_x64: extract(install_sh, "CHROMIUM_SHA256_MAC_X64"),
        win64: extract(install_sh, "CHROMIUM_SHA256_WIN64"),
    }
}
