//! ORDER 1286-4437, re-scoped by 1437-8c6p / 1437-av8u — the macOS arm of
//! `--reset-state`, which is the SOFT reset (host-state-lifecycle, operator
//! rulings 2026-09-27 and 2026-10-08: "SOFT reset is the default only and
//! forever").
//!
//! CONTRACT, identical on all three platforms:
//!   * one flag name and one meaning everywhere;
//!   * the installer calls it AFTER the new app is in place, and calls nothing
//!     else — HARD is `--reset-guest`, a power-user flag no installer reaches;
//!   * it destroys DERIVED state only and preserves operator data: the VM and its
//!     guest (and so the guest-resident Vault store), the Keychain share and root
//!     token, the installation anchor, `nvram.bin` and the caches with the models;
//!   * it announces `reset: SOFT`, both lists and the store's disposition BEFORE
//!     touching anything, and calls no credential clearer;
//!   * `TILLANDSIAS_DESTRUCTIVE_RESET_OK=0` is the ONE affordance that skips it;
//!   * it reprovisions SYNCHRONOUSLY and the dispatch exits 1 on any Err.
//!
//! THE GUEST HALF IS DEFERRED TO THE NEXT BOOT, and that is the macOS platform
//! difference. Windows runs its in-distro wipe through `wsl.exe` before
//! re-provisioning. macOS has no host-to-guest shell (order 272: the control
//! wire is the only channel, and it needs a booted guest whose daemon is up),
//! so this body leaves a request with a fresh nonce in the guest-bin share
//! (`tillandsias_core::guest_bin_path::SOFT_RESET_REQUEST_FILE`). The guest
//! daemon, which the host re-injects on every boot, runs the Linux SOFT wipe
//! (`podman system reset --force` and the build markers) once per nonce before
//! it binds the control wire — so before the tray delivers the share and the
//! vault bootstraps, which is the ordering Windows' `soft_wipe_guest` documents
//! for the same reason. The installer opens the app right after this returns,
//! so "next boot" is seconds later.
//!
//! WHY THIS RETURNS `Result<(), String>` AND NOT `-> i32` LIKE ITS SIBLINGS.
//! `--reset-state` means the same thing on every platform, so it follows the
//! cross-platform convention (Linux's reprovision is `run_init`, which returns
//! `Result<(), String>`), not the local one. See tillandsias-core's reset-state
//! documentation.
//!
//! THE PRE-FLIGHT GUARD IS NOT VACUOUS EVEN THOUGH THIS CODE *IS* THE BINARY IT
//! CHECKS FOR. On macneo 2026-09-20 the installed app was observed GONE while
//! 1.2 GiB of VM state survived — cause never identified. A repair tool that
//! assumes the thing it repairs with is present is not a repair tool.

use std::path::{Path, PathBuf};

/// The Keychain items a SOFT reset KEEPS. Before 1437-8c6p this list was named
/// for the opposite: the reset cleared both, and with them every sign-in, on
/// every install (measured on the v56.10.9.1 smoke, 2026-10-09: "vault is
/// unsealed and serving (provisioning persisted from a prior boot)" before a
/// reinstall, "first boot: running vault operator init" after it).
const KEPT_CREDENTIALS: [&str; 2] = ["vault-shamir-share-v1", "vault-root-token-v1"];

/// PRESERVED. Anchors the INSTALLATION; the in-VM Vault derives its master key
/// from it, so clearing it makes the next vault underivable (803-49re). This
/// used to be "installation-uuid-v1", the LINUX name, while the tray stores the
/// anchor as `tillandsias-vm-uuid` (installation_uuid.rs); every macOS reset
/// therefore announced the anchor "ABSENT BEFORE THIS RESET" on hosts where it
/// was present (macbookair, v56.10.9.1 smoke). Named through the one constant
/// the tray writes, so the two cannot diverge again.
const PRESERVED_ANCHOR: &str = crate::installation_uuid::KEYCHAIN_ACCOUNT;

/// Host-side files a SOFT reset removes: records ABOUT the guest's past runs,
/// not inputs to it. `crashloop.state` must go so a reset breaks a crash-loop
/// latch (Windows' `reset_crashloop_state` is the same step); `heartbeat.state`
/// is rewritten by the next tray within one period. `provision/` is KEPT: it is
/// the kept guest's completion record, and without it the tray reports the
/// guest as never provisioned. `console.log` is the kept VM's console; only
/// HARD takes it, with the VM.
const DERIVED_HOST_FILES: [&str; 2] = ["heartbeat.state", "crashloop.state"];

fn caches_dir() -> Option<PathBuf> {
    std::env::var_os("HOME").map(|h| PathBuf::from(h).join("Library/Caches/tillandsias"))
}

/// The reprovision path this body will need. Checked FIRST, and named in the
/// refusal, so a broken host fails loudly with its state intact.
fn reprovision_path() -> PathBuf {
    PathBuf::from("/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray")
}

fn is_executable(p: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(p).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// What a macOS SOFT reset announces about the Vault store, from what the
/// Keychain answered. The three tokens are host-state-lifecycle's, an interface
/// shared with the Linux and Windows SOFT resets; do not respell them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SoftResetDisposition {
    VerifiedKeep,
    UnverifiedKeep,
    AbsentReinitAtInit,
}

impl SoftResetDisposition {
    pub(crate) fn from_share_read(read: &std::io::Result<Option<String>>) -> Self {
        match read {
            Ok(Some(share)) if !share.trim().is_empty() => Self::VerifiedKeep,
            Ok(_) => Self::AbsentReinitAtInit,
            Err(_) => Self::UnverifiedKeep,
        }
    }

    pub(crate) fn token(self) -> &'static str {
        match self {
            Self::VerifiedKeep => "Verified:KEEP",
            Self::UnverifiedKeep => "Unverified:KEEP",
            Self::AbsentReinitAtInit => "Absent:REINIT-AT-INIT",
        }
    }
}

/// The two announced sets of a macOS SOFT reset. Pure, so the split is tested
/// directly: the VM, the store, both Keychain items, the anchor and the caches
/// are on the PRESERVED side under every disposition, because a SOFT reset
/// deletes no store.
pub(crate) fn soft_reset_plan(
    disposition: SoftResetDisposition,
    image_root: &Path,
    caches: Option<&Path>,
    app: &Path,
) -> (Vec<String>, Vec<String>) {
    let mut destroyed = vec![
        "inside the guest, at its next boot: every podman container, image, volume, secret and \
         network (podman system reset --force)"
            .to_string(),
        "inside the guest: the build markers init-build-state.json and cache_version".to_string(),
    ];
    for f in DERIVED_HOST_FILES {
        destroyed.push(image_root.join(f).display().to_string());
    }
    let store_next = match disposition {
        SoftResetDisposition::VerifiedKeep => "your sign-ins survive the reset",
        SoftResetDisposition::UnverifiedKeep => {
            "kept; the Keychain could not be asked, so it unseals at the next init if the share is there"
        }
        SoftResetDisposition::AbsentReinitAtInit => {
            "kept by this reset, but no share is in the Keychain, so the next init re-initialises it"
        }
    };
    let mut preserved = vec![
        format!(
            "{} — the VM and its guest: rootfs.img, nvram.bin, provision/, console.log (no reprovision)",
            image_root.display()
        ),
        format!(
            "the Vault store inside the guest — {}, {store_next}",
            disposition.token()
        ),
        format!(
            "keychain: {} and {} — never cleared by a SOFT reset",
            KEPT_CREDENTIALS[0], KEPT_CREDENTIALS[1]
        ),
        format!("keychain: {PRESERVED_ANCHOR} — the installation anchor (803-49re)"),
    ];
    if let Some(c) = caches {
        preserved.push(format!(
            "{} — the download cache, models included",
            c.display()
        ));
    }
    preserved.push(format!("{} (the installed application)", app.display()));
    (destroyed, preserved)
}

/// The destructive half, against explicit roots so a test can run it on a
/// scratch tree. Removes [`DERIVED_HOST_FILES`] and, when a guest exists to act
/// on it, leaves the request with `nonce` in `guest_bin_dir`. Never touches
/// `rootfs.img`, the caches or the Keychain. With no guest there is nothing in
/// a guest to wipe, and the provisioning that follows creates a fresh one.
pub(crate) fn apply_soft_reset(
    image_root: &Path,
    guest_bin_dir: &Path,
    guest_present: bool,
    nonce: &str,
) -> Result<(), String> {
    for f in DERIVED_HOST_FILES {
        remove_file(&image_root.join(f))?;
    }
    if guest_present {
        std::fs::create_dir_all(guest_bin_dir)
            .map_err(|e| format!("reset-state: creating {}: {e}", guest_bin_dir.display()))?;
        let request = guest_bin_dir.join(tillandsias_core::guest_bin_path::SOFT_RESET_REQUEST_FILE);
        std::fs::write(&request, format!("{nonce}\n"))
            .map_err(|e| format!("reset-state: writing {}: {e}", request.display()))?;
    }
    Ok(())
}

pub fn run_reset_state() -> Result<(), String> {
    let app = reprovision_path();
    if !is_executable(&app) {
        // "{} {}": the shared constant already ENDS in a colon (v56.9.20.1
        // shipped "...not executable:: /Applications/..." from "{}: {}").
        return Err(format!(
            "{} {}",
            tillandsias_core::reset_state::RESET_NO_REPROVISION_PATH,
            app.display()
        ));
    }

    // ORDER 1315-d4qd — BEFORE the announcement: with HOME unset the root would
    // resolve under /tmp, and an announcement built from it is already a false
    // report whether or not anything is removed afterwards.
    let image_root = crate::diagnose::image_root_for_destruction()?;
    let caches = caches_dir();
    let vz = tillandsias_vm_layer::vz::VzRuntime::new(3, image_root.clone());
    let guest_present = vz.is_provisioned();

    let disposition = SoftResetDisposition::from_share_read(
        &crate::installation_uuid::read_credential_string(KEPT_CREDENTIALS[0]),
    );
    eprintln!("[tillandsias] reset: SOFT");
    let (destroyed, preserved) = soft_reset_plan(disposition, &image_root, caches.as_deref(), &app);
    let d: Vec<&str> = destroyed.iter().map(String::as_str).collect();
    let p: Vec<&str> = preserved.iter().map(String::as_str).collect();
    tillandsias_core::reset_state::announce_reset_plan(&d, &p);
    eprintln!("[tillandsias] reset disposition={}", disposition.token());
    if std::env::var_os("TILLANDSIAS_RESET_KEEP_MODELS").is_some() {
        eprintln!(
            "[tillandsias] TILLANDSIAS_RESET_KEEP_MODELS is ignored: a reset always preserves \
             models and every other download (spec: host-state-lifecycle)"
        );
    }

    if !tillandsias_core::reset_state::destructive_reset_allowed() {
        eprintln!("{}", tillandsias_core::reset_state::RESET_SKIPPED_LINE);
        return provision_now();
    }

    let nonce = format!(
        "{}-{}",
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or(0),
        std::process::id()
    );
    apply_soft_reset(
        &image_root,
        &tillandsias_core::guest_bin_path::guest_bin_dir(),
        guest_present,
        &nonce,
    )?;
    eprintln!(
        "[reset-state] derived state cleared (SOFT) — store and sign-ins kept; the guest \
         rebuilds its containers at its next boot"
    );
    provision_now()
}

fn provision_now() -> Result<(), String> {
    match crate::diagnose::provision_main() {
        0 => Ok(()),
        rc => Err(format!(
            "reset-state: reprovision failed (provision exited {rc}); re-run the installer or \
             `tillandsias-tray --provision`"
        )),
    }
}

/// Absent is success: this is a reset, and a file that is already gone is the
/// state we want. Only an existing file we cannot remove is an error.
fn remove_file(p: &Path) -> Result<(), String> {
    match std::fs::remove_file(p) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(format!("reset-state: removing {}: {e}", p.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(label: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!(
            "tillandsias-8c6p-{label}-{}-{}",
            std::process::id(),
            line!()
        ));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).expect("scratch dir");
        d
    }

    /// 1437-8c6p exit criterion, the part a unit test can reach: the SOFT body
    /// leaves the guest disk, the VM's records and the caches byte-identical,
    /// removes only the derived host files, and leaves the guest a request.
    /// Pre-fix: the body wiped rootfs.img, provision/ and the caches directory.
    #[test]
    fn soft_reset_keeps_the_guest_and_the_caches_and_removes_only_derived_files() {
        let root = scratch("soft");
        let image_root = root.join("Application Support/tillandsias");
        let caches = root.join("Caches/tillandsias");
        let guest_bin = root.join("guest-bin");
        std::fs::create_dir_all(image_root.join("provision")).unwrap();
        std::fs::create_dir_all(caches.join("models")).unwrap();
        let kept = [
            image_root.join("rootfs.img"),
            image_root.join("nvram.bin"),
            image_root.join("console.log"),
            image_root.join("provision/provision.state"),
            caches.join("models/m.gguf"),
        ];
        for k in &kept {
            std::fs::write(k, b"operator data").unwrap();
        }
        for f in DERIVED_HOST_FILES {
            std::fs::write(image_root.join(f), b"derived").unwrap();
        }

        apply_soft_reset(&image_root, &guest_bin, true, "nonce-1").unwrap();

        for k in &kept {
            assert_eq!(
                std::fs::read(k).unwrap(),
                b"operator data",
                "{} must survive a SOFT reset",
                k.display()
            );
        }
        for f in DERIVED_HOST_FILES {
            assert!(!image_root.join(f).exists(), "{f} is derived and must go");
        }
        let request = guest_bin.join(tillandsias_core::guest_bin_path::SOFT_RESET_REQUEST_FILE);
        assert_eq!(std::fs::read_to_string(&request).unwrap(), "nonce-1\n");
        let _ = std::fs::remove_dir_all(&root);
    }

    /// With no guest there is nothing to wipe inside one, so no request is left
    /// for the guest the next provisioning creates from scratch.
    #[test]
    fn soft_reset_without_a_guest_leaves_no_request() {
        let root = scratch("noguest");
        let guest_bin = root.join("guest-bin");
        apply_soft_reset(&root, &guest_bin, false, "nonce-2").unwrap();
        assert!(
            !guest_bin
                .join(tillandsias_core::guest_bin_path::SOFT_RESET_REQUEST_FILE)
                .exists()
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    /// The store, both Keychain items, the anchor and the caches are PRESERVED
    /// under every disposition, and nothing operator-owned is on the destroyed
    /// side.
    #[test]
    fn every_disposition_preserves_the_store_the_keychain_and_the_caches() {
        let image_root = Path::new("/h/Library/Application Support/tillandsias");
        let caches = Path::new("/h/Library/Caches/tillandsias");
        let app = Path::new("/Applications/Tillandsias.app/Contents/MacOS/tillandsias-tray");
        for disp in [
            SoftResetDisposition::VerifiedKeep,
            SoftResetDisposition::UnverifiedKeep,
            SoftResetDisposition::AbsentReinitAtInit,
        ] {
            let (destroyed, preserved) = soft_reset_plan(disp, image_root, Some(caches), app);
            let p = preserved.join("\n");
            for must in [
                "vault-shamir-share-v1",
                "vault-root-token-v1",
                "tillandsias-vm-uuid",
                "rootfs.img",
                "Caches/tillandsias",
                disp.token(),
            ] {
                assert!(p.contains(must), "{disp:?}: preserved side lacks {must}");
            }
            let d = destroyed.join("\n");
            for never in [
                "vault-shamir",
                "vault-root",
                "rootfs.img",
                "Caches/tillandsias",
                "nvram",
            ] {
                assert!(!d.contains(never), "{disp:?}: destroyed side names {never}");
            }
        }
    }

    #[test]
    fn disposition_follows_the_keychain_answer() {
        use SoftResetDisposition as D;
        assert_eq!(D::from_share_read(&Ok(Some("s".into()))), D::VerifiedKeep);
        assert_eq!(
            D::from_share_read(&Ok(Some("  ".into()))),
            D::AbsentReinitAtInit
        );
        assert_eq!(D::from_share_read(&Ok(None)), D::AbsentReinitAtInit);
        assert_eq!(
            D::from_share_read(&Err(std::io::Error::other("locked"))),
            D::UnverifiedKeep
        );
    }

    /// The SOFT body calls no credential clearer and no VM wipe. A source scan
    /// of the function body, because the property is an ABSENCE: the unit
    /// tests above exercise what it does, this pins what it must never do.
    #[test]
    fn run_reset_state_calls_no_clearer_and_no_guest_wipe() {
        let src = include_str!("reset_state.rs");
        let start = src.find("pub fn run_reset_state()").expect("body");
        let end = start + src[start..].find("\nfn provision_now()").expect("end");
        let body: String = src[start..end]
            .lines()
            .filter(|l| !l.trim_start().starts_with("//"))
            .collect::<Vec<_>>()
            .join("\n");
        for forbidden in [
            "delete_credential_string",
            "wipe_provisioned_artifacts",
            "remove_dir_all",
        ] {
            assert!(
                !body.contains(forbidden),
                "SOFT reset must not call {forbidden}"
            );
        }
    }
}
