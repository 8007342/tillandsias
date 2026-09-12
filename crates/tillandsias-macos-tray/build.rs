//! Embed build provenance (git SHA, dirty flag, build time) so the running
//! binary can self-report whether it was built from current HEAD. Without this
//! the only version surfaces are the frozen crate version and the un-bumped
//! VERSION file, so a stale build is indistinguishable from a fresh one — which
//! is exactly how an old artifact can be tested by mistake.
//!
//! Surfaced via `--version` and `--diagnose --json` (build_sha/build_time).

use std::process::Command;

fn git(args: &[&str]) -> Option<String> {
    let out = Command::new("git").args(args).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let s = String::from_utf8_lossy(&out.stdout).trim().to_string();
    if s.is_empty() { None } else { Some(s) }
}

fn main() {
    // 765-evbt: When TILLANDSIAS_GIT_SHA_OVERRIDE is set, the binary is being
    // built in a non-artifact lane (--check, pre-build CI) where provenance
    // doesn't matter but build fingerprint stability does. Use the override
    // SHA, a constant build time, and suppress .git rerun directives to
    // prevent every commit from busting the fingerprint and forcing a
    // recompile of every downstream crate.
    println!("cargo:rerun-if-env-changed=TILLANDSIAS_GIT_SHA_OVERRIDE");
    let override_mode = std::env::var("TILLANDSIAS_GIT_SHA_OVERRIDE").ok();

    let sha_full = if let Some(ref override_sha) = override_mode {
        override_sha.clone()
    } else {
        let sha = git(&["rev-parse", "--short", "HEAD"]).unwrap_or_else(|| "unknown".into());
        // Dirty if there are staged/unstaged tracked changes (untracked ignored).
        let dirty = Command::new("git")
            .args(["status", "--porcelain", "--untracked-files=no"])
            .output()
            .ok()
            .map(|o| !o.stdout.is_empty())
            .unwrap_or(false);
        if dirty { format!("{sha}-dirty") } else { sha }
    };

    // Build time: SOURCE_DATE_EPOCH for reproducible builds, constant
    // "non-artifact" sentinel in override mode (avoids `date -u` which
    // changes every second and busts fingerprints), else `date -u`.
    let build_time = if override_mode.is_some() {
        "non-artifact".to_string()
    } else {
        std::env::var("SOURCE_DATE_EPOCH")
            .ok()
            .and_then(|epoch| {
                Command::new("date")
                    .args(["-u", "-r", &epoch, "+%Y-%m-%dT%H:%M:%SZ"])
                    .output()
                    .ok()
            })
            .or_else(|| {
                Command::new("date")
                    .args(["-u", "+%Y-%m-%dT%H:%M:%SZ"])
                    .output()
                    .ok()
            })
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .unwrap_or_else(|| "unknown".into())
    };

    // 635-bhkb: the repo-root VERSION file is the single source of truth for
    // the release version. Crate versions are never bumped per release, so
    // `CARGO_PKG_VERSION` here is the literal "0.1.0" forever — which made
    // `--version` untruthful, put "0.1.0" in the diagnose JSON that support
    // tooling reads, and (the part that was not cosmetic) made the control
    // wire's build-version skew check compare a real guest version against
    // "0.1.0", so the warning fired on EVERY connection to a healthy guest.
    // A warning that is always true is one an operator learns to scroll past.
    //
    // Mirrors tillandsias-windows-tray/build.rs rather than inventing a second
    // mechanism: same env name, same fallback, same rerun-if-changed. Set
    // UNCONDITIONALLY (not behind a macOS-target gate) so cross-checks from
    // Linux and Windows have the var available — the crate compiles to a
    // cfg-gated stub off Darwin and its tests still need to resolve it.
    let manifest_dir_path =
        std::path::PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").unwrap_or_default());
    let version_file = manifest_dir_path.join("../../VERSION");
    let workspace_version = std::fs::read_to_string(&version_file)
        .map(|s| s.trim().to_string())
        .unwrap_or_else(|_| env!("CARGO_PKG_VERSION").to_string());
    println!("cargo:rerun-if-changed=../../VERSION");
    println!("cargo:rustc-env=WORKSPACE_VERSION={workspace_version}");

    println!("cargo:rustc-env=TILLANDSIAS_GIT_SHA={sha_full}");
    println!("cargo:rustc-env=TILLANDSIAS_BUILD_TIME={build_time}");

    // ORDER 1084-x8ya — bake in the digests of the guest binaries this tray
    // ships, so the host can key the host↔guest control channel to the guest
    // it is about to stage. The guest self-hashes what it runs; the host must
    // derive from that SAME digest or NNpsk0 fails closed with a perfectly
    // equal (build_version, wire_version, hop) triple, which is precisely the
    // bug that made every macOS and Windows install unable to reach Ready.
    //
    // Known at BUILD TIME on purpose, never read from a host file at runtime:
    // a runtime read would make the host agree with whatever guest happens to
    // be on disk and hide the skew a stale guest is supposed to reveal.
    // scripts/build-macos-tray.sh builds the guests first and exports these.
    //
    // TWO digests, selected at runtime by the same arch match guest_binary.rs
    // uses — the bundle ships an aarch64 and an x86_64 guest.
    println!("cargo:rerun-if-env-changed=TILLANDSIAS_GUEST_DIGEST_AARCH64_MUSL");
    println!("cargo:rerun-if-env-changed=TILLANDSIAS_GUEST_DIGEST_X86_64_MUSL");
    let guest_digest_aarch64 =
        std::env::var("TILLANDSIAS_GUEST_DIGEST_AARCH64_MUSL").unwrap_or_default();
    let guest_digest_x86_64 =
        std::env::var("TILLANDSIAS_GUEST_DIGEST_X86_64_MUSL").unwrap_or_default();

    // THE REFUSAL IS SCOPED AS TIGHTLY AS IT CAN BE, and the scoping is the
    // reason it is safe to fail the build at all:
    //   - target_os == macos : the crate compiles as a cfg-gated stub on Linux
    //                          and Windows, in every gate run on every host.
    //                          Those builds have no guest to key to.
    //   - PROFILE == release : debug builds use DEV_ROOT_SEED on BOTH ends, so
    //                          they interoperate without any digest. Every
    //                          `./build.sh --check`, every `cargo test`, every
    //                          fixture is debug and is untouched by this.
    //   - digests absent     : the sanctioned path always exports them.
    // Widening any of the three would red the fleet's gate to fix a macOS
    // keying bug, which is a trade nobody asked for.
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let is_release = std::env::var("PROFILE").unwrap_or_default() == "release";
    if target_os == "macos"
        && is_release
        && (guest_digest_aarch64.is_empty() || guest_digest_x86_64.is_empty())
    {
        panic!(
            "release macOS tray built without the guest digests — build through \
             scripts/build-macos-tray.sh, which builds the guests first"
        );
    }

    println!("cargo:rustc-env=TILLANDSIAS_GUEST_DIGEST_AARCH64_MUSL={guest_digest_aarch64}");
    println!("cargo:rustc-env=TILLANDSIAS_GUEST_DIGEST_X86_64_MUSL={guest_digest_x86_64}");

    // Re-run when HEAD moves so the embedded SHA stays accurate across
    // commits/branch switches. 765-uti9 quick win (velocity audit F6.1):
    // .git/index is deliberately NOT tracked — its mtime moves on every
    // `git add`/`status` refresh, and since this crate compiles (as a
    // cfg-gated stub) on every host, index churn was forcing a rebuild into
    // every gate run fleet-wide. Cost: the -dirty suffix can lag until the
    // next HEAD move — provenance for any COMMITTED state is unchanged.
    //
    // 765-evbt: suppress .git rerun directives in override mode — the SHA is
    // fixed by the caller and git activity must not bust the fingerprint.
    if override_mode.is_none() {
        println!("cargo:rerun-if-changed=../../.git/HEAD");
    }
}
