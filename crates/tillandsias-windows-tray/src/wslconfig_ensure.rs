//! ORDER 1560-uam3: the WSL swap and memory-reclaim keys are hard
//! requirements, ensured in the user's runtime, not only at install.
//!
//! Operator, 2026-10-12: "HyperV and SWAP should not be prompts, our install
//! should add them forcibly as they're hard requirements ... as well as the
//! custom wsl.config file with progressive memory reap setting that we shouyd
//! ensure is present in user's runtime, at least for our own VM."
//!
//! `scripts/install-windows.ps1` (`Get-WslConfigMerge`, `Invoke-WslConfigEnsure`,
//! `Get-WslRestartDecision`) applies these rules at install; this module applies
//! the SAME rules at every tray startup, so a key the user (or a tool) removed
//! comes back. Keep the two rule sets identical:
//!
//! - `[wsl2] swap`: absent -> added; below the 8 GB floor (`swap=0` turns swap
//!   off) -> replaced; at or above it -> kept.
//! - `[wsl2] swapFile`: absent or empty -> added; any other path -> kept.
//! - `[experimental] sparseVhd`: anything but `true` -> `true`.
//! - `[experimental] autoMemoryReclaim`: anything but `gradual` -> `gradual`.
//! - `memory` and `processors` are the user's and never touched.
//!
//! An added key sits under a `# tillandsias:` comment; a replaced one under a
//! `# tillandsias: replaced <key>=<old>` comment. The backup
//! (`.wslconfig.tillandsias-bak`) is written BEFORE the file, and only when
//! something changed. Every detail goes to tray.log, never to a dialog.
//!
//! The installer sizes an added swap by free disk (8/16/24 GB); the tray
//! restores a missing one at the 8 GB floor, which always meets the
//! requirement and needs no disk probe.
//!
//! `.wslconfig` IS GLOBAL: WSL2 runs one utility VM for every distro, so "our
//! VM" is that shared VM, and swap and memory reclaim have no per-distro
//! equivalent. The keys apply at the VM's next start. `wsl --shutdown` is run
//! only when the `tillandsias` distro is the sole running one; another running
//! distro is never stopped (the keys then wait for the next WSL restart).
//!
//! Portable and not cfg-gated except [`ensure_at_startup`], so the rules are
//! tested on every host.

#![cfg_attr(not(target_os = "windows"), allow(dead_code))]

use std::io;
use std::path::{Path, PathBuf};

/// The swap floor, in GB.
pub const SWAP_FLOOR_GB: f64 = 8.0;

/// What a merge did, and the file it hands back.
#[derive(Debug, Clone, PartialEq)]
pub struct Merge {
    pub lines: Vec<String>,
    pub added: Vec<String>,
    pub replaced: Vec<String>,
    pub kept: Vec<String>,
}

impl Merge {
    pub fn changed(&self) -> bool {
        !self.added.is_empty() || !self.replaced.is_empty()
    }
}

/// A `.wslconfig` size ("8GB", "4096MB", "1TB", a bare byte count) in GB;
/// `None` when it does not parse. Same grammar as the installer's
/// `ConvertTo-WslSizeGB`.
pub fn size_gb(value: &str) -> Option<f64> {
    let v = value.trim();
    let upper = v.to_ascii_uppercase();
    let body = upper.strip_suffix('B').unwrap_or(&upper);
    let (num, unit) = match body.chars().last() {
        Some(c @ ('K' | 'M' | 'G' | 'T')) => (&body[..body.len() - 1], Some(c)),
        _ => (body, None),
    };
    let n: f64 = num.trim().parse().ok()?;
    if n < 0.0 || !num.trim().chars().all(|c| c.is_ascii_digit() || c == '.') {
        return None;
    }
    Some(match unit {
        Some('T') => n * 1024.0,
        Some('G') => n,
        Some('M') => n / 1024.0,
        Some('K') => n / 1_048_576.0,
        _ => n / 1_073_741_824.0,
    })
}

fn meets(key: &str, value: &str) -> bool {
    match key {
        "swap" => size_gb(value).is_some_and(|gb| gb >= SWAP_FLOOR_GB),
        "swapFile" => !value.trim().is_empty(),
        "sparseVhd" => value.trim().eq_ignore_ascii_case("true"),
        "autoMemoryReclaim" => value.trim().eq_ignore_ascii_case("gradual"),
        _ => true,
    }
}

/// Merge the hard-requirement keys into `.wslconfig` lines. Pure.
/// `swap_file` is a Windows path; it is written with doubled backslashes
/// because `.wslconfig` expands nothing.
pub fn merge(input: &[String], swap_file: &str, swap_gb: u32) -> Merge {
    let want: [(&str, [(&str, String); 2]); 2] = [
        (
            "wsl2",
            [
                ("swap", format!("{swap_gb}GB")),
                ("swapFile", swap_file.replace('\\', "\\\\")),
            ],
        ),
        (
            "experimental",
            [
                ("sparseVhd", "true".to_string()),
                ("autoMemoryReclaim", "gradual".to_string()),
            ],
        ),
    ];
    // Pass 1: where each section ends, and where each wanted key sits.
    let mut section = String::new();
    let mut present: std::collections::HashMap<String, Vec<usize>> = Default::default();
    let mut last_line: std::collections::HashMap<String, usize> = Default::default();
    for (i, raw) in input.iter().enumerate() {
        let t = raw.trim();
        if t.starts_with('[') && t.ends_with(']') && t.len() > 2 {
            section = t[1..t.len() - 1].trim().to_ascii_lowercase();
            last_line.insert(section.clone(), i);
            continue;
        }
        if t.is_empty() || t.starts_with('#') || t.starts_with(';') {
            continue;
        }
        if let Some((k, _)) = t.split_once('=') {
            let k = k.trim();
            if !k.is_empty() && !k.contains(char::is_whitespace) {
                present
                    .entry(format!("{section}/{}", k.to_ascii_lowercase()))
                    .or_default()
                    .push(i);
                last_line.insert(section.clone(), i);
            }
        }
    }
    let mut added = Vec::new();
    let mut replaced = Vec::new();
    let mut kept = Vec::new();
    let mut replace_at: std::collections::HashMap<usize, Vec<String>> = Default::default();
    let mut insert_after: std::collections::HashMap<usize, Vec<String>> = Default::default();
    let mut append_at_end: Vec<String> = Vec::new();
    for (sec, keys) in &want {
        let mut block = Vec::new();
        for (k, v) in keys {
            let pk = format!("{sec}/{}", k.to_ascii_lowercase());
            if let Some(idxs) = present.get(&pk) {
                for &idx in idxs {
                    let old = input[idx]
                        .trim()
                        .split_once('=')
                        .map(|(_, v)| v.trim())
                        .unwrap_or("");
                    if meets(k, old) {
                        if old != v {
                            kept.push(format!("[{sec}] {k}={old}"));
                        }
                    } else {
                        replace_at.insert(
                            idx,
                            vec![
                                format!("# tillandsias: replaced {k}={old} (hard requirement, order 1560-uam3)"),
                                format!("{k}={v}"),
                            ],
                        );
                        replaced.push(format!("[{sec}] {k}={old} -> {v}"));
                    }
                }
                continue;
            }
            block
                .push("# tillandsias: added by the Tillandsias tray (order 1560-uam3)".to_string());
            block.push(format!("{k}={v}"));
            added.push(format!("[{sec}] {k}={v}"));
        }
        if block.is_empty() {
            continue;
        }
        if let Some(&at) = last_line.get(*sec) {
            insert_after.entry(at).or_default().extend(block);
        } else {
            if !input.is_empty() || !append_at_end.is_empty() {
                append_at_end.push(String::new());
            }
            append_at_end.push(format!("[{sec}]"));
            append_at_end.extend(block);
        }
    }
    let mut lines = Vec::with_capacity(input.len() + 8);
    for (i, l) in input.iter().enumerate() {
        match replace_at.remove(&i) {
            Some(r) => lines.extend(r),
            None => lines.push(l.clone()),
        }
        if let Some(extra) = insert_after.remove(&i) {
            lines.extend(extra);
        }
    }
    lines.extend(append_at_end);
    Merge {
        lines,
        added,
        replaced,
        kept,
    }
}

/// May a changed `.wslconfig` be applied by restarting the shared WSL VM?
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RestartDecision {
    /// Nothing is running; the next VM boot reads the file.
    NoneRunning,
    /// Ours is the only running distro, so `wsl --shutdown` stops nothing of
    /// the user's.
    Restart,
    /// Another distro is running: never stop it; the keys wait for the next
    /// WSL restart.
    Deferred,
}

/// Same rule as the installer's `Get-WslRestartDecision`. `running` is the
/// `wsl --list --running --quiet` names.
pub fn restart_decision(running: &[&str], ours: &str) -> RestartDecision {
    let names: Vec<&str> = running
        .iter()
        .map(|n| n.trim())
        .filter(|n| !n.is_empty())
        .collect();
    if names.is_empty() {
        RestartDecision::NoneRunning
    } else if names.iter().all(|n| n.eq_ignore_ascii_case(ours)) {
        RestartDecision::Restart
    } else {
        RestartDecision::Deferred
    }
}

/// What [`ensure_file`] did on disk.
#[derive(Debug, Clone, PartialEq)]
pub struct FileOutcome {
    pub merge: Merge,
    /// The backup path, when an existing file was changed.
    pub backup: Option<PathBuf>,
}

/// The one write: read `path` (absent = empty), merge, and only when something
/// changed copy the backup FIRST, then write the file (UTF-8 without a BOM,
/// CRLF, as the installer's WriteAllLines does). A file that is not UTF-8 is
/// refused untouched rather than rewritten from a lossy read.
pub fn ensure_file(path: &Path, swap_file: &str, swap_gb: u32) -> io::Result<FileOutcome> {
    let input: Vec<String> = match std::fs::read(path) {
        Ok(bytes) => {
            let body = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&bytes);
            let text = std::str::from_utf8(body).map_err(|e| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    format!("{} is not UTF-8 ({e}); left untouched", path.display()),
                )
            })?;
            text.lines()
                .map(|l| l.trim_end_matches('\r').to_string())
                .collect()
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Vec::new(),
        Err(e) => return Err(e),
    };
    let merge = merge(&input, swap_file, swap_gb);
    let mut backup = None;
    if merge.changed() {
        if path.exists() {
            let mut b = path.as_os_str().to_owned();
            b.push(".tillandsias-bak");
            let b = PathBuf::from(b);
            std::fs::copy(path, &b)?;
            backup = Some(b);
        }
        let mut out = merge.lines.join("\r\n");
        out.push_str("\r\n");
        std::fs::write(path, out)?;
    }
    Ok(FileOutcome { merge, backup })
}

/// The tray-startup step. Resolves `%USERPROFILE%\.wslconfig` (or the
/// `TILLANDSIAS_WSLCONFIG_PATH` scratch seam, for a live check that must not
/// touch the real file), ensures the keys, logs what changed, and restarts the
/// shared VM only when that stops nothing but our distro. A scratch path never
/// restarts anything: WSL does not read it. Never fails startup.
#[cfg(target_os = "windows")]
pub fn ensure_at_startup() {
    let seam = std::env::var_os("TILLANDSIAS_WSLCONFIG_PATH").filter(|v| !v.is_empty());
    let scratch = seam.is_some();
    let path = match seam {
        Some(p) => PathBuf::from(p),
        None => match std::env::var_os("USERPROFILE") {
            Some(home) => PathBuf::from(home).join(".wslconfig"),
            None => {
                tracing::warn!(
                    "wslconfig: USERPROFILE is unset; swap and memory-reclaim keys not checked"
                );
                return;
            }
        },
    };
    let swap_file = match std::env::var_os("LOCALAPPDATA") {
        Some(l) => {
            let dir = PathBuf::from(l).join("tillandsias");
            let _ = std::fs::create_dir_all(&dir);
            dir.join("wsl-swap.vhdx").display().to_string()
        }
        None => {
            tracing::warn!(
                "wslconfig: LOCALAPPDATA is unset; swap and memory-reclaim keys not checked"
            );
            return;
        }
    };
    let outcome = match ensure_file(&path, &swap_file, SWAP_FLOOR_GB as u32) {
        Ok(o) => o,
        Err(e) => {
            tracing::warn!(path = %path.display(), error = %e, "wslconfig: could not ensure the swap and memory-reclaim keys");
            return;
        }
    };
    for a in &outcome.merge.added {
        tracing::info!(path = %path.display(), "wslconfig: added {a}");
    }
    for r in &outcome.merge.replaced {
        tracing::info!(path = %path.display(), "wslconfig: replaced {r} (hard requirement)");
    }
    for k in &outcome.merge.kept {
        tracing::info!(path = %path.display(), "wslconfig: present and kept: {k}");
    }
    if !outcome.merge.changed() {
        tracing::info!(path = %path.display(), "wslconfig: swap and memory-reclaim requirements already met");
        return;
    }
    if let Some(b) = &outcome.backup {
        tracing::info!(backup = %b.display(), "wslconfig: backup written first");
    }
    if scratch {
        tracing::info!(
            "wslconfig: scratch path (TILLANDSIAS_WSLCONFIG_PATH); WSL does not read it, so nothing is restarted"
        );
        return;
    }
    let mut cmd = tillandsias_vm_layer::wsl_command_sync();
    cmd.args(["--list", "--running", "--quiet"]);
    tillandsias_vm_layer::no_window_sync(&mut cmd);
    let running = match cmd.output() {
        Ok(o) => String::from_utf8_lossy(&o.stdout).into_owned(),
        Err(e) => {
            tracing::info!(error = %e, "wslconfig: could not list running distros; the keys apply at the next WSL restart");
            return;
        }
    };
    let names: Vec<&str> = running.lines().collect();
    match restart_decision(&names, crate::wsl_lifecycle::DISTRO_NAME) {
        RestartDecision::NoneRunning => {
            tracing::info!("wslconfig: no WSL distro running; the keys apply when WSL next starts");
        }
        RestartDecision::Deferred => {
            tracing::info!(running = %names.join(", ").trim(), "wslconfig: other WSL distros are running; the keys apply at the next WSL restart");
        }
        RestartDecision::Restart => {
            let mut sd = tillandsias_vm_layer::wsl_command_sync();
            sd.arg("--shutdown");
            tillandsias_vm_layer::no_window_sync(&mut sd);
            match sd.status() {
                Ok(s) => {
                    tracing::info!(status = %s, "wslconfig: only the tillandsias distro was running; restarted WSL so the keys apply now")
                }
                Err(e) => {
                    tracing::warn!(error = %e, "wslconfig: wsl --shutdown failed; the keys apply at the next WSL restart")
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SF: &str = r"C:\Users\u\AppData\Local\tillandsias\wsl-swap.vhdx";

    fn lines(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }
    fn count(m: &Merge, s: &str) -> usize {
        m.lines.iter().filter(|l| l.as_str() == s).count()
    }

    #[test]
    fn an_empty_file_gains_the_four_keys_in_their_sections() {
        let m = merge(&[], SF, 8);
        assert_eq!(m.added.len(), 4, "{m:?}");
        assert_eq!(
            m.lines
                .iter()
                .filter(|l| l.starts_with("# tillandsias:"))
                .count(),
            4
        );
        let wsl2 = m.lines.iter().position(|l| l == "[wsl2]").unwrap();
        let exp = m.lines.iter().position(|l| l == "[experimental]").unwrap();
        let swap = m.lines.iter().position(|l| l == "swap=8GB").unwrap();
        let reclaim = m
            .lines
            .iter()
            .position(|l| l == "autoMemoryReclaim=gradual")
            .unwrap();
        assert!(wsl2 < swap && swap < exp && exp < reclaim, "{:?}", m.lines);
        assert_eq!(
            count(
                &m,
                r"swapFile=C:\\Users\\u\\AppData\\Local\\tillandsias\\wsl-swap.vhdx"
            ),
            1
        );
    }

    #[test]
    fn a_swap_below_the_floor_is_replaced_in_place() {
        for old in ["4GB", "0", "2048MB"] {
            let m = merge(
                &lines(&["[wsl2]", "memory=8GB", &format!("swap={old}")]),
                SF,
                8,
            );
            assert_eq!(count(&m, "swap=8GB"), 1, "{old}: {:?}", m.lines);
            assert_eq!(count(&m, &format!("swap={old}")), 0, "{old}");
            assert!(
                m.lines[2].starts_with(&format!("# tillandsias: replaced swap={old}")),
                "{:?}",
                m.lines
            );
            assert_eq!(m.replaced.len(), 1, "{old}");
            assert!(
                !m.added.iter().any(|a| a.starts_with("[wsl2] swap=")),
                "{old}"
            );
        }
    }

    #[test]
    fn a_swap_at_or_above_the_floor_and_a_user_swapfile_are_kept() {
        let m = merge(
            &lines(&["[wsl2]", "swap=16GB", r"swapFile=D:\\swap.vhdx"]),
            SF,
            8,
        );
        assert_eq!(count(&m, "swap=16GB"), 1);
        assert_eq!(count(&m, r"swapFile=D:\\swap.vhdx"), 1);
        assert!(m.replaced.is_empty(), "{m:?}");
        assert!(m.kept.iter().any(|k| k == "[wsl2] swap=16GB"), "{m:?}");
    }

    #[test]
    fn reclaim_and_sparse_must_be_ours_and_memory_processors_are_never_touched() {
        let input = lines(&[
            "[wsl2]",
            "memory=4GB",
            "processors=2",
            "",
            "[experimental]",
            "sparseVhd=false",
            "autoMemoryReclaim=dropcache",
        ]);
        let m = merge(&input, SF, 8);
        assert_eq!(count(&m, "sparseVhd=true"), 1);
        assert_eq!(count(&m, "autoMemoryReclaim=gradual"), 1);
        assert_eq!(
            count(&m, "sparseVhd=false") + count(&m, "autoMemoryReclaim=dropcache"),
            0
        );
        assert_eq!(m.replaced.len(), 2);
        assert_eq!(count(&m, "memory=4GB"), 1);
        assert_eq!(count(&m, "processors=2"), 1);
    }

    #[test]
    fn a_second_merge_changes_nothing() {
        for input in [
            lines(&[]),
            lines(&[
                "[wsl2]",
                "swap=0",
                "",
                "[experimental]",
                "autoMemoryReclaim=disabled",
            ]),
        ] {
            let once = merge(&input, SF, 8);
            let twice = merge(&once.lines, SF, 8);
            assert!(!twice.changed(), "{twice:?}");
            assert_eq!(twice.lines, once.lines);
        }
    }

    #[test]
    fn reclaim_under_wsl2_is_inert_so_experimental_still_gets_it() {
        let m = merge(&lines(&["[wsl2]", "autoMemoryReclaim=gradual"]), SF, 8);
        assert!(
            m.added
                .iter()
                .any(|a| a == "[experimental] autoMemoryReclaim=gradual"),
            "{m:?}"
        );
    }

    #[test]
    fn size_grammar_matches_the_installer() {
        assert_eq!(size_gb("8GB"), Some(8.0));
        assert_eq!(size_gb("8gb"), Some(8.0));
        assert_eq!(size_gb("4096MB"), Some(4.0));
        assert_eq!(size_gb("1TB"), Some(1024.0));
        assert_eq!(size_gb("0"), Some(0.0));
        assert_eq!(size_gb("8G"), Some(8.0));
        assert_eq!(size_gb("lots"), None);
        assert_eq!(size_gb(""), None);
    }

    #[test]
    fn the_shared_vm_restarts_only_when_ours_is_the_sole_running_distro() {
        assert_eq!(
            restart_decision(&[], "tillandsias"),
            RestartDecision::NoneRunning
        );
        assert_eq!(
            restart_decision(&["", "  "], "tillandsias"),
            RestartDecision::NoneRunning
        );
        assert_eq!(
            restart_decision(&["tillandsias"], "tillandsias"),
            RestartDecision::Restart
        );
        assert_eq!(
            restart_decision(&["tillandsias", "Ubuntu"], "tillandsias"),
            RestartDecision::Deferred
        );
        assert_eq!(
            restart_decision(&["tillandsias-build"], "tillandsias"),
            RestartDecision::Deferred
        );
    }

    #[test]
    fn ensure_file_backs_up_first_and_leaves_a_compliant_file_alone() {
        let dir = tempfile::tempdir().unwrap();
        // Absent: created, no backup.
        let absent = dir.path().join("absent.wslconfig");
        let o = ensure_file(&absent, SF, 8).unwrap();
        assert!(o.merge.changed() && o.backup.is_none());
        assert!(
            std::fs::read_to_string(&absent)
                .unwrap()
                .contains("autoMemoryReclaim=gradual")
        );
        // Conflicting: backup byte-identical, rewrite without BOM, conflicts gone.
        let conflict = dir.path().join("conflict.wslconfig");
        let orig = "[wsl2]\nmemory=8GB\nswap=0\n\n[experimental]\nautoMemoryReclaim=disabled\n";
        std::fs::write(&conflict, orig).unwrap();
        let o = ensure_file(&conflict, SF, 8).unwrap();
        let bak = o.backup.expect("a changed existing file is backed up");
        assert_eq!(std::fs::read_to_string(&bak).unwrap(), orig);
        let after = std::fs::read(&conflict).unwrap();
        assert_ne!(after.first(), Some(&0xEF));
        let after = String::from_utf8(after).unwrap();
        assert!(
            after.contains("swap=8GB\r\n") && !after.contains("swap=0\r\n"),
            "{after}"
        );
        // Compliant: untouched, no backup.
        let good = dir.path().join("good.wslconfig");
        std::fs::write(&good, &after).unwrap();
        let o = ensure_file(&good, SF, 8).unwrap();
        assert!(!o.merge.changed() && o.backup.is_none());
        assert_eq!(std::fs::read_to_string(&good).unwrap(), after);
        assert!(!dir.path().join("good.wslconfig.tillandsias-bak").exists());
    }

    #[test]
    fn a_non_utf8_file_is_refused_untouched() {
        let dir = tempfile::tempdir().unwrap();
        let p = dir.path().join("utf16.wslconfig");
        let bytes = [0xFF, 0xFE, b'[', 0, b'w', 0];
        std::fs::write(&p, bytes).unwrap();
        assert!(ensure_file(&p, SF, 8).is_err());
        assert_eq!(std::fs::read(&p).unwrap(), bytes);
    }
}
