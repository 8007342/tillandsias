//! ORDER 1420-inak — name the first-provision STAGE that failed.
//!
//! A user's clean MacBook (2026-09-27) downloaded the Fedora image and then went
//! red "failed to provision"; a retry did not help and there were NO logs to ask
//! for. Every host-side `run_start` error fed one chip (`🔴 <raw error>`), and a
//! guest-side provisioning failure after a successful boot rendered as a bare
//! `🔴 VM failed`. Five different faults — download, expand (a full disk), VM
//! start, guest binary staging, guest cloud-init — were indistinguishable at the
//! one surface a user can read aloud.
//!
//! This module turns each into a DISTINCT, stage-named line. It is pure string
//! logic with no macOS dependency, so its tests run on every host.

use tillandsias_vm_layer::vz::{FETCH_STAGE_DOWNLOAD, FETCH_STAGE_EXPAND, FETCH_STAGE_SPACE};

/// The first-provision stages a user-visible failure can be attributed to.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stage {
    /// Staging the embedded guest binary beside the image.
    GuestBinary,
    /// Downloading or SHA-256-verifying the Fedora Cloud image.
    ImageDownload,
    /// The pre-download free-space check refused (1420-299a).
    DiskSpace,
    /// Expanding the qcow2 into rootfs.img (where a full disk surfaces).
    ImageExpand,
    /// Any other image-setup step (manifest, mkdir).
    ImageSetup,
    /// Virtualization.framework refused or failed to start the VM.
    VmStart,
    /// The guest booted but its first-boot provisioning script failed.
    GuestProvisioning,
}

impl Stage {
    /// The short, user-facing stage name. Stable: support asks users to read it.
    pub fn label(self) -> &'static str {
        match self {
            Stage::GuestBinary => "Guest binary setup failed",
            Stage::ImageDownload => "Image download failed",
            Stage::DiskSpace => "Not enough disk space",
            Stage::ImageExpand => "Disk image setup failed",
            Stage::ImageSetup => "Image setup failed",
            Stage::VmStart => "VM failed to start",
            Stage::GuestProvisioning => "Guest provisioning failed",
        }
    }

    /// One line of what to try, per stage.
    pub fn hint(self) -> &'static str {
        match self {
            Stage::GuestBinary => "reinstall Tillandsias",
            Stage::ImageDownload => "check the network connection, then Retry",
            Stage::DiskSpace => "free up disk space, then Retry",
            Stage::ImageExpand => "free up disk space, then Retry",
            Stage::ImageSetup => "reinstall Tillandsias",
            Stage::VmStart => "quit other virtual machines, then Retry",
            Stage::GuestProvisioning => {
                "the VM could not finish setup (often network); see the log"
            }
        }
    }
}

/// Classify a `fetch_fedora_cloud_image` error by the stage prefix vm-layer puts
/// on it at the source. A prefix is a contract, not a guess from free text.
pub fn classify_fetch_error(msg: &str) -> Stage {
    if msg.starts_with(FETCH_STAGE_DOWNLOAD) {
        Stage::ImageDownload
    } else if msg.starts_with(FETCH_STAGE_SPACE) {
        Stage::DiskSpace
    } else if msg.starts_with(FETCH_STAGE_EXPAND) {
        Stage::ImageExpand
    } else {
        Stage::ImageSetup
    }
}

/// The full failure text: stage name, what happened, and what to try. This is
/// what goes to the log and the notification; the chip is clamped from it.
pub fn failure_text(stage: Stage, detail: &str) -> String {
    let detail = detail.trim();
    format!("{}: {detail} — {}", stage.label(), stage.hint())
}

/// The guest's own failure record (`provision.state` `phase failed`), named.
/// `line`/`rc`/`cmd` are what the guest's provisioning script recorded.
pub fn guest_failure_detail(line: Option<&str>, rc: Option<&str>, cmd: Option<&str>) -> String {
    let mut parts: Vec<String> = Vec::new();
    if let Some(c) = cmd.map(str::trim).filter(|c| !c.is_empty()) {
        parts.push(format!("`{c}`"));
    }
    if let Some(r) = rc.map(str::trim).filter(|r| !r.is_empty()) {
        parts.push(format!("exit {r}"));
    }
    if let Some(l) = line.map(str::trim).filter(|l| !l.is_empty()) {
        parts.push(format!("at script line {l}"));
    }
    if parts.is_empty() {
        "the guest recorded a failure but no step".to_string()
    } else {
        parts.join(", ")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 1420-inak criterion 1: five injected faults give five DISTINCT
    /// stage-named texts. Built from the same inputs each real site produces.
    #[test]
    fn five_faults_give_five_distinct_stage_named_texts() {
        let download = failure_text(
            classify_fetch_error(&format!(
                "{FETCH_STAGE_DOWNLOAD}sha256 mismatch: want aa got bb"
            )),
            "sha256 mismatch",
        );
        let expand = failure_text(
            classify_fetch_error(&format!(
                "{FETCH_STAGE_EXPAND}No space left on device (os error 28)"
            )),
            "No space left on device",
        );
        let guest_binary = failure_text(Stage::GuestBinary, "copy failed");
        let vm_start = failure_text(Stage::VmStart, "VZErrorDomain Code=2");
        let guest = failure_text(
            Stage::GuestProvisioning,
            &guest_failure_detail(Some("88"), Some("1"), Some("dnf install -y podman socat")),
        );
        let all = [&download, &expand, &guest_binary, &vm_start, &guest];
        for (i, a) in all.iter().enumerate() {
            for b in all.iter().skip(i + 1) {
                assert_ne!(a, b);
            }
        }
        assert!(download.starts_with("Image download failed:"), "{download}");
        assert!(
            expand.starts_with("Disk image setup failed:") && expand.contains("free up disk space"),
            "{expand}"
        );
        assert!(
            guest_binary.starts_with("Guest binary setup failed:"),
            "{guest_binary}"
        );
        assert!(vm_start.starts_with("VM failed to start:"), "{vm_start}");
        assert!(
            guest.starts_with("Guest provisioning failed:")
                && guest.contains("dnf install -y podman socat")
                && guest.contains("exit 1")
                && guest.contains("line 88"),
            "{guest}"
        );
    }

    /// Anything the fetch returns without a stage prefix is still NAMED, never
    /// misattributed to download or expand.
    /// Union of 1420-inak and 1420-299a: the pre-download space refusal is
    /// its OWN stage, never "Image setup failed … reinstall Tillandsias".
    #[test]
    fn the_space_refusal_is_named_as_disk_space_with_the_right_hint() {
        let msg = format!(
            "{FETCH_STAGE_SPACE}not enough free disk space for first provisioning: need 4.3 GB, have 1.1 GB free"
        );
        assert_eq!(classify_fetch_error(&msg), Stage::DiskSpace);
        let t = failure_text(classify_fetch_error(&msg), &msg);
        assert!(
            t.starts_with("Not enough disk space:") && t.contains("free up disk space"),
            "{t}"
        );
        assert!(!t.contains("reinstall"), "{t}");
    }

    #[test]
    fn an_unprefixed_fetch_error_is_image_setup_not_a_guess() {
        assert_eq!(
            classify_fetch_error("bundled manifest parse: bad toml"),
            Stage::ImageSetup
        );
        assert_eq!(
            classify_fetch_error("mkdir /x: permission denied"),
            Stage::ImageSetup
        );
    }

    #[test]
    fn a_guest_record_with_no_fields_still_says_something() {
        assert_eq!(
            guest_failure_detail(None, None, None),
            "the guest recorded a failure but no step"
        );
        assert_eq!(guest_failure_detail(None, Some(" 2 "), None), "exit 2");
    }
}
