//! The resources an on-demand image build may take (order 1776-d5k2, epic
//! 1776-ondm): a disk preflight before it, and a CPU/IO/memory scope during it.
//!
//! WHY. The operator: "actual build failures must NOT keep retrying and kill
//! host resources". `podman build` ran bare, so a forge-base build froze the
//! desktop of a 4-core floor-tier host (1770-z575, 863-iicc); and nothing
//! checked space before a build, so a full disk was found mid-build and the
//! panic text with it was lost (1744-xjfw).
//!
//! - DISK: before a build, free space on podman's graph root is compared with
//!   the image's declared need plus 1 GiB. Too little refuses with
//!   `refused:image-ensure:<image>:disk:<free>/<need>` and builds nothing.
//!   An unknown graph root or free space is not a refusal: the build runs.
//! - SCOPE: the build runs under `systemd-run --user --scope -p CPUWeight=50
//!   -p IOWeight=50 [-p MemoryHigh=<60% of MemTotal>]` when a probe shows the
//!   user manager answers, else under `nice -n 10` (a WSL2 guest, a container,
//!   a host without systemd). `TILLANDSIAS_IMAGE_BUILD_UNBOUNDED=1` runs it bare.
//!
//! @trace spec:podman-orchestration, order:1776-d5k2

use std::path::Path;
use std::sync::OnceLock;

/// The gate's opt-out: run `podman build` bare.
pub(crate) const UNBOUNDED_ENV: &str = "TILLANDSIAS_IMAGE_BUILD_UNBOUNDED";

/// The fixture seam: replace every image's declared need with this many bytes.
pub(crate) const DISK_NEED_OVERRIDE_ENV: &str = "TILLANDSIAS_IMAGE_DISK_NEED_OVERRIDE";

const GIB: u64 = 1024 * 1024 * 1024;

/// Headroom kept free on top of an image's need, so a build never fills the
/// store the running enclave writes to.
const DISK_HEADROOM: u64 = GIB;

/// What a build of `image` may write to the graph root, rounded up from
/// measured image sizes. Adjust with evidence.
pub(crate) fn image_disk_need(image: &str) -> u64 {
    let gib = match image {
        "forge-base" => 8,
        "chromium-core" | "flutter" => 6,
        "inference" => 4,
        "forge" | "chromium-framework" | "webkit" => 2,
        _ => 1,
    };
    gib * GIB
}

/// The need for `image`, honouring the fixture override.
fn need_for(image: &str) -> u64 {
    std::env::var(DISK_NEED_OVERRIDE_ENV)
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .unwrap_or_else(|| image_disk_need(image))
}

const MIB: u64 = 1024 * 1024;

/// The disk decision: `Some(refusal)` when `free` cannot hold `need` plus the
/// headroom. `None` free (the question could not be asked) never refuses.
pub(crate) fn disk_refusal(image: &str, free: Option<u64>, need: u64) -> Option<String> {
    let free = free?;
    let want = need.saturating_add(DISK_HEADROOM);
    (free < want).then(|| {
        format!(
            "refused:image-ensure:{image}:disk:{}MiB/{}MiB — podman's store has {} MiB free; \
             building {image} needs {} MiB plus {} MiB headroom. Free space in the podman \
             store (podman system prune, or remove unused images), then launch again",
            free / MIB,
            want / MIB,
            free / MIB,
            need / MIB,
            DISK_HEADROOM / MIB
        )
    })
}

/// The live disk check for a build of `image` about to start.
pub(crate) fn disk_preflight(image: &str, debug: bool) -> Result<(), String> {
    let Some(root) = graph_root() else {
        if debug {
            eprintln!(
                "[tillandsias] image-ensure {image}: podman's graph root is unknown; no disk preflight"
            );
        }
        return Ok(());
    };
    let free = crate::free_bytes_at(Path::new(root));
    match disk_refusal(image, free, need_for(image)) {
        Some(refusal) => Err(refusal),
        None => Ok(()),
    }
}

/// `podman info --format {{.Store.GraphRoot}}`, once per process.
fn graph_root() -> Option<&'static str> {
    static ROOT: OnceLock<Option<String>> = OnceLock::new();
    ROOT.get_or_init(|| {
        let out = tillandsias_podman::podman_cmd_sync()
            .args(["info", "--format", "{{.Store.GraphRoot}}"])
            .output_bounded(tillandsias_podman::OperationKind::Inspect.default_budget())
            .ok()?;
        if !out.status.success() {
            return None;
        }
        let root = String::from_utf8_lossy(&out.stdout).trim().to_string();
        (!root.is_empty()).then_some(root)
    })
    .as_deref()
}

/// How a build is bounded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum BuildScope {
    /// A transient systemd user scope with these properties.
    Systemd { memory_high: Option<u64> },
    /// `nice -n 10`.
    Nice,
    /// Bare, on the operator's opt-out.
    Unbounded,
}

/// The pure decision.
pub(crate) fn decide(unbounded: bool, systemd_usable: bool, mem_total: Option<u64>) -> BuildScope {
    if unbounded {
        BuildScope::Unbounded
    } else if systemd_usable {
        BuildScope::Systemd {
            memory_high: mem_total.map(|t| t / 10 * 6),
        }
    } else {
        BuildScope::Nice
    }
}

/// The wrapper argv that goes in front of the podman path.
pub(crate) fn prefix(scope: &BuildScope) -> Vec<String> {
    match scope {
        BuildScope::Unbounded => Vec::new(),
        BuildScope::Nice => vec!["nice".into(), "-n".into(), "10".into()],
        BuildScope::Systemd { memory_high } => {
            let mut argv: Vec<String> = [
                "systemd-run",
                "--user",
                "--scope",
                "--quiet",
                "-p",
                "CPUWeight=50",
                "-p",
                "IOWeight=50",
            ]
            .map(String::from)
            .to_vec();
            if let Some(bytes) = memory_high {
                argv.push("-p".into());
                argv.push(format!("MemoryHigh={bytes}"));
            }
            argv.push("--".into());
            argv
        }
    }
}

/// `MemTotal` from /proc/meminfo, in bytes.
fn mem_total() -> Option<u64> {
    let info = std::fs::read_to_string("/proc/meminfo").ok()?;
    let kib = info
        .lines()
        .find_map(|l| l.strip_prefix("MemTotal:"))?
        .trim()
        .trim_end_matches("kB")
        .trim()
        .parse::<u64>()
        .ok()?;
    Some(kib * 1024)
}

/// Can a user scope be created here? `systemd-run` on PATH is not enough: a
/// container or a WSL2 guest has the binary and no user manager. Asked once,
/// with a 5 s bound, by running `true` in a scope.
fn systemd_scope_usable() -> bool {
    use std::process::{Command, Stdio};
    let Ok(mut child) = Command::new("systemd-run")
        .args(["--user", "--scope", "--quiet", "--", "true"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
    };
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Ok(None) if std::time::Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(50))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
        }
    }
}

/// This process's scope for a build, decided once.
pub(crate) fn current() -> &'static BuildScope {
    static SCOPE: OnceLock<BuildScope> = OnceLock::new();
    SCOPE.get_or_init(|| {
        let unbounded = std::env::var(UNBOUNDED_ENV).as_deref() == Ok("1");
        decide(unbounded, !unbounded && systemd_scope_usable(), mem_total())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_store_without_room_refuses_and_names_free_and_need() {
        let need = image_disk_need("forge-base");
        assert_eq!(need, 8 * GIB);
        let refusal = disk_refusal("forge-base", Some(3 * GIB), need).expect("refused");
        assert!(
            refusal.starts_with("refused:image-ensure:forge-base:disk:3072MiB/9216MiB"),
            "{refusal}"
        );
        // Exactly need + headroom is enough; one byte less is not.
        assert_eq!(disk_refusal("web", Some(2 * GIB), GIB), None);
        assert!(disk_refusal("web", Some(2 * GIB - 1), GIB).is_some());
        // NEGATIVE CONTROL: an unknown free space never refuses.
        assert_eq!(disk_refusal("web", None, u64::MAX), None);
    }

    #[test]
    fn the_scope_prefers_systemd_then_nice_and_the_opt_out_wins() {
        assert_eq!(
            decide(false, true, Some(10 * GIB)),
            BuildScope::Systemd {
                memory_high: Some(6 * GIB)
            }
        );
        assert_eq!(decide(false, false, Some(10 * GIB)), BuildScope::Nice);
        assert_eq!(decide(true, true, Some(10 * GIB)), BuildScope::Unbounded);

        let argv = prefix(&decide(false, true, Some(10 * GIB))).join(" ");
        assert_eq!(
            argv,
            format!(
                "systemd-run --user --scope --quiet -p CPUWeight=50 -p IOWeight=50 -p MemoryHigh={} --",
                6 * GIB
            )
        );
        assert_eq!(
            prefix(&BuildScope::Systemd { memory_high: None }).join(" "),
            "systemd-run --user --scope --quiet -p CPUWeight=50 -p IOWeight=50 --"
        );
        assert_eq!(prefix(&BuildScope::Nice).join(" "), "nice -n 10");
        assert!(prefix(&BuildScope::Unbounded).is_empty());
    }
}
